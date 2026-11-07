#!/usr/bin/env bash
# KubeStellar Console in demo mode (no GitHub login).
#
#   ./console.sh setup     create kind cluster kc-demo and download the console
#   ./console.sh run       start the UI (creates kc-demo first if it is missing)
#   ./console.sh stop      stop the console and kc-agent
#   ./console.sh destroy   stop the UI and delete only the kc-demo cluster
#   ./console.sh status
#
# kc-agent is given the kind clusters that are actually running, so kc-demo
# shows up next to any existing kind clusters (including the core lab, once
# ./setup.sh has created it). Stale kubeconfig entries are not loaded.
# Set KC_KUBECONFIG to pass a different file.
# This does not install KubeStellar core. That is ./setup.sh.

set -euo pipefail

CLUSTER="${KC_CLUSTER:-kc-demo}"
PORT="${KC_PORT:-8080}"
AGENT_PORT="${KC_AGENT_PORT:-8585}"
VERSION="${KC_VERSION:-v0.3.42}"
REPO="kubestellar/console"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$ROOT/.kc"
CONSOLE_PID_FILE="$INSTALL_DIR/console.pid"
AGENT_PID_FILE="$INSTALL_DIR/kc-agent.pid"
AGENT_LOG="$INSTALL_DIR/kc-agent.log"
CONSOLE_LOG="$INSTALL_DIR/console.log"
LIVE_KUBECONFIG=""

log() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing '$1'"
}

platform() {
  local os arch
  case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux) os="linux" ;;
    *) die "unsupported os: $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) die "unsupported arch: $(uname -m)" ;;
  esac
  printf '%s_%s\n' "$os" "$arch"
}

cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER"
}

pid_alive() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  local pid
  pid="$(cat "$file" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

stop_pid() {
  local file="$1" name="$2"
  pid_alive "$file" || { rm -f "$file"; return 0; }
  local pid
  pid="$(cat "$file")"
  log "stopping $name (pid $pid)"
  kill "$pid" 2>/dev/null || true
  local _
  for _ in 1 2 3 4 5; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  kill -9 "$pid" 2>/dev/null || true
  rm -f "$file"
}

download() {
  need curl
  local plat tarball url sums tmp expected actual name
  plat="$(platform)"
  mkdir -p "$INSTALL_DIR"
  if [[ -x "$INSTALL_DIR/console" && -x "$INSTALL_DIR/kc-agent" && -f "$INSTALL_DIR/VERSION" ]] \
      && [[ "$(cat "$INSTALL_DIR/VERSION")" == "$VERSION" ]]; then
    log "console $VERSION already downloaded"
    return 0
  fi

  sums="$(mktemp)"
  tmp="$(mktemp -d)"
  log "downloading $VERSION checksums"
  curl -fsSL -o "$sums" \
    "https://github.com/${REPO}/releases/download/${VERSION}/checksums.txt"

  for name in console kc-agent; do
    tarball="${name}_${VERSION#v}_${plat}.tar.gz"
    url="https://github.com/${REPO}/releases/download/${VERSION}/${tarball}"
    expected="$(awk -v n="$tarball" '$2 == n || $2 == "*"n { print $1; exit }' "$sums")"
    [[ -n "$expected" ]] || { rm -rf "$tmp" "$sums"; die "no checksum for $tarball"; }
    log "downloading $tarball"
    curl -fsSL -o "$tmp/$tarball" "$url"
    actual="$(shasum -a 256 "$tmp/$tarball" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || { rm -rf "$tmp" "$sums"; die "checksum mismatch for $tarball"; }
    tar -xzf "$tmp/$tarball" -C "$tmp"
    mv -f "$tmp/$name" "$INSTALL_DIR/$name"
    chmod +x "$INSTALL_DIR/$name"
  done

  if [[ -d "$tmp/web/dist" ]]; then
    rm -rf "$INSTALL_DIR/web"
    mkdir -p "$INSTALL_DIR/web"
    mv "$tmp/web/dist" "$INSTALL_DIR/web/dist"
  fi
  rm -rf "$tmp" "$sums"
  [[ -d "$INSTALL_DIR/web/dist" ]] || die "console tarball did not include web/dist"
  printf '%s\n' "$VERSION" > "$INSTALL_DIR/VERSION"
  log "installed $VERSION into $INSTALL_DIR"
  patch_frontend
}

