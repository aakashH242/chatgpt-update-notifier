#!/usr/bin/env bash
set -euo pipefail

# expected_distro is the Compose service's asserted /etc/os-release ID.
expected_distro=${1:?usage: test-container.sh DISTRO}
# root is the read-only project mount shared by every distro service.
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# test_root contains the disposable user home and command mocks for this container.
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

# Stop with one consistent message so Compose logs identify the failed assertion.
fail_test() { printf 'FAIL [%s]: %s\n' "$expected_distro" "$*" >&2; exit 1; }

# Verify that Compose did not accidentally run a service against the wrong image.
[[ -r /etc/os-release ]] || fail_test 'missing /etc/os-release'
. /etc/os-release
[[ $ID == "$expected_distro" ]] || fail_test "expected $expected_distro, found $ID"

# Run the portable behavior suite and static checks in this distro's own Bash and tools.
bash -n "$root/chatgpt-update-notifier" "$root/install.sh" "$root/tests/test.sh" "$root/tests/test-container.sh"
shellcheck -S warning "$root/chatgpt-update-notifier" "$root/install.sh" "$root/tests/test.sh" "$root/tests/test-container.sh"
bash "$root/tests/test.sh"
bash -c '. "$1"; detect_distro; [[ $distro == "$2" ]]' _ "$root/chatgpt-update-notifier" "$expected_distro" ||
  fail_test 'runtime distro detection returned the wrong ID'

# Debian-family installer checks require a source entry; package-manager commands
# below remain mocked so containers never install or upgrade ChatGPT itself.
if [[ $expected_distro == ubuntu || $expected_distro == debian ]]; then
  mkdir -p /etc/apt/sources.list.d
  printf 'Types: deb\nURIs: https://persistent.oaistatic.com/codex-app-prod/linux/deb\nSuites: stable\nComponents: main\n' \
    >/etc/apt/sources.list.d/chatgpt-container-test.sources
fi

# user_home is owned by an unprivileged numeric user, matching the installer's
# normal-user requirement without adding an account to each base image.
user_home="$test_root/home"
mock_bin="$test_root/mock-bin"
mock_log="$test_root/mock.log"
mkdir -p "$user_home" "$mock_bin"
: >"$mock_log"
chmod 755 "$test_root" "$mock_bin"
chown -R 65534:65534 "$user_home" "$mock_log"

# One basename-dispatched executable keeps all external side effects mocked while
# preserving the exact distro branches and command arguments in mock_log.
mock_command="$mock_bin/mock-command"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "%s %s\n" "${0##*/}" "$*" >>"$MOCK_LOG"' \
  'case ${0##*/} in' \
  '  dpkg-query) printf "install ok installed" ;;' \
  '  dnf) [[ ${1:-} == repolist ]] && printf "openai-chatgpt OpenAI ChatGPT\n" ;;' \
  '  pacman-conf) printf "openai-chatgpt\n" ;;' \
  '  rpm|pacman|systemctl|notify-send|xterm|curl|tar|checkupdates|fakeroot|sudo) ;;' \
  'esac' >"$mock_command"
chmod 755 "$mock_command"
for executable in dpkg-query dnf pacman-conf rpm pacman systemctl notify-send xterm curl tar checkupdates fakeroot sudo; do
  ln -s mock-command "$mock_bin/$executable"
done

# Run one command through a real pseudo-terminal as the unprivileged test user.
# input supplies wizard answers; command is fixed by this test file, never user data.
run_as_user() {
  local input=$1 command=$2
  printf '%s' "$input" | setpriv --reuid=65534 --regid=65534 --clear-groups \
    env HOME="$user_home" SHELL=/bin/bash XDG_CONFIG_HOME="$user_home/.config" \
      XDG_STATE_HOME="$user_home/.local/state" XDG_CACHE_HOME="$user_home/.cache" \
      PATH="$mock_bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
      MOCK_LOG="$mock_log" script -q -e -c "$command" /dev/null
}

# Keep successful wizard output quiet, but print the captured transcript before
# failing so a distro-specific pseudo-terminal or installer error is actionable.
run_checked_as_user() {
  local transcript="$test_root/user-command.log"
  if ! run_as_user "$1" "$2" >"$transcript" 2>&1; then
    sed -n '1,240p' "$transcript" >&2
    fail_test "$3"
  fi
}

# A fresh install accepts default scan/alert values, a custom 12-second app wait,
# and the default manual-confirmation mode before approving installation.
run_checked_as_user $'\n\n12\n\ny\n' "bash $root/install.sh" 'fresh installer run failed'
config="$user_home/.config/chatgpt-update-notifier/config"
binary="$user_home/.local/bin/chatgpt-update-notifier"
units="$user_home/.config/systemd/user"
[[ -x $binary && -f $units/chatgpt-update-notifier.service && -f $units/chatgpt-update-notifier.timer ]] ||
  fail_test 'installer did not create the executable and user units'
grep -qx 'interval_minutes=60' "$config" || fail_test 'installer omitted the default interval'
grep -qx 'notification_seconds=15' "$config" || fail_test 'installer omitted the default alert duration'
grep -qx 'shutdown_timeout_seconds=12' "$config" || fail_test 'installer omitted the chosen shutdown timeout'
grep -qx 'assume_yes=false' "$config" || fail_test 'installer did not default to manual confirmation'
grep -qx 'stop_app=true' "$config" || fail_test 'installer omitted the safe stop-app default'
grep -qx 'stop_delay_seconds=30' "$config" || fail_test 'installer omitted the stop delay default'
grep -qx 'force_kill=false' "$config" || fail_test 'installer did not default force kill to disabled'
grep -qx 'restart_app=true' "$config" || fail_test 'installer omitted the restart default'
grep -qx 'restart_delay_seconds=30' "$config" || fail_test 'installer omitted the restart delay default'
grep -q '^systemctl --user enable --now chatgpt-update-notifier.timer$' "$mock_log" || fail_test 'installer did not enable the user timer'

# Reinstall must keep the user's config rather than asking for or replacing values.
config_before=$(sha256sum "$config")
run_checked_as_user $'y\n' "bash $root/install.sh" 'reinstall failed'
[[ $(sha256sum "$config") == "$config_before" ]] || fail_test 'reinstall changed the existing config'

# Exercise the real distro dispatch while sudo is mocked, then assert the exact
# command selected for this image. No ChatGPT GUI process exists in the container.
: >"$mock_log"
run_checked_as_user $'y\n\n' "$binary upgrade" 'interactive upgrade flow failed'
case $expected_distro in
  ubuntu|debian)
    grep -q '^sudo apt update$' "$mock_log" || fail_test 'APT refresh command was not selected'
    grep -q '^sudo apt install --only-upgrade chatgpt$' "$mock_log" || fail_test 'APT upgrade command was not selected'
    ;;
  fedora) grep -q '^sudo dnf upgrade --refresh chatgpt$' "$mock_log" || fail_test 'DNF upgrade command was not selected' ;;
  arch) grep -q '^sudo pacman -Syu$' "$mock_log" || fail_test 'full pacman upgrade command was not selected' ;;
