#!/bin/sh
#
# Entrypoint for running CLIProxyAPI as a unikernel on Unikraft Cloud.
#
# The unikernel root filesystem is read-only. A persistent volume is
# attached at /data (see .github/workflows/unikraft-deploy.yml). This
# script seeds the volume with a configuration file on first boot and
# then starts the server against it, so all later changes made through
# the management panel (including OAuth credential files) survive
# restarts and redeploys.
#
# Environment variables provided by the deploy workflow:
#   DEPLOY=cloud              Enables CLIProxyAPI cloud deploy mode.
#   MANAGEMENT_PASSWORD=...   Enables the remote management panel.
#   WRITABLE_PATH=/data       Directs writable state (management panel
#                             assets, fallback stores) onto the volume.

set -eu

APP_BIN="/CLIProxyAPI/CLIProxyAPI"
APP_DIR="/CLIProxyAPI"
DATA_DIR="${CPA_DATA_DIR:-/data}"
CONFIG_FILE="${CPA_CONFIG_FILE:-$DATA_DIR/config.yaml}"

mkdir -p "$DATA_DIR"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[unikraft-entrypoint] no configuration found, seeding $CONFIG_FILE"
    if [ -f "$APP_DIR/config.example.yaml" ]; then
        cp "$APP_DIR/config.example.yaml" "$CONFIG_FILE"
        # Keep credential files on the persistent volume.
        sed -i "s|^auth-dir:.*|auth-dir: $DATA_DIR/auths|" "$CONFIG_FILE"
    else
        # Minimal fallback so cloud deploy mode does not idle forever.
        cat > "$CONFIG_FILE" <<EOF
host: ""
port: 8317
auth-dir: $DATA_DIR/auths
EOF
    fi
fi

mkdir -p "$DATA_DIR/auths"

# Self-heal a broken TLS block before the server reads it.
#
# The management panel's visual editor writes the TLS switch under
# `server.tls` (v8 layout). Saving with the switch on but no certificate
# paths persists an unbootable config: the server refuses to start with
# "tls.cert or tls.key is empty" and the instance crash-loops. On Unikraft
# Cloud TLS is terminated at the platform edge (443 -> 8317/http+tls), so
# instance-level TLS must stay off. Flip the switch back when cert or key
# is missing/empty, covering both the legacy top-level `tls:` block and the
# v8 `server.tls` block. A block with real cert/key paths is left untouched.
fix_broken_tls_config() {
    cfg_path="$1"
    [ -f "$cfg_path" ] || return 0
    # Cheap gate: only run the block parser when a suspicious `enable: true`
    # coexists with a `tls:` block anywhere in the file, otherwise leave the
    # config byte-identical.
    grep -Eq '^[[:space:]]*tls:' "$cfg_path" 2>/dev/null || return 0
    grep -Eq '^[[:space:]]*enable:[[:space:]]*"?true' "$cfg_path" 2>/dev/null || return 0
    tmp_cfg="$(mktemp "${cfg_path}.XXXXXX")" || return 0
    if awk '
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function flush(   i) {
    if (!capture) { return }
    if (en_idx && (cert_bad || key_bad)) { sub(/true/, "false", buf[en_idx]) }
    for (i = 1; i <= n; i++) { print buf[i] }
    n = 0; capture = 0; en_idx = 0; cert_bad = 1; key_bad = 1
}
BEGIN { capture = 0; n = 0; sec0 = "" }
{
    raw = $0
    t = raw; sub(/^[ \t]+/, "", t)
    ind = length(raw) - length(t)
    if (t == "" || substr(t, 1, 1) == "#") {
        if (capture) { buf[++n] = raw } else { print raw }
        next
    }
    if (capture && ind > tls_ind) {
        buf[++n] = raw
        colon = index(t, ":")
        if (colon > 0) {
            ck = trim(substr(t, 1, colon - 1))
            cv = trim(substr(t, colon + 1))
            sub(/[ \t]*#.*$/, "", cv); cv = trim(cv)
            if (ck == "enable" && (cv == "true" || cv == "\"true\"")) { en_idx = n }
            if (ck == "cert") { if (cv == "" || cv == "\"\"" || cv == "null" || cv == "~") { cert_bad = 1 } else { cert_bad = 0 } }
            if (ck == "key")  { if (cv == "" || cv == "\"\"" || cv == "null" || cv == "~") { key_bad = 1 }  else { key_bad = 0 } }
        }
        next
    }
    if (capture) { flush() }
    colon = index(t, ":")
    key = t; rest = ""
    if (colon > 0) {
        key = trim(substr(t, 1, colon - 1))
        rest = trim(substr(t, colon + 1))
        sub(/[ \t]*#.*$/, "", rest); rest = trim(rest)
    }
    if (ind == 0) { sec0 = key }
    if (key == "tls" && rest == "" && ((ind == 0 && sec0 == "tls") || (ind > 0 && sec0 == "server"))) {
        capture = 1; tls_ind = ind; n = 0; en_idx = 0; cert_bad = 1; key_bad = 1
        buf[++n] = raw
        next
    }
    print raw
}
END { flush() }
' "$cfg_path" > "$tmp_cfg" 2>/dev/null; then
        if cmp -s "$cfg_path" "$tmp_cfg"; then
            rm -f "$tmp_cfg" || true
        else
            if cat "$tmp_cfg" > "$cfg_path"; then
                echo "[unikraft-entrypoint] repaired config: tls.enable was true with empty cert/key; forced to false (TLS is terminated by Unikraft Cloud on :443)"
            else
                echo "[unikraft-entrypoint] warning: failed to rewrite $cfg_path" >&2
            fi
            rm -f "$tmp_cfg" || true
        fi
    else
        rm -f "$tmp_cfg" || true
        echo "[unikraft-entrypoint] warning: TLS config check failed; continuing with existing config" >&2
    fi
    return 0
}

fix_broken_tls_config "$CONFIG_FILE" || true

echo "[unikraft-entrypoint] starting CLIProxyAPI with config: $CONFIG_FILE"
exec "$APP_BIN" --config "$CONFIG_FILE"
