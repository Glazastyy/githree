#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_SOURCE="$0"
if [[ -n "${BASH_SOURCE:-}" ]]; then
  SCRIPT_SOURCE="${BASH_SOURCE[0]}"
fi
if [[ "$SCRIPT_SOURCE" == "bash" || "$SCRIPT_SOURCE" == "-" ]]; then
  ROOT_DIR="$(pwd)"
else
  ROOT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" && pwd)"
fi
RUN_DIR="$ROOT_DIR/.run"
LOG_DIR="$ROOT_DIR/.logs"
INSTALL_DIR="$RUN_DIR/install"
PROJECT_DIR="$ROOT_DIR"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/install-${TIMESTAMP}.log"
HAS_TTY=0
USE_COLOR=0
STEP_INDEX=0
DOCKER_NEEDS_SUDO=0
COMPOSE_LOG_TAIL_LINES=60
DEPLOY_MODE="image"
DEFAULT_IMAGE_REPO="ghcr.io/sarahsec/githree"
DEFAULT_IMAGE_TAG="latest"
DOCKER_STARTUP_ATTEMPTS=60
APP_HEALTH_ATTEMPTS=45
SOURCE_REPO_URL="https://github.com/Glazastyy/githree.git"
FALLBACK_PROJECT_DIR="$INSTALL_DIR/source/githree"
PROMPT_INPUT="/dev/stdin"
GITHREECTL_CONFIG_PATH=""
GITHREECTL_BINARY_PATH=""
GITHREECTL_INSTALL_ROOT=""
CONTAINER_APP_UID=10001
CONTAINER_APP_GID=10001
SSH_ASSETS_DIR="$INSTALL_DIR/ssh"
SSH_ENABLED_FOR_CONTAINER="no"

if [[ -t 1 && -w /dev/tty ]]; then
  HAS_TTY=1
fi
if [[ -r /dev/tty ]]; then
  PROMPT_INPUT="/dev/tty"
fi

mkdir -p "$RUN_DIR" "$LOG_DIR" "$INSTALL_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

if [[ $HAS_TTY -eq 1 && -z "${NO_COLOR:-}" ]]; then
  USE_COLOR=1
fi

if [[ $USE_COLOR -eq 1 ]]; then
  C_RESET=$'\033[0m'
  C_MUTED=$'\033[38;5;245m'
  C_INFO=$'\033[38;2;88;166;255m'
  C_WARN=$'\033[38;2;240;180;60m'
  C_ERROR=$'\033[38;2;255;95;95m'
  C_SUCCESS=$'\033[38;2;64;210;120m'
  C_PRIMARY=$'\033[38;2;240;80;50m'
  C_BOLD=$'\033[1m'
else
  C_RESET=""
  C_MUTED=""
  C_INFO=""
  C_WARN=""
  C_ERROR=""
  C_SUCCESS=""
  C_PRIMARY=""
  C_BOLD=""
fi

readonly ROOT_DIR RUN_DIR LOG_DIR INSTALL_DIR LOG_FILE HAS_TTY USE_COLOR

print_banner() {
  if [[ $USE_COLOR -eq 0 ]]; then
    return
  fi

  cat <<EOF
${C_PRIMARY}${C_BOLD}============================================================${C_RESET}
${C_PRIMARY}${C_BOLD}  GITHREE INSTALLER${C_RESET}
${C_MUTED}  Docker-first setup with guided checks and runtime wiring${C_RESET}
${C_PRIMARY}${C_BOLD}============================================================${C_RESET}
EOF
}

format_prompt() {
  local message="$1"
  if [[ $USE_COLOR -eq 1 ]]; then
    printf '%b%s%b' "$C_INFO$C_BOLD" "$message" "$C_RESET"
  else
    printf '%s' "$message"
  fi
}

on_error() {
  local exit_code="$?"
  local line_no="${1:-unknown}"
  printf '[%s] [ERROR] Installation failed at line %s: %s (exit=%s)\n' \
    "$(date +'%Y-%m-%d %H:%M:%S')" "$line_no" "${BASH_COMMAND:-unknown}" "$exit_code" >&2
  printf '[%s] [ERROR] Full log: %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$LOG_FILE" >&2
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

log() {
  local level="$1"
  shift
  local color="$C_RESET"
  case "$level" in
    INFO) color="$C_INFO" ;;
    WARN) color="$C_WARN" ;;
    ERROR) color="$C_ERROR" ;;
    SUCCESS) color="$C_SUCCESS" ;;
    STEP) color="$C_PRIMARY" ;;
  esac

  printf '%b[%s] [%s] %s%b\n' "$color" "$(date +'%Y-%m-%d %H:%M:%S')" "$level" "$*" "$C_RESET"
}

info() { log INFO "$@"; }
warn() { log WARN "$@" >&2; }
die() { log ERROR "$@" >&2; exit 1; }
success() { log SUCCESS "$@"; }
step() {
  STEP_INDEX=$((STEP_INDEX + 1))
  log STEP "Step ${STEP_INDEX}: $*"
}

usage() {
  cat <<'EOF'
Usage: ./install.sh [--yes] [--ctl-only] [--help]

Options:
  --yes, -y    Non-interactive mode using defaults where possible
  --ctl-only   Install only githreectl host CLI (skip Docker deploy)
  --help, -h   Show this help
EOF
}

ASSUME_YES=0
CTL_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=1 ;;
    --ctl-only) CTL_ONLY=1 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

if [[ $ASSUME_YES -eq 0 && ! -r /dev/tty ]]; then
  ASSUME_YES=1
fi

