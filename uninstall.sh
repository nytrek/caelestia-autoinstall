#!/usr/bin/env bash
#
# caelestia-autoinstall - removes Caelestia and restores the configs
# backed up by install.sh.
#
# https://github.com/nytrek/caelestia-autoinstall
#
#   curl -fsSL https://raw.githubusercontent.com/nytrek/caelestia-autoinstall/main/uninstall.sh | bash

set -Eeuo pipefail

readonly VERSION="1.2.0"
readonly AUTHOR="github.com/nytrek"
readonly STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
readonly STATE_DIR="$STATE_HOME/caelestia-autoinstall"
readonly DOTS_STATE="$STATE_HOME/caelestia/dots-state.json"
readonly CORE_PKGS=(caelestia-shell caelestia-cli quickshell-git caelestia-firefox-theme)
# Never removed by --purge, even if install.sh brought them in
readonly PROTECTED='^(base|base-devel|linux.*|sudo|git|curl|python|yay|yay-bin|paru.*|.*-keyring|mesa|nvidia.*|networkmanager|pipewire.*|wireplumber|bluez.*|sddm|greetd.*|gdm|lightdm.*|uwsm)$'

PURGE=0
RESTORE=1
ASSUME_YES=0
DRY_RUN=0

LOG_FILE=""
SUDO_PID=""
BACKUP=""
PKGS=()
SUMMARY=()

TTY=0
[ -t 1 ] && TTY=1
if [ "$TTY" -eq 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RESET=$'\e[0m' BOLD=$'\e[1m' DIM=$'\e[2m' RED=$'\e[31m' GREEN=$'\e[32m'
  YELLOW=$'\e[33m' BLUE=$'\e[34m' CYAN=$'\e[38;2;150;241;241m'
else
  RESET="" BOLD="" DIM="" RED="" GREEN="" YELLOW="" BLUE="" CYAN=""
fi

exec 3>&1 5>/dev/null

line() { printf '%s\n' "$1" >&5; printf '%s\n' "${2:-$1}" >&3; }
info() { line "   [*] $*" "   ${BLUE}[*]${RESET} $*"; }
ok()   { line "   [+] $*" "   ${GREEN}[+]${RESET} $*"; }
warn() { line "   [!] $*" "   ${YELLOW}[!]${RESET} $*"; }
err()  { line "   [-] $*" "   ${RED}[-]${RESET} $*"; }
note() { SUMMARY+=("$*"); }
tilde() { printf '%s' "${1/#$HOME/\~}"; }

section() {
  local rule
  printf -v rule '%*s' $((49 - ${#1})) ''
  line "" ""
  line " :: $1" " ${BOLD}${BLUE}::${RESET} ${BOLD}$1${RESET} ${DIM}${rule// /─}${RESET}"
}

die() {
  trap - ERR
  err "$*"
  [ -z "$LOG_FILE" ] || info "Log: $(tilde "$LOG_FILE")"
  exit 1
}

# shellcheck disable=SC2329
on_error() { die "Failed at line $2 (exit $1)"; }

# shellcheck disable=SC2329
on_exit() { [ -z "$SUDO_PID" ] || kill "$SUDO_PID" 2>/dev/null || true; }

have() { command -v "$1" >/dev/null 2>&1; }
pkg_installed() { pacman -Q "$1" >/dev/null 2>&1; }
state_get() { sed -n "s/^$1=//p" "$STATE_DIR/state" 2>/dev/null | tail -n1 || true; }

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    line "   [~] $*" "   ${DIM}[~] $*${RESET}"
    return 0
  fi
  "$@" </dev/null
}

usage() {
  cat >&3 <<EOF
caelestia-autoinstall uninstaller v$VERSION - $AUTHOR
Removes Caelestia and puts back the configs you had before install.sh.

Usage: bash uninstall.sh [options]

Options:
  --purge           Also remove the packages install.sh added (Hyprland, apps...)
                    and ~/.config/caelestia
  --keep-configs    Don't restore the backup
  -y, --yes         Don't ask for confirmation
  --dry-run         Show what would be done without changing anything
  -h, --help        Show this help
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --purge) PURGE=1 ;;
      --keep-configs) RESTORE=0 ;;
      -y | --yes) ASSUME_YES=1 ;;
      --dry-run) DRY_RUN=1 ;;
      -h | --help) usage; exit 0 ;;
      *) die "Unknown option: $1 (see --help)" ;;
    esac
    shift
  done
}

