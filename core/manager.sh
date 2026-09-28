# shellcheck shell=bash
# This sourced module intentionally consumes globals and functions from the root script
# and rollback module; standalone ShellCheck cannot follow those dynamic source edges.
# shellcheck disable=SC2154

# manager_notifier_version is empty when the manager found no newer notifier.
manager_notifier_version=''
# manager_settings holds one staged value for every supported config key. Nothing
# reaches disk until the user chooses Save changes in the native or terminal editor.
declare -gA manager_settings=()
declare -ga manager_setting_keys=()

# Rebuild the conditional update action from the version already checked when the
# manager opened. This avoids a second network request after a silence is removed.
set_manager_notifier_action() {
  manager_notifier_version=''
  if [[ -n ${latest_notifier_version:-} ]] &&
     newer_notifier_version "$latest_notifier_version" "$notifier_version" &&
     ! is_silenced silenced-notifier-version "$latest_notifier_version"; then
    manager_notifier_version=$latest_notifier_version
  fi
}

# Refresh the manager's conditional notifier CTA without blocking the rest of the
# menu on GitHub failure. The normal updater rechecks before downloading anything.
refresh_manager_notifier() {
  local status=0
  manager_notifier_version=''
  refresh_notifier_update || status=$?
  if (( status == 0 )); then
    set_manager_notifier_action
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

# Show a consistently sized tag/label list and print only its stable tag. Native
# list dialogs already activate a row on double-click; the prompt makes that shortcut visible.
gui_choice() {
  local title=$1 prompt=$2 first_column=$3 second_column=$4 rows height
  shift 4
  rows=$(($# / 2))
  height=$((240 + rows * 28))
  (( height < 320 )) && height=320
  (( height > 560 )) && height=560
  prompt+=$'\n\nDouble-click a row, or select it and choose Select.'
  case $dialog_app in
    kdialog)
      kdialog --title "$title" --geometry "760x$height" --ok-label Select --cancel-label Cancel \
        --menu "$prompt" "$@"
      ;;
    zenity)
      zenity --list --title="$title" --text="$prompt" --width=760 --height="$height" \
        --ok-label=Select --cancel-label=Cancel \
        --hide-column=1 --print-column=1 --column="$first_column" --column="$second_column" "$@"
      ;;
  esac
}

# Display the main mouse-selectable manager menu and print its stable action identifier.
gui_manager_action() {
  local current=$1
  local -a choices=(check 'Check for ChatGPT updates now' rollback 'Roll back ChatGPT' list 'Show saved rollback versions' silences 'Manage silences' settings 'Settings')
  if [[ -n $manager_notifier_version ]]; then
    choices=(update "Update notifier to $manager_notifier_version" "${choices[@]}")
  fi
  gui_choice 'ChatGPT Update Notifier' "Current ChatGPT: $current" Action Choose "${choices[@]}"
}

# Show a short informational result with the native toolkit already selected.
gui_message() {
  case $dialog_app in
    kdialog) kdialog --title "$1" --msgbox "$2" ;;
    zenity) zenity --info --title="$1" --width=600 --text="$2" ;;
  esac
}

# Print each valid silence as marker, user-facing label, and version. One marker
# per update stream is sufficient because a newer candidate never matches the old marker.
silence_rows() {
  local marker label version
  for marker in silenced-version silenced-notifier-version; do
    version=$(silence_marker_value "$marker") || continue
    case $marker in
      silenced-version) label='ChatGPT update' ;;
      silenced-notifier-version) label='Notifier update' ;;
    esac
    printf '%s\t%s\t%s\n' "$marker" "$label" "$version"
  done
}

