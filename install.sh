#!/usr/bin/env bash
#
# caelestia-autoinstall - unattended installer for the Caelestia dots
# (Hyprland + Quickshell) on Arch-based distros.
#
# https://github.com/nytrek/caelestia-autoinstall
#
#   curl -fsSL https://raw.githubusercontent.com/nytrek/caelestia-autoinstall/main/install.sh | bash

# Everything runs from main() on the last line, so bash reads the whole file
# before executing anything, even when piped from curl.

set -Eeuo pipefail

readonly VERSION="1.2.0"
readonly AUTHOR="github.com/nytrek"
readonly MANIFEST_URL="https://raw.githubusercontent.com/caelestia-dots/caelestia/main/manifest.toml"
readonly MIN_FREE_GB=6
readonly TOTAL_STEPS=16
readonly OS_RELEASE_FILE="${CAELESTIA_OS_RELEASE:-/etc/os-release}"
readonly STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/caelestia-autoinstall"
readonly DOTS_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/caelestia/dots-state.json"
readonly YAY_FLAGS=(--needed --noconfirm --ask 4 --answerclean None --answerdiff None
  --answeredit None --removemake --cleanafter)

# group|id|label|package, or c:<name> for a Caelestia component (installs its theming too)
readonly APP_LIST=(
  "Browsers|brave|Brave|brave-bin"
  "Browsers|chrome|Google Chrome|google-chrome"
  "Browsers|zen|Zen Browser|c:zen"
  "Development|vscode|VS Code (OSS)|c:vscode"
  "Development|vscodium|VSCodium|c:vscodium"
  "Development|pycharm|PyCharm Community|pycharm-community-edition"
  "Development|zed|Zed|c:zed"
  "Development|nvim|Neovim|c:nvim"
  "Media & chat|spotify|Spotify + Spicetify|c:spotify"
  "Media & chat|discord|Discord (Equibop)|c:discord"
  "Media & chat|telegram|Telegram|telegram-desktop"
  "Media & chat|vlc|VLC|vlc"
  "Media & chat|obs|OBS Studio|obs-studio"
  "Productivity|keepassxc|KeePassXC|keepassxc"
  "Productivity|obsidian|Obsidian|obsidian"
  "Productivity|libreoffice|LibreOffice|libreoffice-fresh"
  "Productivity|qbittorrent|qBittorrent|qbittorrent"
  "Productivity|gimp|GIMP|gimp"
)

ENABLE=""
DISABLE=""
APPS_ARG=""
ASK_APPS=1
DM_CHOICE="auto"
DO_CLEANUP=1
DO_REBOOT=0
DRY_RUN=0

STEP="start"
STEP_NUM=0
LOG_FILE=""
BACKUP_FILE=""
SUDO_PID=""
TASK_PID=""
TMP_DIR=""
HAS_SYSTEMD=0
RECONFIGURE=0
VIRT=""
OS_ID=""
OS_LIKE=""
OS_NAME=""
FAMILY=""
FOREIGN_BEFORE=""
QS_REMOVE=""
QS_VARIANTS=""
REMOVED_SHELL=""
EXTRA_PKGS=()
SUMMARY=()

# Output

