# Unikraft 部署说明

本 fork 在上游 CLIProxyAPI 基础上增加了把服务部署到 [Unikraft Cloud](https://unikraft.cloud)（unikernel 云平台）所需的全部文件，上游源码零改动，因此随时可以与上游 `Sync fork` 无冲突同步。

---

## 一、与上游相比新增的文件

| 文件 | 作用 |
|---|---|
| `Dockerfile.unikraft` | Unikraft 专用镜像构建：`CGO_ENABLED=0 -buildmode=pie` 纯静态 PIE 二进制 + Alpine 最小根文件系统（含 CA 证书、时区数据）。**unikernel 根文件系统只读且无动态链接器，必须静态 PIE**；CGO 关闭意味着动态库插件不可用（默认配置本来也没开） |
| `unikraft-entrypoint.sh` | 入口脚本：首次启动时把 `config.example.yaml` 种子化到持久卷 `/data/config.yaml`（auth-dir 改写为 `/data/auths`），再以 `--config /data/config.yaml` 启动服务。配置、OAuth 凭据、管理面板资源全部落在卷上，重启/重新部署不丢 |
| `Kraftfile` | `unikraft build` 的必需入口（stable 版 CLI 不认裸 Dockerfile）：`runtime: base-compat:latest` + `rootfs.source: ./Dockerfile.unikraft` + `erofs` 只读打包 + `cmd` 指向入口脚本 |
| `.github/workflows/unikraft-deploy.yml` | 一键构建部署流水线（详见下文） |
| `Unikraft 部署说明.md` | 本文档 |

上游的 `Dockerfile` / `docker-compose.yml` 等原文件未做任何修改。

## 二、需要填的机密与变量

位置：仓库 **Settings → Secrets and variables → Actions**。

> ⚠ **必须是 Repository 级**（Secrets 标签页的 "Actions secrets" / Variables 标签页的 "Actions variables"），**不是** Environment secrets/variables——本 workflow 没有声明 `environment:`，Environment 里加的读不到。

**Secrets（必填，2 个）：**

| 名称 | 说明 |
|---|---|
| `UKC_TOKEN` | Unikraft Cloud 的 API token。console.unikraft.cloud → 组织/账户设置里生成 |
| `MANAGEMENT_PASSWORD` | 管理面板登录密码，自己定的强密码。云上面板 `https://<域名>/management.html` 用它登录，同时也是 Management API 的鉴权密钥。建议纯字母数字（会作为环境变量传给实例） |

**Variables（可选，都有默认值）：**

| 名称 | 默认 | 说明 |
|---|---|---|
| `UKC_METRO` | `sfo` | 部署区域（美西旧金山）。改区域要删实例+卷重建，见"坑" |
| `UKC_ORG` | `nero` | Unikraft Cloud 组织名 = 镜像命名空间。控制台 URL `/org/<名字>/` 可查 |
| `UKC_DOMAIN` | 无（随机域名） | 自定义子域前缀，如 `cpa` → `cpa.sfo.unikraft.app`。⚠ 只认 **Variables 标签页底部 "Actions variables" 的 Repository variable**（对应 workflow 的 `vars.*`）；顶部 Environment variables 和 Secrets 标签页加了都读不到。需配合手动触发勾选 `recreate_instance` 生效，见第七节"切换自定义域名" |

## 三、部署要点（流水线做了什么）

触发条件：push 到 `main` 且命中路径清单（4 个部署文件 + Go 源码 + go.mod/go.sum），或手动 Actions → Run workflow。步骤：

1. 校验 Secrets 是否齐全（缺了会明确报错）
2. `unikraft/setup-action@v1` 安装 CLI 并登录
3. 解析镜像引用（组织名**强制转小写**，原因见坑 1）→ `unikraft build .` 用 BuildKit 构建 unikernel 镜像并推送到 `unikraft.io/nero/cliproxyapi:latest`
4. 确保持久卷 `cliproxyapi-data`（512 MiB）存在，不存在则创建
5. 实例 `cliproxyapi` 已存在则原地更新（换镜像+环境变量+重启），否则创建：`-m 512`、`-p 443:8317/http+tls`（平台边缘终结 TLS）、挂卷 `/data`、`--scale-to-zero policy=off`（不休眠）、`--restart=on-failure`
6. 输出实例详情和启动日志到 run summary

实例环境变量：`DEPLOY=cloud`（云部署模式）、`MANAGEMENT_PASSWORD`（启用远程管理面板，绕过 config 里的 `allow-remote` 限制）、`WRITABLE_PATH=/data`（把管理面板资源下载等可写状态导到卷）。

**首次启动流程**：入口脚本种子化默认配置 → 服务起来但处于 **safe mode**（默认配置里 `api-keys` 是示例值，代理端点禁用）→ 浏览器打开 `https://<域名>/management.html`，用 `MANAGEMENT_PASSWORD` 登录 → 修改 `api-keys` 为你自己的密钥（写入卷，持久）→ 代理端点开放。之后在面板里添加各 AI 账号（OAuth 登录/凭据文件都落卷）。

**客户端接入**：OpenAI 兼容端点为 `https://<域名>/v1/...`，API Key 用你在面板里设置的 `api-keys` 值。

## 四、可调项

| 项目 | 调整方式 |
|---|---|
| 区域 | Variables 加 `UKC_METRO`（fra/iad/sfo/sin 等，以控制台为准）。**已部署后修改不会迁移**——需删实例、删卷后重跑（见坑 7） |
| 内存 | 改 workflow 里 `MEMORY_MB`（当前 512，MiB），下次部署生效 |
| 卷大小 | 改 `VOLUME_SIZE_MB`（当前 512，MiB）。只影响新建卷 |
| 休眠 | 当前 `--scale-to-zero policy=off` 常驻运行（7×24 计费）。想省钱改回 `policy=on,cooldown-time=<毫秒>`，闲时缩零、请求毫秒级唤醒 |
| 自定义子域 | Repository variable 加 `UKC_DOMAIN`（如 `cpa`）→ Actions → Run workflow → 勾选 **recreate_instance**（自动删实例重建，卷原样挂回，凭据不丢，只换域名）。详见第七节"切换自定义域名" |
| 完全自有域名 | 用 `unikraft certificates create` 上传证书 + DNS 解析，进阶用法 |
| 镜像 tag | 当前固定 `:latest`，每次构建覆盖 |

## 五、踩过的坑（及可能踩的坑）

1. **组织名大写 = 灾难**：CLI 的镜像名解析沿用 Docker reference 规则，首段含**大写字母会被判定为 registry 主机名**（`NERO-Tsui/cliproxyapi` 被当主机去 DNS 解析）。OCI 路径本来也要求全小写。workflow 已自动转小写，若手动用 CLI 操作注意
2. **`unikraft build` 必须有 Kraftfile**：stable 版 CLI 不会回退到裸 Dockerfile（prod-staging 源码刚加这功能还没发布），报 `no kraftfile found`
3. **必须静态 PIE**：`-buildmode=pie`，且 `CGO_ENABLED=0`。普通 `go build` 产物（非 PIE）unikernel 加载不了
4. **Secrets/Variables 加错位置**：加到 Environment 那套里 workflow 读不到（见第二节的大警告）
5. **Secrets 未填时首跑必失败**：这是设计好的检查步骤，报错会告诉你缺哪个
6. **fork 里上游自带的 workflow 会报红**（docker-image.yml 等缺上游 secrets），与本部署无关，去 Actions 页面逐个 Disable 即可
7. **换 metro 不迁移资源**：实例和卷都属于特定 metro。换区 = 删实例 + 删卷 → 改 `UKC_METRO` → 重跑 → **auths 凭据全部丢失**，需在面板重新登录各账号
8. **删实例 ≠ 删卷**：重新部署/删除实例，卷上的配置和凭据都在；但删除卷 = 凭据清零
9. **镜像推送 401** = 命名空间不对：核对控制台组织名（`UKC_ORG`），注意全小写
10. **safe mode**：`api-keys` 还是示例值时所有代理端点返回禁用提示，这是防呆设计，不是故障
11. **`.sh` 脚本必须 LF 行尾**：CRLF 会让 unikernel 里的 sh 报错。仓库 autocrlf 提交时自动转 LF；若在 Windows 手工编辑注意别引入 CRLF
12. **管理面板资源是运行时从 GitHub 下载的**：首次冷启动需要几秒；镜像里已带 CA 证书所以出站 HTTPS 正常
13. **并发部署**：workflow 有 concurrency 组，同时多次触发会排队不会互相覆盖
14. **UKC_DOMAIN 放错位置不生效**：workflow 的 `${{ vars.* }}` 只读 Variables 标签页底部的 **Repository variables**。放错的三种情况都读不到——Variables 标签页顶部的 Environment variables（需 job 声明 `environment:`，本 workflow 未声明）、Secrets 标签页的 Repository secrets、顶部的 Environment secrets
15. **自定义子域被他人占用**：create 步骤直接红叉失败，Actions 日志显示平台报错（`set -euo pipefail` 保证不会静默）。recreate 模式下旧实例已删，回退办法见第七节"切换自定义域名"末尾

## 六、已部署镜像与资源的删除方式

CLI（需要 darwin/Linux，Windows 用 WSL2；或全部用控制台 UI 操作）：

```bash
# 删除实例（保留卷，配置/凭据不丢）
unikraft instances delete cliproxyapi

# 删除持久卷（⚠ 配置和全部 OAuth 凭据清零）
unikraft volumes delete cliproxyapi-data

# 删除自动创建的服务组（域名随之释放）
unikraft services list          # 找到 cliproxyapi 对应的 service group 名称
unikraft services delete <service-group-name>

# 删除推送的镜像
unikraft images delete nero/cliproxyapi:latest
```

控制台路径：console.unikraft.cloud → 对应 metro 的 Instances / Volumes / Services / Images 页面。

彻底退订 = 四样全删（实例、卷、服务组、镜像）。

## 七、全流程与维护手册

### 首次部署（已完成，存档参考）

1. Fork 并改名为 `CLIProxyAPI-unikraft`，克隆到本地
2. 新增 4 个部署文件（见第一节），push 到 `main`
3. 填 2 个 Secrets（`UKC_TOKEN`、`MANAGEMENT_PASSWORD`）
4. Actions 手动触发 Unikraft Cloud Deploy → 构建镜像、建卷、建实例
5. 打开 `https://<fqdn>/management.html` → 登录 → 改 `api-keys` → 添加 AI 账号
6. 客户端配置 `https://<fqdn>/v1` + 你的 api-key

### 日常更新

- **改了本仓库部署文件/上游同步后自动部署**：push 到 `main` 命中触发路径即自动跑；或在 Actions 页面手动 Run workflow
- **与上游同步**：GitHub 仓库页面 Sync fork → 更新 `main` → 自动触发重新构建部署（新增文件与上游零冲突）
- **只改配置/加账号**：无需重新部署，面板操作直接落卷生效

### 切换自定义域名

域名（service group 的 FQDN）属于 create-only 字段，已存在的实例无法直接修改，需要删除并重建实例：

1. **确认变量位置**：Settings → Secrets and variables → Actions → **Variables 标签页底部 "Actions variables"** → `UKC_DOMAIN=cpa`。若之前加在 Environment variables 或 Secrets 标签页，删掉错误条目后在此处重建（放错位置的值 workflow 读不到）
2. **手动触发重建**：Actions → Unikraft Cloud Deploy → Run workflow → 勾选 **recreate_instance** → Run。流程自动完成：删旧实例 → 清理旧服务组（随机域名随之释放）→ 等待卷释放 → 以新域名重建实例（卷原样挂回，api-keys 和已添加账号全部保留）。整个过程约 1-2 分钟中断
3. **验证**：run summary 中实例 `service.domains` 应为 `cpa.sfo.unikraft.app`；`curl https://cpa.sfo.unikraft.app/v1/models` 返回模型列表
4. **更新客户端**：把所有客户端的 base URL 从旧随机域名改为 `https://cpa.sfo.unikraft.app`（旧域名随之失效）

> **若前缀已被占用**：create 步骤红叉失败并在日志显示平台报错，此时旧实例已删。回退：删除/清空 `UKC_DOMAIN` 变量，再勾选 recreate_instance 重跑（恢复随机域名服务）；或换个前缀重试。平台没有跨账户域名占用预检接口，只能创建时试错。
>
> **换 metro（区域）**也用 recreate_instance，但额外要求：旧 metro 的卷不能跨区挂载，须先删卷（⚠ 凭据丢失，需重新登录各账号），改 `UKC_METRO` 后勾选 recreate 重跑（workflow 会自动在新区域重建卷）。

### 回滚

Actions → Unikraft Cloud Deploy → 找到历史上某次绿色的 run → 右上角 **Re-run all jobs**（重跑使用当时的 commit 重建镜像并替换实例，数据卷不受影响）。

### 重置全部凭据

更新 `MANAGEMENT_PASSWORD`（如需）→ 删除实例 → 删除卷 → 重跑 workflow → 等于全新首次部署（重新在面板配置）。

### 常用排查

```bash
unikraft instances logs cliproxyapi          # 运行日志（入口脚本输出在开头）
unikraft instances get cliproxyapi -o yaml   # 实例详情（含域名、状态）
unikraft instances restart cliproxyapi      # 手动重启
```

| 症状 | 处置 |
|---|---|
| 实例日志出现 `standing by for configuration` | `/data/config.yaml` 没种上：检查卷是否挂载成功 |
| 面板打不开 | 核对 `MANAGEMENT_PASSWORD` secret 是否设置、实例是否 running |
| 请求 401 | 客户端 api-key 与配置不符；或代理端点仍在 safe mode |
| 构建失败 | 看 Actions 日志；多数是 Secrets/变量问题（报错有提示） |