# Show the existing native choice widget with only the silences that currently exist.
gui_silence_action() {
  local marker label version
  local -a choices=()
  while IFS=$'\t' read -r marker label version; do
    choices+=("$marker" "Unsilence $label $version")
  done < <(silence_rows)
  ((${#choices[@]})) || { gui_message 'Manage silences' 'No versions are silenced.'; return 1; }
  choices+=(all 'Clear all silences')
  gui_choice 'Manage silences' 'Choose a version to unsilence.' Action Version "${choices[@]}"
}

# Remove the native-dialog selection through the shared marker helper, then confirm
# which update stream can alert again. Closing the chooser changes nothing.
manager_gui_silences() {
  local action version
  action=$(gui_silence_action) || return 0
  case $action in
    silenced-version|silenced-notifier-version)
      version=$(silence_marker_value "$action") || return 0
      remove_silence_marker "$action" || return 1
      gui_message 'Silence removed' "$version can alert again."
      ;;
    all)
      clear_silences >/dev/null || return 1
      gui_message 'Silences cleared' 'All available versions can alert again.'
      ;;
  esac
}

# Describe one config key for both native and terminal editors. The parser remains
# the authority for validation; these labels only explain the accepted value.
describe_manager_setting() {
  setting_kind=number
  case $1 in
    interval_minutes) setting_label='Check interval'; setting_hint='15–10080 minutes, in steps of 15' ;;
    notification_seconds) setting_label='Notification duration'; setting_hint='1–600 seconds' ;;
    play_sound) setting_label='Play notification sound'; setting_hint='true or false'; setting_kind=boolean ;;
    shutdown_timeout_seconds) setting_label='Normal shutdown wait'; setting_hint='1–60 seconds' ;;
    assume_yes) setting_label='One-click update mode'; setting_hint='true or false'; setting_kind=boolean ;;
    stop_app) setting_label='Stop ChatGPT before one-click update'; setting_hint='true or false'; setting_kind=boolean ;;
    stop_delay_seconds) setting_label='Delay before stopping ChatGPT'; setting_hint='0–180 seconds' ;;
    force_kill) setting_label='Force-close ChatGPT if it is stuck'; setting_hint='true may lose unsaved work; false is safer'; setting_kind=boolean ;;
    restart_app) setting_label='Restart ChatGPT after update'; setting_hint='true or false'; setting_kind=boolean ;;
    restart_delay_seconds) setting_label='Delay before restarting ChatGPT'; setting_hint='0–180 seconds' ;;
    rollback_versions) setting_label='Rollback versions to keep'; setting_hint='0 means unlimited; otherwise 1–1000' ;;
    enable_gui) setting_label='Use native manager dialogs'; setting_hint='true or false'; setting_kind=boolean ;;
    *) return 1 ;;
  esac
}

# Copy the validated runtime config into an editable staging map in schema order.
load_manager_settings() {
  local entry key
  manager_settings=()
  manager_setting_keys=()
  for entry in "${config_defaults[@]}"; do
    key=${entry%%=*}
    manager_setting_keys+=("$key")
    manager_settings[$key]=${!key}
  done
}

# Validate one proposed value through the shared config boundary before staging it.
stage_manager_setting() {
  local key=$1 value=$2
  validate_config_value "$key" "$value" || return 1
  manager_settings[$key]=$validated_config_value
}

# Show all staged native settings, plus explicit Save and Cancel actions.
gui_settings_action() {
  local key
  local -a choices=()
  for key in "${manager_setting_keys[@]}"; do
    describe_manager_setting "$key" || continue
    choices+=("$key" "$setting_label: ${manager_settings[$key]} · $setting_hint")
  done
  choices+=(save 'Save changes' cancel 'Cancel without saving')
  gui_choice 'ChatGPT Update Notifier Settings' 'Choose a setting to change.' Setting Value "${choices[@]}"
}

# Ask for one native value. Boolean settings use a fixed choice; numbers use the
# toolkit's entry box with the current value prefilled.
gui_manager_setting_value() {
  local key=$1 current=${manager_settings[$1]}
  describe_manager_setting "$key" || return 1
  if [[ $setting_kind == boolean ]]; then
    if [[ $current == true ]]; then
      gui_choice "$setting_label" "$setting_hint" Value Meaning true 'Enabled (true)' false 'Disabled (false)'
    else
      gui_choice "$setting_label" "$setting_hint" Value Meaning false 'Disabled (false)' true 'Enabled (true)'
    fi
    return
  fi
  case $dialog_app in
    kdialog) kdialog --title "$setting_label" --inputbox "$setting_hint" "$current" ;;
    zenity) zenity --entry --title="$setting_label" --text="$setting_hint" --entry-text="$current" ;;
  esac
}

# Keep the native editor open while values are staged. Save performs one atomic
# replacement; closing, cancelling, or entering an invalid value never writes.
gui_settings() {
  local action value
  load_manager_settings
  while action=$(gui_settings_action); do
    [[ -n $action ]] || continue
    case $action in
      save)
        if save_config_values manager_settings; then
          gui_message 'ChatGPT Update Notifier' 'Settings saved. New values apply on the next notifier run.'
          return 0
        fi
        gui_message 'ChatGPT Update Notifier' 'Settings could not be saved. The previous config was kept.'
        return 1
        ;;
      cancel) return 0 ;;
      *)
        [[ -n ${manager_settings[$action]+x} ]] || continue
        value=$(gui_manager_setting_value "$action") || continue
        if ! stage_manager_setting "$action" "$value"; then
          describe_manager_setting "$action"
          gui_message 'Invalid setting' "Use $setting_hint for $setting_label. Nothing was saved."
        fi
        ;;
    esac
  done
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
  gui_choice 'Roll back ChatGPT' "Current ChatGPT: $current" Version 'Saved copy' "${choices[@]}"
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
    silences) manager_gui_silences ;;
    settings) gui_settings ;;
    update) open_terminal --update || gui_message 'Update notifier' "Open a terminal and run: ~/.local/bin/$app --update" ;;
  esac
}