esac

# Switch the preserved config to one-click mode and verify its normal sudo
# authentication is followed by each distro's noninteractive package flags.
printf 'interval_minutes=60\nnotification_seconds=15\nshutdown_timeout_seconds=12\nassume_yes=true\nstop_app=true\nstop_delay_seconds=0\nforce_kill=false\nrestart_app=true\nrestart_delay_seconds=0\n' >"$config"
chown 65534:65534 "$config"
: >"$mock_log"
run_checked_as_user '' "$binary upgrade" 'one-click upgrade flow failed'
grep -q '^sudo -v -p ChatGPT Update Notifier' "$mock_log" || fail_test 'one-click mode did not authenticate before upgrading'
case $expected_distro in
  ubuntu|debian)
    grep -q '^sudo -n apt-get update$' "$mock_log" || fail_test 'one-click APT refresh was not noninteractive'
    grep -q '^sudo -n apt-get install --only-upgrade -y chatgpt$' "$mock_log" || fail_test 'one-click APT upgrade flags were wrong'
    ;;
  fedora) grep -q '^sudo -n dnf upgrade --refresh -y chatgpt$' "$mock_log" || fail_test 'one-click DNF flags were wrong' ;;
  arch) grep -q '^sudo -n pacman -Syu --noconfirm$' "$mock_log" || fail_test 'one-click pacman flags were wrong' ;;
esac

# Uninstall removes only program files and keeps both configuration and state.
state_dir="$user_home/.local/state/chatgpt-update-notifier"
mkdir -p "$state_dir"
printf 'keep\n' >"$state_dir/test-marker"
chown -R 65534:65534 "$state_dir"
run_checked_as_user $'y\n' "bash $root/install.sh --uninstall" 'uninstall failed'
[[ ! -e $binary && ! -e $units/chatgpt-update-notifier.service && ! -e $units/chatgpt-update-notifier.timer ]] ||
  fail_test 'uninstall left installed notifier files behind'
[[ -f $config && -f $state_dir/test-marker ]] || fail_test 'uninstall removed config or state'

# A second fresh setup covers the conditional one-click onboarding questions.
# Blank answers keep the default stop/restart choices; explicit answers choose
# a seven-second warning and permit force close after a clean-shutdown timeout.
rm -- "$config"
run_checked_as_user $'\n\n\ny\n\n7\ny\n\ny\n' "bash $root/install.sh" 'one-click onboarding failed'
grep -qx 'assume_yes=true' "$config" || fail_test 'one-click onboarding was not saved'
grep -qx 'stop_app=true' "$config" || fail_test 'one-click onboarding lost stop_app'
grep -qx 'stop_delay_seconds=7' "$config" || fail_test 'one-click onboarding lost the chosen stop delay'
grep -qx 'force_kill=true' "$config" || fail_test 'one-click onboarding lost force_kill consent'
grep -qx 'restart_app=true' "$config" || fail_test 'one-click onboarding lost restart_app'
run_checked_as_user $'y\n' "bash $root/install.sh --uninstall" 'second uninstall failed'

# Choosing not to stop ChatGPT skips the force-kill question and collects only
# the restart countdown that can apply while the app remains open.
rm -- "$config"
run_checked_as_user $'\n\n\ny\nn\n\n9\ny\n' "bash $root/install.sh" 'non-stopping one-click onboarding failed'
grep -qx 'assume_yes=true' "$config" || fail_test 'non-stopping onboarding lost one-click mode'
grep -qx 'stop_app=false' "$config" || fail_test 'non-stopping onboarding changed stop_app'
grep -qx 'force_kill=false' "$config" || fail_test 'force_kill was enabled without its onboarding question'
grep -qx 'restart_app=true' "$config" || fail_test 'non-stopping onboarding lost restart_app'
grep -qx 'restart_delay_seconds=9' "$config" || fail_test 'non-stopping onboarding lost the restart delay'
run_checked_as_user $'y\n' "bash $root/install.sh --uninstall" 'third uninstall failed'

printf 'PASS: %s syntax, shellcheck, behavior, install, upgrade dispatch, reinstall, and uninstall\n' "$expected_distro"
