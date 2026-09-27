#!/usr/bin/env bash
# The production functions are sourced through a runtime-computed path below;
# older ShellCheck releases cannot follow that source and misreport their calls.
# Mock functions deliberately assign globals consumed by sourced production functions.
# shellcheck disable=SC2034,SC2154,SC2218
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_home=$(mktemp -d)
trap 'rm -rf -- "$test_home"' EXIT
export XDG_CONFIG_HOME="$test_home/config" XDG_STATE_HOME="$test_home/state" XDG_CACHE_HOME="$test_home/cache"
mkdir -p "$XDG_CONFIG_HOME/chatgpt-update-notifier"
config="$XDG_CONFIG_HOME/chatgpt-update-notifier/config"
. "$root/chatgpt-update-notifier"

fail_test() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ $1 == "$2" ]] || fail_test "expected '$2', got '$1'"; }
assert_eq "$(<"$root/VERSION")" "$notifier_version"
[[ $(main --version) == *"$notifier_version"*"$project_url"* ]] || fail_test '--version omitted version or project URL'
[[ $(main --help) == *"$project_url#readme"* ]] || fail_test '--help omitted README URL'
if main --update 2>/dev/null; then fail_test '--update ran without a terminal'; fi
if rollback_command --list unexpected >/dev/null 2>&1; then fail_test 'rollback accepted an extra argument'; fi

printf 'interval_minutes=60\n' >"$config"
read_config
assert_eq "$interval_minutes" 60
assert_eq "$notification_seconds" 15
assert_eq "$play_sound" true
assert_eq "$shutdown_timeout_seconds" 10
assert_eq "$assume_yes" false
assert_eq "$stop_app" true
assert_eq "$stop_delay_seconds" 30
assert_eq "$force_kill" false
assert_eq "$restart_app" true
assert_eq "$restart_delay_seconds" 30
assert_eq "$rollback_versions" 3
assert_eq "$enable_gui" true
assert_eq "${#missing_config_defaults[@]}" 11

# Migrations preserve every existing byte and value, append all missing defaults,
# and become a no-op after the first successful pass.
printf '# Keep this comment exactly.\nplay_sound=false\n' >"$config"
original_size=$(wc -c <"$config")
original_prefix=$(head -c "$original_size" "$config" | sha256sum)
append_missing_config_defaults
assert_eq "$(head -c "$original_size" "$config" | sha256sum)" "$original_prefix"
assert_eq "$(grep -c '^interval_minutes=' "$config")" 1
assert_eq "$(grep -c '^play_sound=' "$config")" 1
grep -qx 'interval_minutes=60' "$config" || fail_test 'migration omitted the default interval'
grep -qx 'play_sound=false' "$config" || fail_test 'migration replaced the existing sound preference'
for expected_default in notification_seconds=15 shutdown_timeout_seconds=10 assume_yes=false stop_app=true stop_delay_seconds=30 force_kill=false restart_app=true restart_delay_seconds=30 rollback_versions=3 enable_gui=true; do
  grep -qx "$expected_default" "$config" || fail_test "migration omitted $expected_default"
done
migrated_config=$(sha256sum "$config")
append_missing_config_defaults
assert_eq "$(sha256sum "$config")" "$migrated_config"

printf 'interval_minutes=60\nnotification_seconds=1\n' >"$config"
read_config
assert_eq "$notification_seconds" 1
printf 'interval_minutes=60\nnotification_seconds=600\n' >"$config"
read_config
assert_eq "$notification_seconds" 600
for invalid_seconds in 0 601 nope; do
  printf 'interval_minutes=60\nnotification_seconds=%s\n' "$invalid_seconds" >"$config"
  if read_config 2>/dev/null; then fail_test "accepted invalid notification_seconds=$invalid_seconds"; fi
done
printf 'interval_minutes=60\nnotification_seconds=15\nnotification_seconds=30\n' >"$config"
if read_config 2>/dev/null; then fail_test 'accepted duplicate notification_seconds'; fi
printf 'interval_minutes=60\nshutdown_timeout_seconds=1\n' >"$config"
read_config
assert_eq "$shutdown_timeout_seconds" 1
printf 'interval_minutes=60\nshutdown_timeout_seconds=60\n' >"$config"
read_config
assert_eq "$shutdown_timeout_seconds" 60
for invalid_shutdown in 0 61 nope; do
  printf 'interval_minutes=60\nshutdown_timeout_seconds=%s\n' "$invalid_shutdown" >"$config"
  if read_config 2>/dev/null; then fail_test "accepted invalid shutdown_timeout_seconds=$invalid_shutdown"; fi
done
printf 'interval_minutes=60\nshutdown_timeout_seconds=10\nshutdown_timeout_seconds=20\n' >"$config"
if read_config 2>/dev/null; then fail_test 'accepted duplicate shutdown_timeout_seconds'; fi
printf 'interval_minutes=60\nrollback_versions=0\n' >"$config"
read_config
assert_eq "$rollback_versions" 0
printf 'interval_minutes=60\nrollback_versions=1000\n' >"$config"
read_config
assert_eq "$rollback_versions" 1000
for invalid_retention in 1001 nope; do
  printf 'interval_minutes=60\nrollback_versions=%s\n' "$invalid_retention" >"$config"
  if read_config 2>/dev/null; then fail_test "accepted invalid rollback_versions=$invalid_retention"; fi
done
printf 'interval_minutes=60\nplay_sound=false\nassume_yes=true\nstop_app=false\nstop_delay_seconds=0\nforce_kill=true\nrestart_app=false\nrestart_delay_seconds=180\nenable_gui=false\n' >"$config"
read_config
assert_eq "$play_sound" false
assert_eq "$assume_yes" true
assert_eq "$stop_app" false
assert_eq "$stop_delay_seconds" 0
assert_eq "$force_kill" true
assert_eq "$restart_app" false
assert_eq "$restart_delay_seconds" 180
assert_eq "$enable_gui" false
for boolean_key in play_sound assume_yes stop_app force_kill restart_app enable_gui; do
  for invalid_boolean in yes TRUE False 1; do
    printf 'interval_minutes=60\n%s=%s\n' "$boolean_key" "$invalid_boolean" >"$config"
    if read_config 2>/dev/null; then fail_test "accepted invalid $boolean_key=$invalid_boolean"; fi
  done
done
for delay_key in stop_delay_seconds restart_delay_seconds; do
  for invalid_delay in 181 nope; do
    printf 'interval_minutes=60\n%s=%s\n' "$delay_key" "$invalid_delay" >"$config"
    if read_config 2>/dev/null; then fail_test "accepted invalid $delay_key=$invalid_delay"; fi
  done
done
printf 'interval_minutes=60\nforce_kill=false\nforce_kill=true\n' >"$config"
if read_config 2>/dev/null; then fail_test 'accepted duplicate force_kill'; fi
# A late parse failure must not retain earlier values that enable unattended actions.
printf 'assume_yes=true\nforce_kill=true\nthis is invalid\n' >"$config"
if read_config 2>/dev/null; then fail_test 'accepted a partially valid corrupt config'; fi
assert_eq "$assume_yes" false
assert_eq "$force_kill" false
notify-send() { printf '%s\n' "$*" >"$test_home/config-alert"; }
rm -- "$config"
run_check 2>/dev/null
[[ $(<"$test_home/config-alert") == *'Config is missing or unreadable'*'https://github.com/aakashH242/chatgpt-update-notifier'* ]] || fail_test 'missing config did not warn with GitHub link'
[[ $(<"$test_home/config-alert") == *'--expire-time=15000'* ]] || fail_test 'config warning did not use default display time'
[[ $(<"$test_home/config-alert") == *'--hint=string:sound-name:message-new-instant'* ]] || fail_test 'config warning omitted the default sound hint'
printf 'interval_minutes=10\n' >"$config"
if read_config 2>/dev/null; then fail_test 'accepted interval under 15 minutes'; fi
run_check 2>/dev/null
[[ $(<"$test_home/config-alert") == *'Config is corrupt'*'https://github.com/aakashH242/chatgpt-update-notifier'* ]] || fail_test 'corrupt config did not warn with GitHub link'
printf 'interval_minutes=$(touch %s/never-run)\n' "$test_home" >"$config"
if read_config 2>/dev/null; then fail_test 'executed or accepted config as shell'; fi
[[ ! -e $test_home/never-run ]] || fail_test 'executed config content'
printf 'interval_minutes=60\n' >"$config"

# Settings persistence validates the complete schema before atomically replacing
# the live file. Invalid, incomplete, failed, or symlink targets keep old bytes.
read_config
declare -A proposed_config=()
for entry in "${config_defaults[@]}"; do
  key=${entry%%=*}
  proposed_config[$key]=${!key}