SUDO_BIN=""
if [[ "$(id -u)" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO_BIN="sudo"
  else
    die "This installer needs elevated privileges for package installation, but 'sudo' is not available."
  fi
fi

run() {
  info "Running: $*"
  "$@"
}

run_privileged() {
  if [[ -n "$SUDO_BIN" ]]; then
    run "$SUDO_BIN" "$@"
  else
    run "$@"
  fi
}

prime_sudo_credentials() {
  if [[ -z "$SUDO_BIN" ]]; then
    return 0
  fi
  info "Validating sudo credentials..."
  "$SUDO_BIN" -v
}

prompt() {
  local prompt_text="$1"
  local default_value="${2:-}"
  local result
  if [[ $ASSUME_YES -eq 1 ]]; then
    printf '%s\n' "$default_value"
    return 0
  fi
  if [[ -n "$default_value" ]]; then
    read -r -p "$(format_prompt "$prompt_text [$default_value]: ")" result < "$PROMPT_INPUT"
    printf '%s\n' "${result:-$default_value}"
  else
    read -r -p "$(format_prompt "$prompt_text: ")" result < "$PROMPT_INPUT"
    printf '%s\n' "$result"
  fi
}

prompt_yes_no() {
  local question="$1"
  local default_choice="${2:-yes}" # yes|no
  local input

  if [[ "$default_choice" != "yes" && "$default_choice" != "no" ]]; then
    die "Internal error: invalid default choice '$default_choice'"
  fi

  if [[ $ASSUME_YES -eq 1 ]]; then
    [[ "$default_choice" == "yes" ]]
    return
  fi

  local suffix="[y/N]"
  [[ "$default_choice" == "yes" ]] && suffix="[Y/n]"

  while true; do
    read -r -p "$(format_prompt "$question $suffix ")" input < "$PROMPT_INPUT"
    input="${input,,}"
    if [[ -z "$input" ]]; then
      [[ "$default_choice" == "yes" ]]
      return
    fi
    case "$input" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) warn "Please answer yes or no." ;;
    esac
  done
}

OS_NAME=""
PKG_MANAGER=""

detect_os() {
  case "$(uname -s)" in
    Linux) OS_NAME="linux" ;;
    Darwin) OS_NAME="macos" ;;
    *) die "Unsupported OS: $(uname -s). This installer supports Linux and macOS." ;;
  esac

  if [[ "$OS_NAME" == "linux" ]]; then
    if command -v apt-get >/dev/null 2>&1; then
      PKG_MANAGER="apt"
    elif command -v dnf >/dev/null 2>&1; then
      PKG_MANAGER="dnf"
    elif command -v pacman >/dev/null 2>&1; then
      PKG_MANAGER="pacman"
    elif command -v zypper >/dev/null 2>&1; then
      PKG_MANAGER="zypper"
    else
      PKG_MANAGER="unknown"
    fi
  else
    if command -v brew >/dev/null 2>&1; then
      PKG_MANAGER="brew"
    else
      PKG_MANAGER="unknown"
    fi
  fi

  info "Detected OS: $OS_NAME (package manager: $PKG_MANAGER)"
}

detect_default_image_repository() {
  if [[ -n "${GITHREE_IMAGE_REPO:-}" ]]; then
    printf '%s\n' "$GITHREE_IMAGE_REPO"
    return 0
  fi
  printf '%s\n' "$DEFAULT_IMAGE_REPO"
}

install_docker() {
  info "Attempting Docker installation for $OS_NAME ..."
  case "$PKG_MANAGER" in
    apt)
      run_privileged apt-get update
      run_privileged apt-get install -y docker.io docker-compose-plugin
      ;;
    dnf)
      run_privileged dnf install -y docker docker-compose-plugin
      ;;
    pacman)
      run_privileged pacman -Sy --noconfirm docker docker-compose
      ;;
    zypper)
      run_privileged zypper --non-interactive install docker docker-compose
      ;;
    brew)
      run brew install --cask docker
      warn "Docker Desktop was installed. Open Docker Desktop to start the daemon."
      ;;
    *)
      die "Automatic Docker installation is not supported on this OS/package manager. Install Docker manually and rerun."
      ;;
  esac
}

install_caddy() {
  info "Attempting host Caddy installation for $OS_NAME ..."
  case "$PKG_MANAGER" in
    apt)
      run_privileged apt-get update
      run_privileged apt-get install -y caddy
      ;;
    dnf)
      run_privileged dnf install -y caddy
      ;;
    pacman)
      run_privileged pacman -Sy --noconfirm caddy
      ;;
    zypper)
      run_privileged zypper --non-interactive install caddy
      ;;
    brew)
      run brew install caddy
      ;;
    *)
      die "Automatic Caddy installation is not supported on this OS/package manager."
      ;;
  esac
}

install_git() {
  info "Attempting Git installation for $OS_NAME ..."
  case "$PKG_MANAGER" in
    apt)
      run_privileged apt-get update
      run_privileged apt-get install -y git
      ;;
    dnf)
      run_privileged dnf install -y git
      ;;
    pacman)
      run_privileged pacman -Sy --noconfirm git
      ;;
    zypper)
      run_privileged zypper --non-interactive install git
      ;;
    brew)
      run brew install git
      ;;
    *)
      die "Automatic Git installation is not supported on this OS/package manager."
      ;;
  esac
}

