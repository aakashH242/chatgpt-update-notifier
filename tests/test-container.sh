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
core_scripts=("$root/core/package-operation.sh" "$root/core/rollback.sh" "$root/core/manager.sh")
bash -n "$root/chatgpt-update-notifier" "$root/install.sh" "${core_scripts[@]}" "$root/tests/test.sh" "$root/tests/test-container.sh"
shellcheck -S warning "$root/chatgpt-update-notifier" "$root/install.sh" "${core_scripts[@]}" "$root/tests/test.sh" "$root/tests/test-container.sh"
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
# Deliberately avoid ~/.config so install and uninstall exercise XDG_CONFIG_HOME.
user_config_home="$user_home/xdg-config"
# The launcher, icon, modules, and matching uninstaller must follow XDG_DATA_HOME too.
user_data_home="$user_home/xdg-data"
mock_bin="$test_root/mock-bin"
mock_log="$test_root/mock.log"
package_version_file="$test_root/package-version"
custom_pacman_cache="$test_root/custom-pacman-cache"
real_pacman_cache="$test_root/real-pacman-cache"
mkdir -p "$user_home" "$mock_bin"
: >"$mock_log"
printf '26.900.1-1\n' >"$package_version_file"
chmod 755 "$test_root" "$mock_bin"
chown -R 65534:65534 "$user_home" "$mock_log" "$package_version_file"

# One basename-dispatched executable keeps all external side effects mocked while
# preserving the exact distro branches and command arguments in mock_log.
mock_command="$mock_bin/mock-command"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "%s %s\n" "${0##*/}" "$*" >>"$MOCK_LOG"' \
  'case ${0##*/} in' \
  '  dpkg-query) if [[ $* == *Status* ]]; then printf "install ok installed"; else printf "%s\tamd64\n" "$(<"$PACKAGE_VERSION_FILE")"; fi ;;' \
  '  dpkg-deb) case ${*: -1} in Package) printf chatgpt ;; Version) printf 26.900.1-1 ;; Architecture) printf amd64 ;; esac ;;' \
  '  dnf) [[ ${1:-} == repolist ]] && printf "openai-chatgpt OpenAI ChatGPT\n" ;;' \
  '  rpm) if [[ ${1:-} == -qp ]]; then printf "chatgpt\t0:26.900.1-1\tx86_64\n"; elif [[ $* == *--qf* ]]; then printf "0:%s\tx86_64\n" "$(<"$PACKAGE_VERSION_FILE")"; fi ;;' \
  '  pacman) case ${1:-} in -Q) printf "chatgpt-bin %s\n" "$(<"$PACKAGE_VERSION_FILE")" ;; -Qp) printf "chatgpt-bin 26.900.1-1\n" ;; -Qi|-Qip) printf "Architecture : x86_64\n" ;; esac ;;' \
  '  pacman-conf) if [[ ${1:-} == CacheDir ]]; then printf "%s\n" "$CUSTOM_PACMAN_CACHE"; else printf "openai-chatgpt\n"; fi ;;' \
  '  curl) if [[ -n ${BOOTSTRAP_ARCHIVE:-} ]]; then output=; while (($#)); do if [[ $1 == -o ]]; then output=$2; shift 2; else shift; fi; done; cp -- "$BOOTSTRAP_ARCHIVE" "$output"; fi ;;' \
  '  install) for argument in "$@"; do [[ -z ${FAIL_INSTALL_SOURCE:-} || $argument != "$FAIL_INSTALL_SOURCE" ]] || exit 70; done; exec /usr/bin/install "$@" ;;' \
  '  sudo) case "$*" in *"dnf install"*".rpm"|*"apt-get install"*".deb"|*"pacman -U"*".pkg.tar.zst") printf "26.900.1-1\n" >"$PACKAGE_VERSION_FILE" ;; esac ;;' \
  '  tar) if [[ -n ${BOOTSTRAP_ARCHIVE:-} ]]; then exec /usr/bin/tar "$@"; fi ;;' \
  '  systemctl|notify-send|xterm|checkupdates|fakeroot|pacman-key) ;;' \
  'esac' >"$mock_command"
chmod 755 "$mock_command"
for executable in dpkg-query dpkg-deb dnf install pacman-conf rpm pacman systemctl notify-send xterm curl tar checkupdates fakeroot pacman-key sudo; do
  ln -s mock-command "$mock_bin/$executable"
done

# Supply one readable exact package in each distro's native cache. Package metadata
# validation remains active through the command mocks above; no package is installed.
case $expected_distro in
  fedora) mkdir -p /var/cache/libdnf5; printf 'test rpm\n' >/var/cache/libdnf5/chatgpt-26.900.1-1.x86_64.rpm ;;
  ubuntu|debian) mkdir -p /var/cache/apt/archives; printf 'test deb\n' >/var/cache/apt/archives/chatgpt_26.900.1-1_amd64.deb ;;
  arch)
    # A configured CacheDir may be a symlink when users move package storage to
    # another filesystem. The production search must follow this root only.
    mkdir -p "$real_pacman_cache"
    ln -s "$real_pacman_cache" "$custom_pacman_cache"
    printf 'test package\n' >"$real_pacman_cache/chatgpt-bin-26.900.1-1-x86_64.pkg.tar.zst"
    printf 'test signature\n' >"$real_pacman_cache/chatgpt-bin-26.900.1-1-x86_64.pkg.tar.zst.sig"
    ;;