TTY=0
[ -t 1 ] && TTY=1
if [ "$TTY" -eq 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RESET=$'\e[0m' BOLD=$'\e[1m' DIM=$'\e[2m' RED=$'\e[31m' GREEN=$'\e[32m'
  YELLOW=$'\e[33m' BLUE=$'\e[34m' CYAN=$'\e[38;2;150;241;241m'
else
  RESET="" BOLD="" DIM="" RED="" GREEN="" YELLOW="" BLUE="" CYAN=""
fi

# fd 3 is the terminal, fd 5 the log. stdout/stderr go to the log once main() sets it up.
exec 3>&1 5>/dev/null

line() { printf '%s\n' "$1" >&5; printf '%s\n' "${2:-$1}" >&3; }
info() { line "   [*] $*" "   ${BLUE}[*]${RESET} $*"; }
ok()   { line "   [+] $*" "   ${GREEN}[+]${RESET} $*"; }
warn() { line "   [!] $*" "   ${YELLOW}[!]${RESET} $*"; }
err()  { line "   [-] $*" "   ${RED}[-]${RESET} $*"; }
note() { SUMMARY+=("$*"); }
tilde() { printf '%s' "${1/#$HOME/\~}"; }

step() {
  STEP_NUM=$((STEP_NUM + 1))
  STEP="$1"
  local tag rule
  tag=$(printf '[%02d/%d]' "$STEP_NUM" "$TOTAL_STEPS")
  printf -v rule '%*s' $((56 - ${#tag} - ${#1})) ''
  line "" ""
  line " $tag $1" " ${BOLD}${BLUE}${tag}${RESET} ${BOLD}$1${RESET} ${DIM}${rule// /─}${RESET}"
}

elapsed() {
  local s=$((SECONDS - $1))
  if [ "$s" -ge 60 ]; then printf '%dm%02ds' $((s / 60)) $((s % 60)); else printf '%ds' "$s"; fi
}

die() {
  trap - ERR
  err "$*"
  failure_hints
  exit 1
}

failure_hints() {
  [ -n "$LOG_FILE" ] || return 0
  if [ -s "$LOG_FILE" ]; then
    line "" ""
    line "   Last lines of the log:" "   ${DIM}Last lines of the log:${RESET}"
    tail -n 12 "$LOG_FILE" | sed "s/^/     ${DIM}/; s/\$/${RESET}/" >&3
  fi
  line "" ""
  info "Log: $(tilde "$LOG_FILE")"
  [ -z "$BACKUP_FILE" ] || info "Previous configs: $(tilde "$BACKUP_FILE")"
  [ -z "$REMOVED_SHELL" ] || info "Removed shell, to get it back: sudo pacman -S $REMOVED_SHELL"
  info "Running the script again resumes where it stopped."
}

# shellcheck disable=SC2317,SC2329
on_error() {
  local code=$1 lineno=$2
  err "Failed during \"$STEP\" (line $lineno, exit $code)"
  failure_hints
  exit "$code"
}

# shellcheck disable=SC2317,SC2329
on_interrupt() {
  [ -z "$TASK_PID" ] || kill "$TASK_PID" 2>/dev/null || true
  printf '\r\e[K' >&3
  err "Interrupted during \"$STEP\""
  exit 130
}

# shellcheck disable=SC2317,SC2329
on_exit() {
  [ -z "$SUDO_PID" ] || kill "$SUDO_PID" 2>/dev/null || true
  [ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
}

# Commands

have() { command -v "$1" >/dev/null 2>&1; }
pkg_installed() { pacman -Q "$1" >/dev/null 2>&1; }
in_repos() { pacman -Sp --print-format '%n' "$1" >/dev/null 2>&1; }
svc_enabled() { systemctl is-enabled "$1" >/dev/null 2>&1; }

dry() {
  local cmd=${1/"${YAY_FLAGS[*]}"/[flags]}
  line "   [~] $cmd" "   ${DIM}[~] $cmd${RESET}"
}

# stdin is /dev/null so nothing reads the rest of the script when piped via curl
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    dry "$*"
    return 0
  fi
  "$@" </dev/null
}

# task <label> <cmd...> runs cmd in the background with its output going to the log
task() {
  local label=$1 start=$SECONDS rc=0 i=0
  shift
  if [ "$DRY_RUN" -eq 1 ]; then
    dry "$*"
    return 0
  fi
  printf '\n$ %s\n' "$*"
  "$@" </dev/null &
  TASK_PID=$!
  if [ "$TTY" -eq 1 ]; then
    local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    [ "${TERM:-}" != linux ] || frames=('|' '/' '-' "\\")
    while kill -0 "$TASK_PID" 2>/dev/null; do
      printf '\r   %s[%s]%s %s %s%s%s\e[K' "$BLUE" "${frames[i++ % ${#frames[@]}]}" "$RESET" \
        "$label" "$DIM" "$(elapsed "$start")" "$RESET" >&3
      sleep 0.1
    done
    printf '\r\e[K' >&3
  fi
  wait "$TASK_PID" || rc=$?
  TASK_PID=""
  if [ "$rc" -eq 0 ]; then
    line "   [+] $label ($(elapsed "$start"))" "   ${GREEN}[+]${RESET} $label ${DIM}$(elapsed "$start")${RESET}"
  else
    err "$label"
  fi
  return "$rc"
}

# retry <n> <cmd...>
retry() {
  local tries=$1 i
  shift
  for ((i = 1; i <= tries; i++)); do
    "$@" && return 0
    if [ "$i" -lt "$tries" ]; then
      warn "Attempt $i of $tries failed, retrying in 5s"
      sleep 5
    fi
  done
  return 1
}

# State for uninstall.sh

state_has() { grep -qs "^$1=" "$STATE_DIR/state"; }

state_set() {
  [ "$DRY_RUN" -eq 0 ] || return 0
  mkdir -p "$STATE_DIR"
  { grep -sv "^$1=" "$STATE_DIR/state" || true; printf '%s=%s\n' "$1" "$2"; } >"$STATE_DIR/state.tmp"
  mv "$STATE_DIR/state.tmp" "$STATE_DIR/state"
}

# First run only, so a re-run never overwrites what the system looked like originally
snapshot_packages() {
  [ "$DRY_RUN" -eq 0 ] && [ ! -f "$STATE_DIR/packages-before" ] || return 0
  mkdir -p "$STATE_DIR"
  pacman -Qq >"$STATE_DIR/packages-before"
  state_set installed "$(date +%F)"
}

# UI

banner() {
  printf '%s' "$CYAN" >&3
  cat >&3 <<'EOF'

   ╭─────────────────────────────────────────────────╮
   │      ______           __          __  _         │
   │     / ____/___ ____  / /__  _____/ /_(_)___ _   │
   │    / /   / __ `/ _ \/ / _ \/ ___/ __/ / __ `/   │
   │   / /___/ /_/ /  __/ /  __(__  ) /_/ / /_/ /    │
   │   \____/\__,_/\___/_/\___/____/\__/_/\__,_/     │
   │                                                 │
   ╰─────────────────────────────────────────────────╯
EOF
  printf '%s' "$RESET" >&3
  printf '    %sautoinstall%s %sv%s%s%*s%s\n' "$BOLD" "$RESET" "$DIM" "$VERSION" "$RESET" \
    $((37 - ${#VERSION})) "$AUTHOR" "" >&3
  printf 'caelestia-autoinstall v%s (%s)\n' "$VERSION" "$AUTHOR" >&5
  if [ "$DRY_RUN" -eq 1 ]; then
    line "" ""
    warn "Dry run: nothing will be changed"
  fi
}

usage() {
  cat >&3 <<EOF
caelestia-autoinstall v$VERSION - $AUTHOR
Installs the Caelestia dots (Hyprland + Quickshell) on Arch-based distros.

Usage: bash install.sh [options]

Options:
  --apps LIST       Install these apps without asking (ids or menu numbers)
                    brave, chrome, zen, vscode, vscodium, pycharm, zed, nvim,
                    spotify, discord, telegram, vlc, obs, keepassxc, obsidian,
                    libreoffice, qbittorrent, gimp
  -y, --yes         Don't show the apps menu
  --enable LIST     Extra Caelestia components (e.g. uwsm,todoist)
  --disable LIST    Default Caelestia components to skip (e.g. firefox)
  --dm MANAGER      Login screen: auto (default), sddm, greetd, none
  --no-cleanup      Keep build caches
  --reboot          Reboot when done
  --dry-run         Show what would be done without changing anything
  -h, --help        Show this help
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --apps) [ $# -ge 2 ] || die "--apps needs a list"; APPS_ARG="$2"; ASK_APPS=0; shift 2 ;;
      --apps=*) APPS_ARG="${1#*=}"; ASK_APPS=0; shift ;;
      -y | --yes) ASK_APPS=0; shift ;;
      --enable) [ $# -ge 2 ] || die "--enable needs a list"; ENABLE="$2"; shift 2 ;;
      --enable=*) ENABLE="${1#*=}"; shift ;;
      --disable) [ $# -ge 2 ] || die "--disable needs a list"; DISABLE="$2"; shift 2 ;;
      --disable=*) DISABLE="${1#*=}"; shift ;;
      --dm) [ $# -ge 2 ] || die "--dm needs a value"; DM_CHOICE="$2"; shift 2 ;;
      --dm=*) DM_CHOICE="${1#*=}"; shift ;;
      --no-cleanup) DO_CLEANUP=0; shift ;;
      --reboot) DO_REBOOT=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h | --help) usage; exit 0 ;;
      *) die "Unknown option: $1 (see --help)" ;;
    esac
  done
  case "$DM_CHOICE" in
    auto | sddm | greetd | none) ;;
    *) die "--dm must be auto, sddm, greetd or none (got: $DM_CHOICE)" ;;
  esac
}