install_rust_toolchain() {
  info "Attempting Rust toolchain installation for $OS_NAME ..."

  if command -v curl >/dev/null 2>&1; then
    if run bash -lc "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable"; then
      if [[ -f "${HOME:-}/.cargo/env" ]]; then
        # shellcheck disable=SC1090
        . "${HOME}/.cargo/env"
      fi
      export PATH="${HOME:-}/.cargo/bin:${PATH}"
      if command -v cargo >/dev/null 2>&1; then
        info "Rust toolchain installed via rustup."
        return 0
      fi
    else
      warn "rustup installation command failed."
    fi
  fi

  warn "rustup install path unavailable; trying package manager fallback."
  case "$PKG_MANAGER" in
    apt)
      run_privileged apt-get update || return 1
      run_privileged apt-get install -y rustc cargo || return 1
      ;;
    dnf)
      run_privileged dnf install -y rust cargo || return 1
      ;;
    pacman)
      run_privileged pacman -Sy --noconfirm rust || return 1
      ;;
    zypper)
      run_privileged zypper --non-interactive install rust cargo || return 1
      ;;
    brew)
      run brew install rust || return 1
      ;;
    *)
      return 1
      ;;
  esac

  command -v cargo >/dev/null 2>&1
}

ensure_cargo_for_githreectl() {
  if command -v cargo >/dev/null 2>&1; then
    return 0
  fi

  warn "Cargo is not installed; required to build githreectl host CLI."
  if ! prompt_yes_no "Install Rust toolchain now to build githreectl?" "yes"; then
    return 1
  fi

  if ! install_rust_toolchain; then
    warn "Rust installation failed or is unsupported on this host."
    return 1
  fi

  command -v cargo >/dev/null 2>&1
}

install_githreectl_build_tools() {
  info "Attempting native build tools installation for $OS_NAME ..."
  case "$PKG_MANAGER" in
    apt)
      run_privileged apt-get update || return 1
      run_privileged apt-get install -y build-essential pkg-config || return 1
      ;;
    dnf)
      run_privileged dnf install -y gcc gcc-c++ make pkgconf-pkg-config || return 1
      ;;
    pacman)
      run_privileged pacman -Sy --noconfirm base-devel pkgconf || return 1
      ;;
    zypper)
      run_privileged zypper --non-interactive install gcc gcc-c++ make pkg-config || return 1
      ;;
    brew)
      run xcode-select --install || true
      run brew install pkg-config || return 1
      ;;
    *)
      return 1
      ;;
  esac

  command -v cc >/dev/null 2>&1
}

ensure_build_tools_for_githreectl() {
  if command -v cc >/dev/null 2>&1 && command -v pkg-config >/dev/null 2>&1; then
    return 0
  fi

  warn "Native build tools are missing (required: cc and pkg-config) to compile githreectl."
  if ! prompt_yes_no "Install native build tools now?" "yes"; then
    return 1
  fi

  if ! install_githreectl_build_tools; then
    warn "Build tools installation failed or is unsupported on this host."
    return 1
  fi

  command -v cc >/dev/null 2>&1 && command -v pkg-config >/dev/null 2>&1
}

ensure_command() {
  local cmd="$1"
  local package_name="$2"
  local installer="$3"

  if command -v "$cmd" >/dev/null 2>&1; then
    info "Dependency found: $cmd"
    return 0
  fi

  warn "Missing dependency: $cmd"
  if prompt_yes_no "Install $package_name now?" "yes"; then
    "$installer"
  else
    die "Cannot continue without $cmd."
  fi

  command -v "$cmd" >/dev/null 2>&1 || die "$cmd is still unavailable after installation attempt."
}

is_valid_project_dir() {
  local candidate="$1"
  [[ -d "$candidate" ]] \
    && [[ -f "$candidate/Dockerfile" ]] \
    && [[ -f "$candidate/config/default.toml" ]] \
    && [[ -f "$candidate/backend/Cargo.toml" ]] \
    && [[ -f "$candidate/frontend/package.json" ]] \
    && [[ -f "$candidate/tools/githreectl/Cargo.toml" ]]
}

refresh_bootstrap_source() {
  local dir="$1"

  if [[ ! -d "$dir/.git" ]]; then
    return 1
  fi

  info "Refreshing cached bootstrapped source from ${SOURCE_REPO_URL}"
  if git -C "$dir" fetch --depth 1 origin >/dev/null 2>&1 \
    && git -C "$dir" reset --hard FETCH_HEAD >/dev/null 2>&1 \
    && git -C "$dir" clean -fd >/dev/null 2>&1; then
    info "Cached source refreshed successfully."
    return 0
  fi

  warn "Failed to refresh cached source; installer will try existing cache contents."
  return 1
}

ensure_project_source() {
  if is_valid_project_dir "$PROJECT_DIR"; then
    info "Using local project source at: $PROJECT_DIR"
    return 0
  fi

  warn "No complete Githree checkout found next to install.sh."
  warn "Bootstrapping source from ${SOURCE_REPO_URL}"
  ensure_command git "Git" install_git

  local fallback_parent
  fallback_parent="$(dirname "$FALLBACK_PROJECT_DIR")"
  mkdir -p "$fallback_parent"

  if is_valid_project_dir "$FALLBACK_PROJECT_DIR"; then
    info "Using cached bootstrapped source at: $FALLBACK_PROJECT_DIR"
    refresh_bootstrap_source "$FALLBACK_PROJECT_DIR" || true
  else
    if [[ -e "$FALLBACK_PROJECT_DIR" ]]; then
      run rm -rf "$FALLBACK_PROJECT_DIR"
    fi
    run git clone --depth 1 "$SOURCE_REPO_URL" "$FALLBACK_PROJECT_DIR"
  fi

  is_valid_project_dir "$FALLBACK_PROJECT_DIR" || die "Bootstrapped source is invalid: $FALLBACK_PROJECT_DIR"
  PROJECT_DIR="$FALLBACK_PROJECT_DIR"
  info "Project source ready at: $PROJECT_DIR"
}

COMPOSE_CMD=()
DOCKER_CMD=(docker)

