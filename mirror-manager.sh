#!/usr/bin/env bash
# HostBaran Mirror Manager - safe Linux repository mirror manager.
set -Eeuo pipefail

readonly SCRIPT_NAME="HostBaran Mirror Manager"
readonly SCRIPT_VERSION="$(cat "$(dirname "${BASH_SOURCE[0]}")/VERSION" 2>/dev/null || printf '1.0.0')"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_FILE="$SCRIPT_DIR/config/mirrors.conf"
readonly BACKUP_ROOT="/var/backups/mirror-manager"
readonly LOG_FILE="/var/log/mirror-manager.log"
readonly LOCK_FILE="/var/run/mirror-manager.lock"

DRY_RUN=0
VERBOSE=0
QUIET=0
NO_COLOR=0
NO_UPDATE=0
ASSUME_YES=0
JSON_OUTPUT=0
ROLLBACK=0
ROLLBACK_ON_ERROR=0
BACKUP_ENABLED=1
BACKUP_DIR=""
LOCK_FD=""
OS_ID=""
OS_NAME=""
OS_VERSION=""
OS_MAJOR=""
OS_CODENAME=""
ARCH=""
KERNEL=""
HOSTNAME_VALUE=""
FOUND=0
CHANGED=0
SKIPPED=0
FAILED=0
CURRENT_FILE=""
CHANGED_FILES=()
BACKED_UP_FILES=()

# shellcheck disable=SC1090
UBUNTU_MIRROR="https://ir.archive.ubuntu.com"
ALMALINUX_MIRROR="https://mirror.hostbaran.com/almalinux"
EPEL_MIRROR="https://mirror.hostbaran.com/epel"
MARIADB_MIRROR="https://mirror.hostbaran.com/mariadb"
CLOUDLINUX_MIRROR="https://mirror.hostbaran.com/cloudlinux"
if [[ -r "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
fi

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  COLOR_GREEN=$'\033[32m'; COLOR_YELLOW=$'\033[33m'; COLOR_RED=$'\033[31m'
  COLOR_CYAN=$'\033[36m'; COLOR_DIM=$'\033[2m'; COLOR_RESET=$'\033[0m'
else
  COLOR_GREEN=""; COLOR_YELLOW=""; COLOR_RED=""; COLOR_CYAN=""; COLOR_DIM=""; COLOR_RESET=""
fi

set_no_color() {
  COLOR_GREEN=""; COLOR_YELLOW=""; COLOR_RED=""; COLOR_CYAN=""; COLOR_DIM=""; COLOR_RESET=""
}

usage() {
  cat <<'EOF'
Usage:
  mirror-manager.sh [OPTIONS]

Options:
  --dry-run             Preview changes without modifying files
  --backup              Enable backups (default)
  --rollback            Restore the latest backup
  --rollback-on-error   Restore this session after an error
  --yes                 Skip confirmation
  --verbose             Show detailed output
  --quiet               Show only the final summary
  --no-color            Disable terminal colors
  --no-update           Skip metadata refresh
  --json                Print machine-readable JSON
  --version             Show version
  --help                Show this help
EOF
}

log_line() {
  local level="$1" message="$2"
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$level" "$message" >> "$LOG_FILE" 2>/dev/null || true
}

print_message() {
  local color="$1" tag="$2" message="$3"
  (( QUIET )) && return 0
  printf '%b[%s]%b %s\n' "$color" "$tag" "$COLOR_RESET" "$message"
  log_line "$tag" "$message"
}

info() { print_message "$COLOR_CYAN" "i" "$1"; }
success() { print_message "$COLOR_GREEN" "✓" "$1"; }
warning() { print_message "$COLOR_YELLOW" "!" "$1"; }
error() { print_message "$COLOR_RED" "✗" "$1" >&2; }
debug() { (( VERBOSE )) && print_message "$COLOR_DIM" "DEBUG" "$1"; }

fail() { error "$1"; exit "${2:-1}"; }

parse_args() {
  while (($#)); do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --backup) BACKUP_ENABLED=1 ;;
      --rollback) ROLLBACK=1 ;;
      --rollback-on-error) ROLLBACK_ON_ERROR=1 ;;
      --yes) ASSUME_YES=1 ;;
      --verbose) VERBOSE=1 ;;
      --quiet) QUIET=1 ;;
      --no-color) NO_COLOR=1; set_no_color ;;
      --no-update) NO_UPDATE=1 ;;
      --json) JSON_OUTPUT=1; QUIET=1 ;;
      --version) printf '%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
      --help|-h) usage; exit 0 ;;
      *) fail "Unknown option: $1" 1 ;;
    esac
    shift
  done
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || {
    error "This tool must be run as root. Example: sudo bash mirror-manager.sh"
    exit 3
  }
}

