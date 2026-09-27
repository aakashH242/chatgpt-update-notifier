# shellcheck shell=bash
# This sourced module intentionally shares validated config and lifecycle globals with
# the root orchestrator; standalone ShellCheck cannot follow that dynamic source edge.
# shellcheck disable=SC2034,SC2154

# rollback_root contains private, exact package artifacts that survive notifier uninstall.
rollback_root="$state_dir/rollbacks"
# These globals describe the package currently installed or loaded from one snapshot.
package_name='' package_version='' package_arch=''
manifest_distro='' manifest_arch='' manifest_version='' manifest_filename=''
manifest_sha256='' manifest_created_at='' manifest_signature_filename=''
manifest_signature_sha256=''
rollback_snapshot_version=''
restore_command_args=()

# Accept package-manager versions and architectures without permitting path separators,
# whitespace, control characters, or shell syntax into generated snapshot paths.
valid_package_token() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9.+:~^_-]*$ ]]; }

# Read the installed package's exact version and architecture into package_version and
# package_arch. Package-manager output is treated as data and validated before reuse.
installed_package_identity() {
  local identity
  case $distro in
    fedora)
      package_name=chatgpt
      identity=$(rpm -q --qf '%{epochnum}:%{version}-%{release}\t%{arch}\n' "$package_name") || return 1
      ;;
    ubuntu|debian)
      package_name=chatgpt
      identity=$(dpkg-query -W -f='${Version}\t${Architecture}\n' "$package_name") || return 1
      ;;
    arch)
      package_name=chatgpt-bin
      package_version=$(pacman -Q "$package_name") || return 1
      package_version=${package_version#"$package_name "}
      package_arch=$(LC_ALL=C pacman -Qi "$package_name" | awk -F ' *: *' '$1 == "Architecture" { print $2; exit }') || return 1
      valid_package_token "$package_version" && valid_package_token "$package_arch"
      return
      ;;
    *) return 1 ;;
  esac
  IFS=$'\t' read -r package_version package_arch <<<"$identity"
  valid_package_token "$package_version" && valid_package_token "$package_arch"
}

# Print the installed ChatGPT package version for the CLI and native manager header.
current_chatgpt_version() {
  detect_distro >/dev/null 2>&1 && installed_package_identity >/dev/null 2>&1 || {
    printf 'not installed'
    return 1
  }
  printf '%s' "$package_version"
}

# Verify that one local package artifact contains the requested ChatGPT version and
# architecture. Native package readers validate metadata instead of trusting filenames.
artifact_matches() {
  local file=$1 expected_version=$2 expected_arch=$3 identity found_name found_version found_arch
  [[ -f $file && ! -L $file ]] || return 1
  case $distro in
    fedora)
      identity=$(rpm -qp --qf '%{name}\t%{epochnum}:%{version}-%{release}\t%{arch}\n' "$file" 2>/dev/null) || return 1
      ;;
    ubuntu|debian)
      found_name=$(dpkg-deb -f "$file" Package 2>/dev/null) || return 1
      found_version=$(dpkg-deb -f "$file" Version 2>/dev/null) || return 1
      found_arch=$(dpkg-deb -f "$file" Architecture 2>/dev/null) || return 1
      identity="$found_name"$'\t'"$found_version"$'\t'"$found_arch"
      ;;
    arch)
      found_name=$(pacman -Qp "$file" 2>/dev/null) || return 1
      found_version=${found_name#* }
      found_name=${found_name%% *}
      found_arch=$(LC_ALL=C pacman -Qip "$file" 2>/dev/null | awk -F ' *: *' '$1 == "Architecture" { print $2; exit }') || return 1
      identity="$found_name"$'\t'"$found_version"$'\t'"$found_arch"
      ;;
  esac
  IFS=$'\t' read -r found_name found_version found_arch <<<"$identity"
  [[ $found_name == "$package_name" && $found_version == "$expected_version" && $found_arch == "$expected_arch" ]]
}