# Demo mode 401s were treated as an expired login, so the page reloaded
# /login every few seconds. Plant the dev-user cookie before the app boots.
patch_frontend() {
  local index="$INSTALL_DIR/web/dist/index.html"
  local src="$ROOT/demo-session.js"
  [[ -f "$index" && -f "$src" ]] || return 0
  cp "$src" "$INSTALL_DIR/web/dist/demo-session.js"
  if grep -q '/demo-session.js' "$index"; then
    return 0
  fi
  python3 - "$index" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
needle = '<script type="module"'
insert = '<script src="/demo-session.js"></script>\n    '
if needle not in text:
    raise SystemExit("index.html has no module script tag")
path.write_text(text.replace(needle, insert + needle, 1))
PY
  log "patched console frontend to keep the demo session"
}

prepare_kubeconfig() {
  if [[ -n "${KC_KUBECONFIG:-}" ]]; then
    [[ -f "$KC_KUBECONFIG" ]] || die "KC_KUBECONFIG not found: $KC_KUBECONFIG"
    LIVE_KUBECONFIG="$KC_KUBECONFIG"
    log "using kubeconfig $LIVE_KUBECONFIG"
    return 0
  fi

  local parts=() name ctx part joined
  mkdir -p "$INSTALL_DIR/kubeconfig.d"
  rm -f "$INSTALL_DIR/kubeconfig.d/"*
  while read -r name; do
    [[ -n "$name" ]] || continue
    ctx="kind-${name}"
    part="$INSTALL_DIR/kubeconfig.d/${ctx}"
    if kubectl --context "$ctx" config view --minify --flatten >"$part"; then
      parts+=("$part")
      log "including running cluster $ctx"
    else
      rm -f "$part"
      log "skipping $ctx (no kubeconfig context)"
    fi
  done < <(kind get clusters)

  [[ ${#parts[@]} -gt 0 ]] || die "no running kind clusters"
  joined="$(IFS=:; echo "${parts[*]}")"
  KUBECONFIG="$joined" kubectl config view --flatten >"$INSTALL_DIR/kubeconfig"
  chmod 600 "$INSTALL_DIR/kubeconfig"
  LIVE_KUBECONFIG="$INSTALL_DIR/kubeconfig"
}

cmd_setup() {
  need docker
  need kind
  need kubectl
  docker info >/dev/null 2>&1 || die "docker is not running"
  if cluster_exists; then
    log "kind cluster '$CLUSTER' already exists"
  else
    local prev=""
    prev="$(kubectl config current-context 2>/dev/null || true)"
    log "creating kind cluster '$CLUSTER'"
    kind create cluster --name "$CLUSTER"
    if [[ -n "$prev" ]]; then
      kubectl config use-context "$prev" >/dev/null
      log "restored kubectl context '$prev'"
    fi
  fi
  download
  log "setup done. next: ./console.sh run"
}

cmd_run() {
  cluster_exists || cmd_setup
  [[ -x "$INSTALL_DIR/console" ]] || download
  patch_frontend
  if pid_alive "$CONSOLE_PID_FILE"; then
    log "console already running at http://localhost:${PORT}"
    exit 0
  fi
  rm -f "$CONSOLE_PID_FILE" "$AGENT_PID_FILE"

  mkdir -p "$INSTALL_DIR/data"
  if [[ ! -s "$INSTALL_DIR/data/.jwt_secret" ]]; then
    openssl rand -hex 32 > "$INSTALL_DIR/data/.jwt_secret"
    chmod 600 "$INSTALL_DIR/data/.jwt_secret"
  fi

  prepare_kubeconfig
  : >"$AGENT_LOG"
  : >"$CONSOLE_LOG"

  log "starting kc-agent on :$AGENT_PORT"
  nohup "$INSTALL_DIR/kc-agent" -kubeconfig "$LIVE_KUBECONFIG" >>"$AGENT_LOG" 2>&1 &
  echo $! > "$AGENT_PID_FILE"
  sleep 1
  if ! pid_alive "$AGENT_PID_FILE"; then
    log "kc-agent failed to start. see $AGENT_LOG"
    exit 1
  fi

  log "starting console on :$PORT (demo mode, no GitHub login)"
  (
    cd "$INSTALL_DIR"
    export DEV_MODE=false
    export SKIP_ONBOARDING=true
    export IGNORE_PERSISTED_OAUTH_CREDENTIALS=true
    export KUBECONFIG="$LIVE_KUBECONFIG"
    export JWT_SECRET
    JWT_SECRET="$(cat "$INSTALL_DIR/data/.jwt_secret")"
    unset GITHUB_CLIENT_ID GITHUB_CLIENT_SECRET || true
    exec ./console --port "$PORT"
  ) >>"$CONSOLE_LOG" 2>&1 &
  echo $! > "$CONSOLE_PID_FILE"

  local i code
  code="000"
  for i in $(seq 1 60); do
    if ! pid_alive "$CONSOLE_PID_FILE"; then
      log "console exited during startup. see $CONSOLE_LOG"
      cmd_stop
      exit 1
    fi
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/" || true)"
    case "$code" in
      200|301|302|401|403) break ;;
    esac
    sleep 1
  done
  case "$code" in
    200|301|302|401|403) ;;
    *)
      log "console did not become ready (last http $code). see $CONSOLE_LOG"
      cmd_stop
      exit 1
      ;;
  esac

  log "console:    http://localhost:${PORT}"
  log "kc-agent:   http://localhost:${AGENT_PORT}"
  log "kubeconfig: $LIVE_KUBECONFIG"
  log "stop with Ctrl+C, or ./console.sh stop"
  if command -v open >/dev/null 2>&1; then
    open "http://localhost:${PORT}" >/dev/null 2>&1 || true
  fi

  trap 'cmd_stop; exit 0' INT TERM
  wait "$(cat "$CONSOLE_PID_FILE")" || true
}

