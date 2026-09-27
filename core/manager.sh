# shellcheck shell=bash
# This sourced module intentionally consumes globals and functions from the root script
# and rollback module; standalone ShellCheck cannot follow those dynamic source edges.
# shellcheck disable=SC2154

# manager_notifier_version is empty when the manager found no newer notifier.
manager_notifier_version=''

# Refresh the manager's conditional notifier CTA without blocking the rest of the
# menu on GitHub failure. The normal updater rechecks before downloading anything.
refresh_manager_notifier() {
  local status=0
  manager_notifier_version=''
  refresh_notifier_update || status=$?
  if (( status == 0 )); then
    manager_notifier_version=$latest_notifier_version
  elif (( status == 2 )); then
    error 'Notifier update check failed; manager remains available'
  fi
  return 0
}

# Select the first available native dialog only when the validated config permits GUI use.
native_dialog() {
  [[ $enable_gui == true ]] || return 1
  if command -v kdialog >/dev/null 2>&1; then dialog_app=kdialog; return 0; fi
  if command -v zenity >/dev/null 2>&1; then dialog_app=zenity; return 0; fi
  return 1
}

# Display the main mouse-selectable manager menu and print its stable action identifier.
gui_manager_action() {
  local current=$1
  local -a choices=(check 'Check for ChatGPT updates now' rollback 'Roll back ChatGPT' list 'Show saved rollback versions' clear 'Clear silences')
  if [[ -n $manager_notifier_version ]]; then
    choices=(update "Update notifier to $manager_notifier_version" "${choices[@]}")
  fi
  case $dialog_app in
    kdialog)
      kdialog --title 'ChatGPT Update Notifier' --menu "Current ChatGPT: $current" "${choices[@]}"
      ;;
    zenity)
      zenity --list --title='ChatGPT Update Notifier' --text="Current ChatGPT: $current" \
        --width=520 --height=300 --hide-column=1 --print-column=1 \
        --column=Action --column=Choose "${choices[@]}"
      ;;
  esac
}

# Show a short informational result with the native toolkit already selected.
gui_message() {
  case $dialog_app in
    kdialog) kdialog --title "$1" --msgbox "$2" ;;
    zenity) zenity --info --title="$1" --width=600 --text="$2" ;;
  esac
}

# Display a native snapshot chooser and print only the selected validated snapshot version.
gui_snapshot_version() {
  local created version saved_distro saved_arch _path current
  local -a choices=()
  detect_distro || return 1
  installed_package_identity || return 1
  current=$package_version
  while IFS=$'\t' read -r created version saved_distro saved_arch _path; do
    [[ $saved_distro == "$distro" && $saved_arch == "$package_arch" ]] || continue
    choices+=("$version" "$saved_distro $saved_arch · $(date -d "@$created" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$created")")
  done < <(snapshot_rows)
  ((${#choices[@]})) || {
    case $dialog_app in
      kdialog) kdialog --title 'ChatGPT Update Notifier' --sorry 'No rollback copies are available yet.' ;;
      zenity) zenity --error --title='ChatGPT Update Notifier' --text='No rollback copies are available yet.' ;;
    esac
    return 1
  }
  case $dialog_app in
    kdialog) kdialog --title 'Roll back ChatGPT' --menu "Current ChatGPT: $current" "${choices[@]}" ;;
    zenity)
      zenity --list --title='Roll back ChatGPT' --text="Current ChatGPT: $current" \
        --width=600 --height=360 --hide-column=1 --print-column=1 \
        --column=Version --column='Saved copy' "${choices[@]}"
      ;;
  esac
}

# Show saved versions in the same native toolkit selected for the manager.
gui_snapshot_list() {
  local text
  text=$(list_rollback_snapshots)
  gui_message 'Saved ChatGPT rollback versions' "$text"
}

# Open the visible rollback terminal for a native-dialog selection. Privileged work and
# sudo authentication never happen inside a hidden desktop launcher process.
launch_gui_rollback() {
  local version
  version=$(gui_snapshot_version) || return 0
  open_terminal rollback "$version" || {
    error "Could not open a terminal. Run: ~/.local/bin/$app rollback $version"
    send_notification 'Open a terminal to roll back ChatGPT' "$HOME/.local/bin/$app rollback $version" || true
  }
}