check_bash() {
  (( BASH_VERSINFO[0] >= 4 )) || fail "Bash version 4 or newer is required." 1
}

check_dependencies() {
  local command_name
  local required=(awk sed grep find cp mv mkdir mktemp date uname hostname cmp curl)
  for command_name in "${required[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || fail "Missing required dependency: $command_name" 1
  done
  if [[ "$OS_ID" == ubuntu ]]; then
    command -v apt-get >/dev/null 2>&1 || fail "Missing required dependency: apt-get" 1
  elif [[ "$OS_ID" == almalinux ]]; then
    command -v dnf >/dev/null 2>&1 || fail "Missing required dependency: dnf" 1
  fi
}

detect_os() {
  [[ -r /etc/os-release ]] || fail "Cannot read /etc/os-release." 1
  # shellcheck disable=SC1091
  source /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_NAME="${PRETTY_NAME:-${NAME:-unknown}}"
  OS_VERSION="${VERSION_ID:-unknown}"
  OS_MAJOR="${OS_VERSION%%.*}"
  OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
  ARCH="$(uname -m)"
  KERNEL="$(uname -r)"
  HOSTNAME_VALUE="$(hostname 2>/dev/null || printf 'unknown')"
  if [[ "$OS_ID" == ubuntu ]]; then
    [[ "$OS_VERSION" =~ ^(20\.04|22\.04|24\.04|26\.04)$ ]] || unsupported_os
  elif [[ "$OS_ID" == almalinux ]]; then
    [[ "$OS_MAJOR" =~ ^(8|9|10)$ ]] || unsupported_os
  else
    unsupported_os
  fi
}

unsupported_os() {
  cat >&2 <<EOF
Unsupported Operating System

Detected: $OS_NAME ($OS_VERSION)
Supported: Ubuntu 20.04, 22.04, 24.04, 26.04; AlmaLinux 8, 9, 10
EOF
  exit 2
}

acquire_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec {LOCK_FD}>"$LOCK_FILE" || fail "Cannot create execution lock: $LOCK_FILE" 1
    flock -n "$LOCK_FD" || fail "Another Mirror Manager process is already running." 1
  else
    warning "flock is unavailable; concurrent execution protection is disabled."
  fi
}

check_mirror_connectivity() {
  local mirror="$1"
  info "Checking mirror connectivity: $mirror"
  curl --fail --silent --show-error --location --max-time 10 "$mirror/" -o /dev/null || {
    error "Mirror health check failed; no files will be modified: $mirror"
    exit 4
  }
}