# Distro

os_field() { sed -n "s/^$1=//p" "$OS_RELEASE_FILE" | head -n1 | tr -d "\"'"; }

detect_os() {
  step "Detecting the system"
  [ -r "$OS_RELEASE_FILE" ] || die "Can't read $OS_RELEASE_FILE"

  OS_ID=$(os_field ID | tr '[:upper:]' '[:lower:]')
  OS_LIKE=$(os_field ID_LIKE | tr '[:upper:]' '[:lower:]')
  OS_NAME=$(os_field PRETTY_NAME)
  OS_NAME=${OS_NAME:-$(os_field NAME)}
  OS_NAME=${OS_NAME:-$OS_ID}

  case " $OS_ID $OS_LIKE " in
    *" arch "* | *" archlinux "*) FAMILY="arch" ;;
    *" debian "* | *" ubuntu "*) FAMILY="debian" ;;
    *" fedora "* | *" rhel "* | *" centos "*) FAMILY="fedora" ;;
    *" suse "* | *" opensuse "*) FAMILY="suse" ;;
    *) FAMILY="other" ;;
  esac
  case "$OS_ID" in
    cachyos | endeavouros | manjaro | garuda | artix | arcolinux | rebornos | archcraft | biglinux | parabola) FAMILY="arch" ;;
  esac
  if [ "$FAMILY" = "other" ] && have pacman && [ -f /etc/pacman.conf ]; then
    FAMILY="arch"
  fi

  info "$OS_NAME ($OS_ID${OS_LIKE:+, like $OS_LIKE})"
  if [ "$FAMILY" != "arch" ]; then
    unsupported
    exit 2
  fi
  ok "Arch family"

  if [ "$OS_ID" = "manjaro" ]; then
    warn "Manjaro holds packages back from Arch, AUR builds like quickshell-git may fail"
  fi
}

unsupported() {
  local family
  case "$FAMILY" in
    debian) family="Debian/Ubuntu family (Mint, Pop!_OS, Zorin...)" ;;
    fedora) family="Fedora/RHEL family" ;;
    suse) family="openSUSE" ;;
    *) family="not an Arch derivative" ;;
  esac
  err "$OS_NAME is not supported: $family"
  cat >&3 <<EOF

   Caelestia needs the latest Hyprland, quickshell-git and several packages that
   only exist in the AUR. Its own installer only handles dependencies on Arch, and
   building all of that against older libraries here would most likely leave a
   broken desktop.

   Nothing was changed. On an Arch-based distro such as CachyOS or EndeavourOS
   this script does everything automatically.

EOF
}

# Requirements

preflight() {
  step "Checking requirements"

  [ "$(id -u)" -ne 0 ] || die "Don't run this as root or with sudo, it asks for your password once"
  ok "User: $(id -un)"

  local arch
  arch=$(uname -m)
  [ "$arch" = "x86_64" ] || die "Unsupported architecture: $arch (several packages are x86_64 only)"
  ok "Architecture: $arch"

  have sudo || die "sudo is missing: install it as root (pacman -S sudo) and add yourself to wheel"
  have pacman || die "pacman not found"

  if [ -d /run/systemd/system ]; then
    HAS_SYSTEMD=1
  else
    warn "No systemd (Artix?): services and the login screen are left to you"
  fi

  detect_vm
  check_internet
  check_disk
}

detect_vm() {
  have systemd-detect-virt || return 0
  local v
  v=$(systemd-detect-virt --vm 2>/dev/null || true)
  [ -n "$v" ] && [ "$v" != "none" ] || return 0
  VIRT="$v"
  warn "Virtual machine ($VIRT): enable 3D acceleration or Hyprland won't start"
}

check_internet() {
  local url
  if ! have curl; then
    warn "curl not installed, skipping the connection check"
    return 0
  fi
  for url in https://aur.archlinux.org https://github.com https://archlinux.org; do
    if curl -fsS --max-time 15 -o /dev/null "$url" 2>/dev/null; then
      ok "Internet: connected"
      [ "$url" = "https://aur.archlinux.org" ] || warn "The AUR isn't answering right now, it may be down"
      return 0
    fi
  done
  die "No internet connection"
}

free_gb() { df -Pk "$1" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}'; }

check_disk() {
  local root_free home_free config_gb=0 need
  root_free=$(free_gb /)
  home_free=$(free_gb "$HOME")
  # The official installer copies ~/.config to ~/.config.bak
  if [ -d "$HOME/.config" ] && [ ! -e "$HOME/.config.bak" ]; then
    config_gb=$({ du -sk "$HOME/.config" 2>/dev/null || true; } | awk 'NR==1 {printf "%d", $1/1024/1024 + 1}')
    config_gb=${config_gb:-1}
  fi
  need=$((MIN_FREE_GB + config_gb))

  [ "${root_free:-0}" -ge "$MIN_FREE_GB" ] || die "Not enough space on /: ${root_free:-?} GB free, need $MIN_FREE_GB GB"
  [ "${home_free:-0}" -ge "$need" ] || die "Not enough space in home: ${home_free:-?} GB free, need $need GB"
  ok "Disk: $root_free GB free on /, $home_free GB in home"
}

# Apps

tty_available() { { : </dev/tty; } 2>/dev/null; }