esac

# Run one command through a real pseudo-terminal as the unprivileged test user.
# input supplies wizard answers; command is fixed by this test file, never user data.
run_as_user() {
  local input=$1 command=$2
  printf '%s' "$input" | setpriv --reuid=65534 --regid=65534 --clear-groups \
    env HOME="$user_home" SHELL=/bin/bash XDG_CONFIG_HOME="$user_config_home" \
      XDG_DATA_HOME="$user_data_home" \
      XDG_STATE_HOME="$user_home/.local/state" XDG_CACHE_HOME="$user_home/.cache" \
      PATH="$mock_bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
      MOCK_LOG="$mock_log" PACKAGE_VERSION_FILE="$package_version_file" \
      CUSTOM_PACMAN_CACHE="$custom_pacman_cache" script -q -e -c "$command" /dev/null
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

# A lone raw installer may fetch the complete main archive. The same incomplete
# file in versioned-release mode must fail without escaping to mutable main.
bootstrap_root="$test_root/bootstrap"
bootstrap_source="$bootstrap_root/source/chatgpt-update-notifier-main"
raw_installer="$user_home/raw-install.sh"
mkdir -p "$bootstrap_source/core" "$bootstrap_source/assets"
printf '#!/usr/bin/env bash\nprintf bootstrapped >"$BOOTSTRAP_MARKER"\n' >"$bootstrap_source/install.sh"
printf '#!/usr/bin/env bash\nnotifier_version=1.2.0\n' >"$bootstrap_source/chatgpt-update-notifier"
printf '1.2.0\n' >"$bootstrap_source/VERSION"
printf 'releases: []\n' >"$bootstrap_source/CHANGELOG.yaml"
printf '# module\n' >"$bootstrap_source/core/package-operation.sh"
printf '# module\n' >"$bootstrap_source/core/rollback.sh"
printf '# module\n' >"$bootstrap_source/core/manager.sh"
printf '<svg xmlns="http://www.w3.org/2000/svg"/>\n' >"$bootstrap_source/assets/chatgpt-update-notifier.svg"
/usr/bin/tar -czf "$bootstrap_root/main.tar.gz" -C "$bootstrap_root/source" chatgpt-update-notifier-main
cp "$root/install.sh" "$raw_installer"
chown 65534:65534 "$raw_installer"
BOOTSTRAP_ARCHIVE="$bootstrap_root/main.tar.gz" BOOTSTRAP_MARKER="$user_home/bootstrap-ran" \
  run_checked_as_user '' "bash $raw_installer" 'raw standalone installer did not bootstrap'
[[ $(<"$user_home/bootstrap-ran") == bootstrapped ]] || fail_test 'downloaded bootstrap installer did not run'
: >"$mock_log"
if BOOTSTRAP_ARCHIVE="$bootstrap_root/main.tar.gz" BOOTSTRAP_MARKER="$user_home/release-should-not-run" \
    run_as_user '' "bash $raw_installer --release 1.2.0" >"$test_root/release-mode.log" 2>&1; then
  fail_test 'incomplete versioned release reported success'
fi
grep -q '^curl ' "$mock_log" && fail_test 'incomplete versioned release fetched mutable main'
[[ ! -e $user_home/release-should-not-run ]] || fail_test 'incomplete versioned release ran downloaded main'

# Published v1.1 invokes a tagged installer without --release. A partial extracted
# archive must still fail instead of silently replacing itself from mutable main.
partial_release="$user_home/partial-release"
mkdir "$partial_release"
cp "$root/install.sh" "$root/VERSION" "$partial_release/"
: >"$mock_log"
if BOOTSTRAP_ARCHIVE="$bootstrap_root/main.tar.gz" BOOTSTRAP_MARKER="$user_home/partial-should-not-run" \
    run_as_user '' "bash $partial_release/install.sh" >"$test_root/partial-release.log" 2>&1; then
  fail_test 'partial unflagged release reported success'
fi
grep -q '^curl ' "$mock_log" && fail_test 'partial unflagged release fetched mutable main'
[[ ! -e $user_home/partial-should-not-run ]] || fail_test 'partial unflagged release ran downloaded main'

# A fresh install accepts default scan/alert values, a custom 12-second app wait,
# and the default manual-confirmation mode before approving installation.
run_checked_as_user $'\n\n\n\n12\n\ny\n' "bash $root/install.sh" 'fresh installer run failed'
config="$user_config_home/chatgpt-update-notifier/config"
binary="$user_home/.local/bin/chatgpt-update-notifier"
units="$user_config_home/systemd/user"
program_data="$user_data_home/chatgpt-update-notifier/1.2.4"
desktop_file="$user_data_home/applications/chatgpt-update-notifier.desktop"
icon_file="$user_data_home/icons/hicolor/scalable/apps/chatgpt-update-notifier.svg"
[[ -x $binary && -f $units/chatgpt-update-notifier.service && -f $units/chatgpt-update-notifier.timer &&
   -f $program_data/core/package-operation.sh && -f $program_data/core/rollback.sh &&
   -f $program_data/core/manager.sh && -x $program_data/install.sh &&
   -f $desktop_file && -f $icon_file ]] ||
  fail_test 'installer did not create the executable and user units'
grep -qx 'interval_minutes=60' "$config" || fail_test 'installer omitted the default interval'
grep -qx 'notification_seconds=15' "$config" || fail_test 'installer omitted the default alert duration'
grep -qx 'play_sound=true' "$config" || fail_test 'installer omitted the default notification sound'
grep -qx 'shutdown_timeout_seconds=12' "$config" || fail_test 'installer omitted the chosen shutdown timeout'
grep -qx 'assume_yes=false' "$config" || fail_test 'installer did not default to manual confirmation'
grep -qx 'stop_app=true' "$config" || fail_test 'installer omitted the safe stop-app default'
grep -qx 'stop_delay_seconds=30' "$config" || fail_test 'installer omitted the stop delay default'
grep -qx 'force_kill=false' "$config" || fail_test 'installer did not default force kill to disabled'
grep -qx 'restart_app=true' "$config" || fail_test 'installer omitted the restart default'
grep -qx 'restart_delay_seconds=30' "$config" || fail_test 'installer omitted the restart delay default'
grep -qx 'rollback_versions=3' "$config" || fail_test 'installer omitted the rollback retention default'
grep -qx 'enable_gui=false' "$config" || fail_test 'installer enabled unavailable native dialogs'
grep -q '^systemctl --user enable --now chatgpt-update-notifier.timer$' "$mock_log" || fail_test 'installer did not enable the user timer'
grep -q '^notify-send .*--hint=string:sound-name:message-new-instant' "$mock_log" ||
  fail_test 'installer readiness alert omitted the default sound hint'
grep -q '^Categories=Utility;$' "$desktop_file" || fail_test 'desktop launcher used duplicate main categories'

# Failed staging copies must leave both the active same-version modules and fixed
# executable byte-for-byte intact; neither source is written directly to its live path.
module_before=$(sha256sum "$program_data/core/package-operation.sh")
binary_before=$(sha256sum "$binary")
for failing_source in "$root/core/package-operation.sh" "$root/chatgpt-update-notifier"; do
  if run_as_user $'y\n' "FAIL_INSTALL_SOURCE=$failing_source bash $root/install.sh" \
      >"$test_root/staged-install-failure.log" 2>&1; then
    fail_test "installer succeeded after staged copy failure: $failing_source"
  fi
  [[ $(sha256sum "$program_data/core/package-operation.sh") == "$module_before" ]] ||
    fail_test 'failed staged copy changed the active package-operation module'
  [[ $(sha256sum "$binary") == "$binary_before" ]] ||
    fail_test 'failed staged copy changed the active executable'
done
if find "$user_data_home/chatgpt-update-notifier" -maxdepth 1 -name '.pending.*' -print -quit | grep -q .; then
  fail_test 'failed staged copy left a pending release directory'
fi

# File publication must reject corrupted live paths that are directories; plain
# mv would otherwise nest the staged file there and falsely report success.
module_path="$program_data/core/package-operation.sh"
mv -- "$module_path" "$test_root/package-operation.backup"
mkdir "$module_path"
chown 65534:65534 "$module_path"
if run_as_user $'y\n' "bash $root/install.sh" >"$test_root/module-target-directory.log" 2>&1; then
  fail_test 'installer accepted a directory at a live module path'
fi
[[ -d $module_path && ! -e $module_path/package-operation.sh ]] ||
  fail_test 'module publication nested a staged file inside a directory target'
rm -r -- "$module_path"
mv -- "$test_root/package-operation.backup" "$module_path"

module_link_target="$test_root/module-link-target"
mkdir "$module_link_target"
mv -- "$module_path" "$test_root/package-operation.backup"
ln -s "$module_link_target" "$module_path"
run_checked_as_user $'y\n' "bash $root/install.sh" 'installer did not repair a directory-symlink module path'
[[ -f $module_path && ! -L $module_path && ! -e $module_link_target/package-operation.sh ]] ||
  fail_test 'module publication followed a directory symlink instead of replacing it'
rm -- "$test_root/package-operation.backup"

mv -- "$binary" "$test_root/notifier-binary.backup"
mkdir "$binary"
chown 65534:65534 "$binary"
if run_as_user $'y\n' "bash $root/install.sh" >"$test_root/binary-target-directory.log" 2>&1; then
  fail_test 'installer accepted a directory at the executable path'
fi
[[ -d $binary && ! -e $binary/chatgpt-update-notifier ]] ||
  fail_test 'executable publication nested a staged file inside a directory target'
rm -r -- "$binary"
mv -- "$test_root/notifier-binary.backup" "$binary"

# Reinstall must keep the user's config rather than asking for or replacing values.
config_before=$(sha256sum "$config")
run_checked_as_user $'y\n' "bash $root/install.sh" 'reinstall failed'
[[ $(sha256sum "$config") == "$config_before" ]] || fail_test 'reinstall changed the existing config'

# Declining a missing dependency must leave an older executable and config paired.
printf '#!/usr/bin/env bash\nexit 0\n' >"$binary"
printf '# Simulated old config.\ninterval_minutes=120\n' >"$config"
chmod 755 "$binary"
chown 65534:65534 "$binary" "$config"
old_binary_checksum=$(sha256sum "$binary")
declined_config_checksum=$(sha256sum "$config")
rm -- "$mock_bin/notify-send"
dependency_decline_log="$test_root/dependency-decline.log"
if run_as_user $'y\nn\n' "bash $root/install.sh" >"$dependency_decline_log" 2>&1; then
  fail_test 'installer succeeded after a missing dependency was declined'
fi
grep -q 'Missing packages were not installed; setup stopped.' "$dependency_decline_log" ||
  fail_test 'installer did not reach the missing-dependency refusal'
[[ $(sha256sum "$binary") == "$old_binary_checksum" ]] || fail_test 'declined dependency replaced the installed executable'
[[ $(sha256sum "$config") == "$declined_config_checksum" ]] || fail_test 'declined dependency changed the old config'
ln -s mock-command "$mock_bin/notify-send"

# An older valid config is extended in place: existing bytes and choices stay,
# every absent key receives its current default, and a second run is a no-op.
printf '# Keep this old config prefix.\ninterval_minutes=120\nplay_sound=false\n' >"$config"
chown 65534:65534 "$config"
old_config_size=$(wc -c <"$config")
old_config_prefix=$(head -c "$old_config_size" "$config" | sha256sum)
old_config_checksum=$(sha256sum "$config")
run_checked_as_user $'n\n' "bash $root/install.sh" 'old-config cancellation failed'
[[ $(sha256sum "$config") == "$old_config_checksum" ]] || fail_test 'cancelled migration changed the config'
run_checked_as_user $'y\n' "bash $root/install.sh" 'old-config migration failed'
[[ $(head -c "$old_config_size" "$config" | sha256sum) == "$old_config_prefix" ]] ||
  fail_test 'migration rewrote the existing config prefix'
grep -qx 'interval_minutes=120' "$config" || fail_test 'migration replaced the existing interval'
grep -qx 'play_sound=false' "$config" || fail_test 'migration replaced the existing sound preference'
for expected_default in notification_seconds=15 shutdown_timeout_seconds=10 assume_yes=false stop_app=true stop_delay_seconds=30 force_kill=false restart_app=true restart_delay_seconds=30 rollback_versions=3 enable_gui=false; do
  [[ $(grep -cx "$expected_default" "$config") == 1 ]] || fail_test "migration did not append exactly one $expected_default"
done
migrated_config=$(sha256sum "$config")
run_checked_as_user $'y\n' "bash $root/install.sh" 'post-migration reinstall failed'
[[ $(sha256sum "$config") == "$migrated_config" ]] || fail_test 'post-migration reinstall changed a complete config'

# Exercise the real distro dispatch while sudo is mocked, then assert the exact
# command selected for this image. No ChatGPT GUI process exists in the container.
: >"$mock_log"
run_checked_as_user $'y\n\n' "$binary upgrade" 'interactive upgrade flow failed'
case $expected_distro in
  ubuntu|debian)
    grep -q '^sudo apt update$' "$mock_log" || fail_test 'APT refresh command was not selected'
    grep -q '^sudo apt install --only-upgrade chatgpt$' "$mock_log" || fail_test 'APT upgrade command was not selected'
    ;;
  fedora) grep -q '^sudo dnf --setopt=keepcache=True upgrade --refresh chatgpt$' "$mock_log" || fail_test 'DNF upgrade command was not selected' ;;
  arch) grep -q '^sudo pacman -Syu$' "$mock_log" || fail_test 'full pacman upgrade command was not selected' ;;