done
proposed_config[interval_minutes]=75
proposed_config[play_sound]=false
save_config_values proposed_config
grep -qx 'interval_minutes=75' "$config" || fail_test 'settings save omitted the new interval'
grep -qx 'play_sound=false' "$config" || fail_test 'settings save omitted the new sound value'
assert_eq "$(stat -c %a "$config")" 600
saved_config=$(sha256sum "$config")
proposed_config[interval_minutes]=16
if save_config_values proposed_config 2>/dev/null; then fail_test 'settings save accepted an invalid interval'; fi
assert_eq "$(sha256sum "$config")" "$saved_config"
proposed_config[interval_minutes]=75
unset 'proposed_config[restart_app]'
if save_config_values proposed_config 2>/dev/null; then fail_test 'settings save accepted an incomplete schema'; fi
assert_eq "$(sha256sum "$config")" "$saved_config"
proposed_config[restart_app]=true
mv() { return 1; }
if save_config_values proposed_config 2>/dev/null; then fail_test 'settings save ignored atomic replacement failure'; fi
unset -f mv
assert_eq "$(sha256sum "$config")" "$saved_config"
[[ -z $(find "${config%/*}" -maxdepth 1 -name '.config.*' -print -quit) ]] || fail_test 'failed settings save left a temporary config'
printf() {
  if [[ ${1:-} == %s && ${2:-} == *$'notification_seconds='* ]]; then return 1; fi
  builtin printf "$@"
}
if save_config_values proposed_config 2>/dev/null; then fail_test 'settings save published a partial write'; fi
unset -f printf
assert_eq "$(sha256sum "$config")" "$saved_config"
[[ -z $(find "${config%/*}" -maxdepth 1 -name '.config.*' -print -quit) ]] || fail_test 'partial settings write left a temporary config'
mv -- "$config" "$config.real"
ln -s "${config##*/}.real" "$config"
if save_config_values proposed_config 2>/dev/null; then fail_test 'settings save replaced a config symlink'; fi
assert_eq "${saved_config%% *}" "$(sha256sum "$config.real" | cut -d ' ' -f1)"
rm -- "$config"
mv -- "$config.real" "$config"

rpm() { [[ $1 == -q ]] && printf '0:26.900.1-1.x86_64'; }
dnf() { [[ ${DNF_FAIL:-0} == 0 ]] || return 1; printf '%s' "${DNF_RESULT:-}"; }
DNF_RESULT='0:26.901.1-1.x86_64' check_fedora
assert_eq "$candidate" '0:26.901.1-1.x86_64'
DNF_RESULT='' check_fedora
assert_eq "$candidate" ''
if DNF_FAIL=1 check_fedora; then fail_test 'ignored DNF failure'; fi

find_apt_source() { apt_source="$test_home/chatgpt.sources"; }
dpkg-query() { printf '26.900.1'; }
apt-get() { [[ ${APT_FAIL:-0} == 0 ]]; }
apt-cache() { printf 'chatgpt:\n  Installed: 26.900.1\n  Candidate: %s\n  https://persistent.oaistatic.com/codex-app-prod/linux/deb\n' "$APT_CANDIDATE"; }
dpkg() { [[ $1 == --compare-versions && $2 == 26.901.1 && $3 == gt && $4 == 26.900.1 ]]; }
APT_CANDIDATE='26.901.1' check_apt
assert_eq "$candidate" '26.901.1'
APT_CANDIDATE='26.900.1' check_apt
assert_eq "$candidate" ''
APT_CANDIDATE='26.899.1' check_apt
assert_eq "$candidate" ''
if APT_FAIL=1 check_apt; then fail_test 'ignored APT refresh failure'; fi

pacman() { printf 'chatgpt-bin 26.900.1-1\n'; }
checkupdates() { [[ ${ARCH_FAIL:-0} == 0 ]] || return 1; [[ ${ARCH_EMPTY:-0} == 0 ]] || return 2; printf '%s' "${ARCH_RESULT:-}"; }
ARCH_RESULT='chatgpt-bin 26.900.1-1 -> 26.901.1-1' check_arch
assert_eq "$candidate" '26.901.1-1'
ARCH_RESULT='' check_arch
assert_eq "$candidate" ''
ARCH_EMPTY=1 check_arch
assert_eq "$candidate" ''
if ARCH_FAIL=1 check_arch; then fail_test 'ignored checkupdates failure'; fi

# Build a fake official launcher and process tree so detection can validate the
# main process without inspecting or terminating the developer's live desktop app.
original_path=$PATH
fake_bin="$test_home/fake-bin"
fake_app="$test_home/fake-app"
proc_root="$test_home/proc"
mkdir -p "$fake_bin" "$fake_app" "$proc_root/101" "$proc_root/102" "$proc_root/103"
printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_app/codex-launcher"
printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_app/ChatGPT"
printf '#!/usr/bin/env bash\nexit 0\n' >"$test_home/not-chatgpt"
chmod +x "$fake_app/codex-launcher" "$fake_app/ChatGPT" "$test_home/not-chatgpt"
ln -s "$fake_app/codex-launcher" "$fake_bin/chatgpt"
ln -s "$fake_app/ChatGPT" "$proc_root/101/exe"
ln -s "$fake_app/ChatGPT" "$proc_root/102/exe"
ln -s "$test_home/not-chatgpt" "$proc_root/103/exe"
printf '%s\0' "$fake_app/ChatGPT" >"$proc_root/101/cmdline"
printf '%s\0%s\0' "$fake_app/ChatGPT" '--type=renderer' >"$proc_root/102/cmdline"
printf '%s\0' "$test_home/not-chatgpt" >"$proc_root/103/cmdline"
PATH="$fake_bin:$PATH"
assert_eq "$(find_chatgpt_main_pids)" 101
chatgpt_running || fail_test 'did not detect the validated ChatGPT main process'

# Exercise the clean-close deadline with mocked process state. The success case
# exits after one poll; the timeout case performs exactly the configured polls.
mock_running=1
kill_calls=0
sleep_calls=0
last_signal=''
find_chatgpt_main_pids() { (( mock_running )) && printf '4242\n'; }
kill() { kill_calls=$((kill_calls + 1)); last_signal=$1; mock_running=0; }
sleep() { sleep_calls=$((sleep_calls + 1)); }
shutdown_timeout_seconds=10
close_chatgpt || fail_test 'clean ChatGPT shutdown reported failure'
assert_eq "$kill_calls" 1
assert_eq "$sleep_calls" 0
assert_eq "$last_signal" -TERM
mock_running=1
kill_calls=0
signal_chatgpt TERM 9999
assert_eq "$kill_calls" 0
assert_eq "$mock_running" 1
mock_running=1
kill_calls=0
sleep_calls=0
kill() { kill_calls=$((kill_calls + 1)); last_signal=$1; }
shutdown_timeout_seconds=3
if close_chatgpt; then fail_test 'ChatGPT shutdown timeout reported success'; fi
assert_eq "$kill_calls" 1
assert_eq "$sleep_calls" 3
assert_eq "$last_signal" -TERM
kill() { kill_calls=$((kill_calls + 1)); last_signal=$1; mock_running=0; }
force_close_chatgpt || fail_test 'force close reported failure after the process exited'
assert_eq "$kill_calls" 2
assert_eq "$last_signal" -KILL
if signal_chatgpt HUP 2>/dev/null; then fail_test 'accepted an unsupported ChatGPT signal'; fi
assert_eq "$kill_calls" 2
unset -f kill sleep

# Reload real helpers, then verify detached startup uses the public launcher and
# a systemd exec-type service rather than the private Electron binary.
. "$root/chatgpt-update-notifier"
PATH="$fake_bin:$original_path"
systemd_run_args=''
systemd-run() { systemd_run_args=$*; }
start_chatgpt
[[ $systemd_run_args == *'--user --collect --quiet --property=Type=exec'*"$fake_bin/chatgpt"* ]] || fail_test 'startup did not use systemd-run and the public launcher'
unset -f systemd-run
proc_root="$test_home/empty-proc"
mkdir -p "$proc_root"

detect_distro() { distro=fedora; }
available='0:26.901.1-1.x86_64'
check_update() { installed='0:26.900.1-1.x86_64'; candidate=$available; [[ ${CHECK_FAIL:-0} == 0 ]]; }
alerts=0
notify_update() { alerts=$((alerts + 1)); }
run_check
assert_eq "$alerts" 1
run_check
assert_eq "$alerts" 1
printf '%s\n' "$available" >"$state_dir/silenced-version"
printf 'interval_minutes=15\n' >"$config"
printf '%s\n' "$(($(date +%s) - 900))" >"$state_dir/last-check"
run_check
assert_eq "$alerts" 1
available='0:26.902.1-1.x86_64'
printf '%s\n' "$(($(date +%s) - 900))" >"$state_dir/last-check"
run_check
assert_eq "$alerts" 2
printf '%s\n' "$(($(date +%s) - 900))" >"$state_dir/last-check"
before=$(<"$state_dir/last-check")
if CHECK_FAIL=1 run_check 2>/dev/null; then fail_test 'ignored offline check failure'; fi
assert_eq "$(<"$state_dir/last-check")" "$before"
silence >/dev/null
assert_eq "$(<"$state_dir/silenced-version")" "$available"