show_app_menu() {
  local left=() right=() entry grp label last="" n=0 first_right cell rows i blank
  first_right=$(printf '%s\n' "${APP_LIST[@]}" | cut -d'|' -f1 | uniq | sed -n 3p)
  printf -v blank '%32s' ''
  local -n col=left
  for entry in "${APP_LIST[@]}"; do
    n=$((n + 1))
    IFS='|' read -r grp _ label _ <<<"$entry"
    if [ "$grp" != "$last" ]; then
      [ "$grp" != "$first_right" ] || local -n col=right
      [ "${#col[@]}" -eq 0 ] || col+=("$blank")
      printf -v cell '%-32s' "$grp"
      col+=("${BOLD}${cell}${RESET}")
      last=$grp
    fi
    printf -v cell '%3d  %-27s' "$n" "$label"
    col+=("${BLUE}${cell:0:3}${RESET}${cell:3}")
  done

  line "" ""
  rows=$((${#left[@]} > ${#right[@]} ? ${#left[@]} : ${#right[@]}))
  if [ "$(tput cols 2>/dev/null || echo 80)" -ge 72 ]; then
    for ((i = 0; i < rows; i++)); do
      printf '     %s%s\n' "${left[i]:-$blank}" "${right[i]:-}" >&3
    done
  else
    printf '     %s\n' "${left[@]}" "$blank" "${right[@]}" >&3
  fi
  line "" ""
}

# Turns "1 4-6 brave" into app ids
resolve_apps() {
  local tok a b i n id total=${#APP_LIST[@]} out=()
  for tok in ${1//,/ }; do
    case "$tok" in
      a | all) for ((n = 1; n <= total; n++)); do out+=("$n"); done ;;
      *[0-9]-[0-9]*)
        a=${tok%-*} b=${tok#*-}
        if [[ "$a$b" =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$b" -le "$total" ] && [ "$a" -le "$b" ]; then
          for ((n = a; n <= b; n++)); do out+=("$n"); done
        else
          warn "Ignoring invalid range: $tok"
        fi
        ;;
      *[!0-9]*)
        n=0
        for ((i = 0; i < total; i++)); do
          id=$(cut -d'|' -f2 <<<"${APP_LIST[i]}")
          [ "$id" != "$tok" ] || n=$((i + 1))
        done
        if [ "$n" -gt 0 ]; then out+=("$n"); else warn "Ignoring unknown app: $tok"; fi
        ;;
      *)
        if [ "$tok" -ge 1 ] && [ "$tok" -le "$total" ]; then out+=("$tok"); else warn "Ignoring invalid number: $tok"; fi
        ;;
    esac
  done
  [ "${#out[@]}" -eq 0 ] || printf '%s\n' "${out[@]}" | sort -nu
}

choose_apps() {
  step "Optional apps"
  local answer="" n label src picked=()

  if [ -n "$APPS_ARG" ]; then
    answer=$APPS_ARG
  elif [ "$ASK_APPS" -eq 1 ] && tty_available; then
    show_app_menu
    line "   Numbers or ranges (1 4-6), a for all, Enter for none." \
      "   ${DIM}Numbers or ranges (1 4-6), ${RESET}a${DIM} for all, ${RESET}Enter${DIM} for none.${RESET}"
    printf '   %s[?]%s > ' "$YELLOW" "$RESET" >&3
    read -r answer </dev/tty || answer=""
    printf '   [?] > %s\n' "$answer" >&5
  fi

  while read -r n; do
    [ -n "$n" ] || continue
    IFS='|' read -r _ _ label src <<<"${APP_LIST[n - 1]}"
    picked+=("$label")
    case "$src" in
      c:*) ENABLE="${ENABLE:+$ENABLE,}${src#c:}" ;;
      *) EXTRA_PKGS+=("$src") ;;
    esac
  done < <(resolve_apps "$answer")

  if [ "${#picked[@]}" -eq 0 ]; then
    info "No extra apps"
  else
    ok "Selected: $(printf '%s, ' "${picked[@]}" | sed 's/, $//')"
    note "Apps: $(printf '%s, ' "${picked[@]}" | sed 's/, $//')"
  fi
}

start_sudo() {
  step "Administrator access"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "Dry run, not asking for a password"
    return 0
  fi
  info "Enter your password (only once)"
  sudo -v || die "Couldn't get sudo rights, is your user in the wheel group?"
  (
    while kill -0 "$$" 2>/dev/null; do
      sudo -n true 2>/dev/null || true
      sleep 45
    done
  ) &
  SUDO_PID=$!
  ok "sudo ready"
}

package_manager_running() {
  local p
  for p in pacman yay paru pamac-daemon pamac-manager packagekitd octopi; do
    pgrep -x "$p" >/dev/null 2>&1 && return 0
  done
  return 1
}

wait_for_pacman_lock() {
  local lock=/var/lib/pacman/db.lck waited=0
  [ -e "$lock" ] || return 0
  info "pacman is locked, waiting up to 10 minutes"
  while [ -e "$lock" ] && [ "$waited" -lt 600 ]; do
    sleep 5
    waited=$((waited + 5))
  done
  [ -e "$lock" ] || return 0
  if package_manager_running; then
    die "Another program is installing packages (pacman, Discover, pamac...), wait for it and run this again"
  fi
  warn "Removing a stale pacman lock left by an interrupted install"
  run sudo rm -f "$lock"
}

# Backup

backup_configs() {
  step "Backing up current configs"
  local items=() p
  for p in hypr fish foot fastfetch btop micro Thunar starship.toml spicetify uwsm quickshell caelestia; do
    [ ! -e "$HOME/.config/$p" ] || items+=(".config/$p")
  done
  if [ "${#items[@]}" -eq 0 ]; then
    info "Nothing to back up"
    return 0
  fi
  BACKUP_FILE="$HOME/caelestia-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "Would save ${items[*]} to $(tilde "$BACKUP_FILE")"
    return 0
  fi
  if tar -czf "$BACKUP_FILE" -C "$HOME" "${items[@]}" 2>/dev/null; then
    ok "Saved to $(tilde "$BACKUP_FILE")"
    note "Previous configs: $(tilde "$BACKUP_FILE")"
    state_has backup || state_set backup "$BACKUP_FILE"
  else
    warn "Backup failed, continuing (the official installer also copies ~/.config to ~/.config.bak)"
    BACKUP_FILE=""
  fi
}

# System update

refresh_mirrors() {
  # Each distro has its own tool; Arch's reflector would break Manjaro or Artix
  case "$OS_ID" in
    manjaro)
      ! have pacman-mirrors || task "Ranking mirrors" sudo pacman-mirrors --fasttrack 5 || true ;;
    artix)
      info "Keeping the current Artix mirrors" ;;
    cachyos)
      if have cachyos-rate-mirrors; then task "Ranking mirrors" sudo cachyos-rate-mirrors || true
      else refresh_arch_mirrorlist; fi ;;
    *)
      refresh_arch_mirrorlist ;;
  esac
}

