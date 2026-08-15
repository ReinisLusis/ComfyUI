#!/usr/bin/env bash
# ============================================================
# ComfyUI Launcher / Stopper  (macOS + Linux)
#
# Bootstraps and launches a ComfyUI install:
#   1. find or create a Python venv
#   2. install requirements (AMD ROCm torch handled specially)
#   3. launch main.py in the background, wait until healthy, open browser
#
# No PID file. Source of truth = whatever is listening on :8188,
# identity-verified via its process command line.
#
# Usage:
#   ./comfyui-launcher.sh                 -> start (or reuse) ComfyUI
#   ./comfyui-launcher.sh install         -> bootstrap venv + deps only (no launch)
#   ./comfyui-launcher.sh stop            -> stop a running ComfyUI instance
#   ./comfyui-launcher.sh status          -> print whether ComfyUI is running
#   ./comfyui-launcher.sh --no-browser    -> start without opening the browser
#
# Env overrides:
#   COMFYUI_ROOT   folder containing main.py (default: this script's parent)
#   COMFYUI_VENV   venv path (default: $COMFYUI_ROOT/venv)
#   COMFYUI_PORT   port (default: 8188)
# ============================================================

PORT="${COMFYUI_PORT:-8188}"
URL="http://127.0.0.1:${PORT}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMFYUI_ROOT="${COMFYUI_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
VENV_DIR="${COMFYUI_VENV:-${COMFYUI_ROOT}/venv}"
PYTHON_BIN="${VENV_DIR}/bin/python"

REQUIREMENTS="${COMFYUI_ROOT}/requirements.txt"
LOGFILE="${COMFYUI_ROOT}/comfyui_launcher.log"
ERRFILE="${COMFYUI_ROOT}/comfyui_launcher.err"
SENTINEL="${VENV_DIR}/.deps-ready"

AMD_INDEX="https://repo.amd.com/rocm/whl-multi-arch/"

log()  { printf '%s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
die()  { printf '[FATAL] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: comfyui-launcher.sh [command] [options]

Commands:
  start     bootstrap + launch + open browser (default)
  install   bootstrap venv + deps only, do NOT launch
  stop      stop a running ComfyUI instance
  status    print whether ComfyUI is running

Options (with start):
  --no-browser   launch without opening the browser

Env overrides:
  COMFYUI_ROOT   folder containing main.py (default: this script's parent)
  COMFYUI_VENV   venv path (default: $COMFYUI_ROOT/venv)
  COMFYUI_PORT   port (default: 8188)
EOF
}

# ---- is this an AMD ROCm machine? ----
is_rocm() {
  # torch already installed -> trust it
  if "${PYTHON_BIN}" -c "import torch" >/dev/null 2>&1; then
    "${PYTHON_BIN}" -c "import torch; exit(0 if torch.version.hip else 1)" >/dev/null 2>&1
    return
  fi
  # torch not installed yet -> environment markers
  [[ -d /opt/rocm ]] || command -v rocminfo >/dev/null 2>&1
}

# ---- resolve python: existing venv -> system python3 -> python -> fail ----
ensure_python() {
  if [[ -x "${PYTHON_BIN}" ]]; then
    if "${PYTHON_BIN}" -m pip --version >/dev/null 2>&1; then
      log "Using venv python: ${PYTHON_BIN}"
      return 0
    fi
    warn "venv at ${VENV_DIR} is broken (pip missing) - recreating..."
    rm -rf "${VENV_DIR}"
  fi
  local sys
  sys="$(command -v python3 || command -v python || true)"
  [[ -n "${sys}" ]] || die "No Python interpreter found. Install python3 first."
  log "Creating venv at ${VENV_DIR} using ${sys} ..."
  if ! "${sys}" -m venv "${VENV_DIR}"; then
    die "Failed to create venv at ${VENV_DIR}. On Debian/Ubuntu: sudo apt install python3-venv"
  fi
  if ! "${PYTHON_BIN}" -m pip --version >/dev/null 2>&1; then
    die "venv created but pip is missing. On Debian/Ubuntu: sudo apt install python3-venv"
  fi
  log "Created venv: ${VENV_DIR}"
}

# ---- install requirements (idempotent via a sentinel hash) ----
ensure_deps() {
  [[ -f "${REQUIREMENTS}" ]] || die "requirements.txt not found at ${REQUIREMENTS}"

  # Torch install policy: only ROCm needs a special index here.
  # CUDA (Linux), MPS (macOS) and CPU are all served by the default PyPI
  # wheels, which `pip install -r requirements.txt` picks up automatically.
  if is_rocm; then
    if "${PYTHON_BIN}" -c "import torch; exit(0 if torch.version.hip else 1)" >/dev/null 2>&1; then
      log "ROCm torch already installed - skipping torch stack."
    else
      log "Installing torch stack from AMD ROCm index ..."
      "${PYTHON_BIN}" -m pip install --index-url "${AMD_INDEX}" torch torchvision torchaudio \
        || die "Failed to install ROCm torch stack."
    fi
  fi

  local stamp
  stamp="$(COMFY_REQ="${REQUIREMENTS}" "${PYTHON_BIN}" -c \
    "import hashlib,os;print(hashlib.sha256(open(os.environ['COMFY_REQ'],'rb').read()).hexdigest())" 2>/dev/null)"
  if [[ -n "${stamp}" && -f "${SENTINEL}" && "$(cat "${SENTINEL}")" == "${stamp}" ]]; then
    log "Dependencies up to date - skipping install."
    return 0
  fi

  log "Installing requirements ..."
  "${PYTHON_BIN}" -m pip install -r "${REQUIREMENTS}" || die "Failed to install requirements."
  printf '%s' "${stamp}" > "${SENTINEL}"
  log "Dependencies installed."
}

# ---- PID listening on the port (empty string if none) ----
port_owner() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN -t 2>/dev/null | tail -n 1 || true
  elif command -v ss >/dev/null 2>&1; then
    ss -tlnp "sport = :${PORT}" 2>/dev/null | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | tail -n 1 || true
  else
    netstat -tlnp 2>/dev/null | awk -v p=":${PORT}" '$4 ~ p { n=split($NF,a,"/"); print a[1] }' | tail -n 1 || true
  fi
}

# ---- is this PID really our ComfyUI? (its command line references main.py) ----
is_comfyui() {
  ps -p "$1" -o args= 2>/dev/null | grep -q "main.py"
}

healthy() {
  curl -fsS -m 2 "${URL}" >/dev/null 2>&1
}

open_browser() {
  [[ "${NO_BROWSER}" == "1" ]] && return 0
  if command -v open >/dev/null 2>&1; then
    open "${URL}"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "${URL}"
  else
    log "Open ${URL} in your browser."
  fi
}

# ============================================================
# arg parsing
# ============================================================
CMD="start"
NO_BROWSER=0
for a in "$@"; do
  case "$a" in
    start)          CMD=start ;;
    install|setup)  CMD=install ;;
    stop)           CMD=stop ;;
    status)         CMD=status ;;
    --no-browser)   NO_BROWSER=1 ;;
    help|-h|--help) usage; exit 0 ;;
    *) warn "Unknown argument: $a"; usage; exit 1 ;;
  esac