detect_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
    info "Using Docker Compose command: docker compose"
    return
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
    info "Using Docker Compose command: docker-compose"
    return
  fi
  die "Docker Compose is not available. Install Docker Compose plugin and rerun."
}

can_access_docker_without_sudo() {
  docker info >/dev/null 2>&1
}

docker_access_error_output() {
  docker info 2>&1 >/dev/null || true
}

docker_access_denied_to_socket() {
  local err
  err="$(docker_access_error_output)"
  [[ "$err" == *"permission denied while trying to connect to the docker API"* ]]
}

docker_service_is_active() {
  if [[ "$OS_NAME" != "linux" ]]; then
    return 1
  fi
  systemctl is-active --quiet docker
}

configure_compose_privilege_mode() {
  if [[ $DOCKER_NEEDS_SUDO -ne 1 ]]; then
    return 0
  fi

  if [[ -z "$SUDO_BIN" ]]; then
    die "Docker requires privileged execution, but sudo is unavailable."
  fi

  COMPOSE_CMD=("$SUDO_BIN" "${COMPOSE_CMD[@]}")
  DOCKER_CMD=("$SUDO_BIN" "${DOCKER_CMD[@]}")
  info "Docker commands for this installer run will use sudo."
}

print_compose_failure_tail() {
  tail -n "$COMPOSE_LOG_TAIL_LINES" "$LOG_FILE" >&2
  warn "Docker Compose failed. Displayed the last ${COMPOSE_LOG_TAIL_LINES} log lines above."
}

run_compose_command() {
  local progress_tag="$1"
  shift
  local progress_text="$1"
  shift
  local compose_args=("$@")
  local marker="----- docker-compose output $(date +'%Y-%m-%d %H:%M:%S') -----"
  local spinner='|/-\'
  local spin_idx=0

  info "Running: ${COMPOSE_CMD[*]} ${compose_args[*]}"
  info "Compose output is being written to: $LOG_FILE"

  {
    echo "$marker"
    echo "Command: ${COMPOSE_CMD[*]} ${compose_args[*]}"
  } >>"$LOG_FILE"

  if [[ $HAS_TTY -eq 1 ]]; then
    "${COMPOSE_CMD[@]}" "${compose_args[@]}" >>"$LOG_FILE" 2>&1 &
    local compose_pid=$!

    while kill -0 "$compose_pid" 2>/dev/null; do
      printf '\r%b[%s]%b %s %s   ' \
        "$C_MUTED" "$progress_tag" "$C_RESET" "$progress_text" "${spinner:spin_idx:1}" > /dev/tty
      spin_idx=$(((spin_idx + 1) % 4))
      sleep 0.2
    done

    if wait "$compose_pid"; then
      printf '\r' > /dev/tty
      return 0
    fi

    printf '\r' > /dev/tty
    print_compose_failure_tail
    return 1
  fi

  if "${COMPOSE_CMD[@]}" "${compose_args[@]}" >>"$LOG_FILE" 2>&1; then
    return 0
  fi

  print_compose_failure_tail
  return 1
}

run_compose_stack() {
  local compose_file="$1"
  local deploy_mode="$2"

  if [[ $DOCKER_NEEDS_SUDO -eq 1 ]]; then
    prime_sudo_credentials
  fi

  if [[ "$deploy_mode" == "image" ]]; then
    run_compose_command "PULL" "Pulling prebuilt image..." -f "$compose_file" pull githree || return 1
    run_compose_command "START" "Starting containers..." -f "$compose_file" up -d || return 1
    return 0
  fi

  run_compose_command "BUILD" "Building containers..." -f "$compose_file" up -d --build
}

print_runtime_diagnostics() {
  local compose_file="$1"
  {
    echo "----- runtime diagnostics $(date +'%Y-%m-%d %H:%M:%S') -----"
    echo "Compose ps:"
    "${COMPOSE_CMD[@]}" -f "$compose_file" ps || true
    echo
    echo "Container logs (last 120 lines):"
    "${COMPOSE_CMD[@]}" -f "$compose_file" logs --tail 120 githree || true
    echo
  } >>"$LOG_FILE" 2>&1

  warn "Runtime diagnostics were appended to $LOG_FILE"
}

wait_for_http_ready() {
  local app_port="$1"
  local attempts="$APP_HEALTH_ATTEMPTS"
  local spinner='|/-\'
  local spin_idx=0
  local status_code=""
  local use_curl=0

  if command -v curl >/dev/null 2>&1; then
    use_curl=1
  else
    warn "curl is unavailable; using TCP socket probe for readiness checks."
  fi

  while (( attempts > 0 )); do
    if [[ $use_curl -eq 1 ]]; then
      status_code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 3 "http://127.0.0.1:${app_port}/" || true)"
    else
      if (exec 3<>"/dev/tcp/127.0.0.1/${app_port}") >/dev/null 2>&1; then
        status_code="200"
        exec 3<&-
        exec 3>&-
      else
        status_code="000"
      fi
    fi

    if [[ "$status_code" =~ ^[1-5][0-9][0-9]$ ]]; then
      if [[ $HAS_TTY -eq 1 ]]; then
        printf '\r' > /dev/tty
      fi
      return 0
    fi

    if [[ $HAS_TTY -eq 1 ]]; then
      printf '\r%b[HEALTH]%b Waiting for HTTP on 127.0.0.1:%s %s (%ss left)   ' \
        "$C_MUTED" "$C_RESET" "$app_port" "${spinner:spin_idx:1}" "$((attempts * 2))" > /dev/tty
      spin_idx=$(((spin_idx + 1) % 4))
    elif (( attempts % 5 == 0 )); then
      info "Waiting for Githree HTTP endpoint on port ${app_port}..."
    fi

    sleep 2
    ((attempts--))
  done

  if [[ $HAS_TTY -eq 1 ]]; then
    printf '\r' > /dev/tty
  fi
  return 1
}