refresh_arch_mirrorlist() {
  local list=/etc/pacman.d/mirrorlist
  if ! have reflector; then
    info "reflector not installed, keeping the current mirrors"
    return 0
  fi
  run sudo cp "$list" "$list.caelestia-autoinstall.bak" || true
  if ! task "Ranking mirrors" sudo reflector --latest 20 --protocol https --sort rate --save "$list"; then
    warn "reflector failed, restoring the previous mirrorlist"
    run sudo cp "$list.caelestia-autoinstall.bak" "$list" || true
  fi
}

update_system() {
  step "Updating the system"
  wait_for_pacman_lock

  # A wrong clock breaks signature checks
  if [ "$HAS_SYSTEMD" -eq 1 ] && ! svc_enabled chronyd.service && ! svc_enabled ntpd.service && ! svc_enabled openntpd.service; then
    run sudo timedatectl set-ntp true >/dev/null 2>&1 || true
  fi

  # Keyrings first, stale ones make everything else fail with "invalid signature"
  local keyrings=() k
  in_repos archlinux-keyring && keyrings+=(archlinux-keyring)
  for k in cachyos-keyring endeavouros-keyring manjaro-keyring artix-keyring chaotic-keyring garuda-keyring; do
    ! pkg_installed "$k" || keyrings+=("$k")
  done
  [ "${#keyrings[@]}" -gt 0 ] || keyrings=(archlinux-keyring)
  if ! retry 2 task "Keyrings" sudo pacman -Sy --needed --noconfirm "${keyrings[@]}"; then
    refresh_mirrors
    retry 2 task "Keyrings" sudo pacman -Syy --needed --noconfirm "${keyrings[@]}" ||
      warn "Couldn't update the keyrings, trying the upgrade anyway"
  fi

  if ! retry 2 task "System upgrade" sudo pacman -Syu --noconfirm; then
    refresh_mirrors
    retry 2 task "System upgrade" sudo pacman -Syyu --noconfirm ||
      die "System upgrade failed, usually a broken mirror or a full disk"
  fi
}

ensure_base_tools() {
  step "Base tools"
  retry 3 task "git, base-devel, curl, python" sudo pacman -S --needed --noconfirm git base-devel curl python ||
    die "Couldn't install the base tools"
}

# shellcheck disable=SC2317,SC2329
makepkg_in() { cd "$1" && makepkg -si --noconfirm; }

ensure_yay() {
  step "AUR helper"
  if have yay; then
    ok "yay already installed"
    return 0
  fi
  if in_repos yay; then
    retry 3 task "yay (repos)" sudo pacman -S --needed --noconfirm yay || die "Couldn't install yay"
  else
    local dir="$TMP_DIR/yay-bin"
    retry 3 task "Cloning yay-bin" git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$dir" ||
      die "Couldn't clone yay-bin, the AUR is probably down"
    task "Building yay-bin" makepkg_in "$dir" || die "Couldn't build yay"
  fi
  if [ "$DRY_RUN" -eq 0 ]; then
    have yay || die "yay isn't available after installing it"
    yay -Y --gendb </dev/null >/dev/null 2>&1 || true
  fi
}

# Conflicts

resolve_conflicts() {
  step "Known conflicts"
  local found=0 p

  # Caelestia needs quickshell-git; any other build (quickshell, CachyOS' noctalia-qs)
  # clashes. It goes together with whatever depends on it, and only later on.
  local qs_variants=()
  while read -r p; do
    case "$p" in
      "" | quickshell-git | quickshell-git-debug) ;;
      *) qs_variants+=("$p") ;;
    esac
  done < <(pacman -Qq 2>/dev/null | grep -E '^(quickshell.*|noctalia-qs.*)$' || true)

  if [ "${#qs_variants[@]}" -gt 0 ]; then
    found=1
    QS_VARIANTS="${qs_variants[*]}"
    QS_REMOVE=$(pacman -Rcp --print-format '%n' "${qs_variants[@]}" 2>/dev/null | grep -v '^caelestia-' | paste -sd ' ' || true)
    QS_REMOVE=${QS_REMOVE:-$QS_VARIANTS}
    warn "Clashing quickshell build: $QS_VARIANTS"
    if printf '%s\n' "$QS_REMOVE" | grep -qiE 'greet|sddm|gdm|lightdm|plasma|gnome-shell|kwin|mutter'; then
      die "Removing $QS_VARIANTS would also remove: $QS_REMOVE. Remove it yourself and run this again"
    fi
    info "Will be replaced right before building quickshell-git: $QS_REMOVE"
  fi

  # Caelestia uses PipeWire; jack2/pulseaudio clash and --noconfirm answers "no"
  if pkg_installed jack2 || pkg_installed pulseaudio; then
    found=1
    local extras=()
    while read -r p; do
      [ -z "$p" ] || extras+=("$p")
    done < <(pacman -Qq 2>/dev/null | grep -xE 'pulseaudio-(alsa|bluetooth|jack|zeroconf|equalizer|lirc|rtp)|jack2-dbus' || true)
    [ "${#extras[@]}" -eq 0 ] || run sudo pacman -Rdd --noconfirm "${extras[@]}" || true
    # --ask 4 answers yes to "remove the conflicting package?"
    retry 2 task "Switching audio to PipeWire" sudo pacman -S --needed --noconfirm --ask 4 \
      pipewire pipewire-pulse pipewire-jack pipewire-alsa wireplumber || die "Couldn't switch audio to PipeWire"
    note "Audio switched to PipeWire (was jack2/pulseaudio)"
  fi

  # Repo conflicts are handled by --ask 4, this one is repo vs AUR
  if pkg_installed darkly && ! pkg_installed darkly-bin && ! in_repos darkly-bin; then
    found=1
    if run sudo pacman -Rdd --noconfirm darkly; then ok "Removed darkly (replaced by darkly-bin)"; else warn "Couldn't remove darkly"; fi
  fi

  [ "$found" -eq 1 ] || ok "None found"
}

# Dependencies, read from the official manifest so they never go stale