# Let terminal users stage the same settings with numbered choices. Empty input
# keeps the current value; Save and Cancel are the only exits that affect intent.
manager_terminal_settings() {
  local answer key value index save_choice cancel_choice
  load_manager_settings
  save_choice=$((${#manager_setting_keys[@]} + 1))
  cancel_choice=$((save_choice + 1))
  while true; do
    printf '\nSettings\n\n'
    index=1
    for key in "${manager_setting_keys[@]}"; do
      describe_manager_setting "$key"
      printf '  %2d) %-38s %s\n' "$index" "$setting_label" "${manager_settings[$key]}"
      index=$((index + 1))
    done
    printf '  %2d) Save changes\n  %2d) Cancel without saving\n\n' "$save_choice" "$cancel_choice"
    read -r -p "Choose [1-$cancel_choice]: " answer || return 0
    if ! valid_uint "$answer" 1 "$cancel_choice"; then
      printf 'Choose a number from 1 to %s.\n' "$cancel_choice"
      continue
    fi
    answer=$((10#$answer))
    if (( answer == save_choice )); then
      if save_config_values manager_settings; then
        printf 'Settings saved. New values apply on the next notifier run.\n'
        return 0
      fi
      printf 'Settings could not be saved. The previous config was kept.\n'
      return 1
    fi
    (( answer == cancel_choice )) && return 0
    key=${manager_setting_keys[answer - 1]}
    describe_manager_setting "$key"
    read -r -p "$setting_label (${setting_hint}) [${manager_settings[$key]}]: " value || return 0
    [[ -z $value ]] && continue
    stage_manager_setting "$key" "$value" || printf 'Invalid value; %s was not changed.\n' "$setting_label"
  done
}

# List current markers in the terminal and remove one or all of them. A successful
# removal rebuilds the notifier action from the version checked when the manager opened.
manager_terminal_silences() {
  local marker label version answer index clear_choice back_choice
  local -a markers=() labels=() versions=()
  while IFS=$'\t' read -r marker label version; do
    markers+=("$marker") labels+=("$label") versions+=("$version")
  done < <(silence_rows)
  if ((${#markers[@]} == 0)); then
    printf 'No versions are silenced.\n'
    return 0
  fi
  printf '\nSilenced versions\n\n'
  for ((index=0; index<${#markers[@]}; index++)); do
    printf '  %d) Unsilence %s %s\n' "$((index + 1))" "${labels[index]}" "${versions[index]}"
  done
  clear_choice=$((${#markers[@]} + 1))
  back_choice=$((clear_choice + 1))
  printf '  %d) Clear all silences\n  %d) Back\n\n' "$clear_choice" "$back_choice"
  read -r -p "Choose [1-$back_choice]: " answer || return 0
  valid_uint "$answer" 1 "$back_choice" || { printf 'Nothing changed.\n'; return 0; }
  answer=$((10#$answer))
  (( answer == back_choice )) && return 0
  if (( answer == clear_choice )); then
    clear_silences || return 1
  else
    index=$((answer - 1))
    remove_silence_marker "${markers[index]}" || return 1
    printf '%s %s can alert again.\n' "${labels[index]}" "${versions[index]}"
  fi
  set_manager_notifier_action
}

# Run the numbered manager after its caller has provided an interactive input stream.
# Keeping the loop separate lets failure handling be tested without a real desktop terminal.
manager_terminal_loop() {
  local current answer last_choice
  refresh_manager_notifier
  current=$(current_chatgpt_version || true)
  while true; do
    printf '\nChatGPT Update Notifier\n\nCurrent ChatGPT: %s\n\n' "$current"
    printf '  1) Check for ChatGPT updates now\n  2) Roll back ChatGPT\n  3) List saved rollback versions\n  4) Manage silences\n  5) Settings\n'
    last_choice=6
    if [[ -n $manager_notifier_version ]]; then
      printf '  6) Update notifier to %s\n  7) Exit\n\n' "$manager_notifier_version"
      last_choice=7
    else
      printf '  6) Exit\n\n'
    fi
    read -r -p "Choose [1-$last_choice]: " answer || return 0
    case $answer in
      1) run_check force || true; read -r -p 'Press Enter to continue...' _ || true ;;
      2) rollback_interactive || true; current=$(current_chatgpt_version || true) ;;
      3) list_rollback_snapshots; read -r -p 'Press Enter to continue...' _ || true ;;
      4) manager_terminal_silences || true; read -r -p 'Press Enter to continue...' _ || true ;;
      5) manager_terminal_settings || true ;;
      6)
        [[ -z $manager_notifier_version ]] && return 0
        update_notifier || true
        # Exit because a successful update replaces this running script. On
        # cancellation or failure, reopening the manager offers the release again.
        return 0
        ;;
      7)
        if [[ $last_choice == 7 ]]; then return 0; fi
        printf 'Choose a number from 1 to %s.\n' "$last_choice"
        ;;
      *) printf 'Choose a number from 1 to %s.\n' "$last_choice" ;;
    esac
  done
}

# Provide the universal numbered manager when native dialogs are absent or disabled.
manager_terminal() {
  local config_status=0
  read_config || config_status=$?
  if (( config_status )); then warn_config "$config_status"; fi
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
  if [[ -t 0 ]]; then manager_terminal_loop; return; fi
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