# Copy a verified cache/download candidate into the private staging directory.
# snapshot_file is set to the new copy; an adjacent Arch signature is copied when present.
stage_artifact() {
  local source=$1 target_dir=$2 filename=${1##*/}
  [[ $filename != */ && $filename =~ ^[A-Za-z0-9][A-Za-z0-9.%+:~^_-]*$ ]] || return 1
  artifact_matches "$source" "$package_version" "$package_arch" || return 1
  if [[ $distro == arch ]]; then
    [[ -f $source.sig && ! -L $source.sig ]] || return 1
    pacman-key --verify "$source.sig" "$source" >/dev/null 2>&1 || return 1
  fi
  install -m 600 "$source" "$target_dir/$filename" || return 1
  snapshot_file="$target_dir/$filename"
  snapshot_signature=''
  if [[ $distro == arch ]]; then
    install -m 600 "$source.sig" "$target_dir/$filename.sig" || return 1
    snapshot_signature="$target_dir/$filename.sig"
  fi
}

# Search only native package cache roots for the exact installed artifact. Each result is
# inspected by its package manager, so a similarly named package cannot become a snapshot.
stage_cached_artifact() {
  local staging_dir=$1 root pattern candidate
  local -a roots=()
  case $distro in
    fedora) roots=(/var/cache/libdnf5 /var/cache/dnf); pattern='chatgpt-*.rpm' ;;
    ubuntu|debian) roots=(/var/cache/apt/archives); pattern='chatgpt_*.deb' ;;
    arch)
      while IFS= read -r root; do [[ -n $root ]] && roots+=("$root"); done < <(pacman-conf CacheDir 2>/dev/null)
      ((${#roots[@]})) || roots=(/var/cache/pacman/pkg)
      pattern='chatgpt-bin-*.pkg.tar.zst'
      ;;
  esac
  for root in "${roots[@]}"; do
    [[ -d $root ]] || continue
    while IFS= read -r -d '' candidate; do
      if stage_artifact "$candidate" "$staging_dir"; then return 0; fi
    # Follow a configured cache-root symlink, but keep find's default behavior for
    # symlinks inside that cache so the search cannot escape through nested links.
    done < <(find -H "$root" -type f -name "$pattern" -print0 2>/dev/null)
  done
  return 1
}

# Download the exact installed package from signed, refreshed OpenAI repository metadata.
# Arch repositories normally expose only the newest build, so Arch safely requires its cache.
stage_repository_artifact() {
  local staging_dir=$1 download_dir candidate
  download_dir="$staging_dir/download"
  mkdir "$download_dir"
  case $distro in
    fedora)
      dnf -q --disablerepo='*' --enablerepo=openai-chatgpt download --destdir="$download_dir" \
        "$package_name-$package_version.$package_arch" >/dev/null || return 1
      ;;
    ubuntu|debian)
      prepare_apt_repository || return 1
      (cd "$download_dir" && apt-get "${apt_options[@]}" download "$package_name=$package_version" >/dev/null) || return 1
      ;;
    arch) return 1 ;;
  esac
  while IFS= read -r -d '' candidate; do
    if stage_artifact "$candidate" "$staging_dir"; then
      rm -r -- "$download_dir"
      return 0
    fi
  done < <(find "$download_dir" -maxdepth 1 -type f -print0)
  return 1
}