read_manifest() {
  local manifest="$TMP_DIR/manifest.toml"
  retry 3 curl -fsSL --max-time 30 -o "$manifest" "$MANIFEST_URL" || die "Couldn't download Caelestia's manifest"

  python3 - "$manifest" "$ENABLE" "$DISABLE" "$DOTS_STATE" <<'PY'
import json, sys, tomllib

manifest, enable_arg, disable_arg, state_path = sys.argv[1:5]
with open(manifest, "rb") as f:
    m = tomllib.load(f)

def split(s):
    return {x.strip() for x in s.split(",") if x.strip()}

comps = {c["name"]: c for c in m.get("components", []) if c.get("name")}
enable, disable = split(enable_arg), split(disable_arg)
for name in sorted((enable | disable) - comps.keys()):
    print(f"WARN Unknown component ignored: {name}")
enable &= comps.keys()
disable &= comps.keys()

# Already installed: keep what was enabled before and reinstall only if something changed
try:
    with open(state_path) as f:
        prev = set(json.load(f).get("enabled_components", [])) & comps.keys()
except (OSError, ValueError):
    prev = None
if prev is not None:
    if enable - prev or disable & prev:
        print("RECONFIGURE")
    enable = (enable | prev) - disable
    disable |= {n for n, c in comps.items() if c.get("default") and n not in enable}

print("ENABLE " + ",".join(sorted(enable)))
print("DISABLE " + ",".join(sorted(disable)))

pkgs = list(m.get("packages", []))
for name, c in comps.items():
    if (c.get("default") or name in enable) and name not in disable:
        pkgs += c.get("packages", [])
for p in dict.fromkeys(pkgs):
    if not p.startswith("local:"):
        print("PKG " + p)
PY
}

install_dependencies() {
  step "Caelestia dependencies"
  local line pkg listing repo_pkgs=() aur_pkgs=() failed=()

  listing=$(read_manifest) || die "Couldn't read Caelestia's manifest"
  while IFS= read -r line; do
    case "$line" in
      WARN\ *) warn "${line#WARN }" ;;
      RECONFIGURE) RECONFIGURE=1 ;;
      ENABLE*) ENABLE=${line#ENABLE}; ENABLE=${ENABLE# } ;;
      DISABLE*) DISABLE=${line#DISABLE}; DISABLE=${DISABLE# } ;;
      PKG\ *)
        pkg=${line#PKG }
        case "$pkg" in
          quickshell*) ;;
          *) if in_repos "$pkg"; then repo_pkgs+=("$pkg"); else aur_pkgs+=("$pkg"); fi ;;
        esac
        ;;
    esac
  done <<<"$listing"

  for pkg in caelestia-cli caelestia-shell; do
    case " ${aur_pkgs[*]} " in *" $pkg "*) ;; *) aur_pkgs+=("$pkg") ;; esac
  done
  info "${#repo_pkgs[@]} from the repos, ${#aur_pkgs[@]} from the AUR"

  if [ "${#repo_pkgs[@]}" -gt 0 ] &&
    ! retry 2 task "Repository packages" sudo pacman -S --needed --noconfirm --ask 4 "${repo_pkgs[@]}"; then
    warn "Batch install failed, trying one by one"
    for pkg in "${repo_pkgs[@]}"; do
      task "$pkg" sudo pacman -S --needed --noconfirm --ask 4 "$pkg" || failed+=("$pkg")
    done
    [ "${#failed[@]}" -eq 0 ] || die "Couldn't install: ${failed[*]} (the log shows the exact conflict)"
  fi

  remove_conflicting_quickshell
  install_real_quickshell

  if ! retry 2 aur_install "AUR packages (some are compiled)" "${aur_pkgs[@]}"; then
    warn "Batch install failed, trying one by one"
    failed=()
    for pkg in "${aur_pkgs[@]}"; do
      retry 2 aur_install "$pkg" "$pkg" || failed+=("$pkg")
    done
    case " ${failed[*]} " in
      "  ") ;;
      *" caelestia-shell "* | *" caelestia-cli "*) die "Couldn't install essential packages: ${failed[*]}" ;;
      *) warn "Skipped (optional): ${failed[*]}"; note "Optional packages that failed: ${failed[*]}" ;;
    esac
  fi
  verify_quickshell
}

# When the AUR RPC is down yay falls back to the first provider it finds
# (caelestia-cli-git instead of caelestia-cli) and the official installer then
# clashes with it, so the AUR has to answer and the exact names are checked after
aur_up() { curl -fsS --max-time 20 "https://aur.archlinux.org/rpc?v=5&type=info&arg=caelestia-cli" 2>/dev/null | grep -q '"resultcount":1'; }

wait_for_aur() {
  local i
  for ((i = 1; i <= 12; i++)); do
    aur_up && return 0
    [ "$i" -gt 1 ] || warn "The AUR isn't answering, waiting up to 2 min"
    sleep 10
  done
  return 1
}

# Installed packages that stand in for the given ones (caelestia-cli-git for caelestia-cli)
# shellcheck disable=SC2317,SC2329
substitutes() {
  LC_ALL=C pacman -Qi 2>/dev/null | awk -v want=" $* " '
    /^[^ ]/ { field = $1 }
    /^Name / { name = $3 }
    field == "Provides" {
      if (/^Provides/) sub(/^Provides *: /, "")
      for (i = 1; i <= NF; i++) {
        p = $i
        sub(/[<>=].*/, "", p)
        if (p != name && index(want, " " p " ")) print name
      }
    }' | sort -u | paste -sd ' ' || true
}

# aur_install <label> <pkg...>
# shellcheck disable=SC2317,SC2329
aur_install() {
  local label=$1 subs missing=() p
  shift
  wait_for_aur || { err "The AUR isn't answering"; return 1; }
  subs=$(substitutes "$@")
  if [ -n "$subs" ]; then
    # shellcheck disable=SC2086
    run sudo pacman -Rdd --noconfirm $subs || return 1
    ok "Removed $subs (replaced by the packages Caelestia expects)"
  fi
  task "$label" yay -S "${YAY_FLAGS[@]}" "$@" || return 1
  [ "$DRY_RUN" -eq 0 ] || return 0
  for p in "$@"; do pkg_installed "$p" || missing+=("$p"); done
  [ "${#missing[@]}" -eq 0 ] || { warn "Not installed by their exact name: ${missing[*]}"; return 1; }
}

quickshell_provider() { pacman -Q quickshell-git 2>/dev/null | awk '{print $1}' || true; }

# Always the real one from the AUR: CachyOS' noctalia-qs claims to provide
# quickshell-git and Caelestia then fails with "Unrecognized pragma DefaultEnv"
install_real_quickshell() {
  if [ "$(quickshell_provider)" = "quickshell-git" ]; then
    ok "quickshell-git already installed"
  else
    retry 2 task "Building quickshell-git (5-15 min)" yay -S "${YAY_FLAGS[@]}" aur/quickshell-git ||
      die "Couldn't build quickshell-git"
  fi
  REMOVED_SHELL=""
}

