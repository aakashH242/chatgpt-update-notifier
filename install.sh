#!/usr/bin/env bash
set -euo pipefail

# name is shared by the executable, user units, and per-user data directories.
name=chatgpt-update-notifier
# source_dir is the archive or checkout containing this running installer.
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# binary is the only executable copied into the user's PATH.
binary="$HOME/.local/bin/$name"
# units is the shared user-systemd directory. File operations below name only
# this tool's service and timer; other user units in the directory are untouched.
units="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
# config is user-editable and must survive reinstall and uninstall unless reset is approved.
config="${XDG_CONFIG_HOME:-$HOME/.config}/$name/config"
# state_dir contains version silence markers and check history; uninstall leaves it intact.
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/$name"
# guide is the recovery path when the ChatGPT app itself is not installed.
guide='https://learn.chatgpt.com/docs/linux/linux-app'
# project_url supplies the one archive fetched by a standalone installer download.
project_url='https://github.com/aakashH242/chatgpt-update-notifier'

# Color variables are empty for redirected output and NO_COLOR, so messages stay readable.
# bold/blue/green mark hierarchy and success; dim/reset prevent styling from leaking.
if [[ -t 1 && -z ${NO_COLOR+x} ]]; then
  bold=$'\033[1m' blue=$'\033[34m' green=$'\033[32m' dim=$'\033[2m' reset=$'\033[0m'
else
  bold='' blue='' green='' dim='' reset=''
fi

