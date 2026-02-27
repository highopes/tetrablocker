#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
WORKDIR="$(pwd)"

BIN_SRC="${WORKDIR}/tetrablocker"
CONF_SRC="${WORKDIR}/tetrablocker.conf"
UNIT_SRC="${WORKDIR}/tetrablocker.service"

BIN_DST="/usr/local/bin/tetrablocker"
CONF_DST="/etc/tetrablocker/tetrablocker.conf"
UNIT_DST="/etc/systemd/system/tetrablocker.service"

CONF_DIR="/etc/tetrablocker"
POLICY_DIR="/etc/tetragon/tetragon.tp.d"

log() { echo "[$SCRIPT_NAME] $*"; }
die() { echo "[$SCRIPT_NAME] ERROR: $*" >&2; exit 1; }

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "must run as root (try: sudo $SCRIPT_NAME)"
  fi
}

check_inputs() {
  [[ -f "$BIN_SRC" ]] || die "missing file: $BIN_SRC"
  [[ -f "$CONF_SRC" ]] || die "missing file: $CONF_SRC"
  [[ -f "$UNIT_SRC" ]] || die "missing file: $UNIT_SRC"
}

backup_if_exists() {
  local path="$1"
  if [[ -e "$path" ]]; then
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    cp -a "$path" "${path}.bak.${ts}"
  fi
}

stop_service_if_running() {
  if systemctl list-unit-files | awk '{print $1}' | grep -qx "tetrablocker.service"; then
    if systemctl is-active --quiet tetrablocker; then
      log "stopping service: tetrablocker"
      systemctl stop tetrablocker
    fi
  fi
}

install_files() {
  log "installing binary -> $BIN_DST"
  backup_if_exists "$BIN_DST"
  install -m 0755 "$BIN_SRC" "$BIN_DST"

  log "installing config -> $CONF_DST"
  install -d -m 0755 "$CONF_DIR"
  backup_if_exists "$CONF_DST"
  install -m 0644 "$CONF_SRC" "$CONF_DST"

  log "installing systemd unit -> $UNIT_DST"
  backup_if_exists "$UNIT_DST"
  install -m 0644 "$UNIT_SRC" "$UNIT_DST"
}

ensure_dirs_from_conf() {
  install -d -m 0755 "$POLICY_DIR"

  local state_dir allowlist_file allowlist_dir
  state_dir="$(python3 - <<'PY'
import json
p="/etc/tetrablocker/tetrablocker.conf"
try:
    with open(p,"r",encoding="utf-8") as f:
        obj=json.load(f)
    print(obj.get("state_dir") or "/var/lib/tetrablocker")
except Exception:
    print("/var/lib/tetrablocker")
PY
  )"
  install -d -m 0755 "$state_dir"

  allowlist_file="$(python3 - <<'PY'
import json
p="/etc/tetrablocker/tetrablocker.conf"
try:
    with open(p,"r",encoding="utf-8") as f:
        obj=json.load(f)
    print(obj.get("allowlist_file") or "/etc/tetrablocker/allowlist.json")
except Exception:
    print("/etc/tetrablocker/allowlist.json")
PY
  )"
  allowlist_dir="$(dirname "$allowlist_file")"
  install -d -m 0755 "$allowlist_dir"
}

validate() {
  log "validating python script syntax"
  python3 -m py_compile "$BIN_DST"

  log "validating config JSON"
  python3 - <<'PY'
import json
p="/etc/tetrablocker/tetrablocker.conf"
with open(p,"r",encoding="utf-8") as f:
    json.load(f)
print("ok")
PY

  log "checking tetra_bin path (best-effort)"
  python3 - <<'PY'
import json, os, shutil
p="/etc/tetrablocker/tetrablocker.conf"
with open(p,"r",encoding="utf-8") as f:
    obj=json.load(f)
tb=obj.get("tetra_bin","tetra")
ok = (os.path.exists(tb) and os.access(tb, os.X_OK)) if os.path.isabs(tb) else (shutil.which(tb) is not None)
print("tetra_bin:", tb, "ok" if ok else "NOT_FOUND")
PY
}

reload_and_start() {
  log "systemd daemon-reload"
  systemctl daemon-reload

  log "enable service (idempotent)"
  systemctl enable tetrablocker >/dev/null 2>&1 || true

  log "start service: tetrablocker"
  systemctl start tetrablocker

  log "status:"
  systemctl status tetrablocker --no-pager || true
}

print_help() {
  cat <<'EOF'

===== Useful commands =====

# Live logs
sudo journalctl -u tetrablocker -f

# Status
sudo systemctl status tetrablocker --no-pager

# Stop / Start / Restart
sudo systemctl stop tetrablocker
sudo systemctl start tetrablocker
sudo systemctl restart tetrablocker

# Emergency disable allowlist (edit config -> restart)
sudo sed -i 's/"allowlist":[[:space:]]*true/"allowlist": false/' /etc/tetrablocker/tetrablocker.conf
sudo systemctl restart tetrablocker

# Re-enable allowlist
sudo sed -i 's/"allowlist":[[:space:]]*false/"allowlist": true/' /etc/tetrablocker/tetrablocker.conf
sudo systemctl restart tetrablocker

# Show allowlist file
cat /etc/tetrablocker/allowlist.json | sed -n '1,200p'

# List current tracing policies
sudo tetra tracingpolicy list

# Show tb-allowlist policies on disk
ls -l /etc/tetragon/tetragon.tp.d/tb-allowlist-*.yaml 2>/dev/null || true

EOF
}

main() {
  need_root
  check_inputs

  log "=== install/update tetrablocker ==="
  stop_service_if_running
  install_files
  ensure_dirs_from_conf
  validate
  reload_and_start
  print_help
  log "done"
}

main "$@"