curl() { [[ ${CURL_FAIL:-0} == 0 ]] || return 1; printf '%s' "${REMOTE_VERSION:-1.2.0}"; }
notifier_alerts=0
notify_notifier_update() { notifier_alerts=$((notifier_alerts + 1)); }
REMOTE_VERSION=1.2.1 check_notifier_update
REMOTE_VERSION=1.2.1 check_notifier_update
assert_eq "$notifier_alerts" 2
printf '1.2.1\n' >"$state_dir/silenced-notifier-version"
REMOTE_VERSION=1.2.1 check_notifier_update
assert_eq "$notifier_alerts" 2
REMOTE_VERSION=1.3.0 check_notifier_update
assert_eq "$notifier_alerts" 3
REMOTE_VERSION=1.0.0 check_notifier_update
assert_eq "$notifier_alerts" 3
REMOTE_VERSION="\$(touch $test_home/never-run-version)" check_notifier_update 2>/dev/null
assert_eq "$notifier_alerts" 3
[[ ! -e $test_home/never-run-version ]] || fail_test 'executed a remote VERSION as shell'
CURL_FAIL=1 check_notifier_update 2>/dev/null
assert_eq "$notifier_alerts" 3
assert_eq "$(<"$state_dir/last-available-notifier-version")" 1.3.0
REMOTE_VERSION=1.4.0 refresh_notifier_update
assert_eq "$(<"$state_dir/last-available-notifier-version")" 1.4.0
refresh_status=0
REMOTE_VERSION=1.2.0 refresh_notifier_update || refresh_status=$?
assert_eq "$refresh_status" 1
refresh_status=0
CURL_FAIL=1 refresh_notifier_update 2>/dev/null || refresh_status=$?
assert_eq "$refresh_status" 2
saved_state_dir=$state_dir
state_dir="$test_home/notifier-state-file"
printf 'not a directory\n' >"$state_dir"
refresh_status=0
CURL_FAIL=0 REMOTE_VERSION=1.4.0 refresh_notifier_update 2>/dev/null || refresh_status=$?
assert_eq "$refresh_status" 2
state_dir=$saved_state_dir
[[ $(show_changelog "$root/CHANGELOG.yaml" 1.1.0) == *'Configurable desktop notification sounds'* ]] || fail_test 'YAML release notes were not displayed'

. "$root/chatgpt-update-notifier"
detect_distro() { distro=fedora; }
terminal() { return 1; }
timeout() { printf '%s\n' "$@" >"$test_home/notify-args"; printf 'silence'; }
distro=fedora installed='0:26.900.1-1.x86_64' candidate=$available
notify_update
assert_eq "$(<"$state_dir/silenced-version")" "$candidate"
assert_eq "$(tail -n 1 "$test_home/notify-args")" "$installed → $candidate"
grep -qx -- '--expire-time=15000' "$test_home/notify-args" || fail_test 'app alert did not use default display time'
grep -qx -- '15s' "$test_home/notify-args" || fail_test 'default action listener timeout differs from alert duration'
grep -qx -- '--hint=string:sound-name:message-new-instant' "$test_home/notify-args" || fail_test 'app alert omitted the default sound hint'
if grep -q -- '--action=install=' "$test_home/notify-args"; then fail_test 'offered installation without a terminal'; fi
terminal() { terminal_app=konsole; }
opened=0
open_terminal() { [[ $1 == upgrade ]] || fail_test 'wrong terminal command'; opened=$((opened + 1)); }
notification_seconds=600
play_sound=false
set_notification_options || fail_test 'disabled sound made notification option setup fail'
timeout() { printf '%s\n' "$@" >"$test_home/notify-args"; printf 'install'; }
notify_update
assert_eq "$opened" 1
assert_eq "$(tail -n 1 "$test_home/notify-args")" "$installed → $candidate"
grep -qx -- '--expire-time=600000' "$test_home/notify-args" || fail_test 'app alert ignored configured display time'
grep -qx -- '600s' "$test_home/notify-args" || fail_test 'action listener timeout differs from alert duration'
if grep -q -- 'sound-name' "$test_home/notify-args"; then fail_test 'app alert played sound when play_sound=false'; fi
grep -qx -- '--hint=boolean:suppress-sound:true' "$test_home/notify-args" || fail_test 'app alert did not request silence'
rm -- "$state_dir/silenced-version"
timeout() { :; }
notify_update
[[ ! -e $state_dir/silenced-version ]] || fail_test 'expired app alert silenced a release'
timeout() { return 124; }
notify_update 2>"$test_home/app-expiry-log"
[[ ! -s $test_home/app-expiry-log && ! -e $state_dir/silenced-version ]] || fail_test 'app alert timeout was treated as dismissal or failure'
timeout() { printf 'silence'; return 124; }
notify_update
[[ ! -e $state_dir/silenced-version ]] || fail_test 'partial action output on timeout silenced a release'

. "$root/chatgpt-update-notifier"
notification_seconds=600
terminal() { terminal_app=ptyxis; }
ptyxis() { [[ $1 == -- && $3 == upgrade ]] || fail_test 'terminal did not receive the upgrade command'; }
open_terminal upgrade
ptyxis() { [[ $1 == -- && $3 == --update ]] || fail_test 'terminal did not receive the notifier update command'; }
open_terminal --update
timeout() { printf '%s\n' "$@" >"$test_home/notify-args"; printf 'dismiss'; }
latest_notifier_version=1.2.0
notify_notifier_update
assert_eq "$(<"$state_dir/silenced-notifier-version")" 1.2.0
grep -qx -- '--expire-time=600000' "$test_home/notify-args" || fail_test 'notifier alert ignored configured display time'
grep -qx -- '600s' "$test_home/notify-args" || fail_test 'notifier action listener timeout differs from alert duration'
rm -- "$state_dir/silenced-notifier-version"
timeout() { :; }
notify_notifier_update
[[ ! -e $state_dir/silenced-notifier-version ]] || fail_test 'expired notification silenced a release'
timeout() { return 124; }
notify_notifier_update 2>"$test_home/notifier-expiry-log"
[[ ! -s $test_home/notifier-expiry-log && ! -e $state_dir/silenced-notifier-version ]] || fail_test 'notifier alert timeout was treated as dismissal or failure'
opened=0
open_terminal() { [[ $1 == --update ]] || fail_test 'wrong notifier terminal command'; opened=$((opened + 1)); }
timeout() { printf 'update'; }
notify_notifier_update
assert_eq "$opened" 1
printf '1.3.0\n' >"$state_dir/last-available-notifier-version"
silence_notifier >/dev/null
assert_eq "$(<"$state_dir/silenced-notifier-version")" 1.3.0

# Exact rollback copies are completed atomically, validated from their manifests,
# kept without a limit at zero, and pruned to the configured newest count.
. "$root/chatgpt-update-notifier"
rollback_root="$test_home/rollback-state"
state_dir="$test_home/rollback-state-parent"
rollback_root="$state_dir/rollbacks"
mock_installed_version='0:26.900.1-1'
detect_distro() { distro=fedora; }
installed_package_identity() {
  package_name=chatgpt
  package_version=$mock_installed_version
  package_arch=x86_64
}
artifact_matches() {
  [[ -f $1 && $(<"$1") == "$2|$3" ]]
}
stage_cached_artifact() {
  snapshot_file="$1/chatgpt-${package_version//:/_}.x86_64.rpm"
  printf '%s|%s' "$package_version" "$package_arch" >"$snapshot_file"
  chmod 600 "$snapshot_file"
  snapshot_signature=''
}
stage_repository_artifact() { return 1; }
clock_file="$test_home/snapshot-clock"
printf '1790000000\n' >"$clock_file"
date() {
  if [[ ${1:-} == +%s ]]; then
    local value
    value=$(<"$clock_file")
    value=$((value + 1))
    printf '%s\n' "$value" >"$clock_file"
    printf '%s\n' "$value"
  else
    command date "$@"
  fi
}
rollback_versions=0
for mock_installed_version in 0:26.900.1-1 0:26.901.1-1 0:26.902.1-1 0:26.903.1-1; do
  snapshot_before_upgrade >/dev/null
done
assert_eq "$(find "$rollback_root" -mindepth 1 -maxdepth 1 -type d | wc -l)" 4
rollback_versions=3
mock_installed_version='0:26.900.1-1'
snapshot_before_upgrade >/dev/null
assert_eq "$(find "$rollback_root" -mindepth 1 -maxdepth 1 -type d | wc -l)" 3
package_arch=x86_64
find_snapshot_by_version '0:26.900.1-1' || fail_test 'protected current rollback snapshot was pruned'
find_snapshot_by_version '0:26.903.1-1' || fail_test 'newest rollback snapshot was not retained'
valid_snapshot=$selected_snapshot_dir
grep -qx 'distro=fedora' "$valid_snapshot/snapshot" || fail_test 'snapshot manifest omitted distro'
grep -qx 'version=0:26.903.1-1' "$valid_snapshot/snapshot" || fail_test 'snapshot manifest omitted exact version'
read_snapshot_manifest "$valid_snapshot" || fail_test 'valid snapshot failed verification'
valid_artifact="$valid_snapshot/$manifest_filename"
printf 'tampered' >>"$valid_artifact"
if read_snapshot_manifest "$valid_snapshot"; then fail_test 'accepted a snapshot with a bad checksum'; fi
printf '%s|%s' '0:26.903.1-1' x86_64 >"$valid_artifact"
read_snapshot_manifest "$valid_snapshot" || fail_test 'restored snapshot did not validate'

# A fresh CLI shell has no distro global before `rollback --list`. Valid snapshots
# must still be shown instead of losing a nounset error inside process substitution.
(
  unset distro package_name
  current_chatgpt_version() { printf '0:26.904.1-1'; }
  list_output=$(list_rollback_snapshots)
  [[ $list_output == *'0:26.903.1-1'* ]] || fail_test 'fresh-shell rollback list hid a valid snapshot'
)
mv -- "$valid_artifact" "$valid_artifact.real"
ln -s "${valid_artifact##*/}.real" "$valid_artifact"
if read_snapshot_manifest "$valid_snapshot"; then fail_test 'accepted a symlinked rollback artifact'; fi
rm -- "$valid_artifact"
mv -- "$valid_artifact.real" "$valid_artifact"