done

# ============================================================
# STATUS
# ============================================================
if [[ "${CMD}" == "status" ]]; then
  pid="$(port_owner)"
  if [[ -n "${pid}" ]] && is_comfyui "${pid}"; then
    log "ComfyUI is running (PID ${pid})."
    exit 0
  fi
  log "ComfyUI is not running."
  exit 1
fi

# ============================================================
# STOP
# ============================================================
if [[ "${CMD}" == "stop" ]]; then
  log "Stopping ComfyUI..."
  pid="$(port_owner)"
  if [[ -z "${pid}" ]]; then
    log "Nothing is listening on port ${PORT}. Nothing to stop."
    exit 0
  fi
  if is_comfyui "${pid}"; then
    kill "${pid}" 2>/dev/null || true
    log "Stopped PID ${pid} (verified ComfyUI)."
  else
    warn "PID ${pid} is on port ${PORT} but is NOT ComfyUI. Not touching it."
  fi
  exit 0
fi

# ============================================================
# INSTALL (bootstrap only, do not launch)
# ============================================================
if [[ "${CMD}" == "install" ]]; then
  [[ -f "${COMFYUI_ROOT}/main.py" ]] || die "main.py not found at ${COMFYUI_ROOT}/main.py"
  ensure_python
  ensure_deps
  log "Bootstrap complete. Launch with: ${BASH_SOURCE[0]}"
  exit 0
fi

# ============================================================
# START (or reuse)
# ============================================================
log "ComfyUI Launcher"

pid="$(port_owner)"
if [[ -n "${pid}" ]]; then
  if is_comfyui "${pid}"; then
    log "ComfyUI is already running (PID ${pid}, verified)."
    open_browser
    exit 0
  fi
  warn "Port ${PORT} is already in use by PID ${pid}, but it is NOT ComfyUI."
  die "Close whatever that is before launching."
fi

[[ -f "${COMFYUI_ROOT}/main.py" ]] || die "main.py not found at ${COMFYUI_ROOT}/main.py"

ensure_python
ensure_deps

log "Launching ComfyUI in background..."
: > "${LOGFILE}"
: > "${ERRFILE}"
( cd "${COMFYUI_ROOT}" && exec nohup "${PYTHON_BIN}" main.py >"${LOGFILE}" 2>"${ERRFILE}" < /dev/null ) &
NEW_PID=$!
log "Started with PID ${NEW_PID} (only used to monitor THIS startup)."

log "Waiting for ComfyUI to become ready..."
tries=0
while true; do
  if ! kill -0 "${NEW_PID}" 2>/dev/null; then
    echo
    die "ComfyUI process (PID ${NEW_PID}) exited unexpectedly during startup. See ${ERRFILE}"
  fi

  tries=$(( tries + 1 ))
  if healthy; then
    log "ComfyUI is up and responding."
    open_browser
    exit 0
  fi

  if [[ ${tries} -ge 40 ]]; then
    die "Timed out after ${tries} attempts (~2 minutes). See ${LOGFILE} / ${ERRFILE}."
  fi

  printf '  attempt %s/40 - not ready yet (server still starting)...\n' "${tries}"
  sleep 3
done
