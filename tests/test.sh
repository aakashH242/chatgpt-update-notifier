#!/usr/bin/env bash
# The production functions are sourced through a runtime-computed path below;
# older ShellCheck releases cannot follow that source and misreport their calls.
# shellcheck disable=SC2218
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
assert_eq "${#missing_config_defaults[@]}" 9

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
for expected_default in notification_seconds=15 shutdown_timeout_seconds=10 assume_yes=false stop_app=true stop_delay_seconds=30 force_kill=false restart_app=true restart_delay_seconds=30; do
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
printf 'interval_minutes=60\nplay_sound=false\nassume_yes=true\nstop_app=false\nstop_delay_seconds=0\nforce_kill=true\nrestart_app=false\nrestart_delay_seconds=180\n' >"$config"
read_config
assert_eq "$play_sound" false
assert_eq "$assume_yes" true
assert_eq "$stop_app" false
assert_eq "$stop_delay_seconds" 0
assert_eq "$force_kill" true
assert_eq "$restart_app" false
assert_eq "$restart_delay_seconds" 180
for boolean_key in play_sound assume_yes stop_app force_kill restart_app; do
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

curl() { [[ ${CURL_FAIL:-0} == 0 ]] || return 1; printf '%s' "${REMOTE_VERSION:-1.1.0}"; }
notifier_alerts=0
notify_notifier_update() { notifier_alerts=$((notifier_alerts + 1)); }
REMOTE_VERSION=1.1.1 check_notifier_update
REMOTE_VERSION=1.1.1 check_notifier_update
assert_eq "$notifier_alerts" 2
printf '1.1.1\n' >"$state_dir/silenced-notifier-version"
REMOTE_VERSION=1.1.1 check_notifier_update
assert_eq "$notifier_alerts" 2
REMOTE_VERSION=1.2.0 check_notifier_update
assert_eq "$notifier_alerts" 3
REMOTE_VERSION=1.0.0 check_notifier_update
assert_eq "$notifier_alerts" 3
REMOTE_VERSION="\$(touch $test_home/never-run-version)" check_notifier_update 2>/dev/null
assert_eq "$notifier_alerts" 3
[[ ! -e $test_home/never-run-version ]] || fail_test 'executed a remote VERSION as shell'
CURL_FAIL=1 check_notifier_update 2>/dev/null
assert_eq "$notifier_alerts" 3
assert_eq "$(<"$state_dir/last-available-notifier-version")" 1.2.0
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
timeout() { printf '%s\n' "$@" >"$test_home/notify-args"; printf 'install'; }
notify_update
assert_eq "$opened" 1
assert_eq "$(tail -n 1 "$test_home/notify-args")" "$installed → $candidate"
grep -qx -- '--expire-time=600000' "$test_home/notify-args" || fail_test 'app alert ignored configured display time'
grep -qx -- '600s' "$test_home/notify-args" || fail_test 'action listener timeout differs from alert duration'
if grep -q -- 'sound-name' "$test_home/notify-args"; then fail_test 'app alert played sound when play_sound=false'; fi
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
detect_distro() { distro=fedora; }
rpm() { [[ $1 == -q ]]; }
configured_assume_yes=false
configured_stop_app=true
configured_force_kill=false
configured_restart_app=true
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
countdown_new_pid=0
countdown_close_app=0
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
  app_running=1 app_pid=4242 pid_checks=0 close_calls=0 force_calls=0 start_calls=0
  auth_calls=0 package_calls=0 status_alerts=0 close_fails=0 close_failures_remaining=0 force_fails=0 start_fails=0
  auth_status=0 package_status=0 package_new_pid=0 countdown_new_pid=0 countdown_close_app=0
  last_status_body='' status_bodies=''
  : >"$sudo_log"
}

# Cancelling the displayed command must happen before app detection or shutdown.
reset_upgrade_mocks
upgrade <<<"n" >"$test_home/upgrade-output"
assert_eq "$pid_checks" 0
assert_eq "$close_calls" 0
assert_eq "$package_calls" 0

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
grep -q 'You will be asked to restart it after the upgrade.' "$test_home/upgrade-output" || fail_test 'force-close refusal omitted restart guidance'

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

# Restore the production functions before release and concurrency tests continue.
. "$root/chatgpt-update-notifier"

release_dir="$test_home/releases/chatgpt-update-notifier-v1.2.0"
mkdir -p "$release_dir"
printf '1.2.0\n' >"$release_dir/VERSION"
printf '#!/usr/bin/env bash\nnotifier_version=1.2.0\n' >"$release_dir/chatgpt-update-notifier"
printf '#!/usr/bin/env bash\nprintf installed > %q\n' "$test_home/update-ran" >"$release_dir/install.sh"
printf 'releases:\n  - version: 1.2.0\n    changes:\n      - Test release\n' >"$release_dir/CHANGELOG.yaml"
tar -czf "$test_home/release.tar.gz" -C "$test_home/releases" chatgpt-update-notifier-v1.2.0
mkdir -p "$test_home/repo/archive/refs/tags" "$test_home/repo/refs/heads/main"
cp -- "$test_home/release.tar.gz" "$test_home/repo/archive/refs/tags/v1.2.0.tar.gz"
printf '1.2.0\n' >"$test_home/repo/refs/heads/main/VERSION"
unset -f curl
project_url="file://$test_home/repo"
latest_version_url="$project_url/refs/heads/main/VERSION"
update_output=$(printf 'n\n' | update_notifier)
[[ $update_output == *'Test release'*'Command: bash'*'Cancelled.'* ]] || fail_test 'update did not show notes, command, and confirmation'
[[ ! -e $test_home/update-ran ]] || fail_test 'update ran after cancellation'
printf 'y\n' | update_notifier >/dev/null
assert_eq "$(<"$test_home/update-ran")" installed
rm -- "$test_home/update-ran"
printf '0.9.0\n' >"$release_dir/VERSION"
tar -czf "$test_home/repo/archive/refs/tags/v1.2.0.tar.gz" -C "$test_home/releases" chatgpt-update-notifier-v1.2.0
if update_notifier 2>/dev/null; then fail_test 'mismatched release reported success'; fi
[[ ! -e $test_home/update-ran ]] || fail_test 'mismatched release ran installer'
rm -- "$test_home/repo/archive/refs/tags/v1.2.0.tar.gz"
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