# Each distro restores the saved local package with its native dependency checks intact.
distro=fedora
assert_eq "$(restore_command manual '/tmp/old chatgpt.rpm')" 'sudo dnf install /tmp/old\ chatgpt.rpm'
assert_eq "$(restore_command automatic '/tmp/old.rpm')" 'sudo -n dnf install -y /tmp/old.rpm'
distro=ubuntu
assert_eq "$(restore_command manual '/tmp/old.deb')" 'sudo apt-get install --allow-downgrades /tmp/old.deb'
assert_eq "$(restore_command automatic '/tmp/old.deb')" 'sudo -n apt-get install --allow-downgrades -y /tmp/old.deb'
distro=arch
assert_eq "$(restore_command manual '/tmp/old.pkg.tar.zst')" 'sudo pacman -U /tmp/old.pkg.tar.zst'
assert_eq "$(restore_command automatic '/tmp/old.pkg.tar.zst')" 'sudo -n pacman -U --noconfirm /tmp/old.pkg.tar.zst'

# Arch protection is usable only when the detached package signature is present
# and trusted by the same system keyring pacman will use during restore.
arch_package="$test_home/chatgpt-bin-old.pkg.tar.zst"
arch_stage="$test_home/arch-signature-stage"
mkdir "$arch_stage"
printf 'arch package\n' >"$arch_package"
distro=arch package_name=chatgpt-bin package_version=26.900.1-1 package_arch=x86_64
artifact_matches() { :; }
if stage_artifact "$arch_package" "$arch_stage"; then fail_test 'Arch snapshot accepted a missing signature'; fi
printf 'signature\n' >"$arch_package.sig"
pacman-key() { return 1; }
if stage_artifact "$arch_package" "$arch_stage"; then fail_test 'Arch snapshot accepted an invalid signature'; fi
pacman-key() { :; }
stage_artifact "$arch_package" "$arch_stage" || fail_test 'Arch snapshot rejected a verified signature'
unset -f pacman-key