verify_quickshell() {
  [ "$DRY_RUN" -eq 0 ] || return 0
  local real
  real=$(quickshell_provider)
  [ "$real" != "quickshell-git" ] || return 0
  if [ -n "$real" ]; then
    warn "quickshell-git is provided by $real, which doesn't work with Caelestia"
    run sudo pacman -Rdd --noconfirm "$real" || die "Couldn't remove $real"
    note "Replaced $real with the real quickshell-git"
  fi
  install_real_quickshell
  [ "$(quickshell_provider)" = "quickshell-git" ] || die "quickshell-git didn't install correctly"
}

# Only once the repo packages are in and the AUR answers, so a failure never
# leaves the user without a shell
remove_conflicting_quickshell() {
  [ -n "$QS_VARIANTS" ] || return 0
  retry 3 git ls-remote --exit-code https://aur.archlinux.org/quickshell-git.git HEAD >/dev/null 2>&1 ||
    die "The AUR isn't answering. Nothing was removed, try again later"
  local v dependents=()
  for v in $QS_REMOVE; do
    case " $QS_VARIANTS " in *" $v "*) ;; *) dependents+=("$v") ;; esac
  done
  if [ "${#dependents[@]}" -gt 0 ]; then
    run sudo pacman -R --noconfirm "${dependents[@]}" || die "Couldn't remove ${dependents[*]}"
  fi
  # shellcheck disable=SC2086
  run sudo pacman -Rdd --noconfirm $QS_VARIANTS || die "Couldn't remove $QS_VARIANTS"
  REMOVED_SHELL="$QS_REMOVE"
  state_set removed_shell "$QS_REMOVE"
  ok "Removed $QS_REMOVE"
  note "Removed clashing shell: $QS_REMOVE"
}

# Official installer

run_caelestia_installer() {
  local args=(--noconfirm --aur-helper yay)
  [ "$DRY_RUN" -eq 1 ] || have caelestia || die "The caelestia command wasn't installed"
  wait_for_aur || warn "The AUR still isn't answering, trying anyway"

  if [ -f "$DOTS_STATE" ] && [ "$RECONFIGURE" -eq 0 ]; then
    step "Updating Caelestia"
    # The system is already up to date, an AUR hiccup here isn't worth failing for
    if retry 2 task "caelestia update" caelestia update "${args[@]}"; then
      note "Caelestia updated to the latest version"
    else
      warn "caelestia update didn't finish (usually the AUR), run it again later"
      note "Pending: caelestia update"
    fi
    return 0
  fi

  step "Running the official installer"
  [ -z "$ENABLE" ] || args+=(--enable-components "$ENABLE")
  [ -z "$DISABLE" ] || args+=(--disable-components "$DISABLE")
  retry 2 task "caelestia install" caelestia install "${args[@]}" || die "The official installer failed"
  note "Your tweaks go in ~/.config/caelestia/ (hypr-user.lua, hypr-vars.lua)"
}

# VM graphics can't give Quickshell an EGL surface ("Could not create EGL surface")
# and the bar never shows up, so the session renders in software. hypr-user.lua is
# loaded before the shell starts and caelestia update never touches it.
vm_software_rendering() {
  [ -n "$VIRT" ] || return 0
  local file="${XDG_CONFIG_HOME:-$HOME/.config}/caelestia/hypr-user.lua"
  if grep -qs LIBGL_ALWAYS_SOFTWARE "$file"; then
    ok "Software rendering already set for the VM"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    dry "enable software rendering in $(tilde "$file")"
    return 0
  fi
  mkdir -p "$(dirname "$file")"
  printf '\n-- caelestia-autoinstall: VM without a usable GPU, delete on real hardware\nhl.env("LIBGL_ALWAYS_SOFTWARE", "1")\n' >>"$file"
  ok "Software rendering enabled for the VM"
  note "VM: software rendering is set in $(tilde "$file")"
}

install_apps() {
  step "Installing apps"
  if [ "${#EXTRA_PKGS[@]}" -eq 0 ]; then
    info "Nothing to install"
    return 0
  fi
  local p failed=()
  for p in "${EXTRA_PKGS[@]}"; do
    retry 2 task "$p" yay -S "${YAY_FLAGS[@]}" "$p" || failed+=("$p")
  done
  [ "${#failed[@]}" -eq 0 ] || note "Apps that failed: ${failed[*]}"
}

# Session, login screen and services

