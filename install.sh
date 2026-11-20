#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

RELEASE_BASE_URL="${CLIPROXY_RELEASE_BASE_URL:-}"
RELEASE_API_URL="${CLIPROXY_RELEASE_API_URL:-}"
RELEASE_LATEST_URL="${CLIPROXY_RELEASE_LATEST_URL:-https://github.com/zhangzhangjun/clp-combination/releases/latest}"
INSTALL_DIR="${CLIPROXY_INSTALL_DIR:-/opt/cliproxyapi}"
SERVICE_NAME="cliproxyapi"
SERVICE_USER="cliproxyapi"

die() {
  echo "CLIProxyAPI installer: $*" >&2
  exit 1
}

for command_name in tar sha256sum awk id od tr sed head grep useradd chown chmod cp mv rmdir mkdir mktemp rm systemd-tmpfiles; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  die "curl or wget is required"
fi
command -v systemctl >/dev/null 2>&1 || die "systemd/systemctl is required on this server"
[[ "$(uname -s)" == "Linux" ]] || die "this release installer supports Linux only"
[[ "$(id -u)" == "0" ]] || die "run as root, for example: sudo bash <(curl -fsSL .../install.sh)"
[[ "$INSTALL_DIR" == /* ]] || die "CLIPROXY_INSTALL_DIR must be an absolute path"
[[ "$INSTALL_DIR" != *[[:space:]]* ]] || die "CLIPROXY_INSTALL_DIR cannot contain spaces"
[[ "$INSTALL_DIR" != *[!A-Za-z0-9_./-]* ]] || die "CLIPROXY_INSTALL_DIR may only contain letters, numbers, dot, slash, underscore, and hyphen"
[[ ! -L "$INSTALL_DIR" ]] || die "refusing to install through a symbolic-link directory: $INSTALL_DIR"
if [[ -e "$INSTALL_DIR" && ! -d "$INSTALL_DIR" ]]; then
  die "installation path exists and is not a directory: $INSTALL_DIR"
fi

case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) die "unsupported CPU architecture: $(uname -m)" ;;
esac

download() {
  local url="$1"
  local destination="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fLsS --retry 3 --connect-timeout 15 "$url" -o "$destination"
  else
    wget -q --tries=3 --timeout=30 -O "$destination" "$url"
  fi
}

TEMP_DIR="$(mktemp -d)"
INSTALL_BINARY_TMP=""
cleanup() {
  if [[ -n "$INSTALL_BINARY_TMP" ]]; then
    rm -f -- "$INSTALL_BINARY_TMP"
  fi
  rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

RELEASE_TAG=""
if [[ -z "$RELEASE_BASE_URL" ]]; then
  if [[ -n "$RELEASE_API_URL" ]]; then
    RELEASE_JSON="$TEMP_DIR/latest-release.json"
    download "$RELEASE_API_URL" "$RELEASE_JSON" || die "failed to query the configured latest-release API"
    RELEASE_TAG="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$RELEASE_JSON" | head -n 1)"
  elif command -v curl >/dev/null 2>&1; then
    if LATEST_TARGET_URL="$(curl -fLsS --retry 3 --connect-timeout 15 -o /dev/null -w '%{url_effective}' "$RELEASE_LATEST_URL")"; then
      RELEASE_TAG="${LATEST_TARGET_URL##*/}"
    fi
    if [[ ! "$RELEASE_TAG" =~ ^v?[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$ ]]; then
      LATEST_PAGE="$TEMP_DIR/latest-release.html"
      download "$RELEASE_LATEST_URL" "$LATEST_PAGE" || die "failed to query the latest GitHub Release"
      RELEASE_TAG="$(grep -Eo '/zhangzhangjun/clp-combination/releases/tag/v?[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?' "$LATEST_PAGE" | head -n 1 | sed 's#^.*/##')"
    fi
  else
    LATEST_PAGE="$TEMP_DIR/latest-release.html"
    download "$RELEASE_LATEST_URL" "$LATEST_PAGE" || die "failed to query the latest GitHub Release"
    RELEASE_TAG="$(grep -Eo '/releases/tag/v?[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?' "$LATEST_PAGE" | head -n 1 | sed 's#^.*/##')"
  fi
  [[ "$RELEASE_TAG" =~ ^v?[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$ ]] || die "GitHub latest Release returned an invalid version tag"
  RELEASE_BASE_URL="https://github.com/zhangzhangjun/clp-combination/releases/download/$RELEASE_TAG"
  echo "Latest GitHub Release: $RELEASE_TAG"
fi

ARCHIVE_PATH="$TEMP_DIR/CLIProxyAPI-centos-${ARCH}.tar.gz"
CHECKSUM_PATH="$TEMP_DIR/CLIProxyAPI-centos-${ARCH}.sha256"
ARCHIVE_NAME=""
echo "Downloading CLIProxyAPI Linux/$ARCH release..."
for candidate in "CLIProxyAPI-centos-${ARCH}-${RELEASE_TAG}.tar.gz" "CLIProxyAPI-centos-${ARCH}.tar.gz"; do
  if ! download "${RELEASE_BASE_URL%/}/$candidate" "$ARCHIVE_PATH"; then
    continue
  fi
  candidate_checksum="$candidate.sha256"
  if download "${RELEASE_BASE_URL%/}/$candidate_checksum" "$CHECKSUM_PATH"; then
    ARCHIVE_NAME="$candidate"
    break
  fi
  rm -f -- "$ARCHIVE_PATH" "$CHECKSUM_PATH"
done
[[ -n "$ARCHIVE_NAME" ]] || die "GitHub Release ${RELEASE_TAG:-at the configured URL} has no downloadable CLIProxyAPI Linux/$ARCH package attachment; publish the package archive and its .sha256 file with buliu/build-release.bat"
echo "Using release package: $ARCHIVE_NAME"

EXPECTED_SHA="$(awk 'NR == 1 { print $1; exit }' "$CHECKSUM_PATH")"
[[ "$EXPECTED_SHA" =~ ^[[:xdigit:]]{64}$ ]] || die "invalid SHA256 file"
printf '%s  %s\n' "$EXPECTED_SHA" "$ARCHIVE_PATH" | sha256sum --check --status || die "release archive SHA256 verification failed"

ARCHIVE_ENTRIES="$(tar -tzf "$ARCHIVE_PATH")" || die "release archive is not a valid gzip tar file"
while IFS= read -r archive_entry; do
  case "$archive_entry" in
    /*|../*|*/../*|*/..) die "unsafe path in release archive: $archive_entry" ;;
  esac
done <<< "$ARCHIVE_ENTRIES"

# Feed awk with a here-string instead of a producer pipeline. With pipefail
# enabled, the early awk exit otherwise sends SIGPIPE to printf and makes the
# installer terminate with status 141 after a successful archive download.
PACKAGE_DIR_NAME="$(awk -F/ 'NF { print $1; exit }' <<< "$ARCHIVE_ENTRIES")"
[[ -n "$PACKAGE_DIR_NAME" && "$PACKAGE_DIR_NAME" != . && "$PACKAGE_DIR_NAME" != .. ]] || die "release archive has no package directory"
tar -xzf "$ARCHIVE_PATH" -C "$TEMP_DIR"
PACKAGE_DIR="$TEMP_DIR/$PACKAGE_DIR_NAME"
[[ -f "$PACKAGE_DIR/cli-proxy-api" ]] || die "release archive is missing its Linux executable"
[[ -f "$PACKAGE_DIR/config.example.yaml" ]] || die "release archive is missing config.example.yaml"
[[ -d "$PACKAGE_DIR/static" ]] || die "release archive is missing frontend assets"

mkdir -p "$INSTALL_DIR"
# Copy package data first, but never overwrite a running executable in place.
shopt -s dotglob nullglob
for package_entry in "$PACKAGE_DIR"/*; do
  [[ "${package_entry##*/}" == "cli-proxy-api" ]] && continue
  cp -a -- "$package_entry" "$INSTALL_DIR/"
done
shopt -u dotglob nullglob
mkdir -p "$INSTALL_DIR/auths" "$INSTALL_DIR/logs"

# Migrate legacy JSON auth files without following or relocating symlinks.
legacy_auth_dir="$INSTALL_DIR/.cli-proxy-api"
legacy_auth_count=0
if [[ -L "$legacy_auth_dir" ]]; then
  echo "Leaving legacy auth directory symlink untouched: $legacy_auth_dir" >&2
elif [[ -d "$legacy_auth_dir" ]]; then
  shopt -s nullglob dotglob
  for legacy_auth in "$legacy_auth_dir"/*.json; do
    [[ -e "$legacy_auth" || -L "$legacy_auth" ]] || continue
    legacy_name="${legacy_auth##*/}"
    if [[ -L "$legacy_auth" ]]; then
      echo "Leaving legacy auth symlink untouched: $legacy_auth" >&2
      continue
    fi
    if [[ ! -f "$legacy_auth" ]]; then
      echo "Leaving non-file legacy auth entry untouched: $legacy_auth" >&2
      continue
    fi
    if [[ -e "$INSTALL_DIR/auths/$legacy_name" || -L "$INSTALL_DIR/auths/$legacy_name" ]]; then
      echo "Keeping legacy auth file because the destination already exists: $legacy_name" >&2
      continue
    fi
    mv -- "$legacy_auth" "$INSTALL_DIR/auths/$legacy_name"
    legacy_auth_count=$((legacy_auth_count + 1))
  done
  shopt -u nullglob dotglob
  if (( legacy_auth_count > 0 )); then
    echo "Moved $legacy_auth_count legacy auth file(s) into $INSTALL_DIR/auths."
  fi
  if rmdir -- "$legacy_auth_dir" 2>/dev/null; then
    echo "Removed the now-empty legacy auth directory: $legacy_auth_dir"
  elif [[ -d "$legacy_auth_dir" ]]; then
    echo "Legacy auth directory retained because it still contains files or conflicts: $legacy_auth_dir" >&2
  fi