# Parse and validate one flat snapshot manifest. The package checksum and native metadata
# must both match before the directory is offered or installed.
read_snapshot_manifest() {
  local snapshot_dir=$1 manifest="$1/snapshot" line key value file signature actual_sha
  local -A seen=()
  manifest_distro='' manifest_arch='' manifest_version='' manifest_filename=''
  manifest_sha256='' manifest_created_at='' manifest_signature_filename=''
  manifest_signature_sha256=''
  [[ -d $snapshot_dir && ! -L $snapshot_dir && -f $manifest && ! -L $manifest ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^([a-z0-9_]+)=(.*)$ ]] || return 1
    key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
    [[ -z ${seen[$key]+x} ]] || return 1
    case $key in
      distro|arch|version|filename|sha256|created_at|signature_filename|signature_sha256) seen[$key]=$value ;;
      *) return 1 ;;
    esac
  done <"$manifest"
  for key in distro arch version filename sha256 created_at signature_filename signature_sha256; do
    [[ -n ${seen[$key]+x} ]] || return 1
    printf -v "manifest_$key" '%s' "${seen[$key]}"
  done
  case $manifest_distro in ubuntu|debian|fedora|arch) ;; *) return 1 ;; esac
  valid_package_token "$manifest_arch" && valid_package_token "$manifest_version" || return 1
  [[ $manifest_filename =~ ^[A-Za-z0-9][A-Za-z0-9.%+:~^_-]*$ ]] || return 1
  [[ $manifest_sha256 =~ ^[a-f0-9]{64}$ && $manifest_created_at =~ ^[0-9]{10,}$ ]] || return 1
  file="$snapshot_dir/$manifest_filename"
  [[ -f $file && ! -L $file ]] || return 1
  actual_sha=$(sha256sum "$file") || return 1
  [[ ${actual_sha%% *} == "$manifest_sha256" ]] || return 1
  if [[ $manifest_distro == arch ]]; then
    [[ $manifest_signature_filename == "$manifest_filename.sig" ]] || return 1
    [[ $manifest_signature_sha256 =~ ^[a-f0-9]{64}$ ]] || return 1
    signature="$snapshot_dir/$manifest_signature_filename"
    [[ -f $signature && ! -L $signature ]] || return 1
    actual_sha=$(sha256sum "$signature") || return 1
    [[ ${actual_sha%% *} == "$manifest_signature_sha256" ]] || return 1
    pacman-key --verify "$signature" "$file" >/dev/null 2>&1 || return 1
  elif [[ -n $manifest_signature_filename || -n $manifest_signature_sha256 ]]; then
    return 1
  fi
  # Listing may run before this shell has detected a distro. Preserve an unset
  # caller state while the manifest's own distro selects its metadata validator.
  local saved_distro=${distro-} saved_name=${package_name-}
  distro=$manifest_distro
  case $distro in arch) package_name=chatgpt-bin ;; *) package_name=chatgpt ;; esac
  if ! artifact_matches "$file" "$manifest_version" "$manifest_arch"; then
    distro=$saved_distro package_name=$saved_name
    return 1
  fi
  distro=$saved_distro package_name=$saved_name
}

