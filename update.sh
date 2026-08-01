#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" && pwd)"
DEFAULT_REPO_URL="https://github.com/Glazastyy/githree"
DEFAULT_REPO_GIT_URL="${DEFAULT_REPO_URL}.git"
DEFAULT_REPO_SSH_URL="git@github.com:Glazastyy/githree.git"
RUN_DIR="${SCRIPT_DIR}/.run/update"
LOG_DIR="${SCRIPT_DIR}/.logs"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/update-${TIMESTAMP}.log"
HAS_TTY=0
USE_COLOR=0
FORCE=0
DEV=0
CHECK_ONLY=0
CHECK_TAGS=0
SKIP_BUILD=0
SKIP_RESTART=0
SKIP_TESTS=0
BACKUP=0
MERGE_STRATEGY=""
REMOTE_URL="$DEFAULT_REPO_GIT_URL"
BRANCH=""

if [[ -t 1 && -w /dev/tty ]]; then
  HAS_TTY=1
fi

mkdir -p "$RUN_DIR" "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

if [[ $HAS_TTY -eq 1 && -z "${NO_COLOR:-}" ]]; then
  USE_COLOR=1
fi

if [[ $USE_COLOR -eq 1 ]]; then
  C_RESET=$'\033[0m'
  C_INFO=$'\033[38;2;88;166;255m'
  C_WARN=$'\033[38;2;240;180;60m'
  C_ERROR=$'\033[38;2;255;95;95m'
  C_SUCCESS=$'\033[38;2;64;210;120m'
  C_PRIMARY=$'\033[38;2;240;80;50m'
  C_BOLD=$'\033[1m'
else
  C_RESET=""
  C_INFO=""
  C_WARN=""
  C_ERROR=""
  C_SUCCESS=""
  C_PRIMARY=""
  C_BOLD=""
fi

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
success() { log SUCCESS "$@"; }
die() { log ERROR "$@" >&2; exit 1; }
step() { log STEP "$@"; }

on_error() {
  local exit_code="$?"
  local line_no="${1:-unknown}"
  log ERROR "Update failed at line ${line_no}: ${BASH_COMMAND:-unknown} (exit=${exit_code})"
  log ERROR "Full log: ${LOG_FILE}"
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

usage() {
  cat <<'EOF'
Usage: ./update.sh [options]

Options:
  -c, --check              Check Glazastyy/githree for updates and exit
      --check-tags         Check Glazastyy/githree tags for updates and exit
      --branch <name>      Update from a specific branch (default: current branch)
      --remote <url>       Override remote repository URL
      --backup             Run githreectl backup before updating when available
      --skip-build         Skip Bun/Rust build validation after pulling
      --skip-tests         Skip test commands during build validation
      --skip-restart       Skip Docker Compose/githreectl restart
      --ours               Prefer local changes if git merge conflicts
  -f, --force              Run without confirmation prompts
  -d, --dev                Do not replace update.sh before continuing
  -h, --help               Show this help

Exit codes for --check and --check-tags:
  0 update available
  3 no update available
  99 remote check failed
EOF
}

while (($#)); do
  case "$1" in
    -c|--check) CHECK_ONLY=1; shift ;;
    --check-tags) CHECK_TAGS=1; shift ;;
    --branch)
      shift
      [[ $# -gt 0 ]] || die "missing value for --branch"
      BRANCH="$1"
      shift
      ;;
    --remote)
      shift
      [[ $# -gt 0 ]] || die "missing value for --remote"
      REMOTE_URL="$1"
      shift
      ;;
    --backup) BACKUP=1; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --skip-tests) SKIP_TESTS=1; shift ;;
    --skip-restart) SKIP_RESTART=1; shift ;;
    --ours) MERGE_STRATEGY="ours"; shift ;;
    -f|--force) FORCE=1; shift ;;
    -d|--dev) DEV=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