fi

GENERATED_API_KEY=""
GENERATED_MANAGEMENT_KEY=""
if [[ ! -f "$INSTALL_DIR/config.yaml" ]]; then
  CONFIG_TEMPLATE="$INSTALL_DIR/config.zh-CN.yaml"
  if [[ ! -f "$CONFIG_TEMPLATE" ]]; then
    CONFIG_TEMPLATE="$INSTALL_DIR/config.example.yaml"
    echo "Chinese config template is unavailable in this release; using config.example.yaml." >&2
  fi
  cp "$CONFIG_TEMPLATE" "$INSTALL_DIR/config.yaml"
  GENERATED_API_KEY="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
  GENERATED_MANAGEMENT_KEY="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
  sed -i "s/^  secret-key: \"\"$/  secret-key: \"$GENERATED_MANAGEMENT_KEY\"/" "$INSTALL_DIR/config.yaml"
  awk -v key="$GENERATED_API_KEY" '
    /^api-keys:[[:space:]]*$/ { print; print "  - \"" key "\""; in_api_keys = 1; next }
    in_api_keys && /^  - / { next }
    in_api_keys && /^[^[:space:]#]/ { in_api_keys = 0 }
    { print }
  ' "$INSTALL_DIR/config.yaml" > "$INSTALL_DIR/config.yaml.tmp"
  mv "$INSTALL_DIR/config.yaml.tmp" "$INSTALL_DIR/config.yaml"
fi

# Keep paths and logging behavior consistent on both fresh installs and upgrades.
# The release ships a version-matched management panel; prevent the startup updater
# from replacing it with a separately released upstream panel.
awk -v auth_dir="$INSTALL_DIR/auths" -v logs_dir="$INSTALL_DIR/logs" '
  BEGIN { values["auth-dir"] = "\"" auth_dir "\""; values["logs-dir"] = "\"" logs_dir "\""; values["commercial-mode"] = "true"; values["logging-to-file"] = "true"; in_remote_management = 0 }
  {
    if ($0 ~ /^remote-management:[[:space:]]*$/) {
      in_remote_management = 1
      print
      next
    }
    if ($0 ~ /^[^[:space:]#]/) in_remote_management = 0
    if (in_remote_management && $0 ~ /^  disable-auto-update-panel:[[:space:]]*/) {
      print "  disable-auto-update-panel: true"
      found_panel_update_setting = 1
      next
    }
    key = $0
    sub(/:.*/, "", key)
    if ($0 ~ /^[^[:space:]#][^:]*:/ && key in values) {
      print key ": " values[key]
      found[key] = 1
      next
    }
    print
  }
  END {
    for (key in values) if (!found[key]) print key ": " values[key]
  }
' "$INSTALL_DIR/config.yaml" > "$INSTALL_DIR/config.yaml.tmp"
mv "$INSTALL_DIR/config.yaml.tmp" "$INSTALL_DIR/config.yaml"

if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  useradd --system --user-group --home-dir "$INSTALL_DIR" --shell /sbin/nologin "$SERVICE_USER"
fi

# Stage the new binary on the same filesystem and atomically swap its directory
# entry. Replacing the inode with rename(2) avoids ETXTBSY when the old binary is
# still running under systemd during an upgrade.
INSTALL_BINARY_TMP="$(mktemp "$INSTALL_DIR/.cli-proxy-api.new.XXXXXX")"
cp -- "$PACKAGE_DIR/cli-proxy-api" "$INSTALL_BINARY_TMP"
chmod 755 "$INSTALL_BINARY_TMP"
chown "$SERVICE_USER" "$INSTALL_BINARY_TMP"
mv -f -- "$INSTALL_BINARY_TMP" "$INSTALL_DIR/cli-proxy-api"
INSTALL_BINARY_TMP=""

# Keep the encryption key in the service's persistent EnvironmentFile so a
# first install can save protected automation checkpoints and upgrades reuse
# the same key instead of making existing encrypted data unreadable.
DATA_ENV_FILE="$INSTALL_DIR/.env"
[[ ! -L "$DATA_ENV_FILE" ]] || die "refusing to use a symbolic-link environment file: $DATA_ENV_FILE"
if [[ ! -e "$DATA_ENV_FILE" ]]; then
  : > "$DATA_ENV_FILE"
fi
[[ -f "$DATA_ENV_FILE" ]] || die "service environment path is not a regular file: $DATA_ENV_FILE"
if ! awk '
  /^[[:space:]]*XIANYU_DATA_KEY[[:space:]]*=/ {
    value = $0
    sub(/^[^=]*=/, "", value)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
    if (value != "" && value != "\"\"" && value != "\047\047" && value !~ /^#/) configured = 1
  }
  END { exit !configured }
' "$DATA_ENV_FILE"; then
  # Generate 256 random bits using od, which is already required by this installer.
  GENERATED_XIANYU_DATA_KEY="$(od -An -N32 -tx1 /dev/urandom | tr -d '[:space:]')"
  [[ "$GENERATED_XIANYU_DATA_KEY" =~ ^[[:xdigit:]]{64}$ ]] || die "failed to generate XIANYU_DATA_KEY"
  printf '\nXIANYU_DATA_KEY=%s\n' "$GENERATED_XIANYU_DATA_KEY" >> "$DATA_ENV_FILE"
  unset GENERATED_XIANYU_DATA_KEY
  echo "Generated persistent XIANYU_DATA_KEY in $DATA_ENV_FILE"
fi
chmod 600 "$DATA_ENV_FILE"

chown -R "$SERVICE_USER" "$INSTALL_DIR"
chmod 600 "$INSTALL_DIR/config.yaml"
chmod 755 "$INSTALL_DIR/cli-proxy-api"
# Nginx serves the public panel files directly through an alias, while the
# CLIProxyAPI service runs with UMask=0077. Make only the public static tree
# readable/traversable so every install or upgrade keeps those aliased assets
# accessible to the separate Nginx worker account.
chmod -R a+rX -- "$INSTALL_DIR/static"

SYSTEMD_UNIT_DIR="${CLIPROXY_SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
mkdir -p "$SYSTEMD_UNIT_DIR"
SERVICE_FILE="$SYSTEMD_UNIT_DIR/${SERVICE_NAME}.service"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=CLIProxyAPI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=-$INSTALL_DIR/.env
ExecStart=$INSTALL_DIR/cli-proxy-api -config $INSTALL_DIR/config.yaml
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
UMask=0077
NoNewPrivileges=true
ReadWritePaths=$INSTALL_DIR

[Install]
WantedBy=multi-user.target
EOF

# The API process cannot restart its own systemd cgroup. It stages verified
# files, then creates a marker in this root-owned, service-group-writable
# directory. The path unit starts a fixed root worker which only restarts this
# service and rolls the staged files back if systemd cannot bring it up.
UPDATE_TMPFILES="${CLIPROXY_TMPFILES_DIR:-/etc/tmpfiles.d}"
UPDATE_WORKER_DIR="${CLIPROXY_UPDATE_WORKER_DIR:-/usr/local/libexec}"
UPDATE_STATUS_DIR="${CLIPROXY_UPDATE_STATUS_DIR:-/run/cliproxyapi-update}"
UPDATE_ROOT_STATUS_DIR="${CLIPROXY_UPDATE_ROOT_STATUS_DIR:-/var/lib/cliproxyapi-update}"
for managed_path in "$SYSTEMD_UNIT_DIR" "$UPDATE_TMPFILES" "$UPDATE_WORKER_DIR" "$UPDATE_STATUS_DIR" "$UPDATE_ROOT_STATUS_DIR"; do
  [[ "$managed_path" == /* && "$managed_path" =~ ^/[A-Za-z0-9_./-]+$ ]] || die "invalid automatic-update system path: $managed_path"
done
mkdir -p "$UPDATE_TMPFILES" "$UPDATE_WORKER_DIR" "$UPDATE_ROOT_STATUS_DIR"
chown root:root "$UPDATE_ROOT_STATUS_DIR"
chmod 755 "$UPDATE_ROOT_STATUS_DIR"
UPDATE_TMPFILES_FILE="$UPDATE_TMPFILES/cliproxyapi-update.conf"
UPDATE_WORKER="$UPDATE_WORKER_DIR/cliproxyapi-update-worker"
UPDATE_SERVICE_FILE="$SYSTEMD_UNIT_DIR/cliproxyapi-restart.service"
UPDATE_PATH_FILE="$SYSTEMD_UNIT_DIR/cliproxyapi-restart.path"

printf 'd %s 2730 root %s -\n' "$UPDATE_STATUS_DIR" "$SERVICE_USER" > "$UPDATE_TMPFILES_FILE"
cat > "$UPDATE_WORKER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
INSTALL_DIR="$CLIPROXY_INSTALL_DIR"
SYSTEMCTL_PATH="$(command -v systemctl)"
SERVICE_NAME="cliproxyapi"
UPDATE_STATUS_DIR="$CLIPROXY_UPDATE_STATUS_DIR"
UPDATE_ROOT_STATUS_DIR="$CLIPROXY_UPDATE_ROOT_STATUS_DIR"
REQUEST_FILE="$UPDATE_STATUS_DIR/request"
ROOT_STATUS="$UPDATE_ROOT_STATUS_DIR/restart-status.json"
[[ "$INSTALL_DIR" == /* && "$UPDATE_STATUS_DIR" == /* && "$UPDATE_ROOT_STATUS_DIR" == /* ]] || exit 1
rm -f -- "$REQUEST_FILE"
rm -f -- "$ROOT_STATUS"
# Nginx reads the published frontend through an alias, while the update worker
# itself runs with umask 077.  Normalize only the static frontend tree before
# restarting the service so a successful update cannot publish unreadable
# 600/700 assets and leave the management page blank.
normalize_static_permissions() {
  local static_dir="$INSTALL_DIR/static"
  [[ -d "$static_dir" ]] || return 0
  find "$static_dir" -type d -exec chmod 755 {} +
  find "$static_dir" -type f -exec chmod 644 {} +
}
normalize_static_permissions
write_root_status() {
  local status="$1"
  local version="$2"
  local message="$3"
  local tmp
  tmp="$(mktemp "$UPDATE_ROOT_STATUS_DIR/.restart-status.XXXXXX")"
  printf '{"status":"%s","version":"%s","message":"%s"}\n' "$status" "$version" "$message" > "$tmp"
  chmod 644 "$tmp"
  mv -f -- "$tmp" "$ROOT_STATUS"
}
rollback() {
  "$SYSTEMCTL_PATH" stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  if [[ -f "$INSTALL_DIR/.cli-proxy-api.previous" && ! -L "$INSTALL_DIR/.cli-proxy-api.previous" ]]; then
    mv -f -- "$INSTALL_DIR/.cli-proxy-api.previous" "$INSTALL_DIR/cli-proxy-api"
  fi
  if [[ -d "$INSTALL_DIR/static.previous" && ! -L "$INSTALL_DIR/static.previous" ]]; then
    rm -rf -- "$INSTALL_DIR/static.failed"
    if [[ -d "$INSTALL_DIR/static" ]]; then mv -- "$INSTALL_DIR/static" "$INSTALL_DIR/static.failed"; fi
    mv -- "$INSTALL_DIR/static.previous" "$INSTALL_DIR/static"
    rm -rf -- "$INSTALL_DIR/static.failed"
  fi
  if [[ -f "$INSTALL_DIR/.VERSION.txt.previous" && ! -L "$INSTALL_DIR/.VERSION.txt.previous" ]]; then
    mv -f -- "$INSTALL_DIR/.VERSION.txt.previous" "$INSTALL_DIR/VERSION.txt"
  fi
  normalize_static_permissions
  "$SYSTEMCTL_PATH" reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
  "$SYSTEMCTL_PATH" start "$SERVICE_NAME" >/dev/null 2>&1 || true
  write_root_status "failed" "" "service restart failed; previous files were restored" || true
}
PREVIOUS_RESTARTS="$("$SYSTEMCTL_PATH" show --property=NRestarts "$SERVICE_NAME" 2>/dev/null | sed -n 's/^NRestarts=//p' | head -n 1)"
PREVIOUS_PID="$("$SYSTEMCTL_PATH" show --property=MainPID "$SERVICE_NAME" 2>/dev/null | sed -n 's/^MainPID=//p' | head -n 1)"
if ! "$SYSTEMCTL_PATH" restart "$SERVICE_NAME"; then
  rollback
  exit 1
fi
sleep 15
MAIN_PID="$("$SYSTEMCTL_PATH" show --property=MainPID "$SERVICE_NAME" 2>/dev/null | sed -n 's/^MainPID=//p' | head -n 1)"
CURRENT_RESTARTS="$("$SYSTEMCTL_PATH" show --property=NRestarts "$SERVICE_NAME" 2>/dev/null | sed -n 's/^NRestarts=//p' | head -n 1)"
if ! "$SYSTEMCTL_PATH" is-active --quiet "$SERVICE_NAME" || [[ ! "$MAIN_PID" =~ ^[1-9][0-9]*$ ]] || [[ "$MAIN_PID" == "$PREVIOUS_PID" ]] || [[ "$PREVIOUS_RESTARTS" =~ ^[0-9]+$ && "$CURRENT_RESTARTS" =~ ^[0-9]+$ && "$CURRENT_RESTARTS" != "$PREVIOUS_RESTARTS" ]]; then
  rollback
  exit 1
fi
CURRENT_VERSION="$(tr -d '\r\n' < "$INSTALL_DIR/VERSION.txt")"
if ! write_root_status "success" "$CURRENT_VERSION" ""; then
  rollback
  exit 1
fi
rm -f -- "$INSTALL_DIR/.cli-proxy-api.previous" "$INSTALL_DIR/.VERSION.txt.previous"
rm -rf -- "$INSTALL_DIR/static.previous"
EOF

cat > "$UPDATE_SERVICE_FILE" <<EOF
[Unit]
Description=Restart CLIProxyAPI after a verified self-update

[Service]
Type=oneshot
ExecStart=$UPDATE_WORKER
Environment=CLIPROXY_INSTALL_DIR=$INSTALL_DIR
Environment=CLIPROXY_UPDATE_STATUS_DIR=$UPDATE_STATUS_DIR
Environment=CLIPROXY_UPDATE_ROOT_STATUS_DIR=$UPDATE_ROOT_STATUS_DIR
TimeoutStartSec=240
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=CAP_DAC_OVERRIDE CAP_FOWNER
ReadWritePaths=$INSTALL_DIR $UPDATE_STATUS_DIR $UPDATE_ROOT_STATUS_DIR
EOF

cat > "$UPDATE_PATH_FILE" <<EOF
[Unit]
Description=Watch for a verified CLIProxyAPI update restart request

[Path]
PathExists=$UPDATE_STATUS_DIR/request
Unit=cliproxyapi-restart.service

[Install]
WantedBy=multi-user.target
EOF

chown root:root "$UPDATE_WORKER" "$UPDATE_SERVICE_FILE" "$UPDATE_PATH_FILE" "$UPDATE_TMPFILES_FILE"
chmod 750 "$UPDATE_WORKER"
chmod 644 "$UPDATE_SERVICE_FILE" "$UPDATE_PATH_FILE" "$UPDATE_TMPFILES_FILE"
systemd-tmpfiles --create "$UPDATE_TMPFILES_FILE"

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null
systemctl enable --now cliproxyapi-restart.path >/dev/null
if systemctl is-active --quiet "$SERVICE_NAME"; then
  systemctl restart "$SERVICE_NAME"
else
  systemctl start "$SERVICE_NAME"
fi
systemctl is-active --quiet "$SERVICE_NAME" || {
  systemctl --no-pager --full status "$SERVICE_NAME" || true
  die "service did not become active; inspect with: journalctl -u $SERVICE_NAME -n 100"
}

echo "CLIProxyAPI is running as a systemd service: $SERVICE_NAME"
echo "Install directory: $INSTALL_DIR"
echo "API endpoint: http://<server-ip>:8317"
if [[ -n "$GENERATED_API_KEY" ]]; then
  echo "Generated client API key: $GENERATED_API_KEY"
  echo "Generated management key: $GENERATED_MANAGEMENT_KEY"
  echo "Save these keys now; the management key is stored hashed after first startup."
fi
echo "Useful commands: systemctl status $SERVICE_NAME; journalctl -u $SERVICE_NAME -f"