# Print valid snapshot records newest-first as timestamp, version, distro, arch, and path.
snapshot_rows() {
  local snapshot_dir
  [[ -d $rollback_root ]] || return 0
  for snapshot_dir in "$rollback_root"/*; do
    [[ -d $snapshot_dir ]] || continue
    if read_snapshot_manifest "$snapshot_dir"; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$manifest_created_at" "$manifest_version" \
        "$manifest_distro" "$manifest_arch" "$snapshot_dir"
    fi
  done | sort -t $'\t' -k1,1nr
}

# Set selected_snapshot_dir to the newest valid snapshot for one exact version.
find_snapshot_by_version() {
  local wanted=$1 row created version saved_distro saved_arch path
  selected_snapshot_dir=''
  while IFS=$'\t' read -r created version saved_distro saved_arch path; do
    if [[ $version == "$wanted" && $saved_distro == "$distro" && $saved_arch == "$package_arch" ]]; then
      selected_snapshot_dir=$path
      return 0
    fi
  done < <(snapshot_rows)
  return 1
}

# Remove valid snapshots beyond the configured count while reserving one protected
# package inside that count. Zero keeps every valid snapshot. Invalid or manually
# added directories stay because ownership is unproven.
prune_snapshots() {
  local protected_path=${1:-} created version saved_distro saved_arch path count=0
  local newest_to_keep=$rollback_versions
  (( rollback_versions )) || return 0
  [[ -z $protected_path ]] || newest_to_keep=$((rollback_versions - 1))
  while IFS=$'\t' read -r created version saved_distro saved_arch path; do
    [[ $path == "$protected_path" ]] && continue
    count=$((count + 1))
    (( count <= newest_to_keep )) && continue
    [[ $path == "$rollback_root/"* && -d $path && ! -L $path ]] && rm -r -- "$path"
  done < <(snapshot_rows)
}

# Preserve the exact currently installed package before an upgrade. The completed directory
# appears only after artifact validation, checksums, and manifest writing all succeed.
snapshot_before_upgrade() {
  installed_package_identity || { error 'Could not identify the installed ChatGPT package'; return 1; }
  rollback_snapshot_version=$package_version
  [[ ! -L $rollback_root ]] || { error 'The rollback directory cannot be a symlink'; return 1; }
  mkdir -p "$rollback_root" || return 1
  chmod 700 "$rollback_root" || return 1
  if find_snapshot_by_version "$package_version"; then
    printf 'Rollback copy already saved for ChatGPT %s.\n' "$package_version"
    prune_snapshots "$selected_snapshot_dir" || error 'The rollback copy exists, but older copies could not be pruned'
    return 0
  fi
  local staging_dir final_dir staging_suffix filename sha created signature_filename='' signature_sha=''
  staging_dir=$(mktemp -d "$rollback_root/.pending.XXXXXX") || return 1
  chmod 700 "$staging_dir" || { rm -r -- "$staging_dir"; return 1; }
  if ! stage_cached_artifact "$staging_dir" && ! stage_repository_artifact "$staging_dir"; then
    rm -r -- "$staging_dir"
    error "Could not save an exact rollback package for ChatGPT $package_version"
    return 1
  fi
  filename=${snapshot_file##*/}
  sha=$(sha256sum "$snapshot_file") || { rm -r -- "$staging_dir"; return 1; }
  sha=${sha%% *}
  if [[ -n $snapshot_signature ]]; then
    signature_filename=${snapshot_signature##*/}
    signature_sha=$(sha256sum "$snapshot_signature") || { rm -r -- "$staging_dir"; return 1; }
    signature_sha=${signature_sha%% *}
  fi
  created=$(date +%s)
  printf 'distro=%s\narch=%s\nversion=%s\nfilename=%s\nsha256=%s\ncreated_at=%s\nsignature_filename=%s\nsignature_sha256=%s\n' \
    "$distro" "$package_arch" "$package_version" "$filename" "$sha" "$created" \
    "$signature_filename" "$signature_sha" >"$staging_dir/snapshot.tmp" || { rm -r -- "$staging_dir"; return 1; }
  chmod 600 "$staging_dir/snapshot.tmp" || { rm -r -- "$staging_dir"; return 1; }
  mv -- "$staging_dir/snapshot.tmp" "$staging_dir/snapshot" || { rm -r -- "$staging_dir"; return 1; }
  staging_suffix=${staging_dir##*/.pending.}
  final_dir="$rollback_root/$created-$staging_suffix"
  mv -- "$staging_dir" "$final_dir" || { rm -r -- "$staging_dir"; return 1; }
  if ! read_snapshot_manifest "$final_dir"; then
    rm -r -- "$final_dir"
    error 'The completed rollback copy failed verification'
    return 1
  fi
  printf 'Saved rollback copy for ChatGPT %s.\n' "$package_version"
  prune_snapshots "$final_dir" || error 'The rollback copy was saved, but older copies could not be pruned'
  return 0
}

# Print the current version and each valid snapshot in a compact human-readable list.
list_rollback_snapshots() {
  local current row created version saved_distro saved_arch path found=0
  current=$(current_chatgpt_version || true)
  printf 'Current ChatGPT: %s\n\n' "$current"
  printf 'Saved rollback versions:\n'
  while IFS=$'\t' read -r created version saved_distro saved_arch path; do
    found=1
    printf '  %s  %s %s  saved %s\n' "$version" "$saved_distro" "$saved_arch" \
      "$(date -d "@$created" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$created")"
  done < <(snapshot_rows)
  (( found )) || printf '  None yet. A copy is saved before the next update.\n'
}

# Build the native local-package restore command into restore_command_args.
build_restore_command() {
  local mode=$1 package_file=$2
  case $distro:$mode in
    fedora:manual) restore_command_args=(sudo dnf install "$package_file") ;;
    fedora:automatic) restore_command_args=(sudo -n dnf install -y "$package_file") ;;
    ubuntu:manual|debian:manual) restore_command_args=(sudo apt-get install --allow-downgrades "$package_file") ;;
    ubuntu:automatic|debian:automatic) restore_command_args=(sudo -n apt-get install --allow-downgrades -y "$package_file") ;;
    arch:manual) restore_command_args=(sudo pacman -U "$package_file") ;;
    arch:automatic) restore_command_args=(sudo -n pacman -U --noconfirm "$package_file") ;;
  esac
}

# Print an exact shell-safe representation of the restore command shown to the user.
restore_command() {
  build_restore_command "$1" "$2"
  format_command "${restore_command_args[@]}"
}