# Print one wizard line to stdout without interpretation of user-provided text.
say() { printf '%s\n' "$*"; }
# Stop setup with a clear error; no caller should continue after a failed prerequisite.
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
# Show a numbered wizard stage using the optional color values above.
step() { printf '\n%s[%s]%s %s\n' "$blue" "$1" "$reset" "$2"; }
# Ask a yes/no question with a caller-selected default. EOF never grants consent;
# an empty answer selects the displayed default only in an interactive terminal.
confirm() {
  local answer suffix='[y/N]'
  [[ ${2:-no} == yes ]] && suffix='[Y/n]'
  read -r -p "$1 $suffix " answer || return 1
  case ${answer,,} in
    y|yes) return 0 ;;
    '') [[ ${2:-no} == yes ]] ;;
    *) return 1 ;;
  esac
}
# Read one short unsigned integer with a visible default and store it in
# integer_answer. Range and step rules stay with each setting's explanation.
ask_integer() {
  local value
  read -r -p "$1 [$2]: " value || exit 1
  value=${value:-$2}
  [[ $value =~ ^[0-9]{1,5}$ ]] || fail 'Enter a whole number.'
  integer_answer=$((10#$value))
}
# Check one directory for the four files needed to install. The standalone
# download obtains them in one archive, but this presence check does not
# verify file integrity or prove an arbitrary local directory is a release.
complete_source() {
  [[ -f $1/install.sh && -f $1/$name && -f $1/VERSION && -f $1/CHANGELOG.yaml ]]
}
# Require a running user systemd manager for either installation or uninstall.
# It never checks or changes the system-wide manager.
require_user_session() {
  command -v systemctl >/dev/null || fail 'systemd is required.'
  systemctl --user show-environment >/dev/null || fail 'No user systemd session. Log into a desktop session and retry.'
}

# Root would install into the wrong home and create unusable user units.
[[ $EUID != 0 ]] || fail 'Run this installer as your normal user, not with sudo.'
[[ -t 0 ]] || fail 'Run this installer in an interactive terminal.'

# Uninstall only this tool's binary and user units. cleanup is a quoted command
# shown to the user, not run; saved config and silence state remain recoverable.
if [[ ${1:-} == --uninstall ]]; then
  say "${bold}ChatGPT Update Notifier${reset}  ${dim}uninstall${reset}"
  say 'This removes the notifier and its user timer. Config and silence state stay.'
  confirm 'Remove the notifier?' || { say 'Cancelled.'; exit 0; }
  require_user_session
  if [[ -e $units/$name.timer ]]; then
    systemctl --user disable --now "$name.timer" >/dev/null || fail 'Could not disable the timer; no files were removed.'
    systemctl --user stop "$name.service" >/dev/null 2>&1 || true
  fi
  rm -f -- "$units/$name.service" "$units/$name.timer" "$binary"
  systemctl --user daemon-reload
  say "${green}Removed.${reset} Your config and state were kept."
  printf -v cleanup 'rm -r -- %q %q' "${config%/*}" "$state_dir"
  say "To remove that saved data too: $cleanup"
  exit 0
fi
[[ $# == 0 ]] || fail 'Usage: bash install.sh [--uninstall]'

# A raw install.sh download has no companion files. bootstrap_dir is temporary;
# fetch one archive so installer, executable, VERSION, and notes share a snapshot.
if ! complete_source "$source_dir"; then
  command -v curl >/dev/null && command -v tar >/dev/null || fail 'Download the complete project archive; curl and tar are needed for a standalone installer.'
  bootstrap_dir=$(mktemp -d)
  trap 'rm -r -- "$bootstrap_dir"' EXIT
  mkdir "$bootstrap_dir/source"
  say 'Downloading the matching project files from GitHub...'
  curl -fsSL --max-time 30 "$project_url/archive/refs/heads/main.tar.gz" -o "$bootstrap_dir/source.tar.gz" || fail 'Could not download the project archive.'
  tar -xzf "$bootstrap_dir/source.tar.gz" -C "$bootstrap_dir/source" --strip-components=1 || fail 'Could not extract the project archive.'
  complete_source "$bootstrap_dir/source" || fail 'The downloaded project archive is incomplete.'
  bash "$bootstrap_dir/source/install.sh"
  exit $?
fi
# source_version is read as data and checked against the executable's embedded value.
# The version check itself does not execute the companion notifier script.
complete_source "$source_dir" && [[ -r $source_dir/VERSION ]] || fail 'The project archive is incomplete.'
source_version=$(<"$source_dir/VERSION")
[[ $source_version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail 'Invalid project VERSION.'
[[ $(sed -n 's/^notifier_version=//p' "$source_dir/$name") == "$source_version" ]] || fail 'VERSION and notifier script do not match.'

say "${bold}ChatGPT Update Notifier${reset}  ${dim}Linux setup${reset}"
say 'Private user install · no background daemon · upgrades start only when you click Install update'

step '1/3' 'Check this system'
# ID chooses the package manager; PRETTY_NAME is only the friendly label shown below.
[[ -r /etc/os-release ]] || fail 'Cannot read /etc/os-release.'
. /etc/os-release
case $ID in
  ubuntu|debian|fedora|arch) distro=$ID ;;
  *) fail "Unsupported distribution: $ID. Supported: Ubuntu, Debian, Fedora, Arch." ;;
esac
case $(uname -m) in x86_64|aarch64) ;; *) fail 'Only x64 and ARM64 are supported.' ;; esac
require_user_session
case $distro in
  fedora)
    rpm -q chatgpt >/dev/null 2>&1 || fail "ChatGPT is not installed. Install it first: $guide"
    dnf repolist --enabled | awk '$1 == "openai-chatgpt" { found=1 } END { exit !found }' || fail 'The official OpenAI DNF repository is not enabled.'
    ;;
  ubuntu|debian)
    [[ $(dpkg-query -W -f='${Status}' chatgpt 2>/dev/null) == 'install ok installed' ]] || fail "ChatGPT is not installed. Install it first: $guide"
    # found_source and file locate a source file mentioning the OpenAI URL.
    # This text check does not verify ownership; APT checks signatures on refresh.
    found_source=0
    for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
      if [[ -r $file ]] && grep -qF 'persistent.oaistatic.com/codex-app-prod/linux/deb' "$file"; then found_source=1; break; fi
    done
    [[ $found_source == 1 ]] || fail 'The official OpenAI APT source is missing.'
    ;;
  arch)
    pacman -Q chatgpt-bin >/dev/null 2>&1 || fail "ChatGPT is not installed. Install it first: $guide"
    pacman-conf --repo-list | grep -qx 'openai-chatgpt' || fail 'The official OpenAI pacman repository is missing.'
    ;;
esac
say "${green}✓${reset} $PRETTY_NAME · ChatGPT installed · user systemd available"

# missing names absent executables; packages maps only those names to distro packages.
# dependency_command is the exact argument array both previewed and executed;
# it runs only after the user separately approves system package installation.
missing=()
command -v notify-send >/dev/null || missing+=(notify-send)
command -v curl >/dev/null || missing+=(curl)
command -v tar >/dev/null || missing+=(tar)
if [[ $distro == arch ]] && ! command -v checkupdates >/dev/null; then missing+=(checkupdates); fi
if [[ $distro == arch ]] && ! command -v fakeroot >/dev/null; then missing+=(fakeroot); fi
if ((${#missing[@]})); then
  packages=()
  # tool is an allowlisted executable name collected by the checks above.
  for tool in "${missing[@]}"; do
    case $tool in
      notify-send) case $distro in ubuntu|debian) packages+=(libnotify-bin) ;; *) packages+=(libnotify) ;; esac ;;
      curl) packages+=(curl) ;;
      tar) packages+=(tar) ;;
      checkupdates) packages+=(pacman-contrib) ;;
      fakeroot) packages+=(fakeroot) ;;
    esac
  done
  case $distro in
    fedora) dependency_command=(sudo dnf install "${packages[@]}") ;;
    ubuntu|debian) dependency_command=(sudo apt install "${packages[@]}") ;;
    arch) dependency_command=(sudo pacman -Syu --needed "${packages[@]}") ;;
  esac
  say "Missing: ${missing[*]}"
  say "Install command: ${dependency_command[*]}"
  if [[ $distro == arch ]]; then say 'Arch warning: this may upgrade the ENTIRE system.'; fi