esac

# Switch the preserved config to one-click mode and verify its normal sudo
# authentication is followed by each distro's noninteractive package flags.
printf 'interval_minutes=60\nnotification_seconds=15\nplay_sound=true\nshutdown_timeout_seconds=12\nassume_yes=true\nstop_app=true\nstop_delay_seconds=0\nforce_kill=false\nrestart_app=true\nrestart_delay_seconds=0\nrollback_versions=3\n' >"$config"
chown 65534:65534 "$config"
: >"$mock_log"
run_checked_as_user '' "$binary upgrade" 'one-click upgrade flow failed'
grep -q '^sudo -v -p ChatGPT Update Notifier' "$mock_log" || fail_test 'one-click mode did not authenticate before upgrading'
case $expected_distro in
  ubuntu|debian)
    grep -q '^sudo -n apt-get update$' "$mock_log" || fail_test 'one-click APT refresh was not noninteractive'
    grep -q '^sudo -n apt-get install --only-upgrade -y chatgpt$' "$mock_log" || fail_test 'one-click APT upgrade flags were wrong'
    ;;
  fedora) grep -q '^sudo -n dnf --setopt=keepcache=True upgrade --refresh -y chatgpt$' "$mock_log" || fail_test 'one-click DNF flags were wrong' ;;
  arch) grep -q '^sudo -n pacman -Syu --noconfirm$' "$mock_log" || fail_test 'one-click pacman flags were wrong' ;;
