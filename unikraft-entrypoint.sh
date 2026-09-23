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

echo "[unikraft-entrypoint] starting CLIProxyAPI with config: $CONFIG_FILE"
exec "$APP_BIN" --config "$CONFIG_FILE"