cleanup() {
  local status=$?
  [[ -n "$CURRENT_FILE" ]] && rm -f -- "$CURRENT_FILE.tmp.$$" 2>/dev/null || true
  if (( status != 0 && ROLLBACK_ON_ERROR && ${#CHANGED_FILES[@]} > 0 )); then
    warning "An error occurred; rolling back this session."
    restore_backup_dir "$BACKUP_DIR" || error "Automatic rollback was incomplete."
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

create_backup_dir() {
  (( BACKUP_ENABLED )) || return 0
  BACKUP_DIR="$BACKUP_ROOT/$(date '+%Y-%m-%d_%H-%M-%S')"
  mkdir -p "$BACKUP_DIR/files" || fail "Cannot create backup directory: $BACKUP_DIR" 1
  printf 'timestamp=%s\nhostname=%s\nos=%s\nversion=%s\narchitecture=%s\n' \
    "$(date -Is)" "$HOSTNAME_VALUE" "$OS_ID" "$OS_VERSION" "$ARCH" > "$BACKUP_DIR/manifest.txt"
}

backup_file() {
  local file="$1" relative destination
  (( BACKUP_ENABLED )) || return 0
  [[ -e "$file" && ! -L "$file" ]] || { error "Secure backup rejected an invalid file: $file"; return 1; }
  relative="${file#/}"
  destination="$BACKUP_DIR/files/$relative"
  mkdir -p "$(dirname "$destination")"
  cp --preserve=mode,ownership,timestamps -- "$file" "$destination" || return 1
  printf 'file=%s\tbackup=%s\n' "/$relative" "$destination" >> "$BACKUP_DIR/manifest.txt"
  BACKED_UP_FILES+=("$file")
}

restore_backup_dir() {
  local directory="$1" file backup
  [[ -r "$directory/manifest.txt" ]] || { error "Valid manifest not found: $directory"; return 1; }
  while IFS=$'\t' read -r file backup; do
    [[ "$file" == file=* ]] || continue
    file="${file#file=}"; backup="${backup#backup=}"
    [[ "$file" == /etc/apt/* || "$file" == /etc/yum.repos.d/* ]] || continue
    [[ -f "$backup" ]] || return 1
    cp --preserve=mode,ownership,timestamps -- "$backup" "$file" || return 1
  done < "$directory/manifest.txt"
  success "Rollback completed: $directory"
}

latest_backup() {
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort -r | head -n 1
}

atomic_replace() {
  local file="$1" temporary="$1.tmp.$$"
  CURRENT_FILE="$file"
  if (( DRY_RUN )); then
    rm -f -- "$temporary"
    CURRENT_FILE=""
    return 0
  fi
  cp --preserve=mode,ownership,timestamps -- "$file" "$temporary" || return 1
  mv -f -- "$temporary" "$file" || return 1
  CURRENT_FILE=""
}

transform_ubuntu_file() {
  local file="$1" temporary
  temporary="$file.tmp.$$"
  if [[ "$file" == *.sources ]]; then
    awk -v target="$UBUNTU_MIRROR" '
      BEGIN { disabled=0 }
      /^$/ { disabled=0 }
      /^[[:space:]]*Enabled:[[:space:]]*no([[:space:]]|$)/ { disabled=1 }
      !disabled && /^[[:space:]]*URIs:[[:space:]]+/ {
        sub(/^([[:space:]]*URIs:[[:space:]]+)https?:\/\/[^\/ 	]+/, "\\1" target, $0)
      }
      { print }
    ' "$file" > "$temporary"
  else
    awk -v target="$UBUNTU_MIRROR" '
      /^[[:space:]]*(deb|deb-src)[[:space:]]+https?:\/\/(archive\.ubuntu\.com|security\.ubuntu\.com|ports\.ubuntu\.com|[a-zA-Z0-9.-]+\.archive\.ubuntu\.com)(\/|[[:space:]])/ {
        sub(/https?:\/\/[^\/ 	]+/, target, $0)
      }
      { print }
    ' "$file" > "$temporary"
  fi
  if cmp -s "$file" "$temporary"; then rm -f -- "$temporary"; return 2; fi
  if (( DRY_RUN )); then
    printf '%s\n' "--- $file"; diff -u "$file" "$temporary" || true
    rm -f -- "$temporary"; return 0
  fi
  backup_file "$file" || { rm -f -- "$temporary"; return 1; }
  mv -f -- "$temporary" "$file" || return 1
  CHANGED_FILES+=("$file")
  return 0
}

transform_alma_file() {
  local file="$1" temporary
  temporary="$file.tmp.$$"
  awk -v alma="$ALMALINUX_MIRROR" -v epel="$EPEL_MIRROR" -v mariadb="$MARIADB_MIRROR" -v repo_file="$file" '
    function repo_component(    value) {
      if (section == "baseos") return "BaseOS"
      if (section == "appstream") return "AppStream"
      if (section == "crb") return "CRB"
      return section
    }
    function flush(    i, line, lower, class, target, path, replaced, has_target) {
      if (count == 0) return
      lower=tolower(blob); class="unknown"
      if ((section ~ /^(baseos|appstream|crb|extras|highavailability|resilientstorage|nfv|rt|sap|saphana)$/ || lower ~ /almalinux/) && lower ~ /(almalinux|repo\.almalinux|mirrors\.almalinux)/) class="alma"
      else if (section ~ /^epel([0-9].*)?$/ || lower ~ /(epel|fedoraproject\.org)/) class="epel"
      else if (section ~ /mariadb/ || lower ~ /mariadb/) class="mariadb"
      if (enabled == 0 || class == "unknown") {
        for (i=1; i<=count; i++) print lines[i]
        count=0; blob=""; enabled=1; section=""; return
      }
      target=(class=="alma" ? alma : class=="epel" ? epel : mariadb)
      for (i=1; i<=count; i++) {
        line=lines[i]
        if (line ~ /^[[:space:]]*enabled[[:space:]]*=/) { print line; continue }
        if (line ~ /^[[:space:]]*(#?[[:space:]]*)?(mirrorlist|metalink)[[:space:]]*=/) {
          print "# " line
          if (class == "alma") path=alma "/$releasever/" repo_component() "/$basearch/os/"
          else if (class == "epel") path=epel "/$releasever/Everything/$basearch/os/"
          else path=mariadb "/yum/$releasever/$basearch/"
          print "baseurl=" path; continue
        }
        if (line ~ /^[[:space:]]*#?[[:space:]]*baseurl[[:space:]]*=/) {
          if (class == "alma") path=alma "/$releasever/" repo_component() "/$basearch/os/"
          else if (class == "epel") path=epel "/$releasever/Everything/$basearch/os/"
          else path=mariadb "/yum/$releasever/$basearch/"
          print "baseurl=" path; has_target=1; continue
        }
        print line
      }
      count=0; blob=""; enabled=1; section=""
    }
    /^\/\// { next }
    /^[[:space:]]*\[/ { flush(); section=$0; sub(/^[[:space:]]*\[/,"",section); sub(/\].*$/, "",section); count=0; blob=""; enabled=1 }
    /^[[:space:]]*enabled[[:space:]]*=[[:space:]]*0([[:space:]]|$)/ { enabled=0 }
    { lines[++count]=$0; blob=blob " " tolower($0) }
    END { flush() }
  ' "$file" > "$temporary"
  if cmp -s "$file" "$temporary"; then rm -f -- "$temporary"; return 2; fi
  if (( DRY_RUN )); then
    printf '%s\n' "--- $file"; diff -u "$file" "$temporary" || true
    rm -f -- "$temporary"; return 0
  fi
  backup_file "$file" || { rm -f -- "$temporary"; return 1; }
  mv -f -- "$temporary" "$file" || return 1
  CHANGED_FILES+=("$file")
  return 0
}

is_official_ubuntu_file() { [[ "$1" == /etc/apt/sources.list || "$1" == /etc/apt/sources.list.d/*.list || "$1" == /etc/apt/sources.list.d/*.sources ]]; }

process_file() {
  local file="$1" result
  FOUND=$((FOUND + 1))
  if [[ "$OS_ID" == ubuntu ]]; then
    if transform_ubuntu_file "$file"; then result=0; else result=$?; fi
  else
    if transform_alma_file "$file"; then result=0; else result=$?; fi
  fi
  case "$result" in
    0) CHANGED=$((CHANGED + 1)); success "Changed: $file" ;;
    1) FAILED=$((FAILED + 1)); error "Modification failed; original file was preserved: $file" ;;
    2) SKIPPED=$((SKIPPED + 1)); debug "Already configured or not eligible: $file" ;;
  esac
}

collect_files() {
  if [[ "$OS_ID" == ubuntu ]]; then
    [[ -f /etc/apt/sources.list ]] && is_official_ubuntu_file /etc/apt/sources.list && process_file /etc/apt/sources.list
    while IFS= read -r -d '' file; do process_file "$file"; done < <(find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) -print0 2>/dev/null)
  else
    while IFS= read -r -d '' file; do process_file "$file"; done < <(find /etc/yum.repos.d -maxdepth 1 -type f -name '*.repo' -print0 2>/dev/null)
  fi
}

validate_configuration() {
  local file
  for file in "${CHANGED_FILES[@]}"; do
    if [[ "$OS_ID" == ubuntu ]]; then
      grep -Eq '^[[:space:]]*(deb|deb-src)[[:space:]]+https?://' "$file" || { error "APT structure is invalid after modification: $file"; return 1; }
    else
      awk '/^\[[^]]+\]/{sections++} END { exit (sections > 0 ? 0 : 1) }' "$file" || { error "DNF structure is invalid after modification: $file"; return 1; }
    fi
  done
}

refresh_metadata() {
  (( NO_UPDATE || DRY_RUN || CHANGED == 0 )) && return 0
  if [[ "$OS_ID" == ubuntu ]]; then apt-get update; else dnf -q makecache; fi
}

confirm_changes() {
  (( ASSUME_YES || DRY_RUN || QUIET )) && return 0
  printf '\nDetected official repositories will be modified; third-party and unknown repositories will remain unchanged. Continue? [Y/n] '
  read -r answer
  [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]] || { info "Operation cancelled."; exit 0; }
}

summary() {
  local status="SUCCESS"
  (( FAILED > 0 && CHANGED > 0 )) && status="PARTIALLY SUCCESSFUL"
  (( FAILED > 0 && CHANGED == 0 )) && status="FAILED"
  if (( JSON_OUTPUT )); then
    printf '{"os":"%s","version":"%s","architecture":"%s","found":%d,"changed":%d,"skipped":%d,"failed":%d,"status":"%s"}\n' "$OS_ID" "$OS_VERSION" "$ARCH" "$FOUND" "$CHANGED" "$SKIPPED" "$FAILED" "$status"
    return
  fi
  cat <<EOF

===========================================
             Operation Summary
===========================================
Operating System : $OS_NAME
Architecture     : $ARCH
Repositories found       : $FOUND
Repositories changed     : $CHANGED
Repositories skipped     : $SKIPPED
Repositories failed      : $FAILED
Backup location          : ${BACKUP_DIR:-not-created}
Status                   : $status
===========================================
EOF
}

main() {
  parse_args "$@"
  (( NO_COLOR )) && set_no_color
  check_bash
  require_root
  detect_os
  check_dependencies
  acquire_lock
  if (( ROLLBACK )); then
    local backup
    backup="$(latest_backup)"; [[ -n "$backup" ]] || fail "No backup was found." 1
    restore_backup_dir "$backup"; exit $?
  fi
  info "Detected: $OS_NAME | Version: $OS_VERSION | Architecture: $ARCH"
  if [[ "$OS_ID" == ubuntu ]]; then
    check_mirror_connectivity "$UBUNTU_MIRROR"
  else
    check_mirror_connectivity "$ALMALINUX_MIRROR"
  fi
  create_backup_dir
  collect_files
  (( FOUND > 0 )) || warning "No repository files were found to process."
  confirm_changes
  validate_configuration || { FAILED=$((FAILED + 1)); summary; exit 4; }
  refresh_metadata || { FAILED=$((FAILED + 1)); summary; exit 4; }
  summary
  (( FAILED > 0 && CHANGED > 0 )) && exit 5
  (( FAILED > 0 )) && exit 1
  exit 0
}

if [[ "${MIRROR_MANAGER_LIB_ONLY:-0}" != 1 ]]; then main "$@"; fi