verify_deployment_health() {
  local compose_file="$1"
  local app_port="$2"
  local container_id=""
  local container_state=""

  container_id="$("${COMPOSE_CMD[@]}" -f "$compose_file" ps -q githree 2>/dev/null | head -n1 || true)"
  if [[ -z "$container_id" ]]; then
    warn "No container ID was returned for service 'githree'."
    print_runtime_diagnostics "$compose_file"
    return 1
  fi

  container_state="$("${DOCKER_CMD[@]}" inspect -f '{{.State.Status}}' "$container_id" 2>/dev/null || true)"
  if [[ "$container_state" != "running" ]]; then
    warn "Service 'githree' is not running (state: ${container_state:-unknown})."
    print_runtime_diagnostics "$compose_file"
    return 1
  fi

  if wait_for_http_ready "$app_port"; then
    info "Verified HTTP reachability at http://127.0.0.1:${app_port}"
    return 0
  fi

  warn "Service container is running, but HTTP endpoint did not become reachable in time."
  print_runtime_diagnostics "$compose_file"
  return 1
}

ensure_docker_daemon() {
  if can_access_docker_without_sudo; then
    info "Docker daemon is running."
    return 0
  fi

  if docker_service_is_active && docker_access_denied_to_socket; then
    DOCKER_NEEDS_SUDO=1
    warn "Docker daemon is running, but current user cannot access /var/run/docker.sock."
    warn "This installer will continue using sudo for Docker commands."
    warn "Optional permanent fix: sudo usermod -aG docker \"${USER:-$(id -un)}\" && newgrp docker"
    return 0
  fi

  warn "Docker daemon is not running."
  local user_triggered_start="no"

  if [[ "$OS_NAME" == "linux" ]]; then
    if prompt_yes_no "Start Docker daemon now (systemctl enable --now docker)?" "yes"; then
      user_triggered_start="yes"
      run_privileged systemctl enable --now docker
    else
      die "Docker daemon is required, and startup was declined. Start Docker manually and rerun."
    fi
  else
    warn "On macOS, Docker Desktop must be running."
    if prompt_yes_no "Open Docker Desktop now?" "yes"; then
      user_triggered_start="yes"
      run open -a Docker
    else
      die "Docker daemon is required, and opening Docker Desktop was declined. Start it manually and rerun."
    fi
  fi

  if [[ "$user_triggered_start" != "yes" ]]; then
    die "Docker daemon is required but was not started."
  fi

  info "Waiting for Docker daemon to become available..."
  local attempts=$DOCKER_STARTUP_ATTEMPTS
  local spinner='|/-\'
  local spin_idx=0
  while (( attempts > 0 )); do
    if can_access_docker_without_sudo; then
      if [[ $HAS_TTY -eq 1 ]]; then
        printf '\r' > /dev/tty
      fi
      info "Docker daemon is now running."
      return 0
    fi

    if docker_service_is_active && docker_access_denied_to_socket; then
      DOCKER_NEEDS_SUDO=1
      if [[ $HAS_TTY -eq 1 ]]; then
        printf '\r' > /dev/tty
      fi
      warn "Docker daemon is running, but current user cannot access /var/run/docker.sock."
      warn "This installer will continue using sudo for Docker commands."
      warn "Optional permanent fix: sudo usermod -aG docker \"${USER:-$(id -un)}\" && newgrp docker"
      return 0
    fi

    if [[ $HAS_TTY -eq 1 ]]; then
      printf '\r%b[WAIT]%b Docker daemon startup in progress %s (%ss left)   ' \
        "$C_MUTED" "$C_RESET" "${spinner:spin_idx:1}" "$((attempts * 2))" > /dev/tty
      spin_idx=$(((spin_idx + 1) % 4))
    elif (( attempts % 10 == 0 )); then
      info "Still waiting for Docker daemon... (${attempts} checks remaining)"
    fi
    sleep 2
    ((attempts--))
  done

  if [[ $HAS_TTY -eq 1 ]]; then
    printf '\r' > /dev/tty
  fi
  die "Docker daemon is still not available. Start Docker manually and rerun."
}

check_port_free() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    if lsof -ti "tcp:${port}" -sTCP:LISTEN >/dev/null 2>&1; then
      return 1
    fi
  fi
  return 0
}

trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

normalize_domains_csv() {
  local raw="$1"
  local output=""
  local part
  IFS=',' read -r -a parts <<<"$raw"
  for part in "${parts[@]}"; do
    part="$(trim_whitespace "$part")"
    part="${part#http://}"
    part="${part#https://}"
    part="${part%%/*}"
    part="${part%/}"
    [[ -n "$part" ]] || continue
    if [[ ",${output}," == *",${part},"* ]]; then
      continue
    fi
    if [[ -z "$output" ]]; then
      output="$part"
    else
      output="${output},${part}"
    fi
  done

  if [[ -z "$output" ]]; then
    output="localhost"
  fi
  printf '%s\n' "$output"
}

primary_domain_from_csv() {
  local csv="$1"
  local first="${csv%%,*}"
  first="$(trim_whitespace "$first")"
  if [[ -z "$first" ]]; then
    printf 'localhost\n'
  else
    printf '%s\n' "$first"
  fi
}

detect_default_ssh_key_path() {
  local ssh_dir="$1"
  local candidate
  for candidate in \
    "${ssh_dir}/id_ed25519" \
    "${ssh_dir}/id_rsa" \
    "${ssh_dir}/id_ecdsa" \
    "${ssh_dir}/id_dsa"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  printf '%s\n' "${ssh_dir}/id_rsa"
}