esac

# Restore the saved package through each distro's real rollback dispatch. The mock
# package identity changes only when the expected local-package command is invoked,
# so the production postcondition check remains active.
case $expected_distro in
  fedora) old_version='0:26.900.1-1'; broken_silence='0:26.901.1-1.x86_64' ;;
  ubuntu|debian|arch) old_version='26.900.1-1'; broken_silence='26.901.1-1' ;;
esac
printf '26.901.1-1\n' >"$package_version_file"
printf 'interval_minutes=60\nnotification_seconds=15\nplay_sound=true\nshutdown_timeout_seconds=12\nassume_yes=false\nstop_app=true\nstop_delay_seconds=0\nforce_kill=false\nrestart_app=true\nrestart_delay_seconds=0\nrollback_versions=3\nenable_gui=false\n' >"$config"
chown 65534:65534 "$config" "$package_version_file"
: >"$mock_log"
run_checked_as_user $'y\n\n' "$binary rollback $old_version" 'manual rollback flow failed'
case $expected_distro in
  ubuntu|debian) grep -q '^sudo apt-get install --allow-downgrades .*\.deb$' "$mock_log" || fail_test 'manual APT rollback command was wrong' ;;
  fedora) grep -q '^sudo dnf install .*\.rpm$' "$mock_log" || fail_test 'manual DNF rollback command was wrong' ;;
  arch) grep -q '^sudo pacman -U .*\.pkg.tar.zst$' "$mock_log" || fail_test 'manual pacman rollback command was wrong' ;;