# Restore one validated snapshot and reuse update confirmation, sudo, app shutdown,
# force-close, restart, and notification behavior. A successful rollback silences only
# the broken version that was installed immediately before this restore.
restore_snapshot() {
  local snapshot_dir=$1 config_status=0 mode=manual current_version current_arch target_version target_arch
  local approved_filename approved_sha approved_signature_filename approved_signature_sha approved_created_at
  local package_file command_text silence_version status=0
  detect_distro || return 1
  installed_package_identity || { error 'ChatGPT is not installed'; return 1; }
  current_version=$package_version
  current_arch=$package_arch
  read_snapshot_manifest "$snapshot_dir" || { error 'The selected rollback snapshot is invalid'; return 1; }
  [[ $manifest_distro == "$distro" && $manifest_arch == "$package_arch" ]] || {
    error 'The selected rollback package is for a different system'
    return 1
  }
  target_version=$manifest_version
  target_arch=$manifest_arch
  approved_filename=$manifest_filename
  approved_sha=$manifest_sha256
  approved_signature_filename=$manifest_signature_filename
  approved_signature_sha=$manifest_signature_sha256
  approved_created_at=$manifest_created_at
  [[ $target_version != "$current_version" ]] || { printf 'ChatGPT %s is already installed.\n' "$target_version"; return 0; }
  read_config || config_status=$?
  if (( config_status )); then error 'Using safe manual defaults because the config could not be read'; fi
  [[ $assume_yes == true ]] && mode=automatic
  package_file="$snapshot_dir/$manifest_filename"
  command_text=$(restore_command "$mode" "$package_file")
  printf '\nChatGPT rollback — %s\n\nInstalled: %s\nRestore:   %s\n\n' "$distro" "$current_version" "$target_version"
  if [[ $distro == arch ]]; then
    printf 'Arch warning: this restores only ChatGPT. pacman will keep dependency checks enabled.\n\n'
  fi
  printf 'Command: %s\n\n' "$command_text"
  if [[ $mode == manual ]]; then
    if ! confirm 'Roll back to this version?'; then printf 'Cancelled.\n'; return 0; fi
  elif ! authenticate_package_action 'roll back ChatGPT'; then
    error 'Administrator authentication failed; ChatGPT was not touched'
    notify_upgrade_status 'ChatGPT rollback not started' 'Administrator authentication was cancelled or failed.'
    return 1
  fi
  if ! acquire_package_operation_lock; then
    notify_upgrade_status 'ChatGPT rollback not started' 'Another update or rollback is already running.'
    return 1
  fi
  if ! installed_package_identity || [[ $package_version != "$current_version" || $package_arch != "$current_arch" ]]; then
    release_package_operation_lock
    error 'The installed ChatGPT package changed; reopen rollback and try again'
    return 1
  fi
  if ! read_snapshot_manifest "$snapshot_dir" ||
     [[ $manifest_distro != "$distro" || $manifest_arch != "$current_arch" || $manifest_version != "$target_version" ||
        $manifest_filename != "$approved_filename" || $manifest_sha256 != "$approved_sha" ||
        $manifest_signature_filename != "$approved_signature_filename" ||
        $manifest_signature_sha256 != "$approved_signature_sha" || $manifest_created_at != "$approved_created_at" ]]; then
    release_package_operation_lock
    error 'The selected rollback snapshot changed; reopen rollback and try again'
    return 1
  fi
  package_file="$snapshot_dir/$manifest_filename"
  package_operation=rollback
  prepare_chatgpt_for_package_change "$mode" 'rolling back'
  build_restore_command "$mode" "$package_file"
  "${restore_command_args[@]}" || status=$?
  if (( status == 0 )) &&
     { ! installed_package_identity || [[ $package_version != "$target_version" || $package_arch != "$target_arch" ]]; }; then
    status=1
    error 'The package manager exited successfully, but the requested ChatGPT version is not installed'
  fi
  printf '\n%s\n' "$([[ $status == 0 ]] && printf 'Rollback finished successfully.' || printf 'Rollback failed.')"
  finish_chatgpt_after_package_change rollback "$status" "$package_was_running" "$mode" "${package_original_pids[@]}"
  if (( status )); then
    release_package_operation_lock
    notify_upgrade_status 'ChatGPT rollback failed' 'The package manager could not restore the saved version.'
  else
    silence_version=$current_version
    [[ $distro == fedora ]] && silence_version="$current_version.$current_arch"
    if mkdir -p "$state_dir" && printf '%s\n' "$silence_version" >"$state_dir/silenced-version"; then
      release_package_operation_lock
      notify_upgrade_status 'ChatGPT rolled back' "$current_version → $target_version. The broken version is silenced."
    else
      status=1
      release_package_operation_lock
      error 'ChatGPT was rolled back, but the broken-version silence marker could not be saved'
      notify_upgrade_status 'ChatGPT rolled back with a warning' \
        "$current_version → $target_version, but the broken version could not be silenced."
    fi
  fi
  printf '\nThank you for using ChatGPT Update Notifier.\n'
  if [[ $mode == manual ]]; then read -r -p 'Press Enter to close this terminal...' _ || true; fi
  return "$status"
}