stage_ssh_assets_for_container() {
  local private_key_path="$1"
  local known_hosts_path="$2"

  [[ -f "$private_key_path" ]] || die "SSH private key not found: $private_key_path"
  [[ -f "$known_hosts_path" ]] || die "SSH known_hosts not found: $known_hosts_path"

  run mkdir -p "$SSH_ASSETS_DIR"
  run cp "$private_key_path" "$SSH_ASSETS_DIR/id_key"
  run cp "$known_hosts_path" "$SSH_ASSETS_DIR/known_hosts"
  run chmod 600 "$SSH_ASSETS_DIR/id_key"
  run chmod 644 "$SSH_ASSETS_DIR/known_hosts"

  if ! run_privileged chown "$CONTAINER_APP_UID:$CONTAINER_APP_GID" "$SSH_ASSETS_DIR/id_key" "$SSH_ASSETS_DIR/known_hosts"; then
    warn "Could not chown SSH assets to ${CONTAINER_APP_UID}:${CONTAINER_APP_GID}. SSH in container may fail due to file permissions."
  fi

  info "Prepared container SSH assets at: $SSH_ASSETS_DIR"
}

write_compose_file() {
  local app_port="$1"
  local rust_log="$2"
  local use_caddy="$3"
  local deploy_mode="$4"
  local image_ref="$5"
  local caddy_http_port="$6"
  local caddy_https_port="$7"
  local primary_domain="$8"
  local hosted_domains="$9"
  local ssh_enabled="${10}"
  local ssh_assets_dir="${11}"

  local compose_file="$INSTALL_DIR/docker-compose.install.yml"
  local caddy_block=""
  local caddy_volume_block=""
  local runtime_block=""
  local ssh_env_block=""
  local ssh_volume_block=""

  if [[ "$deploy_mode" == "image" ]]; then
    runtime_block=$(cat <<EOF
    image: ${image_ref}
    pull_policy: always
EOF
)
  else
    runtime_block=$(cat <<EOF
    build:
      context: ${PROJECT_DIR}
      dockerfile: ${PROJECT_DIR}/Dockerfile
EOF
)
  fi

  if [[ "$use_caddy" == "yes" ]]; then
    caddy_block=$(cat <<EOF

  caddy:
    image: caddy:2.9-alpine
    container_name: githree-caddy
    depends_on:
      - githree
    restart: unless-stopped
    ports:
      - "${caddy_http_port}:80"
      - "${caddy_https_port}:443"
    volumes:
      - ${INSTALL_DIR}/Caddyfile:/etc/caddy/Caddyfile:ro
      - githree_caddy_data:/data
      - githree_caddy_config:/config
EOF
)
    caddy_volume_block=$(cat <<'EOF'
  githree_caddy_data:
  githree_caddy_config:
EOF
)
  fi

  if [[ "$ssh_enabled" == "yes" ]]; then
    ssh_env_block=$(cat <<'EOF'
      - GITHREE_SSH_PRIVATE_KEY_PATH=/app/ssh/id_key
      - GITHREE_SSH_KNOWN_HOSTS_PATH=/app/ssh/known_hosts
EOF
)
    ssh_volume_block=$(cat <<EOF
      - ${ssh_assets_dir}:/app/ssh:ro
EOF
)
  fi

  cat >"$compose_file" <<EOF
services:
  githree:
    container_name: githree
${runtime_block}
    restart: unless-stopped
    ports:
      - "${app_port}:3001"
    volumes:
      - githree_data:/app/data
      - ${PROJECT_DIR}/config:/app/config:ro
${ssh_volume_block}
    environment:
      - RUST_LOG=${rust_log}
      - GITHREE_DOMAIN=${primary_domain}
      - GITHREE_DOMAINS=${hosted_domains}
${ssh_env_block}
${caddy_block}

volumes:
  githree_data:
${caddy_volume_block}
EOF

  info "Generated compose file: $compose_file"
}

write_caddy_file() {
  local domain="$1"
  local app_host_port="$2"
  local caddy_file="$INSTALL_DIR/Caddyfile"

  cat >"$caddy_file" <<EOF
${domain} {
  encode gzip
  reverse_proxy githree:3001
}
EOF
  info "Generated Caddyfile: $caddy_file"
  info "Caddy domain/host: $domain (upstream githree:3001, host app port ${app_host_port})"
}

default_githreectl_config_path() {
  if [[ -n "${GITHREECTL_CONFIG:-}" ]]; then
    printf '%s\n' "$GITHREECTL_CONFIG"
    return 0
  fi

  if [[ -n "${HOME:-}" ]]; then
    printf '%s\n' "${HOME}/.config/githreectl/config.env"
    return 0
  fi

  printf '%s\n' "${INSTALL_DIR}/githreectl/config.env"
}

write_githreectl_config() {
  local compose_file="$1"
  local deploy_mode="$2"
  local image_ref="$3"
  local project_root="$4"
  local githree_config_file="$5"
  local primary_domain="$6"
  local hosted_domains="$7"
  local config_path
  config_path="$(default_githreectl_config_path)"

  run mkdir -p "$(dirname "$config_path")"

  cat >"$config_path" <<EOF
project_dir=${project_root}
compose_file=${compose_file}
service_name=githree
deploy_mode=${deploy_mode}
image_ref=${image_ref}
githree_config_file=${githree_config_file}
primary_domain=${primary_domain}
hosted_domains=${hosted_domains}
EOF

  GITHREECTL_CONFIG_PATH="$config_path"
  info "Generated githreectl config: $config_path"
}