esac
grep -qx "$broken_silence" "$user_home/.local/state/chatgpt-update-notifier/silenced-version" ||
  fail_test 'rollback did not silence the broken distro candidate'

printf '26.901.1-1\n' >"$package_version_file"
sed -i 's/^assume_yes=false$/assume_yes=true/' "$config"
: >"$mock_log"
run_checked_as_user '' "$binary rollback $old_version" 'one-click rollback flow failed'
grep -q '^sudo -v -p ChatGPT Update Notifier' "$mock_log" || fail_test 'one-click rollback did not authenticate'
case $expected_distro in
  ubuntu|debian) grep -q '^sudo -n apt-get install --allow-downgrades -y .*\.deb$' "$mock_log" || fail_test 'one-click APT rollback flags were wrong' ;;
  fedora) grep -q '^sudo -n dnf install -y .*\.rpm$' "$mock_log" || fail_test 'one-click DNF rollback flags were wrong' ;;
  arch) grep -q '^sudo -n pacman -U --noconfirm .*\.pkg.tar.zst$' "$mock_log" || fail_test 'one-click pacman rollback flags were wrong' ;;
esac

# Uninstall removes only program files, keeps configuration/state/cache, and prints
# every retained user-data location in one optional cleanup command.
state_dir="$user_home/.local/state/chatgpt-update-notifier"
cache_dir="$user_home/.cache/chatgpt-update-notifier"
mkdir -p "$state_dir"
mkdir -p "$cache_dir"
printf 'keep\n' >"$state_dir/test-marker"
printf 'keep\n' >"$cache_dir/test-marker"
chown -R 65534:65534 "$state_dir" "$cache_dir"
run_checked_as_user $'y\n' "$binary uninstall" 'installed uninstaller failed'
[[ ! -e $binary && ! -e $units/chatgpt-update-notifier.service && ! -e $units/chatgpt-update-notifier.timer &&
   ! -e $program_data && ! -e $desktop_file && ! -e $icon_file ]] ||
  fail_test 'uninstall left installed notifier files behind'
