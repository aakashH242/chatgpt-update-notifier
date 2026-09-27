# shellcheck shell=bash
# This sourced module owns the shared ChatGPT process and package-operation lifecycle.
# It intentionally uses validated globals and helpers from the root orchestrator and
# snapshot helpers from rollback.sh; ShellCheck cannot follow those dynamic source edges.
# shellcheck disable=SC2034,SC2154

# upgrade_app_state lets completion alerts describe any remaining app action.
upgrade_app_state=unchanged
# proc_root is Linux's process filesystem; tests replace it with a controlled fixture tree.
proc_root=/proc
# package_operation supplies concise update/rollback wording to shared lifecycle helpers.
package_operation=update
# These globals preserve the app state captured before one package operation.
package_was_running=0
package_original_pids=()
# operation_lock_fd owns the advisory lock shared by update and rollback terminals.
operation_lock_fd=''

# Print the current user's genuine ChatGPT main-process PIDs, excluding Electron helpers.
# launcher resolves the public chatgpt command to codex-launcher; expected is its
# sibling ChatGPT binary. Each candidate must have that exact executable and argv[0].
# A deleted suffix is legitimate after a package replaces a still-running binary.
find_chatgpt_main_pids() {
  local launcher expected process executable pid argument helper found=1
  local -a arguments
  launcher=$(command -v chatgpt) || return 1
  launcher=$(readlink -f -- "$launcher") || return 1
  expected="${launcher%/*}/ChatGPT"
  for process in "$proc_root"/[0-9]*; do
    [[ -O $process && -r $process/cmdline && -L $process/exe ]] || continue
    executable=$(readlink -- "$process/exe") || continue
    [[ $executable == "$expected" || $executable == "$expected (deleted)" ]] || continue
    arguments=()
    mapfile -d '' -t arguments <"$process/cmdline" || continue
    [[ ${arguments[0]:-} == "$expected" ]] || continue
    helper=0
    for argument in "${arguments[@]:1}"; do
      if [[ $argument == --type=* ]]; then helper=1; break; fi
    done
    if (( ! helper )); then
      pid=${process##*/}
      printf '%s\n' "$pid"
      found=0
    fi
  done
  return "$found"
}

# Print the currently validated PIDs that match an optional list of targets.
# With no targets, every ChatGPT main process is printed. Matching a supplied
# list prevents a later user-started process from being mistaken for the old app.
current_chatgpt_pids() {
  local current target matched
  while IFS= read -r current; do
    if (($# == 0)); then
      printf '%s\n' "$current"
      continue
    fi
    matched=0
    for target in "$@"; do
      if [[ $current == "$target" ]]; then matched=1; break; fi
    done
    (( matched )) && printf '%s\n' "$current"
  done < <(find_chatgpt_main_pids || true)
}

# Return success while any validated ChatGPT main process, or any supplied
# original target PID, remains alive as the expected current-user executable.
chatgpt_running() { [[ -n $(current_chatgpt_pids "$@") ]]; }

# Send one signal only to PIDs that still pass the ChatGPT identity checks.
# Revalidation immediately before kill prevents signalling a stale, reused PID.
signal_chatgpt() {
  local signal_name=$1
  shift
  local -a pids
  case $signal_name in
    TERM|KILL) ;;
    *) error "Unsupported ChatGPT signal: $signal_name"; return 2 ;;
  esac
  mapfile -t pids < <(current_chatgpt_pids "$@")
  ((${#pids[@]})) || return 0
  kill "-$signal_name" "${pids[@]}" 2>/dev/null || true
}

# Wait up to the supplied number of seconds for all selected processes to exit.
# elapsed counts completed one-second polls; targets may be empty to mean all.
wait_for_chatgpt_exit() {
  local limit=$1 elapsed
  shift
  for ((elapsed=0; elapsed<limit; elapsed++)); do
    chatgpt_running "$@" || return 0
    sleep 1
  done
  ! chatgpt_running "$@"
}

# Request a clean Electron shutdown and wait for the configured deadline.
# Optional PID arguments limit shutdown to the app instance captured before upgrade.
close_chatgpt() {
  signal_chatgpt TERM "$@"
  wait_for_chatgpt_exit "$shutdown_timeout_seconds" "$@"
}

# Force-close only still-validated targets, then briefly verify that they exited.
# SIGKILL is used solely after the policy layer obtains consent or reads force_kill=true.
force_close_chatgpt() {
  signal_chatgpt KILL "$@"
  wait_for_chatgpt_exit 3 "$@"
}

# Launch the public command as a detached user service. Type=exec makes success
# mean systemd completed execve(), while --collect removes the transient unit later.
start_chatgpt() {
  local launcher
  launcher=$(command -v chatgpt) || { error 'Could not find the chatgpt launcher'; return 1; }
  systemd-run --user --collect --quiet --property=Type=exec "$launcher" >/dev/null || {
    error 'Could not start ChatGPT. Run: chatgpt'
    return 1
  }
}

# Show a non-actionable status alert without allowing notification failures to
# alter the upgrade result. The configured popup timeout is reused consistently.
notify_upgrade_status() {
  send_notification --icon=software-update-available "$1" "$2" || true
}

# Count down while the selected old app remains open. Returning failure means it
# closed during the countdown; callers then recheck whether a new app replaced it.
countdown_while_running() {
  local seconds=$1 purpose=$2 remaining
  shift 2
  notify_upgrade_status "ChatGPT $package_operation in progress" "ChatGPT will $purpose in $seconds seconds. Save your work now."
  for ((remaining=seconds; remaining>0; remaining--)); do
    chatgpt_running "$@" || { printf '\n'; return 1; }
    printf '\rChatGPT will %s in %s seconds. Save your work now. ' "$purpose" "$remaining"
    sleep 1
  done
  (( seconds == 0 )) || printf '\n'
  chatgpt_running "$@"
}

# Apply the shared clean-close then force-close policy. Manual mode asks before
# SIGKILL; one-click mode requires both stop_app=true and force_kill=true.
# Failure leaves the app open and lets the package operation continue.
stop_chatgpt() {
  local mode=$1
  shift
  close_chatgpt "$@" && return 0
  printf '\nChatGPT did not close within %s seconds.\n' "$shutdown_timeout_seconds"
  if [[ $mode == manual ]]; then
    printf 'Unsaved work and running tasks may be lost.\n'
    if ! confirm 'Force close it now?'; then
      printf 'Continuing while ChatGPT remains open.\n'
      printf 'You will be asked to restart it after the package change.\n'
      return 1
    fi
  elif [[ $force_kill != true || $stop_app != true ]]; then
    if [[ $stop_app == true ]]; then
      printf 'force_kill=false, so the app will remain open during the package change.\n'
    else
      printf 'force_kill is inactive because stop_app=false; the app will remain open.\n'
    fi
    return 1
  else
    printf 'force_kill=true; force-closing the old app now.\n'
    notify_upgrade_status 'Force-closing ChatGPT' 'ChatGPT did not close cleanly. Unsaved work may be lost.'
  fi
  if force_close_chatgpt "$@"; then
    printf 'ChatGPT was force-closed.\n'
    return 0
  fi
  error 'ChatGPT could not be force-closed; continuing without starting a duplicate'
  return 1
}

# Ask sudo for a normal short-lived credential before one-click mode touches the app.
# purpose keeps update and rollback prompts attributable without duplicating auth logic.
authenticate_package_action() {
  printf 'ChatGPT Update Notifier needs administrator access to %s.\n' "$1"
  printf 'Your password, if requested by sudo, is handled by sudo and is never stored.\n\n'
  sudo -v -p 'ChatGPT Update Notifier — administrator password: '
}

# Keep the established update helper name for callers and focused compatibility tests.
authenticate_automatic_upgrade() { authenticate_package_action 'install this update'; }

# Prevent two visible terminals from changing the package and application lifecycle at
# once. The kernel releases this advisory lock automatically if the process is interrupted.
acquire_package_operation_lock() {
  mkdir -p "$state_dir" || return 1
  exec {operation_lock_fd}>"$state_dir/package-operation.lock" || return 1
  if ! flock -n "$operation_lock_fd"; then
    exec {operation_lock_fd}>&-
    operation_lock_fd=''
    error 'Another ChatGPT update or rollback is already running'
    return 1
  fi
}

# Release the shared package-operation lock before waiting on an actionable notification.
release_package_operation_lock() {
  [[ -n $operation_lock_fd ]] || return 0
  flock -u "$operation_lock_fd" || true
  exec {operation_lock_fd}>&-
  operation_lock_fd=''
}

# Execute the package command arrays built by the same function used for display.
# One-click flags are reached only after authenticate_automatic_upgrade succeeds.
run_package_upgrade() {
  build_upgrade_command "$1"
  "${upgrade_step_one[@]}" || return $?
  ((${#upgrade_step_two[@]})) || return 0
  "${upgrade_step_two[@]}"
}

# Restore the user's pre-upgrade app state after rechecking both the original
# PIDs and all current ChatGPT PIDs. A newly started process is never stopped or
# duplicated. App-control errors never replace the package manager's status.
finish_chatgpt_after_package_change() {
  local operation=$1 operation_status=$2 was_running=$3 mode=$4 result='started'
  local should_start=0 version_word=updated
  [[ $operation == rollback ]] && version_word=restored
  shift 4
  local -a original_pids=("$@")
  upgrade_app_state=unchanged
  (( was_running )) || return 0
  if (( operation_status )); then
    if chatgpt_running; then upgrade_app_state=running; return 0; fi
    printf '\nThe %s failed after ChatGPT was closed.\n' "$operation"
    if [[ $mode == automatic ]]; then
      [[ $restart_app == true ]] && should_start=1
    elif confirm 'Reopen ChatGPT now?' yes; then
      should_start=1
    fi
    if (( should_start )); then
      if start_chatgpt; then
        upgrade_app_state=reopened
        printf 'ChatGPT reopened.\n'
      else
        upgrade_app_state=stopped
      fi
    else
      upgrade_app_state=stopped
      printf 'Run chatgpt when you are ready.\n'
    fi
    return 0
  fi
  if chatgpt_running && ! chatgpt_running "${original_pids[@]}"; then
    upgrade_app_state=running-current
    printf '\nChatGPT was already restarted; leaving the new process alone.\n'
    return 0
  fi
  if chatgpt_running "${original_pids[@]}"; then
    result='restarted'
    printf '\nChatGPT is still running the previous version.\n'
    if [[ $mode == automatic && $restart_app != true ]]; then
      upgrade_app_state=restart-needed
      printf 'Restart ChatGPT later to use the %s version.\n' "$version_word"
      return 0
    fi
    if [[ $mode == manual ]] && ! confirm "Restart it now to use the $version_word version?" yes; then
      upgrade_app_state=restart-needed
      printf 'Restart ChatGPT later to use the %s version.\n' "$version_word"
      return 0
    fi
    if [[ $mode == automatic ]]; then
      countdown_while_running "$restart_delay_seconds" restart "${original_pids[@]}" || true
    fi
    if chatgpt_running "${original_pids[@]}" && ! stop_chatgpt "$mode" "${original_pids[@]}"; then
      upgrade_app_state=restart-needed
      error 'The old ChatGPT process is still running; restart it manually'
      return 0
    fi
    if chatgpt_running; then upgrade_app_state=running-current; return 0; fi
  else
    printf '\nChatGPT was running before the %s.\n' "$operation"
    if [[ $mode == automatic && $restart_app != true ]]; then
      upgrade_app_state=stopped
      printf 'Run chatgpt later to start the %s version.\n' "$version_word"
      return 0
    fi
    if [[ $mode == manual ]] && ! confirm "Start the $version_word app now?" yes; then
      upgrade_app_state=stopped
      printf 'Run chatgpt later to start the %s version.\n' "$version_word"
      return 0
    fi
  fi
  if start_chatgpt; then
    upgrade_app_state=restarted
    printf 'ChatGPT %s successfully.\n' "$result"
  else
    upgrade_app_state=stopped
  fi
}

# Preserve the public helper used by existing tests and update-specific callers.
finish_chatgpt_after_upgrade() { finish_chatgpt_after_package_change upgrade "$@"; }

# Capture a running app and apply the shared pre-operation close policy. Results are
# stored in package_was_running/package_original_pids for the matching finish helper.
prepare_chatgpt_for_package_change() {
  local mode=$1 activity=$2
  package_was_running=0
  package_original_pids=()
  mapfile -t package_original_pids < <(current_chatgpt_pids)
  ((${#package_original_pids[@]})) || return 0
  package_was_running=1
  if [[ $mode == automatic && $stop_app == true ]]; then
    countdown_while_running "$stop_delay_seconds" close "${package_original_pids[@]}" || true
    chatgpt_running "${package_original_pids[@]}" && stop_chatgpt automatic "${package_original_pids[@]}" || true
  elif [[ $mode == manual ]]; then
    printf '\nChatGPT is currently running.\nClosing it first avoids leaving the previous version open after %s.\nAny unsent text or running task may be interrupted.\n\n' "$activity"
    if confirm 'Close ChatGPT first?' yes; then
      stop_chatgpt manual "${package_original_pids[@]}" || true
    else
      printf 'Continuing while ChatGPT remains open.\n'
    fi
  else
    printf 'Continuing while ChatGPT remains open.\n'
  fi
}

# Recheck installation, show the exact command, and preserve the user's initial
# app state. Manual mode confirms each decision; one-click mode first authenticates
# sudo, then follows the validated config without storing credentials.
upgrade() {
  detect_distro || return 1
  case $distro in
    ubuntu|debian) [[ $(dpkg-query -W -f='${Status}' chatgpt 2>/dev/null) == 'install ok installed' ]] ;;
    fedora) rpm -q chatgpt >/dev/null 2>&1 ;;
    arch) pacman -Q chatgpt-bin >/dev/null 2>&1 ;;
  esac || { error 'ChatGPT is no longer installed; no upgrade command was run'; return 1; }
  if ! read_config; then
    error 'Using safe manual defaults because the config could not be read'
    # An invalid config must never authorize deleting a rollback copy. Unlimited
    # retention is the only data-preserving fallback for this operation.
    rollback_versions=0
  fi
  local mode=manual command_text status=0 snapshot_ready=0 new_version='new version'
  [[ $assume_yes == true ]] && mode=automatic
  command_text=$(upgrade_command "$mode")
  printf '\nChatGPT update — %s\n\n' "$distro"
  if [[ $distro == arch ]]; then
    printf 'Arch requires a FULL SYSTEM UPGRADE, not a ChatGPT-only upgrade.\n\n'
  fi
  printf 'Command: %s\n\n' "$command_text"
  if [[ $mode == manual ]]; then
    if ! confirm 'Run this command?'; then printf 'Cancelled.\n'; return 0; fi
  elif ! authenticate_automatic_upgrade; then
    error 'Administrator authentication failed; ChatGPT was not touched'
    notify_upgrade_status 'ChatGPT update not started' 'Administrator authentication was cancelled or failed.'
    return 1
  fi
  if ! acquire_package_operation_lock; then
    notify_upgrade_status 'ChatGPT update not started' 'Another update or rollback is already running.'
    return 1
  fi
  if ! installed_package_identity; then
    release_package_operation_lock
    error 'ChatGPT is no longer installed; no upgrade command was run'
    notify_upgrade_status 'ChatGPT update not started' 'ChatGPT is no longer installed.'
    return 1
  fi
  printf 'Saving the currently installed package for rollback...\n'
  if snapshot_before_upgrade; then
    snapshot_ready=1
  elif [[ $mode == automatic ]]; then
    error 'One-click update stopped because rollback protection could not be created'
    notify_upgrade_status 'ChatGPT update not started' 'The current package could not be saved for rollback.'
    release_package_operation_lock
    return 1
  else
    printf '\nA rollback copy could not be saved. The package is not cached or available from the repository.\n\n'
    if ! confirm 'Continue without rollback protection?'; then
      release_package_operation_lock
      printf 'Cancelled.\n'
      return 0
    fi
  fi
  package_operation=update
  prepare_chatgpt_for_package_change "$mode" 'the update'
  run_package_upgrade "$mode" || status=$?
  printf '\n%s\n' "$([[ $status == 0 ]] && printf 'Upgrade finished successfully.' || printf 'Upgrade failed; no reminder was silenced.')"
  finish_chatgpt_after_upgrade "$status" "$package_was_running" "$mode" "${package_original_pids[@]}"
  release_package_operation_lock
  if (( status )); then
    notify_upgrade_status 'ChatGPT update failed' 'The package manager could not complete the update.'
  elif (( snapshot_ready )); then
    if installed_package_identity; then new_version=$package_version; fi
    notify_rollback_available "$rollback_snapshot_version" "$new_version"
  elif [[ $mode == automatic ]]; then
      case ${upgrade_app_state:-unchanged} in
        restart-needed) notify_upgrade_status 'ChatGPT updated' 'Restart ChatGPT to use the updated version.' ;;
        stopped) notify_upgrade_status 'ChatGPT updated' 'Start ChatGPT when you are ready to use the updated version.' ;;
        restarted|running-current) notify_upgrade_status 'ChatGPT updated' 'The updated app is running.' ;;
        *) notify_upgrade_status 'ChatGPT updated' 'The package upgrade finished successfully.' ;;
      esac
  fi
  printf '\nThank you for using ChatGPT Update Notifier.\n'
  if [[ $mode == manual ]]; then read -r -p 'Press Enter to close this terminal...' _ || true; fi
  return "$status"
}