# Run one native manager interaction. The dialog exits after the selected action starts.
manager_gui() {
  local current action
  refresh_manager_notifier
  current=$(current_chatgpt_version || true)
  action=$(gui_manager_action "$current") || return 0
  case $action in
    check) run_check force ;;
    rollback) launch_gui_rollback ;;
    list) gui_snapshot_list ;;
    clear) clear_silences && gui_message 'ChatGPT Update Notifier' 'Silences cleared. Available versions can alert again.' ;;
    update) open_terminal --update || gui_message 'Update notifier' "Open a terminal and run: ~/.local/bin/$app --update" ;;
  esac
}

# Run the numbered manager after its caller has provided an interactive input stream.
# Keeping the loop separate lets failure handling be tested without a real desktop terminal.
manager_terminal_loop() {
  local current answer last_choice
  refresh_manager_notifier
  current=$(current_chatgpt_version || true)
  while true; do
    printf '\nChatGPT Update Notifier\n\nCurrent ChatGPT: %s\n\n' "$current"
    printf '  1) Check for ChatGPT updates now\n  2) Roll back ChatGPT\n  3) List saved rollback versions\n  4) Clear silences\n'
    last_choice=5
    if [[ -n $manager_notifier_version ]]; then
      printf '  5) Update notifier to %s\n  6) Exit\n\n' "$manager_notifier_version"
      last_choice=6
    else
      printf '  5) Exit\n\n'
    fi
    read -r -p "Choose [1-$last_choice]: " answer || return 0
    case $answer in
      1) run_check force || true; read -r -p 'Press Enter to continue...' _ || true ;;
      2) rollback_interactive || true; current=$(current_chatgpt_version || true) ;;
      3) list_rollback_snapshots; read -r -p 'Press Enter to continue...' _ || true ;;
      4) clear_silences || true; read -r -p 'Press Enter to continue...' _ || true ;;
      5)
        [[ -z $manager_notifier_version ]] && return 0
        update_notifier || true
        # Exit because a successful update replaces this running script. On
        # cancellation or failure, reopening the manager offers the release again.
        return 0
        ;;
      6)
        if [[ $last_choice == 6 ]]; then return 0; fi
        printf 'Choose a number from 1 to %s.\n' "$last_choice"
        ;;
      *) printf 'Choose a number from 1 to %s.\n' "$last_choice" ;;
    esac
  done
}

# Provide the universal numbered manager when native dialogs are absent or disabled.
manager_terminal() {
  [[ -t 0 ]] || { error 'The terminal manager needs an interactive terminal'; return 1; }
  manager_terminal_loop
}

# Open the configured manager from a desktop launcher or terminal. A missing dialog falls
# back to a visible terminal automatically; enable_gui=false always chooses that path.
manage() {
  local config_status=0
  read_config || config_status=$?
  if (( config_status )); then
    warn_config "$config_status"
    enable_gui=false
  fi
  if native_dialog; then manager_gui; return; fi
  if [[ -t 0 ]]; then manager_terminal; return; fi
  open_terminal manage-terminal || {
    error 'Could not open the manager because no supported terminal was found'
    send_notification 'ChatGPT Update Notifier' "Open a terminal and run: ~/.local/bin/$app manage" || true
  }
}

# Route the launcher's dedicated rollback action through GUI selection or terminal fallback.
manage_rollback() {
  local config_status=0
  read_config || config_status=$?
  if (( config_status )); then
    warn_config "$config_status"
    enable_gui=false
  fi
  if native_dialog; then launch_gui_rollback; return; fi
  if [[ -t 0 ]]; then rollback_interactive; return; fi
  open_terminal rollback || {
    error 'Could not open rollback because no supported terminal was found'
    send_notification 'ChatGPT rollback' "Open a terminal and run: ~/.local/bin/$app rollback" || true
  }
}