[[ -f $config && -f $state_dir/test-marker && -f $cache_dir/test-marker ]] ||
  fail_test 'uninstall removed config, state, or cache'
grep -Fq "$user_config_home/chatgpt-update-notifier" "$test_root/user-command.log" ||
  fail_test 'uninstall cleanup command omitted the config location'
grep -Fq "$state_dir" "$test_root/user-command.log" || fail_test 'uninstall cleanup command omitted the state location'
grep -Fq "$cache_dir" "$test_root/user-command.log" || fail_test 'uninstall cleanup command omitted the cache location'

# A second fresh setup covers the conditional one-click onboarding questions.
# Blank answers keep the default stop/restart choices; explicit answers choose
# a seven-second warning and permit force close after a clean-shutdown timeout.
rm -- "$config"
run_checked_as_user $'\n\n\n\n\ny\n\n7\ny\n\ny\n' "bash $root/install.sh" 'one-click onboarding failed'
grep -qx 'play_sound=true' "$config" || fail_test 'one-click onboarding lost the default notification sound'
grep -qx 'assume_yes=true' "$config" || fail_test 'one-click onboarding was not saved'
grep -qx 'stop_app=true' "$config" || fail_test 'one-click onboarding lost stop_app'
grep -qx 'stop_delay_seconds=7' "$config" || fail_test 'one-click onboarding lost the chosen stop delay'
grep -qx 'force_kill=true' "$config" || fail_test 'one-click onboarding lost force_kill consent'
grep -qx 'restart_app=true' "$config" || fail_test 'one-click onboarding lost restart_app'
grep -qx 'rollback_versions=3' "$config" || fail_test 'one-click onboarding lost rollback retention'
run_checked_as_user $'y\n' "bash $root/install.sh --uninstall" 'second uninstall failed'