banner() {
  printf '\n   %scaelestia-autoinstall%s %suninstall v%s%s%*s\n' "$CYAN$BOLD" "$RESET" "$DIM" "$VERSION" "$RESET" \
    $((25 - ${#VERSION})) "$AUTHOR" >&3
  printf 'caelestia-autoinstall uninstall v%s (%s)\n' "$VERSION" "$AUTHOR" >&5
  [ "$DRY_RUN" -eq 0 ] || warn "Dry run: nothing will be changed"
}

# Plan

find_backup() {
  BACKUP=$(state_get backup)
  if [ -z "$BACKUP" ] || [ ! -f "$BACKUP" ]; then
    # Oldest one: later runs back up Caelestia's own configs
    BACKUP=$(find "$HOME" -maxdepth 1 -name 'caelestia-backup-*.tar.gz' 2>/dev/null | sort | head -n1)
  fi
}

find_packages() {
  local p
  for p in "${CORE_PKGS[@]}"; do
    ! pkg_installed "$p" || PKGS+=("$p")
  done
  [ "$PURGE" -eq 1 ] || return 0

  if [ ! -f "$STATE_DIR/packages-before" ]; then
    warn "No package snapshot from install.sh, --purge only removes Caelestia itself"
    return 0
  fi
  local dm
  dm=$(basename "$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null)" .service 2>/dev/null || true)
  while read -r p; do
    [ -n "$p" ] && [ "$p" != "$dm" ] || continue
    [[ "$p" =~ $PROTECTED ]] || PKGS+=("$p")
  done < <(comm -13 <(sort "$STATE_DIR/packages-before") <(pacman -Qqe | sort))
}

show_plan() {
  section "Plan"
  if [ "${#PKGS[@]}" -gt 0 ]; then
    info "Remove packages: ${PKGS[*]}"
    info "plus the dependencies nothing else needs"
  else
    info "No Caelestia packages installed"
  fi
  [ ! -f "$DOTS_STATE" ] || info "Delete the config files Caelestia deployed"
  info "Delete $(tilde "$STATE_HOME/caelestia") and the Caelestia cache"
  [ "$PURGE" -eq 0 ] || info "Delete ~/.config/caelestia (your tweaks)"
  if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    warn "You're inside Hyprland: the bar goes away now, log out when it finishes"
  fi
  if [ "$RESTORE" -eq 1 ] && [ -n "$BACKUP" ]; then
    info "Restore $(tilde "$BACKUP")"
  elif [ "$RESTORE" -eq 1 ]; then
    warn "No backup from install.sh found, configs won't be restored"
  fi
}

confirm() {
  [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] || return 0
  { : </dev/tty; } 2>/dev/null || die "No terminal to confirm, run again with -y"
  local answer
  line "" ""
  printf '   %s[?]%s Continue? [y/N] ' "$YELLOW" "$RESET" >&3
  read -r answer </dev/tty || answer=""
  case "$answer" in
    y | Y | yes) ;;
    *) info "Cancelled, nothing changed"; exit 0 ;;
  esac
}

start_sudo() {
  [ "$DRY_RUN" -eq 0 ] && [ "${#PKGS[@]}" -gt 0 ] || return 0
  info "Enter your password (only once)"
  sudo -v || die "Couldn't get sudo rights"
  (
    while kill -0 "$$" 2>/dev/null; do
      sudo -n true 2>/dev/null || true
      sleep 45
    done
  ) &
  SUDO_PID=$!
}

# Steps

stop_shell() {
  section "Stopping Caelestia"
  if have caelestia; then
    run caelestia shell -k >/dev/null 2>&1 || true
  fi
  # Spotify stays usable once the theme files are gone
  if have spicetify; then
    run spicetify restore >/dev/null 2>&1 || true
  fi
  ok "Shell stopped"
}

remove_configs() {
  section "Removing configs"
  if [ -f "$DOTS_STATE" ]; then
    local count
    count=$(python3 - "$DOTS_STATE" "$HOME" "$DRY_RUN" <<'PY'
import json, os, sys

state, home, dry = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
files = json.load(open(state)).get("deployed_files", {})
stop = {home, os.path.join(home, ".config"), os.path.join(home, ".local", "share")}
removed = 0
for path in files:
    if not (os.path.isfile(path) or os.path.islink(path)):
        continue
    removed += 1
    if dry:
        continue
    os.unlink(path)
    parent = os.path.dirname(path)
    while parent not in stop and parent.startswith(home + os.sep):
        try:
            os.rmdir(parent)
        except OSError:
            break
        parent = os.path.dirname(parent)
print(removed)
PY
)
    ok "Deleted $count deployed files"
  else
    info "No deploy record found"
  fi

  local d
  for d in "$STATE_HOME/caelestia" "${XDG_CACHE_HOME:-$HOME/.cache}/caelestia"; do
    [ ! -e "$d" ] || run rm -rf "$d"
  done
  ok "Deleted Caelestia state and cache"

  if [ "$PURGE" -eq 1 ]; then
    [ ! -e "$HOME/.config/caelestia" ] || run rm -rf "$HOME/.config/caelestia"
    ok "Deleted ~/.config/caelestia"
  elif [ -d "$HOME/.config/caelestia" ]; then
    note "Kept your tweaks in ~/.config/caelestia"
  fi
}

restore_backup() {
  section "Restoring configs"
  if [ "$RESTORE" -eq 0 ]; then
    info "Skipped (--keep-configs)"
    return 0
  fi
  if [ -z "$BACKUP" ]; then
    info "No backup to restore"
  elif run tar -xzf "$BACKUP" -C "$HOME"; then
    ok "Restored $(tilde "$BACKUP")"
  else
    warn "Couldn't extract $(tilde "$BACKUP"), try: tar -xzf $BACKUP -C ~"
  fi
  [ ! -d "$HOME/.config.bak" ] || note "Full copy of ~/.config from the official installer: ~/.config.bak"
}

remove_packages() {
  section "Removing packages"
  if [ "${#PKGS[@]}" -eq 0 ]; then
    info "Nothing to remove"
    return 0
  fi
  # -u skips anything another package still needs instead of failing
  if run sudo pacman -Rsu --noconfirm "${PKGS[@]}"; then
    ok "Packages removed"
  else
    warn "pacman couldn't remove everything, see the log"
    note "Some packages were left installed, check: pacman -Qs caelestia"
  fi
}

restore_login_screen() {
  local before after
  before=$(state_get dm_before)
  after=$(state_get dm_after)
  [ -n "$after" ] || return 0

  section "Login screen"
  if [ -z "$before" ]; then
    info "Keeping $after enabled (before, the system booted to a console)"
  elif [ "$before" != "$after" ] && pkg_installed "$before"; then
    run sudo systemctl disable "$after.service" || true
    if run sudo systemctl enable "$before.service"; then
      ok "Switched back to $before"
    else
      warn "Couldn't enable $before, $after stays active"
    fi
  fi
}

finish() {
  local shell s rule
  shell=$(state_get removed_shell)
  [ -z "$shell" ] || note "install.sh replaced your previous shell, to get it back: yay -S $shell"
  if [ "$PURGE" -eq 0 ]; then
    note "Hyprland and the apps are still installed (--purge removes them)"
  fi
  [ "$DRY_RUN" -eq 1 ] || rm -rf "$STATE_DIR"

  printf -v rule '%57s' ''
  rule=${rule// /─}
  line "" ""
  line " $rule" " ${CYAN}${rule}${RESET}"
  local title="Caelestia was removed"
  [ "$DRY_RUN" -eq 0 ] || title="Dry run finished"
  line "   [+] $title" "   ${GREEN}${BOLD}[+] $title${RESET}"
  line " $rule" " ${CYAN}${rule}${RESET}"
  for s in "${SUMMARY[@]}"; do info "$s"; done
  info "Log: $(tilde "$LOG_FILE")"
  line "" ""
  line "   Next: reboot and pick your previous session." \
    "   ${BOLD}Next:${RESET} reboot and pick your previous session."
  line "" ""
}

main() {
  parse_args "$@"

  LOG_FILE="$HOME/caelestia-uninstall-$(date +%Y%m%d-%H%M%S).log"
  exec 5>>"$LOG_FILE" >&5 2>&5
  trap 'on_error $? $LINENO' ERR
  trap on_exit EXIT

  banner
  [ "$(id -u)" -ne 0 ] || die "Don't run this as root or with sudo"
  have pacman || die "pacman not found"
  if ! pkg_installed caelestia-shell && ! pkg_installed caelestia-cli && [ ! -f "$DOTS_STATE" ]; then
    die "Caelestia doesn't seem to be installed"
  fi

  find_backup
  find_packages
  show_plan
  confirm
  start_sudo
  stop_shell
  remove_configs
  restore_backup
  remove_packages
  restore_login_screen
  finish
}

main "$@"; exit