fi
if ! command -v konsole >/dev/null && ! command -v ptyxis >/dev/null &&
   ! command -v gnome-terminal >/dev/null && ! command -v x-terminal-emulator >/dev/null &&
   ! command -v xterm >/dev/null; then
  say 'No supported terminal launcher found. Alerts will work, but installation is manual.'
fi

step '2/3' 'Choose preferences'
# reset_config tracks explicit consent to replace invalid settings. A child Bash
# process sources the local notifier to reuse its parser; that parser reads the
# user config as data and prints validated values into settings for this installer.
# The validated settings are reviewed below. Older configs inherit safe defaults
# for preferences introduced after their original installation.
reset_config=0
missing_config_count=0
interval=60
notification_seconds=15
play_sound=true
shutdown_timeout_seconds=10
assume_yes=false
stop_app=true
stop_delay_seconds=30
force_kill=false
restart_app=true
restart_delay_seconds=30
if [[ -e $config || -L $config ]]; then
  [[ -f $config ]] || fail "Expected a config file at $config."
  if settings=$(bash -c '. "$1"; read_config; printf "%s %s %s %s %s %s %s %s %s %s %s" "$interval_minutes" "$notification_seconds" "$play_sound" "$shutdown_timeout_seconds" "$assume_yes" "$stop_app" "$stop_delay_seconds" "$force_kill" "$restart_app" "$restart_delay_seconds" "${#missing_config_defaults[@]}"' _ "$source_dir/$name"); then
    read -r interval notification_seconds play_sound shutdown_timeout_seconds assume_yes stop_app stop_delay_seconds force_kill restart_app restart_delay_seconds missing_config_count <<<"$settings"
    say "Keeping your existing config: $config"
    say 'Edit its settings later; changes take effect the next time the notifier runs.'
  else
    say "The existing config is invalid or unreadable: $config"
    [[ -w $config && ! -L $config ]] || fail 'Cannot reset this config; restore its permissions or replace its symlink first.'
    confirm 'Replace it with safe defaults and manual update confirmation?' || { say 'Cancelled; config was kept.'; exit 0; }
    reset_config=1
  fi
else
  say 'Checks and reminders share one interval, in 15-minute steps (15–10080).'
  ask_integer 'Minutes' 60
  interval=$integer_answer
  (( interval >= 15 && interval <= 10080 && interval % 15 == 0 )) || fail 'Use a multiple of 15 between 15 and 10080.'
  say 'Update alerts disappear after 15 seconds by default; choose 1–600 seconds.'
  ask_integer 'Notification seconds' 15
  notification_seconds=$integer_answer
  (( notification_seconds >= 1 && notification_seconds <= 600 )) || fail 'Use 1–600 seconds.'
  if ! confirm 'Play a sound when notifications appear?' yes; then play_sound=false; fi
  say 'ChatGPT gets 10 seconds to close cleanly by default; choose 1–60 seconds.'
  ask_integer 'Shutdown wait seconds' 10
  shutdown_timeout_seconds=$integer_answer
  (( shutdown_timeout_seconds >= 1 && shutdown_timeout_seconds <= 60 )) || fail 'Use 1–60 seconds.'
  say 'One-click mode skips terminal questions only after you click Install update.'
  say 'sudo may still ask for your administrator password; the notifier never stores it.'
  if confirm 'Enable one-click update mode?'; then
    assume_yes=true
    if confirm 'Close ChatGPT automatically before updating?' yes; then
      stop_app=true
      say 'Choose 0–180 seconds to save work before ChatGPT closes.'
      ask_integer 'Delay before closing ChatGPT' 30
      stop_delay_seconds=$integer_answer
      (( stop_delay_seconds >= 0 && stop_delay_seconds <= 180 )) || fail 'Use 0–180 seconds.'
      say 'Force close is used only if ChatGPT ignores the normal shutdown request.'
      if confirm 'Allow force close? Unsaved work may be lost.'; then force_kill=true; fi
    else
      stop_app=false
    fi
    if confirm 'Restart ChatGPT automatically after updating?' yes; then
      restart_app=true
      if [[ $stop_app == false ]]; then
        say 'Choose 0–180 seconds to save work before the still-running app restarts.'
        ask_integer 'Delay before restarting ChatGPT' 30
        restart_delay_seconds=$integer_answer
        (( restart_delay_seconds >= 0 && restart_delay_seconds <= 180 )) || fail 'Use 0–180 seconds.'
      fi
    else
      restart_app=false
    fi
  fi