# Resolve a version to its newest matching snapshot and restore it.
rollback_version() {
  local requested=$1
  valid_package_token "$requested" || { error 'Invalid rollback version'; return 2; }
  detect_distro || return 1
  installed_package_identity || { error 'ChatGPT is not installed'; return 1; }
  find_snapshot_by_version "$requested" || { error "No valid rollback snapshot for $requested"; return 1; }
  restore_snapshot "$selected_snapshot_dir"
}

# Let a terminal user choose one valid local snapshot without entering a version string.
rollback_interactive() {
  [[ -t 0 ]] || { error 'Run rollback in an interactive terminal or choose a version in the app launcher'; return 1; }
  local row created version saved_distro saved_arch path answer index
  local -a rows=() versions=() paths=()
  detect_distro || return 1
  installed_package_identity || { error 'ChatGPT is not installed'; return 1; }
  while IFS= read -r row; do
    IFS=$'\t' read -r created version saved_distro saved_arch path <<<"$row"
    [[ $saved_distro == "$distro" && $saved_arch == "$package_arch" ]] || continue
    rows+=("$row") versions+=("$version") paths+=("$path")
  done < <(snapshot_rows)
  ((${#rows[@]})) || { list_rollback_snapshots; return 1; }
  printf 'Current ChatGPT: %s\n\nAvailable rollback versions:\n\n' "$package_version"
  for ((index=0; index<${#versions[@]}; index++)); do printf '  %s) %s\n' "$((index + 1))" "${versions[index]}"; done
  printf '  %s) Cancel\n\n' "$(( ${#versions[@]} + 1 ))"
  read -r -p "Choose [1-$(( ${#versions[@]} + 1 ))]: " answer || return 1
  [[ $answer =~ ^[0-9]+$ ]] || { error 'Invalid selection'; return 2; }
  (( answer >= 1 && answer <= ${#versions[@]} )) || { printf 'Cancelled.\n'; return 0; }
  restore_snapshot "${paths[answer - 1]}"
}

# Route the public rollback CLI without duplicating snapshot selection logic.
rollback_command() {
  (($# <= 1)) || { error 'Usage: chatgpt-update-notifier rollback [--list|VERSION]'; return 2; }
  case ${1:-} in
    '') rollback_interactive ;;
    --list) list_rollback_snapshots ;;
    --*) error 'Usage: chatgpt-update-notifier rollback [--list|VERSION]'; return 2 ;;
    *) rollback_version "$1" ;;
  esac
}

# After a successful upgrade, offer the exact saved version. Unsupported actions retain
# the visible CLI fallback, and closing the alert does not silence or delete anything.
notify_rollback_available() {
  local old_version=$1 new_version=$2 action='' app_note=''
  case ${upgrade_app_state:-unchanged} in
    restart-needed) app_note=$'\nRestart ChatGPT to use it.' ;;
    stopped) app_note=$'\nStart ChatGPT when you are ready.' ;;
    restarted|running-current) app_note=$'\nThe updated app is running.' ;;
  esac
  local body="$old_version → $new_version$app_note"$'\n'"Rollback: ~/.local/bin/$app rollback $old_version"
  local args=(--icon=software-update-available)
  if terminal; then args+=(--action=rollback="Roll back to $old_version"); fi
  action=$(notify_action "${args[@]}" 'ChatGPT updated' "$body")
  if [[ $action == rollback ]]; then
    open_terminal rollback "$old_version" || {
      error "Could not open a terminal. Run: ~/.local/bin/$app rollback $old_version"
      send_notification 'Open a terminal to roll back ChatGPT' "$HOME/.local/bin/$app rollback $old_version" || true
    }
  fi
}