ensure_session() {
  step "Hyprland session"
  local sessions=/usr/share/wayland-sessions

  if ! ls "$sessions"/hyprland*.desktop >/dev/null 2>&1; then
    [ "$DRY_RUN" -eq 1 ] || die "No Hyprland session in $sessions, check that hyprland installed"
  fi

  # A session entry that uses uwsm fails at login without it
  if grep -qs uwsm "$sessions"/*.desktop; then
    pkg_installed uwsm || retry 2 task "uwsm" sudo pacman -S --needed --noconfirm uwsm || warn "Couldn't install uwsm"
    ! pkg_installed uwsm || run sudo pacman -D --asexplicit uwsm >/dev/null 2>&1 || true
  fi
  ok "Session ready"
}

current_dm() {
  local link=/etc/systemd/system/display-manager.service
  [ -L "$link" ] || return 1
  basename "$(readlink -f "$link")" .service
}

setup_greetd() {
  retry 2 task "greetd" sudo pacman -S --needed --noconfirm greetd greetd-tuigreet || die "Couldn't install greetd"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "Would write /etc/greetd/config.toml"
    return 0
  fi
  [ ! -f /etc/greetd/config.toml ] || sudo cp /etc/greetd/config.toml /etc/greetd/config.toml.bak
  sudo tee /etc/greetd/config.toml >/dev/null <<'EOF'
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --remember-session --asterisks --sessions /usr/share/wayland-sessions"
user = "greeter"
EOF
}

ensure_display_manager() {
  step "Login screen"
  if [ "$DM_CHOICE" = "none" ]; then
    info "Skipped (--dm none)"
    return 0
  fi
  if [ "$HAS_SYSTEMD" -eq 0 ]; then
    warn "Without systemd you need to enable SDDM or greetd yourself"
    note "Pending: enable a login screen"
    return 0
  fi

  local active wanted=""
  active=$(current_dm || true)
  state_has dm_before || state_set dm_before "$active"

  if [ "$DM_CHOICE" = "auto" ]; then
    if [ -n "$active" ]; then
      ok "Keeping $active"
      return 0
    fi
    # Installed but disabled is what leaves people on a TTY after rebooting
    if pkg_installed sddm; then
      wanted="sddm"
    elif pkg_installed gdm; then
      wanted="gdm"
    elif pkg_installed lightdm && pacman -Qq 2>/dev/null | grep -q '^lightdm-.*greeter'; then
      wanted="lightdm"
    fi
    wanted=${wanted:-sddm}
  else
    wanted="$DM_CHOICE"
    if [ "$active" = "$wanted" ]; then
      ok "$wanted already enabled"
      return 0
    fi
  fi

  case "$wanted" in
    sddm) retry 2 task "sddm" sudo pacman -S --needed --noconfirm sddm || { dm_failed "Couldn't install SDDM"; return 0; } ;;
    greetd) setup_greetd ;;
  esac

  if [ -n "$active" ] && [ "$active" != "$wanted" ]; then
    run sudo systemctl disable "$active.service" || true
  fi
  if ! run sudo systemctl enable "$wanted.service"; then
    if [ "$wanted" = "sddm" ]; then
      dm_failed "Couldn't enable SDDM"
      return 0
    fi
    warn "Couldn't enable $wanted, falling back to SDDM"
    wanted="sddm"
    if ! retry 2 task "sddm" sudo pacman -S --needed --noconfirm sddm || ! run sudo systemctl enable sddm.service; then
      dm_failed "Couldn't enable SDDM either"
      return 0
    fi
  fi
  run sudo systemctl set-default graphical.target >/dev/null 2>&1 || true
  state_set dm_after "$wanted"
  ok "$wanted enabled${active:+ (was $active)}"
  note "Login screen: $wanted${active:+ (was $active)}"
}

# Caelestia is already in place at this point, so this must not abort the run
dm_failed() {
  warn "$1"
  warn "After rebooting, log in on the console and run: sudo systemctl enable --now sddm"
  note "Pending: sudo systemctl enable --now sddm"
}

enable_services() {
  step "Services"
  if [ "$HAS_SYSTEMD" -eq 0 ]; then
    info "No systemd, skipped"
    return 0
  fi

  # Only when nothing else manages the network, never leave the user offline
  if pkg_installed networkmanager && ! svc_enabled NetworkManager.service; then
    local other
    other=$(systemctl list-unit-files --state=enabled --no-legend \
      'systemd-networkd.service' 'iwd.service' 'dhcpcd*.service' 'connman.service' \
      'netctl*' 'wpa_supplicant@*' 'wicd.service' 2>/dev/null | awk 'NR==1 {print $1}' || true)
    if [ -z "$other" ]; then
      run sudo systemctl enable NetworkManager.service && ok "NetworkManager enabled"
    else
      info "Network handled by $other, leaving NetworkManager off"
    fi
  else
    ok "Network unchanged"
  fi

  if pkg_installed bluez && ! svc_enabled bluetooth.service; then
    run sudo systemctl enable bluetooth.service && ok "Bluetooth enabled"
  fi

  if pkg_installed power-profiles-daemon && ! svc_enabled power-profiles-daemon.service; then
    if svc_enabled tlp.service || svc_enabled auto-cpufreq.service; then
      info "tlp/auto-cpufreq in use, leaving power-profiles-daemon off"
    else
      run sudo systemctl enable power-profiles-daemon.service && ok "power-profiles-daemon enabled"
    fi
  fi
}

# Cleanup and summary

record_foreign_before() { FOREIGN_BEFORE=$(pacman -Qqm 2>/dev/null | sort || true); }

cleanup_build_files() {
  step "Cleaning up"
  if [ "$DO_CLEANUP" -eq 0 ]; then
    info "Skipped (--no-cleanup)"
    return 0
  fi
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/yay" new p removed=0
  new=$(comm -13 <(printf '%s\n' "$FOREIGN_BEFORE") <(pacman -Qqm 2>/dev/null | sort) || true)
  for p in $new; do
    if [ -d "$cache/$p" ]; then
      run rm -rf "${cache:?}/$p"
      removed=$((removed + 1))
    fi
  done
  ok "Removed $removed build caches"
}

print_summary() {
  local s rule
  printf -v rule '%57s' ''
  rule=${rule// /─}

  line "" ""
  line " $rule" " ${CYAN}${rule}${RESET}"
  local title="Caelestia is installed"
  [ "$DRY_RUN" -eq 0 ] || title="Dry run finished"
  line "   [+] $title ($(elapsed 0))" "   ${GREEN}${BOLD}[+] $title${RESET} ${DIM}$(elapsed 0)${RESET}"
  line " $rule" " ${CYAN}${rule}${RESET}"
  for s in "${SUMMARY[@]}"; do info "$s"; done
  info "Log: $(tilde "$LOG_FILE")"
  line "" ""
  line "   Next: reboot and pick the Hyprland session." "   ${BOLD}Next:${RESET} reboot and pick the ${BOLD}Hyprland${RESET} session."
  line "   Update later with: caelestia update" "   ${DIM}Update later with:${RESET} caelestia update"
  line "" ""
}

maybe_reboot() {
  [ "$DO_REBOOT" -eq 1 ] || return 0
  info "Rebooting in 10s (Ctrl+C to cancel)"
  sleep 10
  run sudo systemctl reboot
}

main() {
  parse_args "$@"

  LOG_FILE="$HOME/caelestia-install-$(date +%Y%m%d-%H%M%S).log"
  exec 5>>"$LOG_FILE" >&5 2>&5
  trap 'on_error $? $LINENO' ERR
  trap on_interrupt INT TERM
  trap on_exit EXIT
  export GIT_TERMINAL_PROMPT=0
  SECONDS=0

  banner
  detect_os
  preflight
  TMP_DIR=$(mktemp -d)
  choose_apps
  start_sudo
  snapshot_packages
  backup_configs
  update_system
  ensure_base_tools
  record_foreign_before
  ensure_yay
  resolve_conflicts
  install_dependencies
  run_caelestia_installer
  vm_software_rendering
  install_apps
  ensure_session
  ensure_display_manager
  enable_services
  cleanup_build_files
  print_summary
  maybe_reboot
}

main "$@"; exit