fi

step '3/3' 'Review and install'
say "App: ChatGPT on $distro"
say "Notifier version: $source_version"
say "Interval: $interval minutes"
say "Alert display: $notification_seconds seconds"
say "Notification sound: $play_sound"
say "App shutdown wait: $shutdown_timeout_seconds seconds"
say "One-click mode: $assume_yes"
if [[ $assume_yes == true ]]; then
  say "Stop app before update: $stop_app"
  if [[ $stop_app == true ]]; then
    say "Stop delay: $stop_delay_seconds seconds · force close after timeout: $force_kill"
  fi
  say "Restart an app that was initially running: $restart_app"
  if [[ $stop_app == false && $restart_app == true ]]; then say "Restart delay: $restart_delay_seconds seconds"; fi
fi
say "Files: $binary, $units/$name.{service,timer}, $config"
if ((${#missing[@]})); then say "System packages (with consent): ${dependency_command[*]}"; fi
confirm 'Install and enable the user timer?' || { say 'Cancelled; nothing changed.'; exit 0; }

# Existing valid configs are migrated only after approval and only when the
# parser found missing keys. The notifier owns validation and default values.
if (( missing_config_count )); then
  bash -c '. "$1"; append_missing_config_defaults' _ "$source_dir/$name" ||
    fail 'Could not update the existing config safely.'
fi

if ((${#missing[@]})); then
  command -v sudo >/dev/null || fail 'sudo is required to install missing system packages.'
  confirm 'Install the missing system packages now?' || fail 'Missing packages were not installed; setup stopped.'
  "${dependency_command[@]}"
  for tool in "${missing[@]}"; do command -v "$tool" >/dev/null || fail "Still missing $tool after package installation."; done
fi

# The timer ticks every 15 minutes; the executable enforces the editable interval.
# Fresh/reset configs are written here; valid older configs were only appended above.
bash -n "$source_dir/$name" || fail 'The notifier script failed its syntax check.'
mkdir -p "${binary%/*}" "$units" "${config%/*}"
if (( reset_config )) || [[ ! -e $config ]]; then
  printf '# Checks: 15–10080 minutes in steps of 15; alert: 1–600 seconds; shutdown: 1–60 seconds; delays: 0–180 seconds\ninterval_minutes=%s\nnotification_seconds=%s\nplay_sound=%s\nshutdown_timeout_seconds=%s\nassume_yes=%s\nstop_app=%s\nstop_delay_seconds=%s\nforce_kill=%s\nrestart_app=%s\nrestart_delay_seconds=%s\n' \
    "$interval" "$notification_seconds" "$play_sound" "$shutdown_timeout_seconds" "$assume_yes" "$stop_app" "$stop_delay_seconds" "$force_kill" "$restart_app" "$restart_delay_seconds" >"$config"
fi
install -m 755 "$source_dir/$name" "$binary"
printf '[Unit]\nDescription=Check for ChatGPT desktop updates\n\n[Service]\nType=oneshot\nExecStart=%%h/.local/bin/%s\n' "$name" >"$units/$name.service"
printf '[Unit]\nDescription=Check ChatGPT updates every 15 minutes\n\n[Timer]\nOnCalendar=*:0/15\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n' >"$units/$name.timer"
systemctl --user daemon-reload
systemctl --user enable --now "$name.timer"
systemctl --user restart "$name.timer"
say "${green}✓ Installed.${reset} The timer is active; the first check is at the next 15-minute tick."
# Use the same display and sound preferences just written to the runtime config.
ready_notification_options=(--app-name='ChatGPT Update Notifier' --expire-time="$((notification_seconds * 1000))")
[[ $play_sound == true ]] && ready_notification_options+=(--hint=string:sound-name:message-new-instant)
if ! notify-send "${ready_notification_options[@]}" 'ChatGPT Update Notifier is ready' 'Desktop notifications are working.'; then
  say 'Warning: the desktop notification service did not respond. Alerts may not appear until it is available.'
fi
say "Config: $config"
say "Uninstall: bash install.sh --uninstall"