# Choosing not to stop ChatGPT skips the force-kill question and collects only
# the restart countdown that can apply while the app remains open.
rm -- "$config"
: >"$mock_log"
run_checked_as_user $'\n\n\nn\n\ny\nn\n\n9\ny\n' "bash $root/install.sh" 'non-stopping one-click onboarding failed'
grep -qx 'play_sound=false' "$config" || fail_test 'onboarding ignored the disabled notification sound'
if grep -q '^notify-send .*sound-name' "$mock_log"; then fail_test 'installer played sound when play_sound=false'; fi
grep -q '^notify-send .*--hint=boolean:suppress-sound:true' "$mock_log" || fail_test 'installer readiness alert did not request silence'
grep -qx 'assume_yes=true' "$config" || fail_test 'non-stopping onboarding lost one-click mode'
grep -qx 'stop_app=false' "$config" || fail_test 'non-stopping onboarding changed stop_app'
grep -qx 'force_kill=false' "$config" || fail_test 'force_kill was enabled without its onboarding question'
grep -qx 'restart_app=true' "$config" || fail_test 'non-stopping onboarding lost restart_app'
grep -qx 'restart_delay_seconds=9' "$config" || fail_test 'non-stopping onboarding lost the restart delay'
run_checked_as_user $'y\n' "bash $root/install.sh --uninstall" 'third uninstall failed'

# When a native dialog is already present, onboarding offers the mouse manager and
# the default-Yes choice is stored without adding a GUI package dependency.
rm -- "$config"
ln -s mock-command "$mock_bin/kdialog"
run_checked_as_user $'\n\n\n\n\n\n\ny\n' "bash $root/install.sh" 'native-GUI onboarding failed'
grep -qx 'enable_gui=true' "$config" || fail_test 'native-GUI onboarding choice was not saved'
run_checked_as_user $'y\n' "bash $root/install.sh --uninstall" 'fourth uninstall failed'

printf 'PASS: %s syntax, shellcheck, behavior, rollback snapshot, launcher, install, upgrade dispatch, reinstall, and uninstall\n' "$expected_distro"