install_githreectl_binary() {
  local crate_dir="$PROJECT_DIR/tools/githreectl"
  if [[ ! -f "$crate_dir/Cargo.toml" ]]; then
    warn "githreectl source was not found at ${crate_dir}; skipping host CLI install."
    return 1
  fi

  if ! ensure_cargo_for_githreectl; then
    warn "Skipping githreectl binary install because Cargo is unavailable."
    return 1
  fi
  if ! ensure_build_tools_for_githreectl; then
    warn "Skipping githreectl binary install because native build tools are unavailable."
    return 1
  fi

  local install_root
  if [[ -n "${HOME:-}" ]]; then
    install_root="${HOME}/.local"
  else
    install_root="${INSTALL_DIR}/githreectl-local"
  fi
  GITHREECTL_INSTALL_ROOT="$install_root"

  run mkdir -p "$install_root"
  run cargo install --path "$crate_dir" --force --root "$install_root"

  local binary_path="${install_root}/bin/githreectl"
  if [[ -x "$binary_path" ]]; then
    local global_bin_dir="/usr/local/bin"
    local global_binary_path="${global_bin_dir}/githreectl"

    if run_privileged mkdir -p "$global_bin_dir" \
      && run_privileged install -m 0755 "$binary_path" "$global_binary_path"; then
      GITHREECTL_BINARY_PATH="$global_binary_path"
      info "Installed githreectl binary: $global_binary_path"
      return 0
    fi

    warn "Could not publish githreectl to ${global_bin_dir}; keeping local install at ${binary_path}."
    GITHREECTL_BINARY_PATH="$binary_path"
    info "Installed githreectl binary: $binary_path"
    if [[ ":$PATH:" != *":${install_root}/bin:"* ]]; then
      warn "githreectl install dir is not currently in PATH: ${install_root}/bin"
      warn "Add it with: export PATH=\"${install_root}/bin:\$PATH\""
    fi
    return 0
  fi

  warn "githreectl install completed but binary was not found at expected path: $binary_path"
  return 1
}

