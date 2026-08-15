#!/usr/bin/env bash
# ============================================================
# ComfyUI Launcher / Stopper  (macOS + Linux)
# No PID file. Source of truth = whatever is actually listening
# on port 8188, identity-verified via its process command line.
#
# Usage:
#   ./comfyui-launcher.sh          -> start (or reuse) ComfyUI, open browser
#   ./comfyui-launcher.sh stop     -> stop a running ComfyUI instance
#
# Python resolution: prefer the venv bundled with the install
# (e.g. an AMD bundle), fall back to system python3/python, and
# bail with an error if none is found.
# ============================================================

PORT="${COMFYUI_PORT:-8188}"
URL="http://127.0.0.1:${PORT}"

# Root of the ComfyUI install (the folder that contains main.py).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMFYUI_ROOT="${COMFYUI_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

LOGFILE="${COMFYUI_ROOT}/comfyui_launcher.log"
ERRFILE="${COMFYUI_ROOT}/comfyui_launcher.err"

log()  { printf '%s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
die()  { printf '[FATAL] %s\n' "$*" >&2; exit 1; }

# ---- locate Python: bundled venv -> system python3 -> system python -> fail ----
find_python() {
  if [[ -x "${COMFYUI_ROOT}/venv/bin/python" ]]; then
    printf '%s\n' "${COMFYUI_ROOT}/venv/bin/python"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    command -v python3
    return 0
  fi
  if command -v python >/dev/null 2>&1; then
    command -v python
    return 0
  fi
  return 1
}

# ---- PID currently LISTENING on the port (empty string if none) ----
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

# ---- true when the server answers HTTP 200 ----
healthy() {
  curl -fsS -m 2 "${URL}" >/dev/null 2>&1
}

open_browser() {
  if command -v open >/dev/null 2>&1; then
    open "${URL}"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "${URL}"
  else
    log "Open ${URL} in your browser."
  fi
}

# ============================================================
# STOP
# ============================================================
if [[ "${1:-}" == "stop" ]]; then
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
# START (or reuse)
# ============================================================
log "ComfyUI Launcher"

pid="$(port_owner)"
if [[ -n "${pid}" ]]; then
  if is_comfyui "${pid}"; then
    log "ComfyUI is already running (PID ${pid}, verified). Opening browser..."
    open_browser
    exit 0
  fi
  warn "Port ${PORT} is already in use by PID ${pid}, but it is NOT ComfyUI."
  die "Close whatever that is before launching."
fi

[[ -f "${COMFYUI_ROOT}/main.py" ]] || die "main.py not found at ${COMFYUI_ROOT}/main.py"

PYTHON="$(find_python)" || die "No Python interpreter found (looked for venv/bin/python, python3, python)."
log "Using python: ${PYTHON}"

log "Launching ComfyUI in background..."
: > "${LOGFILE}"
: > "${ERRFILE}"

( cd "${COMFYUI_ROOT}" && exec nohup "${PYTHON}" main.py >"${LOGFILE}" 2>"${ERRFILE}" < /dev/null ) &
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
    log "ComfyUI is up and responding. Opening browser..."
    open_browser
    exit 0
  fi

  if [[ ${tries} -ge 40 ]]; then
    die "Timed out after ${tries} attempts (~2 minutes). See ${LOGFILE} / ${ERRFILE}."
  fi

  printf '  attempt %s/40 - not ready yet (server still starting)...\n' "${tries}"
  sleep 3
done