cmd_stop() {
  stop_pid "$CONSOLE_PID_FILE" "console"
  stop_pid "$AGENT_PID_FILE" "kc-agent"
}

cmd_destroy() {
  cmd_stop
  if cluster_exists; then
    log "deleting kind cluster '$CLUSTER'"
    kind delete cluster --name "$CLUSTER"
  else
    log "kind cluster '$CLUSTER' is not present"
  fi
  log "left every other kind cluster in place"
  log "binaries remain in $INSTALL_DIR"
}

cmd_status() {
  if cluster_exists; then
    log "cluster:  $CLUSTER (exists)"
  else
    log "cluster:  $CLUSTER (absent)"
  fi
  if pid_alive "$CONSOLE_PID_FILE"; then
    log "console:  running pid $(cat "$CONSOLE_PID_FILE")  http://localhost:${PORT}"
  else
    log "console:  stopped"
  fi
  if pid_alive "$AGENT_PID_FILE"; then
    log "kc-agent: running pid $(cat "$AGENT_PID_FILE")  http://localhost:${AGENT_PORT}"
  else
    log "kc-agent: stopped"
  fi
  if [[ -f "$INSTALL_DIR/VERSION" ]]; then
    log "version:  $(cat "$INSTALL_DIR/VERSION")"
  fi
  log "running kind clusters:"
  kind get clusters 2>/dev/null | sed 's/^/  /' || true
}

usage() {
  cat <<EOF
usage: ./console.sh <setup|run|stop|destroy|status>

  setup    create kind cluster '$CLUSTER' and download console $VERSION
  run      start the console in demo mode (creates the cluster first if needed)
  stop     stop the console and kc-agent
  destroy  stop the UI and delete only the '$CLUSTER' kind cluster
  status   show what is running

KubeStellar core (hosting cluster, ITS, WDS, workload clusters) is ./setup.sh.
EOF
}

main() {
  case "${1:-}" in
    setup) cmd_setup ;;
    run) cmd_run ;;
    stop) cmd_stop ;;
    destroy) cmd_destroy ;;
    status) cmd_status ;;
    -h|--help|help|"") usage ;;
    *) usage >&2; die "unknown command '${1}'" ;;
  esac
}

main "$@"