detect_ctl_only_compose_file() {
  local candidates=(
    "$ROOT_DIR/.run/install/docker-compose.install.yml"
    "$PROJECT_DIR/.run/install/docker-compose.install.yml"
    "$ROOT_DIR/docker-compose.yml"
    "$PROJECT_DIR/docker-compose.yml"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  printf '%s\n' "$ROOT_DIR/.run/install/docker-compose.install.yml"
}

ensure_githreectl_config_for_ctl_only() {
  local config_path
  config_path="$(default_githreectl_config_path)"

  if [[ -f "$config_path" ]]; then
    GITHREECTL_CONFIG_PATH="$config_path"
    info "Using existing githreectl config: $config_path"
    return 0
  fi

  local default_image_repo
  default_image_repo="$(detect_default_image_repository)"
  local image_ref="${default_image_repo}:${DEFAULT_IMAGE_TAG}"
  local compose_file
  compose_file="$(detect_ctl_only_compose_file)"

  write_githreectl_config "$compose_file" "image" "$image_ref" "$ROOT_DIR" "$PROJECT_DIR/config/default.toml" "localhost" "localhost"
  warn "Generated default githreectl config for CTL-only mode."
  warn "If your stack uses another compose file, update: ${GITHREECTL_CONFIG_PATH}"
}

main() {
  print_banner
  info "Starting Githree Docker installer"
  info "Installer root: $ROOT_DIR"
  info "Installer log: $LOG_FILE"

  step "Detecting host OS and package manager"
  detect_os

  step "Ensuring Githree source checkout is available"
  ensure_project_source
  info "Project source: $PROJECT_DIR"

  if [[ $CTL_ONLY -eq 1 ]]; then
    step "Configuring host management CLI only"
    ensure_githreectl_config_for_ctl_only

    if prompt_yes_no "Build and install githreectl host CLI now?" "yes"; then
      install_githreectl_binary || die "Failed to install githreectl host CLI."
    else
      die "CTL-only mode requires githreectl installation."
    fi

    success "githreectl-only setup completed."
    if [[ -n "$GITHREECTL_BINARY_PATH" ]]; then
      info "Installed binary: ${GITHREECTL_BINARY_PATH}"
      info "Config file: ${GITHREECTL_CONFIG_PATH}"
      info "Try: githreectl status"
    fi
    info "Detailed installer log: $LOG_FILE"
    return 0
  fi

  step "Checking Docker installation"
  ensure_command docker "Docker" install_docker
  step "Checking Docker Compose availability"
  detect_compose
  step "Ensuring Docker daemon is ready"
  ensure_docker_daemon
  configure_compose_privilege_mode

  step "Collecting deployment settings"
  local app_port
  app_port="$(prompt "Host port for Githree web app" "3001")"
  [[ "$app_port" =~ ^[0-9]+$ ]] || die "Invalid app port: $app_port"
  check_port_free "$app_port" || die "Port $app_port is already in use. Choose another port."

  local rust_log
  rust_log="$(prompt "RUST_LOG level" "info")"

  local default_image_repo
  default_image_repo="$(detect_default_image_repository)"
  local image_ref="${default_image_repo}:${DEFAULT_IMAGE_TAG}"

  if prompt_yes_no "Use prebuilt GHCR image instead of local build?" "yes"; then
    DEPLOY_MODE="image"
    image_ref="$(prompt "GHCR image reference (repo:tag)" "$image_ref")"
    [[ -n "${image_ref// }" ]] || die "Image reference cannot be empty."
  else
    DEPLOY_MODE="build"
    info "Local Docker build mode selected."
  fi

  local use_caddy="no"
  if prompt_yes_no "Enable Caddy reverse proxy container?" "no"; then
    use_caddy="yes"
  fi

  local caddy_domain=":80"
  local caddy_http_port="80"
  local caddy_https_port="443"

  if [[ "$use_caddy" == "yes" ]]; then
    caddy_domain="$(prompt "Caddy site address (example: githree.org or :80)" ":80")"
    caddy_http_port="$(prompt "Host HTTP port for Caddy" "80")"
    caddy_https_port="$(prompt "Host HTTPS port for Caddy" "443")"
    [[ "$caddy_http_port" =~ ^[0-9]+$ ]] || die "Invalid Caddy HTTP port: $caddy_http_port"
    [[ "$caddy_https_port" =~ ^[0-9]+$ ]] || die "Invalid Caddy HTTPS port: $caddy_https_port"
    check_port_free "$caddy_http_port" || die "Port $caddy_http_port is already in use."
    check_port_free "$caddy_https_port" || die "Port $caddy_https_port is already in use."

    if prompt_yes_no "Install Caddy on host too (optional)?" "no"; then
      install_caddy
    fi
    write_caddy_file "$caddy_domain" "$app_port"
  fi

  local default_hosted_domains="localhost"
  if [[ "$use_caddy" == "yes" && "$caddy_domain" != ":80" ]]; then
    default_hosted_domains="$caddy_domain"
  fi

  local hosted_domains
  hosted_domains="$(prompt "Hosted domain(s), comma-separated (first is primary)" "$default_hosted_domains")"
  hosted_domains="$(normalize_domains_csv "$hosted_domains")"
  local primary_domain
  primary_domain="$(primary_domain_from_csv "$hosted_domains")"
  info "Configured hosted domains: ${hosted_domains}"

  if prompt_yes_no "Configure SSH key + known_hosts inside container for SSH repositories?" "yes"; then
    local default_ssh_dir="${HOME:-/root}/.ssh"
    local ssh_dir
    ssh_dir="$(prompt "Host SSH directory" "$default_ssh_dir")"
    local ssh_key_path_default
    ssh_key_path_default="$(detect_default_ssh_key_path "$ssh_dir")"
    local ssh_key_path
    ssh_key_path="$(prompt "Private key path for container SSH git access" "$ssh_key_path_default")"
    local known_hosts_path
    known_hosts_path="$(prompt "known_hosts path for container SSH host verification" "${ssh_dir}/known_hosts")"

    stage_ssh_assets_for_container "$ssh_key_path" "$known_hosts_path"
    SSH_ENABLED_FOR_CONTAINER="yes"
  else
    SSH_ENABLED_FOR_CONTAINER="no"
    info "Container SSH assets setup skipped. SSH repository URLs may fail inside container."
  fi

  step "Generating compose and optional proxy configuration"
  write_compose_file "$app_port" "$rust_log" "$use_caddy" "$DEPLOY_MODE" "$image_ref" "$caddy_http_port" "$caddy_https_port" "$primary_domain" "$hosted_domains" "$SSH_ENABLED_FOR_CONTAINER" "$SSH_ASSETS_DIR"

  local compose_file="$INSTALL_DIR/docker-compose.install.yml"
  step "Deploying containers"
  if [[ "$DEPLOY_MODE" == "image" ]]; then
    info "Deployment mode: prebuilt image pull"
  else
    info "Deployment mode: local Docker build"
  fi
  info "Deploying stack with Docker Compose ..."
  run_compose_stack "$compose_file" "$DEPLOY_MODE" || die "Docker Compose deployment failed. Check detailed logs at $LOG_FILE."

  step "Verifying deployment health"
  verify_deployment_health "$compose_file" "$app_port" || die "Deployment failed health verification. Check detailed logs at $LOG_FILE."

  step "Configuring host management CLI"
  write_githreectl_config "$compose_file" "$DEPLOY_MODE" "$image_ref" "$ROOT_DIR" "$PROJECT_DIR/config/default.toml" "$primary_domain" "$hosted_domains"
  if prompt_yes_no "Build and install githreectl host CLI now?" "yes"; then
    install_githreectl_binary || true
  else
    warn "Skipped githreectl binary installation."
  fi

  success "Deployment completed."
  success "App URL: http://localhost:${app_port}"
  info "Hosted domains: ${hosted_domains}"
  if [[ "$SSH_ENABLED_FOR_CONTAINER" == "yes" ]]; then
    info "Container SSH support: enabled (mounted from ${SSH_ASSETS_DIR})"
  else
    info "Container SSH support: disabled"
  fi
  info "Manage this installed stack with:"
  if [[ -n "$GITHREECTL_BINARY_PATH" ]]; then
    info "  githreectl status"
    info "  githreectl repo list"
    info "  githreectl repo add --url <repo_url> --name <alias>"
    info "  githreectl backup"
    info "  githreectl update --backup"
    info "  githreectl config: ${GITHREECTL_CONFIG_PATH}"
  else
    local fallback_install_root="$GITHREECTL_INSTALL_ROOT"
    if [[ -z "$fallback_install_root" ]]; then
      if [[ -n "${HOME:-}" ]]; then
        fallback_install_root="${HOME}/.local"
      else
        fallback_install_root="${INSTALL_DIR}/githreectl-local"
      fi
    fi
    info "  githreectl was not installed automatically."
    info "  Build later with: cargo install --path ${PROJECT_DIR}/tools/githreectl --force --root ${fallback_install_root}"
    info "  Config file: ${GITHREECTL_CONFIG_PATH}"
  fi
  info "  githreectl ui status"
  info "  githreectl ui repo-controls hide --restart"
  info "  githreectl ui web-management disable --restart"
  info "  githreectl config set fetch.interval 120s --restart"
  if [[ "$use_caddy" == "yes" ]]; then
    info "Caddy enabled for this stack."
  fi
  info "Detailed installer log: $LOG_FILE"
}

main