prompt_yes_no() {
  local question="$1"
  local default_choice="${2:-no}"
  local suffix="[y/N]"
  local input
  [[ "$default_choice" == "yes" ]] && suffix="[Y/n]"
  if [[ $FORCE -eq 1 ]]; then
    return 0
  fi
  if [[ $HAS_TTY -eq 0 || ! -r /dev/tty ]]; then
    [[ "$default_choice" == "yes" ]]
    return
  fi
  while true; do
    read -r -p "${question} ${suffix} " input < /dev/tty
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

run() {
  info "Running: $*"
  "$@"
}

git_in_repo() {
  git -C "$SCRIPT_DIR" "$@"
}

current_branch() {
  git_in_repo symbolic-ref --quiet --short HEAD 2>/dev/null || printf '%s\n' "main"
}

resolve_branch() {
  if [[ -z "$BRANCH" ]]; then
    BRANCH="$(current_branch)"
  fi
}

fetch_branch() {
  if ! git_in_repo fetch --quiet "$REMOTE_URL" "refs/heads/${BRANCH}"; then
    return 99
  fi
  git_in_repo rev-parse FETCH_HEAD
}

check_for_updates() {
  resolve_branch
  step "Checking ${REMOTE_URL} branch ${BRANCH}"
  local remote_rev
  if ! remote_rev="$(fetch_branch)"; then
    warn "A problem occurred while fetching the latest revision."
    exit 99
  fi
  local local_rev
  local_rev="$(git_in_repo rev-parse HEAD)"
  if [[ "$local_rev" == "$remote_rev" ]] || git_in_repo merge-base --is-ancestor "$remote_rev" HEAD; then
    info "No updates available."
    exit 3
  fi
  success "Updated code is available."
  info "Changes: ${DEFAULT_REPO_URL}/commits/${BRANCH}"
  git_in_repo log --date=short --pretty=format:'%ad - %s' "HEAD..${remote_rev}" || true
  printf '\n'
  exit 0
}

check_for_tags() {
  step "Checking ${REMOTE_URL} tags"
  if ! git_in_repo ls-remote --exit-code --quiet --tags "$REMOTE_URL" >/tmp/githree-update-tags.$$; then
    rm -f /tmp/githree-update-tags.$$
    warn "A problem occurred while fetching remote tags."
    exit 99
  fi
  local latest_tag
  latest_tag="$(awk -F/ '/refs\/tags\/[^{}]+$/ { print $NF }' /tmp/githree-update-tags.$$ | sort -V | tail -n1)"
  rm -f /tmp/githree-update-tags.$$
  [[ -n "$latest_tag" ]] || die "no remote tags found"
  if git_in_repo rev-parse --verify --quiet "$latest_tag" >/dev/null; then
    info "No newer tag available."
    exit 3
  fi
  success "New tag is available: ${latest_tag}"
  info "Latest release: ${DEFAULT_REPO_URL}/releases/latest"
  exit 0
}

save_local_diff() {
  if git_in_repo diff-index --quiet HEAD --; then
    return
  fi
  local diff_dir="${RUN_DIR}/diffs"
  local diff_file="${diff_dir}/diff-before-update-${TIMESTAMP}.patch"
  mkdir -p "$diff_dir"
  git_in_repo diff --stat > "$diff_file"
  git_in_repo diff >> "$diff_file"
  warn "Local uncommitted diff saved to ${diff_file}"
}

verify_origin() {
  local current_remote
  current_remote="$(git_in_repo config --get remote.origin.url || true)"
  if [[ "$REMOTE_URL" != "$DEFAULT_REPO_GIT_URL" && "$REMOTE_URL" != "$DEFAULT_REPO_URL" ]]; then
    return
  fi
  if [[ "$current_remote" == "$DEFAULT_REPO_GIT_URL" || "$current_remote" == "$DEFAULT_REPO_URL" || "$current_remote" == "$DEFAULT_REPO_SSH_URL" ]]; then
    return
  fi
  warn "Current origin is ${current_remote:-unset}"
  warn "Default Githree repository is ${DEFAULT_REPO_GIT_URL}"
  if prompt_yes_no "Set origin to ${DEFAULT_REPO_GIT_URL}?" "no"; then
    run git_in_repo remote set-url origin "$DEFAULT_REPO_GIT_URL"
  fi
}

refresh_update_script() {
  if [[ $DEV -ne 0 ]]; then
    return 0
  fi
  step "Checking for newer update script"
  local before after
  before="$(sha256sum "${SCRIPT_DIR}/update.sh" | awk '{ print $1 }')"
  git_in_repo fetch --quiet "$REMOTE_URL" "refs/heads/${BRANCH}"
  if git_in_repo cat-file -e "FETCH_HEAD:update.sh" 2>/dev/null; then
    git_in_repo checkout --quiet FETCH_HEAD -- update.sh
    chmod +x "${SCRIPT_DIR}/update.sh"
    after="$(sha256sum "${SCRIPT_DIR}/update.sh" | awk '{ print $1 }')"
    if [[ "$before" != "$after" ]]; then
      warn "update.sh changed. Please run ./update.sh again."
      exit 2
    fi
  fi
}

run_backup() {
  if [[ $BACKUP -ne 1 ]]; then
    return 0
  fi
  step "Creating backup"
  if command -v githreectl >/dev/null 2>&1; then
    run githreectl backup
    return
  fi
  warn "githreectl not found; skipping backup"
}

merge_remote() {
  step "Updating local checkout from ${BRANCH}"
  local remote_rev
  remote_rev="$(fetch_branch)"
  local merge_args=("--ff")
  if [[ "$MERGE_STRATEGY" == "ours" ]]; then
    merge_args=("${merge_args[@]}" "-X" "ours")
  fi
  run git_in_repo merge "${merge_args[@]}" "$remote_rev"
}

run_builds() {
  if [[ $SKIP_BUILD -ne 0 ]]; then
    return 0
  fi
  step "Validating frontend"
  if [[ -f "${SCRIPT_DIR}/frontend/package.json" ]]; then
    run bash -c "cd '$SCRIPT_DIR/frontend' && bun install --frozen-lockfile"
    run bash -c "cd '$SCRIPT_DIR/frontend' && bun run check"
    run bash -c "cd '$SCRIPT_DIR/frontend' && bun run lint"
    run bash -c "cd '$SCRIPT_DIR/frontend' && bun run build"
  fi
  step "Validating backend"
  if [[ -f "${SCRIPT_DIR}/backend/Cargo.toml" ]]; then
    if [[ $SKIP_TESTS -eq 0 ]]; then
      run bash -c "cd '$SCRIPT_DIR/backend' && cargo test"
      run bash -c "cd '$SCRIPT_DIR/backend' && cargo clippy -- -D warnings"
    fi
    run bash -c "cd '$SCRIPT_DIR/backend' && cargo fmt --check"
  fi
}

detect_compose_command() {
  if docker compose version >/dev/null 2>&1; then
    printf '%s\n' "docker compose"
    return
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    printf '%s\n' "docker-compose"
    return
  fi
}

detect_compose_file() {
  if [[ -f "${SCRIPT_DIR}/.run/install/docker-compose.install.yml" ]]; then
    printf '%s\n' "${SCRIPT_DIR}/.run/install/docker-compose.install.yml"
    return
  fi
  if [[ -f "${SCRIPT_DIR}/docker-compose.yml" ]]; then
    printf '%s\n' "${SCRIPT_DIR}/docker-compose.yml"
  fi
}

restart_stack() {
  if [[ $SKIP_RESTART -ne 0 ]]; then
    return 0
  fi
  step "Restarting Githree stack"
  if command -v githreectl >/dev/null 2>&1; then
    run githreectl update --skip-self-update
    return
  fi
  local compose_file compose_command
  compose_file="$(detect_compose_file || true)"
  compose_command="$(detect_compose_command || true)"
  if [[ -z "$compose_file" || -z "$compose_command" ]]; then
    warn "No Docker Compose stack detected; skipping restart"
    return
  fi
  read -r -a compose_parts <<< "$compose_command"
  run "${compose_parts[@]}" -f "$compose_file" up -d --build
}

main() {
  require_command git
  [[ -d "${SCRIPT_DIR}/.git" ]] || die "update.sh must run from a Githree git checkout"
  resolve_branch
  [[ $CHECK_ONLY -eq 0 ]] || check_for_updates
  [[ $CHECK_TAGS -eq 0 ]] || check_for_tags
  verify_origin
  refresh_update_script
  if ! prompt_yes_no "Update Githree from ${REMOTE_URL} branch ${BRANCH}?" "no"; then
    info "OK, exiting."
    exit 0
  fi
  save_local_diff
  run_backup
  merge_remote
  run_builds
  restart_stack
  success "Githree update completed."
  info "Log written to ${LOG_FILE}"
}

main