# Cache misses use exact, signed-repository metadata on Fedora and Debian-family
# systems. Arch refuses to guess an old repository URL when only the new package is indexed.
. "$root/chatgpt-update-notifier"
repository_log="$test_home/repository-downloads"
artifact_matches() { [[ -f $1 && $(<"$1") == "$2|$3" ]]; }
package_name=chatgpt package_version='0:26.903.1-1' package_arch=x86_64 distro=fedora
dnf() {
  local argument destination=''
  printf 'dnf %s\n' "$*" >>"$repository_log"
  for argument in "$@"; do [[ $argument == --destdir=* ]] && destination=${argument#*=}; done
  printf '%s|%s' "$package_version" "$package_arch" >"$destination/chatgpt-test.rpm"
}
fedora_stage="$test_home/fedora-stage"
mkdir "$fedora_stage"
stage_repository_artifact "$fedora_stage" || fail_test 'exact Fedora repository package was not staged'
grep -q -- "--disablerepo=\* --enablerepo=openai-chatgpt download .*chatgpt-0:26.903.1-1.x86_64" "$repository_log" ||
  fail_test 'Fedora exact-package download was not restricted to the OpenAI repo'
package_version='26.903.1-1' package_arch=amd64 distro=debian
prepare_apt_repository() { apt_options=(-o Test=isolated); }
apt-get() {
  printf 'apt-get %s\n' "$*" >>"$repository_log"
  printf '%s|%s' "$package_version" "$package_arch" >'chatgpt_26.903.1-1_amd64.deb'
}
debian_stage="$test_home/debian-stage"
mkdir "$debian_stage"
stage_repository_artifact "$debian_stage" || fail_test 'exact Debian repository package was not staged'
grep -q 'apt-get -o Test=isolated download chatgpt=26.903.1-1' "$repository_log" ||
  fail_test 'APT exact-package download did not reuse isolated signed metadata'
distro=arch
arch_stage="$test_home/arch-stage"
mkdir "$arch_stage"
if stage_repository_artifact "$arch_stage"; then fail_test 'Arch guessed an unavailable historical repository package'; fi

# The post-update action carries its version into the visible rollback terminal.
notification_seconds=15 play_sound=false upgrade_app_state=unchanged
terminal() { terminal_app=konsole; }
timeout() { printf 'rollback'; }
opened_command=''
open_terminal() { opened_command=$*; }
notify_rollback_available '0:26.903.1-1' '0:26.904.1-1'
assert_eq "$opened_command" 'rollback 0:26.903.1-1'

# Installed binaries ignore an unrelated adjacent core directory and load only the
# modules retained under their matching notifier version in XDG_DATA_HOME.
installed_layout="$test_home/installed-layout"
installed_data="$installed_layout/data"
installed_home="$installed_layout/home"
installed_bin="$installed_home/.local/bin"
mkdir -p "$installed_bin/core" "$installed_data/chatgpt-update-notifier/1.2.0/core"
cp "$root/chatgpt-update-notifier" "$installed_bin/chatgpt-update-notifier"
cp "$root/core/package-operation.sh" "$root/core/rollback.sh" "$root/core/manager.sh" \
  "$installed_data/chatgpt-update-notifier/1.2.0/core/"
printf '1.2.0\n' >"$installed_bin/VERSION"
printf 'printf wrong >"$MODULE_MARKER"\n' >"$installed_bin/core/package-operation.sh"
printf 'printf wrong >"$MODULE_MARKER"\n' >"$installed_bin/core/rollback.sh"
printf 'printf wrong >>"$MODULE_MARKER"\n' >"$installed_bin/core/manager.sh"
HOME="$installed_home" MODULE_MARKER="$installed_layout/wrong-module" XDG_DATA_HOME="$installed_data" \
  bash -c '. "$1"; type upgrade >/dev/null; type rollback_command >/dev/null; type manage >/dev/null' _ \
  "$installed_bin/chatgpt-update-notifier"
[[ ! -e $installed_layout/wrong-module ]] || fail_test 'installed binary sourced an unrelated adjacent core directory'

# Root-only diagnostics remain available when an installed companion is damaged.
mv "$installed_data/chatgpt-update-notifier/1.2.0/core/package-operation.sh" \
  "$installed_data/chatgpt-update-notifier/1.2.0/core/package-operation.sh.missing"
version_output=$(HOME="$installed_home" XDG_DATA_HOME="$installed_data" bash "$installed_bin/chatgpt-update-notifier" --version)
help_output=$(HOME="$installed_home" XDG_DATA_HOME="$installed_data" bash "$installed_bin/chatgpt-update-notifier" --help)
[[ $version_output == *'1.2.0'* && $help_output == *'Usage:'* ]] || fail_test 'diagnostics required a healthy core module'
mv "$installed_data/chatgpt-update-notifier/1.2.0/core/package-operation.sh.missing" \
  "$installed_data/chatgpt-update-notifier/1.2.0/core/package-operation.sh"

# A matching checkout VERSION selects only its adjacent modules. Missing source
# components must fail instead of silently mixing with a previous installation.
incomplete_checkout="$installed_layout/incomplete-checkout"
mkdir -p "$incomplete_checkout/core"
cp "$root/chatgpt-update-notifier" "$root/VERSION" "$incomplete_checkout/"
cp "$root/core/rollback.sh" "$root/core/manager.sh" "$incomplete_checkout/core/"
if HOME="$installed_home" XDG_DATA_HOME="$installed_data" bash -c '. "$1"' _ \
  "$incomplete_checkout/chatgpt-update-notifier" 2>/dev/null; then
  fail_test 'incomplete checkout fell back to installed modules'
fi

# Every non-installed script is a checkout: missing or mismatched release metadata
# must fail, while a complete checkout remains portable when invoked through a symlink.
cp "$root/core/package-operation.sh" "$incomplete_checkout/core/"
printf '9.9.9\n' >"$incomplete_checkout/VERSION"
if HOME="$installed_home" XDG_DATA_HOME="$installed_data" bash -c '. "$1"' _ \
  "$incomplete_checkout/chatgpt-update-notifier" 2>/dev/null; then
  fail_test 'mismatched checkout VERSION fell back to installed modules'
fi
rm -- "$incomplete_checkout/VERSION"
if HOME="$installed_home" XDG_DATA_HOME="$installed_data" bash -c '. "$1"' _ \
  "$incomplete_checkout/chatgpt-update-notifier" 2>/dev/null; then
  fail_test 'checkout without VERSION fell back to installed modules'
fi
cp "$root/VERSION" "$incomplete_checkout/"
ln -s "$incomplete_checkout/chatgpt-update-notifier" "$installed_layout/checkout-link"
HOME="$installed_home" XDG_DATA_HOME="$installed_data" bash -c \
  '. "$1"; type upgrade >/dev/null; type rollback_command >/dev/null; type manage >/dev/null' _ \
  "$installed_layout/checkout-link" || fail_test 'complete checkout failed through a symlink'

# Native and terminal managers share one silence reset, which removes only the
# two dismissal markers and leaves the last-known candidates available.
(
  . "$root/chatgpt-update-notifier"
  state_dir="$test_home/manager-silences"
  mkdir -p "$state_dir"
  printf '26.901.1\n' >"$state_dir/silenced-version"
  printf '1.3.0\n' >"$state_dir/silenced-notifier-version"
  printf '26.901.1\n' >"$state_dir/last-available-version"
  dialog_app=kdialog
  kdialog() { printf '%s\n' "$*"; }
  native_manager=$(gui_manager_action 26.900.1)
  [[ $native_manager == *'clear Clear silences'* ]] || fail_test 'native manager omitted clear silences'
  [[ $native_manager == *'settings Settings'* ]] || fail_test 'native manager omitted settings'
  [[ $native_manager == *'--geometry 760x380 --ok-label Select --cancel-label Cancel'*'Double-click a row'* ]] ||
    fail_test 'native manager omitted the scaled selectable-list affordances'
  gui_manager_action() { printf 'clear'; }
  gui_message() { printf '%s|%s' "$1" "$2" >"$test_home/clear-gui-message"; }
  current_chatgpt_version() { printf '26.900.1'; }
  manager_gui >/dev/null
  [[ ! -e $state_dir/silenced-version && ! -e $state_dir/silenced-notifier-version ]] ||
    fail_test 'native manager did not clear both silence markers'
  [[ -e $state_dir/last-available-version ]] || fail_test 'clear silences removed last-known update state'
  grep -q 'Silences cleared' "$test_home/clear-gui-message" || fail_test 'native manager did not confirm cleared silences'
)

# Native settings stage edits until Save, and Cancel after an invalid value keeps
# the original file. Manager dispatch reaches the settings editor directly.
(
  . "$root/chatgpt-update-notifier"
  config_file="$test_home/gui-settings-config"
  set_config_defaults
  declare -A initial_settings=()
  for entry in "${config_defaults[@]}"; do key=${entry%%=*}; initial_settings[$key]=${!key}; done
  save_config_values initial_settings
  dialog_app=kdialog
  kdialog() { printf '%s\n' "$*"; }
  load_manager_settings
  native_settings=$(gui_settings_action)
  [[ $native_settings == *'interval_minutes Check interval: 60'*'save Save changes'*'cancel Cancel without saving'* ]] ||
    fail_test 'KDialog settings chooser omitted values or save controls'
  [[ $native_settings == *'--geometry 760x560 --ok-label Select --cancel-label Cancel'*'Double-click a row'* ]] ||
    fail_test 'KDialog settings chooser used the wrong scale or controls'
  [[ $(gui_manager_setting_value interval_minutes) == *'--inputbox'*'15–10080'*' 60' ]] ||
    fail_test 'KDialog numeric setting used the wrong control'
  [[ $(gui_manager_setting_value play_sound) == *'--menu true or false'*'true Enabled (true)'*'false Disabled (false)'* ]] ||
    fail_test 'KDialog boolean setting used the wrong choices'
  [[ $(gui_manager_setting_value play_sound) == *'--geometry 760x320'* ]] ||
    fail_test 'KDialog boolean setting was not compactly scaled'
  manager_settings[play_sound]=false
  [[ $(gui_manager_setting_value play_sound) == *'--menu true or false'*'false Disabled (false)'*'true Enabled (true)'* ]] ||
    fail_test 'KDialog boolean setting did not prefer the saved value'
  [[ $(gui_manager_setting_value force_kill) == *'true may lose unsaved work; false is safer'* ]] ||
    fail_test 'force-close setting omitted the unsaved-work warning'
  unset -f kdialog
  dialog_app=zenity
  zenity() { printf '%s\n' "$*"; }
  zenity_settings=$(gui_settings_action)
  [[ $zenity_settings == *'--width=760 --height=560 --ok-label=Select --cancel-label=Cancel'* ]] ||
    fail_test 'Zenity settings chooser used the wrong scale or controls'
  [[ $zenity_settings == *'--column=Setting --column=Value'*'rollback_versions Rollback versions to keep: 3'* ]] ||
    fail_test 'Zenity settings chooser omitted columns or values'
  [[ $(gui_manager_setting_value notification_seconds) == *'--entry'*'--entry-text=15'* ]] ||
    fail_test 'Zenity numeric setting used the wrong control'
  unset -f zenity
  dialog_app=kdialog
  printf 'interval_minutes\nsave\n' >"$test_home/gui-settings-actions"
  gui_settings_action() {
    local action
    read -r action <"$test_home/gui-settings-actions"
    sed -i '1d' "$test_home/gui-settings-actions"
    printf '%s' "$action"
  }
  gui_manager_setting_value() { [[ $1 == interval_minutes ]]; printf '75'; }
  gui_message() { printf '%s|%s\n' "$1" "$2" >>"$test_home/gui-settings-messages"; }
  gui_settings
  read_config
  assert_eq "$interval_minutes" 75
  grep -q 'Settings saved' "$test_home/gui-settings-messages" || fail_test 'native settings did not confirm save'
  saved_config=$(sha256sum "$config_file")
  printf 'interval_minutes\ncancel\n' >"$test_home/gui-settings-actions"
  gui_manager_setting_value() { printf '16'; }
  gui_settings 2>/dev/null
  assert_eq "$(sha256sum "$config_file")" "$saved_config"
  grep -q 'Invalid setting' "$test_home/gui-settings-messages" || fail_test 'native settings did not explain invalid input'
  gui_manager_action() { printf 'settings'; }
  gui_settings() { : >"$test_home/gui-settings-opened"; }
  current_chatgpt_version() { printf '26.900.1'; }
  refresh_manager_notifier() { :; }
  manager_gui
  [[ -e $test_home/gui-settings-opened ]] || fail_test 'native manager did not dispatch settings'
)

# Terminal settings use the same schema and Save/Cancel semantics.
(
  . "$root/chatgpt-update-notifier"
  config_file="$test_home/terminal-settings-config"
  set_config_defaults
  declare -A initial_settings=()
  for entry in "${config_defaults[@]}"; do key=${entry%%=*}; initial_settings[$key]=${!key}; done
  save_config_values initial_settings
  manager_terminal_settings <<< $'1\n75\n3\nfalse\n13\n' >"$test_home/terminal-settings-output"
  read_config
  assert_eq "$interval_minutes" 75
  assert_eq "$play_sound" false
  grep -q 'Settings saved' "$test_home/terminal-settings-output" || fail_test 'terminal settings did not confirm save'
  manager_terminal_settings <<< $'010\n45\n13\n' >"$test_home/terminal-leading-zero-output"
  read_config
  assert_eq "$restart_delay_seconds" 45
  assert_eq "$force_kill" false
  saved_config=$(sha256sum "$config_file")
  manager_terminal_settings <<< $'1\n16\n13\n' >"$test_home/terminal-invalid-setting-output" 2>/dev/null
  read_config
  assert_eq "$interval_minutes" 75
  grep -q 'Invalid value' "$test_home/terminal-invalid-setting-output" || fail_test 'terminal settings did not explain invalid input'
  manager_terminal_settings <<< $'2\n30\n14\n' >/dev/null
  assert_eq "$(sha256sum "$config_file")" "$saved_config"
)

# Opening either manager checks for a newer notifier. A native CTA opens the
# existing --update terminal, while the terminal CTA calls the changelog flow.
(
  . "$root/chatgpt-update-notifier"
  state_dir="$test_home/manager-update-state"
  refresh_notifier_update() { latest_notifier_version=1.3.0; mkdir -p "$state_dir"; return 0; }
  current_chatgpt_version() { printf '26.900.1'; }
  dialog_app=kdialog
  kdialog() { printf '%s\n' "$*"; }
  refresh_manager_notifier
  [[ $(gui_manager_action 26.900.1) == *'update Update notifier to 1.3.0'* ]] ||
    fail_test 'native manager omitted an available notifier update'
  gui_manager_action() { printf 'update'; }
  open_terminal() { [[ $1 == --update ]] || fail_test 'native manager opened the wrong update command'; : >"$test_home/gui-update-opened"; }
  manager_gui
  [[ -e $test_home/gui-update-opened ]] || fail_test 'native manager did not open the notifier update flow'
  refresh_notifier_update() { return 2; }
  refresh_manager_notifier 2>/dev/null
  [[ -z $manager_notifier_version ]] || fail_test 'failed manager check left a stale update CTA'
)
(
  . "$root/chatgpt-update-notifier"
  state_dir="$test_home/terminal-update-state"
  refresh_notifier_update() { latest_notifier_version=1.3.0; return 0; }
  current_chatgpt_version() { printf '26.900.1'; }
  update_notifier() {
    printf 'What is new in 1.3.0:\n  - Test release\n\nCommand: bash install.sh --release 1.3.0\n'
    : >"$test_home/terminal-update-ran"
    return 1
  }
  manager_terminal_loop <<< $'6\n'
) >"$test_home/terminal-update-output"
[[ -e $test_home/terminal-update-ran ]] || fail_test 'terminal manager did not run the notifier update flow'
grep -q 'Update notifier to 1.3.0' "$test_home/terminal-update-output" || fail_test 'terminal manager omitted update CTA'
grep -q 'What is new in 1.3.0' "$test_home/terminal-update-output" || fail_test 'terminal manager omitted changelog flow'

# The application launcher respects enable_gui and otherwise opens the terminal manager.
read_config() { enable_gui=false; }
opened_command=''
manage
assert_eq "$opened_command" manage-terminal
gui_calls=0
read_config() { enable_gui=true; }
kdialog() { :; }
manager_gui() { gui_calls=$((gui_calls + 1)); }
manage
assert_eq "$gui_calls" 1
unset -f kdialog date

# The detached terminal fallback is a fresh process and must reload customized
# values before its settings editor can stage or save them.
(
  . "$root/chatgpt-update-notifier"
  config_file="$test_home/fresh-terminal-config"
  printf 'interval_minutes=75\nplay_sound=false\n' >"$config_file"
  set_config_defaults
  if manager_terminal </dev/null 2>/dev/null; then fail_test 'terminal manager accepted non-interactive input'; fi
  assert_eq "$interval_minutes" 75
  assert_eq "$play_sound" false
)

# Recoverable failures do not close the numbered manager opened from the desktop.
(
  . "$root/chatgpt-update-notifier"
  state_dir="$test_home/terminal-silences"
  mkdir -p "$state_dir"
  : >"$state_dir/silenced-version"
  : >"$state_dir/silenced-notifier-version"
  current_chatgpt_version() { printf '26.900.1'; }
  run_check() { return 1; }
  rollback_interactive() { return 1; }
  manager_terminal_loop <<< $'1\n\n2\n4\n\n6\n'
  [[ ! -e $state_dir/silenced-version && ! -e $state_dir/silenced-notifier-version ]] ||
    fail_test 'terminal manager did not clear both silence markers'
) >"$test_home/terminal-manager-output"
[[ $(grep -c 'ChatGPT Update Notifier' "$test_home/terminal-manager-output") -ge 3 ]] ||
  fail_test 'terminal manager exited after a recoverable action failure'

# An explicit desktop/menu check reports network failure and may show a previously
# silenced candidate; only scheduled checks stay quiet for that candidate.
(
  . "$root/chatgpt-update-notifier"
  state_dir="$test_home/forced-check-state"
  mkdir -p "$state_dir"
  read_config() { set_config_defaults; }
  detect_distro() { distro=fedora; }
  check_update() { return 1; }
  send_notification() { printf '%s\n' "$*" >"$test_home/forced-check-notification"; }
  if run_check force 2>/dev/null; then fail_test 'failed forced check reported success'; fi
  grep -q 'ChatGPT update check failed' "$test_home/forced-check-notification" ||
    fail_test 'failed forced check had no visible notification'
  check_update() { installed=26.900.1; candidate=26.901.1; }
  notify_update() { : >"$test_home/forced-silenced-notification"; }
  printf '26.901.1\n' >"$state_dir/silenced-version"
  run_check force
  [[ -e $test_home/forced-silenced-notification ]] ||
    fail_test 'forced check hid the available silenced version'
)

# A failed snapshot leaves no half-written directory behind.
rollback_root="$test_home/unavailable-rollbacks"
mock_installed_version='0:26.999.1-1'
installed_package_identity() {
  package_name=chatgpt
  package_version=$mock_installed_version
  package_arch=x86_64
}
stage_cached_artifact() { return 1; }
stage_repository_artifact() { return 1; }
if snapshot_before_upgrade 2>/dev/null; then fail_test 'reported unavailable rollback package as saved'; fi
[[ -z $(find "$rollback_root" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]] || fail_test 'failed snapshot left partial state'

# Snapshot publication explicitly handles write failures even when its caller uses it
# as an if-condition, where Bash does not apply errexit inside the function body.
rollback_root="$test_home/publication-failure-rollbacks"
stage_cached_artifact() {
  snapshot_file="$1/chatgpt-test.rpm"
  printf '%s|%s' "$package_version" "$package_arch" >"$snapshot_file"
  snapshot_signature=''
}
artifact_matches() { [[ -f $1 && $(<"$1") == "$2|$3" ]]; }
mv_calls=0
mv() {
  mv_calls=$((mv_calls + 1))
  (( mv_calls == 2 )) && return 9
  command mv "$@"
}
if snapshot_before_upgrade >"$test_home/publication-failure-output" 2>/dev/null; then
  fail_test 'failed final snapshot publication reported success'
fi
unset -f mv
[[ -z $(find "$rollback_root" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]] ||
  fail_test 'failed final snapshot publication left partial state'
[[ ! -s $test_home/publication-failure-output ]] || fail_test 'failed snapshot publication printed a success message'

# Restore production functions before the upgrade lifecycle suite.
. "$root/chatgpt-update-notifier"
detect_distro() { distro=fedora; }
rpm() { [[ $1 == -q ]]; }
configured_assume_yes=false
configured_stop_app=true
configured_force_kill=false
configured_restart_app=true
configured_read_config_status=0
read_config() {
  interval_minutes=60
  notification_seconds=15
  shutdown_timeout_seconds=2
  assume_yes=$configured_assume_yes
  stop_app=$configured_stop_app
  stop_delay_seconds=0
  force_kill=$configured_force_kill
  restart_app=$configured_restart_app
  restart_delay_seconds=0
  rollback_versions=3
  enable_gui=false
  return "$configured_read_config_status"
}
app_running=0
app_pid=4242
pid_checks=0
close_calls=0
force_calls=0
start_calls=0
auth_calls=0
package_calls=0
status_alerts=0
last_status_body=''
status_bodies=''
close_fails=0
close_failures_remaining=0
force_fails=0
start_fails=0
auth_status=0
package_status=0
package_new_pid=0
restore_query_stuck=0
identity_missing=0
manifest_switch=0
manifest_reads=0
countdown_new_pid=0
countdown_close_app=0
snapshot_status=0
snapshot_calls=0
snapshot_retention_seen=''
rollback_alerts=0
sudo_log="$test_home/sudo-log"
current_chatgpt_pids() {
  pid_checks=$((pid_checks + 1))
  (( app_running )) && printf '%s\n' "$app_pid"
}
chatgpt_running() {
  local target
  (( app_running )) || return 1
  (($# == 0)) && return 0
  for target in "$@"; do [[ $target == "$app_pid" ]] && return 0; done
  return 1
}
close_chatgpt() {
  close_calls=$((close_calls + 1))
  if (( close_failures_remaining )); then
    close_failures_remaining=$((close_failures_remaining - 1))
    return 1
  fi
  (( close_fails )) && return 1
  app_running=0
}
force_close_chatgpt() {
  force_calls=$((force_calls + 1))
  (( force_fails )) && return 1
  app_running=0
}
start_chatgpt() {
  start_calls=$((start_calls + 1))
  (( start_fails )) && return 1
  app_running=1
  app_pid=5252
}
notify_upgrade_status() {
  status_alerts=$((status_alerts + 1))
  last_status_body=$2
  status_bodies+="$2"$'\n'
}
snapshot_before_upgrade() {
  snapshot_calls=$((snapshot_calls + 1))
  snapshot_retention_seen=$rollback_versions
  rollback_snapshot_version='0:26.900.1-1'
  return "$snapshot_status"
}
installed_package_identity() {
  (( identity_missing )) && return 1
  package_name=chatgpt
  if [[ ${package_operation:-update} == rollback && $package_calls -gt 0 && $package_status -eq 0 && $restore_query_stuck -eq 0 ]]; then
    package_version='0:26.900.1-1'
  else
    package_version='0:26.901.1-1'
  fi
  package_arch=x86_64
}
notify_rollback_available() {
  rollback_alerts=$((rollback_alerts + 1))
  case ${upgrade_app_state:-unchanged} in
    restart-needed) notify_upgrade_status 'ChatGPT updated' 'Restart ChatGPT to use the updated version.' ;;
    stopped) notify_upgrade_status 'ChatGPT updated' 'Start ChatGPT when you are ready to use the updated version.' ;;
    restarted|running-current) notify_upgrade_status 'ChatGPT updated' 'The updated app is running.' ;;
    *) notify_upgrade_status 'ChatGPT updated' 'The package upgrade finished successfully.' ;;
  esac
}
countdown_while_running() {
  local purpose=$2
  shift 2
  notify_upgrade_status 'ChatGPT update in progress' "ChatGPT will $purpose soon."
  if (( countdown_close_app )); then app_running=0; return 1; fi
  if (( countdown_new_pid )); then app_running=1; app_pid=5252; return 1; fi
  chatgpt_running "$@"
}
sudo() {
  printf '%s\n' "$*" >>"$sudo_log"
  if [[ $1 == -v ]]; then
    auth_calls=$((auth_calls + 1))
    return "$auth_status"
  fi
  package_calls=$((package_calls + 1))
  if (( package_new_pid )); then app_running=1; app_pid=5252; fi
  return "$package_status"
}
reset_upgrade_mocks() {
  configured_assume_yes=false configured_stop_app=true configured_force_kill=false configured_restart_app=true
  configured_read_config_status=0
  app_running=1 app_pid=4242 pid_checks=0 close_calls=0 force_calls=0 start_calls=0
  auth_calls=0 package_calls=0 status_alerts=0 close_fails=0 close_failures_remaining=0 force_fails=0 start_fails=0
  auth_status=0 package_status=0 package_new_pid=0 countdown_new_pid=0 countdown_close_app=0
  restore_query_stuck=0
  identity_missing=0
  manifest_switch=0 manifest_reads=0
  snapshot_status=0 snapshot_calls=0 snapshot_retention_seen='' rollback_alerts=0
  last_status_body='' status_bodies=''
  : >"$sudo_log"
}

# A malformed config falls back to manual confirmation and unlimited retention.
# Continuing manually must never prune rollback history using a default value.
reset_upgrade_mocks
configured_read_config_status=1
app_running=0
upgrade <<< $'y\n\n' >"$test_home/upgrade-output" 2>"$test_home/upgrade-error"
assert_eq "$auth_calls" 0
assert_eq "$snapshot_retention_seen" 0
grep -q 'Using safe manual defaults' "$test_home/upgrade-error" || fail_test 'config failure omitted its safe-default warning'

# Cancelling the displayed command must happen before app detection or shutdown.
reset_upgrade_mocks
upgrade <<<"n" >"$test_home/upgrade-output"
assert_eq "$pid_checks" 0
assert_eq "$close_calls" 0
assert_eq "$package_calls" 0

# A missing exact package is explicit: manual mode defaults to cancelling, while
# one-click mode aborts after sudo authentication without touching the app.
reset_upgrade_mocks
snapshot_status=1
upgrade <<< $'y\nn\n' >"$test_home/upgrade-output" 2>"$test_home/upgrade-error"
assert_eq "$snapshot_calls" 1
assert_eq "$close_calls" 0
assert_eq "$package_calls" 0
grep -q 'A rollback copy could not be saved.' "$test_home/upgrade-output" || fail_test 'manual snapshot failure omitted its safe explanation'
reset_upgrade_mocks
configured_assume_yes=true
snapshot_status=1
if upgrade >"$test_home/upgrade-output" 2>"$test_home/upgrade-error"; then fail_test 'one-click update continued without rollback protection'; fi
assert_eq "$auth_calls" 1
assert_eq "$close_calls" 0
assert_eq "$package_calls" 0

# A shared advisory lock rejects a second package operation before it snapshots,
# stops ChatGPT, or invokes the package manager.
mkdir -p "$state_dir"
exec 9>"$state_dir/package-operation.lock"
flock -n 9
reset_upgrade_mocks
configured_assume_yes=true
if upgrade >"$test_home/upgrade-output" 2>"$test_home/upgrade-error"; then
  fail_test 'concurrent package operation was not rejected'
fi
assert_eq "$auth_calls" 1
assert_eq "$snapshot_calls" 0
assert_eq "$close_calls" 0
assert_eq "$package_calls" 0
flock -u 9
exec 9>&-

# Installation identity is rechecked under the operation lock. A package removed
# after the initial prompt cannot be mistaken for a mere snapshot cache miss.
reset_upgrade_mocks
configured_assume_yes=true
identity_missing=1
if upgrade >"$test_home/upgrade-output" 2>"$test_home/upgrade-error"; then
  fail_test 'upgrade continued after ChatGPT disappeared before the locked recheck'
fi
assert_eq "$auth_calls" 1
assert_eq "$snapshot_calls" 0
assert_eq "$close_calls" 0
assert_eq "$package_calls" 0
exec 9>"$state_dir/package-operation.lock"
flock -n 9 || fail_test 'missing-package abort leaked the operation lock'
flock -u 9
exec 9>&-

# Default-Yes closes a running app, upgrades, and starts it again afterward.
reset_upgrade_mocks
upgrade <<< $'y\n\n\n' >"$test_home/upgrade-output"
assert_eq "$close_calls" 1
assert_eq "$start_calls" 1
assert_eq "$package_calls" 1
assert_eq "$app_running" 1
grep -q 'Upgrade finished successfully.' "$test_home/upgrade-output" || fail_test 'successful upgrade message was missing'

# Declining the initial close and later restart leaves the old process running.
reset_upgrade_mocks
upgrade <<< $'y\nn\nn\n' >"$test_home/upgrade-output"
assert_eq "$close_calls" 0
assert_eq "$start_calls" 0
assert_eq "$app_running" 1
grep -q 'Restart ChatGPT later' "$test_home/upgrade-output" || fail_test 'manual restart guidance was missing'

# A user who kept the app open can accept the post-upgrade restart instead.
reset_upgrade_mocks
upgrade <<< $'y\nn\n\n' >"$test_home/upgrade-output"
assert_eq "$close_calls" 1
assert_eq "$start_calls" 1
assert_eq "$app_running" 1

# If the package manager fails after a close, offer to reopen the existing install.
reset_upgrade_mocks
package_status=7
if upgrade <<< $'y\n\n\n\n' >"$test_home/upgrade-output"; then fail_test 'reported a failed upgrade as success'; fi
assert_eq "$close_calls" 1
assert_eq "$start_calls" 1
assert_eq "$app_running" 1
assert_eq "$last_status_body" 'The package manager could not complete the update.'
grep -q 'upgrade failed after ChatGPT was closed' "$test_home/upgrade-output" || fail_test 'failed upgrade did not explain the reopen offer'

# Manual mode ignores stored force_kill=true and still asks before escalation.
reset_upgrade_mocks
configured_force_kill=true
close_fails=1
upgrade <<< $'y\n\nn\nn\n' >"$test_home/upgrade-output"
assert_eq "$force_calls" 0
assert_eq "$package_calls" 1
assert_eq "$app_running" 1
grep -q 'You will be asked to restart it after the package change.' "$test_home/upgrade-output" || fail_test 'force-close refusal omitted restart guidance'

# Declining force close can still be followed by a successful clean restart.
reset_upgrade_mocks
close_failures_remaining=1
upgrade <<< $'y\n\nn\n\n\n' >"$test_home/upgrade-output"
assert_eq "$close_calls" 2
assert_eq "$force_calls" 0
assert_eq "$package_calls" 1
assert_eq "$start_calls" 1

# Accepting force close sends the escalation, upgrades, then starts the new app.
reset_upgrade_mocks
close_fails=1
upgrade <<< $'y\n\ny\n\n\n' >"$test_home/upgrade-output"
assert_eq "$force_calls" 1
assert_eq "$package_calls" 1
assert_eq "$start_calls" 1

# The post-upgrade restart uses the same force-close question and shared policy.
reset_upgrade_mocks
close_fails=1
upgrade <<< $'y\nn\n\ny\n\n' >"$test_home/upgrade-output"
assert_eq "$close_calls" 1
assert_eq "$force_calls" 1
assert_eq "$start_calls" 1

# Launch failure is visible but does not rewrite a successful package-manager status.
reset_upgrade_mocks
start_fails=1
upgrade <<< $'y\n\n\n' >"$test_home/upgrade-output" 2>"$test_home/upgrade-error"
assert_eq "$start_calls" 1

# One-click mode authenticates before app control; failed authentication touches nothing.
reset_upgrade_mocks
configured_assume_yes=true
auth_status=1
if upgrade >"$test_home/upgrade-output" 2>"$test_home/upgrade-error"; then fail_test 'reported failed one-click authentication as success'; fi
assert_eq "$auth_calls" 1
assert_eq "$close_calls" 0
assert_eq "$package_calls" 0
assert_eq "$app_running" 1
assert_eq "$status_alerts" 1

# With force_kill disabled, a timeout leaves the app open and still performs the update.
reset_upgrade_mocks
configured_assume_yes=true
configured_force_kill=false
configured_restart_app=false
close_fails=1
upgrade >"$test_home/upgrade-output"
assert_eq "$close_calls" 1
assert_eq "$force_calls" 0
assert_eq "$package_calls" 1
assert_eq "$start_calls" 0
assert_eq "$status_alerts" 2
assert_eq "$last_status_body" 'Restart ChatGPT to use the updated version.'
grep -qx -- '-n dnf upgrade --refresh -y chatgpt' "$sudo_log" || fail_test 'one-click DNF command omitted noninteractive flags'

# restart_app=false keeps a successfully stopped app closed after the update.
reset_upgrade_mocks
configured_assume_yes=true
configured_restart_app=false
upgrade >"$test_home/upgrade-output"
assert_eq "$close_calls" 1
assert_eq "$start_calls" 0
assert_eq "$app_running" 0
assert_eq "$last_status_body" 'Start ChatGPT when you are ready to use the updated version.'

# With force_kill enabled, a timed-out clean stop escalates and restores the app.
reset_upgrade_mocks
configured_assume_yes=true
configured_force_kill=true
close_fails=1
upgrade >"$test_home/upgrade-output"
assert_eq "$force_calls" 1
assert_eq "$package_calls" 1
assert_eq "$start_calls" 1
assert_eq "$app_pid" 5252
[[ $status_bodies == *'ChatGPT did not close cleanly. Unsaved work may be lost.'* ]] || fail_test 'automatic force-close warning was not shown'

# Package failure after force-close restores the existing app and reports failure.
reset_upgrade_mocks
configured_assume_yes=true
configured_force_kill=true
close_fails=1
package_status=7
if upgrade >"$test_home/upgrade-output"; then fail_test 'reported failure after force-close as success'; fi
assert_eq "$force_calls" 1
assert_eq "$package_calls" 1
assert_eq "$start_calls" 1
assert_eq "$last_status_body" 'The package manager could not complete the update.'

# A failed force close never starts a duplicate; the update still runs as configured.
reset_upgrade_mocks
configured_assume_yes=true
configured_force_kill=true
close_fails=1
force_fails=1
upgrade >"$test_home/upgrade-output" 2>"$test_home/upgrade-error"
assert_eq "$force_calls" 2
assert_eq "$package_calls" 1
assert_eq "$start_calls" 0
assert_eq "$app_running" 1
assert_eq "$last_status_body" 'Restart ChatGPT to use the updated version.'

# A different PID appearing during the countdown is user intervention and is left alone.
reset_upgrade_mocks
configured_assume_yes=true
countdown_new_pid=1
upgrade >"$test_home/upgrade-output"
assert_eq "$close_calls" 0
assert_eq "$force_calls" 0
assert_eq "$start_calls" 0
assert_eq "$app_pid" 5252
grep -q 'already restarted' "$test_home/upgrade-output" || fail_test 'countdown restart was not treated as user intervention'

# A manual close during the countdown ends it early and the app is restored afterward.
reset_upgrade_mocks
configured_assume_yes=true
countdown_close_app=1
upgrade >"$test_home/upgrade-output"
assert_eq "$close_calls" 0
assert_eq "$force_calls" 0
assert_eq "$start_calls" 1

# Leaving the app open uses the restart path after the package operation.
reset_upgrade_mocks
configured_assume_yes=true
configured_stop_app=false
upgrade >"$test_home/upgrade-output"
assert_eq "$close_calls" 1
assert_eq "$force_calls" 0
assert_eq "$start_calls" 1

# force_kill is intentionally inactive when stop_app=false, even if manually set true.
reset_upgrade_mocks
configured_assume_yes=true
configured_stop_app=false
configured_force_kill=true
close_fails=1
upgrade >"$test_home/upgrade-output" 2>"$test_home/upgrade-error"
assert_eq "$close_calls" 1
assert_eq "$force_calls" 0
assert_eq "$start_calls" 0
assert_eq "$last_status_body" 'Restart ChatGPT to use the updated version.'

# A new PID created during the package run is treated as a user restart and left alone.
reset_upgrade_mocks
configured_assume_yes=true
configured_stop_app=false
package_new_pid=1
upgrade >"$test_home/upgrade-output"
assert_eq "$close_calls" 0
assert_eq "$start_calls" 0
assert_eq "$app_pid" 5252
grep -q 'already restarted' "$test_home/upgrade-output" || fail_test 'new ChatGPT PID was not recognized as a user restart'

# If the package operation fails after an automatic close, the configured
# restart policy reopens the existing installation and reports the failure.
reset_upgrade_mocks
configured_assume_yes=true
package_status=7
if upgrade >"$test_home/upgrade-output"; then fail_test 'reported a failed one-click package operation as success'; fi
assert_eq "$close_calls" 1
assert_eq "$start_calls" 1
assert_eq "$app_running" 1
assert_eq "$last_status_body" 'The package manager could not complete the update.'

# A failed upgrade leaves an app that was intentionally kept open untouched.
reset_upgrade_mocks
configured_assume_yes=true
configured_stop_app=false
package_status=7
if upgrade >"$test_home/upgrade-output"; then fail_test 'reported an open-app upgrade failure as success'; fi
assert_eq "$close_calls" 0
assert_eq "$force_calls" 0
assert_eq "$start_calls" 0
assert_eq "$app_running" 1
assert_eq "$last_status_body" 'The package manager could not complete the update.'

# An app that was initially closed is never launched as a side effect of one-click mode.
reset_upgrade_mocks
configured_assume_yes=true
app_running=0
upgrade >"$test_home/upgrade-output"
assert_eq "$close_calls" 0
assert_eq "$start_calls" 0

# Automatic package commands retain each distro's safe update semantics.
: >"$sudo_log"
distro=ubuntu
assert_eq "$(upgrade_command automatic)" 'sudo -n apt-get update && sudo -n apt-get install --only-upgrade -y chatgpt'
run_package_upgrade automatic
assert_eq "$(<"$sudo_log")" $'-n apt-get update\n-n apt-get install --only-upgrade -y chatgpt'
: >"$sudo_log"
distro=arch
assert_eq "$(upgrade_command automatic)" 'sudo -n pacman -Syu --noconfirm'
run_package_upgrade automatic
assert_eq "$(<"$sudo_log")" '-n pacman -Syu --noconfirm'
distro=fedora

# Rollback uses the same manual/one-click policy, silences only the broken version
# after success, and never writes that marker after a package-manager failure.
restore_dir="$test_home/restore-snapshot"
mkdir -p "$restore_dir"
: >"$restore_dir/old.rpm"
read_snapshot_manifest() {
  manifest_reads=$((manifest_reads + 1))
  manifest_distro=fedora
  manifest_arch=x86_64
  manifest_version='0:26.900.1-1'
  manifest_filename=old.rpm
  manifest_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  manifest_created_at=1790000000
  manifest_signature_filename=''
  manifest_signature_sha256=''
  if (( manifest_switch && manifest_reads > 1 )); then
    manifest_filename=other.rpm
    manifest_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  fi
}
reset_upgrade_mocks
app_running=0
restore_snapshot "$restore_dir" <<< $'y\n\n' >"$test_home/rollback-output"
assert_eq "$package_calls" 1
assert_eq "$(<"$state_dir/silenced-version")" '0:26.901.1-1.x86_64'
grep -qx -- 'dnf install .*/old.rpm' "$sudo_log" || fail_test 'manual rollback command was not run'
reset_upgrade_mocks
app_running=0
package_status=7
rm -f -- "$state_dir/silenced-version"
if restore_snapshot "$restore_dir" <<< $'y\n\n' >"$test_home/rollback-output"; then fail_test 'failed rollback reported success'; fi
[[ ! -e $state_dir/silenced-version ]] || fail_test 'failed rollback silenced the broken version'
reset_upgrade_mocks
app_running=0
restore_query_stuck=1
rm -f -- "$state_dir/silenced-version"
if restore_snapshot "$restore_dir" <<< $'y\n\n' >"$test_home/rollback-output" 2>"$test_home/rollback-error"; then
  fail_test 'rollback trusted exit zero without verifying the installed version'
fi
[[ ! -e $state_dir/silenced-version ]] || fail_test 'unverified rollback silenced the broken version'
reset_upgrade_mocks
app_running=0
manifest_switch=1
if restore_snapshot "$restore_dir" <<< $'y\n\n' >"$test_home/rollback-output" 2>"$test_home/rollback-error"; then
  fail_test 'rollback accepted a snapshot identity changed after confirmation'
fi
assert_eq "$package_calls" 0
reset_upgrade_mocks
configured_assume_yes=true
app_running=0
restore_snapshot "$restore_dir" >"$test_home/rollback-output"
assert_eq "$auth_calls" 1
grep -qx -- '-n dnf install -y .*/old.rpm' "$sudo_log" || fail_test 'one-click rollback flags were wrong'

# Restore the production functions before release and concurrency tests continue.
. "$root/chatgpt-update-notifier"

release_dir="$test_home/releases/chatgpt-update-notifier-v1.3.0"
mkdir -p "$release_dir/core" "$release_dir/assets"
printf '1.3.0\n' >"$release_dir/VERSION"
printf '#!/usr/bin/env bash\nnotifier_version=1.3.0\n' >"$release_dir/chatgpt-update-notifier"
printf '#!/usr/bin/env bash\n[[ -f ${BASH_SOURCE[0]%%/*}/core/future-core.sh ]] || exit 1\nprintf "%%s" "$*" > %q\n' \
  "$test_home/update-ran" >"$release_dir/install.sh"
printf 'releases:\n  - version: 1.3.0\n    changes:\n      - Test release\n' >"$release_dir/CHANGELOG.yaml"
printf '# future module layout\n' >"$release_dir/core/future-core.sh"
printf '<svg xmlns="http://www.w3.org/2000/svg"/>\n' >"$release_dir/assets/chatgpt-update-notifier.svg"
tar -czf "$test_home/release.tar.gz" -C "$test_home/releases" chatgpt-update-notifier-v1.3.0
mkdir -p "$test_home/repo/archive/refs/tags" "$test_home/repo/refs/heads/main"
cp -- "$test_home/release.tar.gz" "$test_home/repo/archive/refs/tags/v1.3.0.tar.gz"
printf '1.3.0\n' >"$test_home/repo/refs/heads/main/VERSION"
unset -f curl
project_url="file://$test_home/repo"
latest_version_url="$project_url/refs/heads/main/VERSION"
update_output=$(printf 'n\n' | update_notifier)
[[ $update_output == *'Test release'*'Command: bash'*'Cancelled.'* ]] || fail_test 'update did not show notes, command, and confirmation'
[[ ! -e $test_home/update-ran ]] || fail_test 'update ran after cancellation'
printf 'y\n' | update_notifier >/dev/null
assert_eq "$(<"$test_home/update-ran")" '--release 1.3.0'
rm -- "$test_home/update-ran"
rm -- "$release_dir/core/future-core.sh"
tar -czf "$test_home/repo/archive/refs/tags/v1.3.0.tar.gz" -C "$test_home/releases" chatgpt-update-notifier-v1.3.0
if printf 'y\n' | update_notifier 2>/dev/null; then fail_test 'release missing its own module reported success'; fi
[[ ! -e $test_home/update-ran ]] || fail_test 'incomplete release ran installer'
printf '# future module layout\n' >"$release_dir/core/future-core.sh"
printf '0.9.0\n' >"$release_dir/VERSION"
tar -czf "$test_home/repo/archive/refs/tags/v1.3.0.tar.gz" -C "$test_home/releases" chatgpt-update-notifier-v1.3.0
if update_notifier 2>/dev/null; then fail_test 'mismatched release reported success'; fi
[[ ! -e $test_home/update-ran ]] || fail_test 'mismatched release ran installer'
rm -- "$test_home/repo/archive/refs/tags/v1.3.0.tar.gz"
if update_notifier 2>/dev/null; then fail_test 'failed release download reported success'; fi
[[ ! -e $test_home/update-ran ]] || fail_test 'failed download ran installer'

run_check() { :; }
check_notifier_update() { printf '%s\n' "$notification_seconds" >>"$test_home/self-checks"; }
printf 'interval_minutes=60\nnotification_seconds=600\n' >"$config"
main run
printf 'interval_minutes=60\nnotification_seconds=30\n' >"$config"
main run
assert_eq "$(<"$test_home/self-checks")" $'600\n30'

wait_for() {
  local path=$1 attempt
  for ((attempt=0; attempt<100; attempt++)); do
    [[ -e $path ]] && return 0
    sleep 0.01
  done
  return 1
}
run_check() { : >"$test_home/app-started"; wait_for "$test_home/notifier-started"; }
check_notifier_update() { : >"$test_home/notifier-started"; wait_for "$test_home/app-started" || return 2; return 1; }
main run 2>/dev/null || fail_test 'notifier failure blocked a concurrent ChatGPT check'
run_check() { return 7; }
check_notifier_update() { : >"$test_home/notifier-after-app-failure"; }
if main run; then fail_test 'ChatGPT check failure was lost'; fi
[[ -e $test_home/notifier-after-app-failure ]] || fail_test 'ChatGPT check failure blocked the notifier check'

printf 'PASS: config, distro checks, cadence, silence, notifier releases, and failure retries\n'
