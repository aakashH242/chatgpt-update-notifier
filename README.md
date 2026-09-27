# ChatGPT Linux App Update Notification Tool for Linux

Well, I kept missing ChatGPT desktop app updates and was suprised that the Linux app did not have an update flow built-in. I am sure OpenAI will eventually address this.

Until then, here is a small, unofficial notifier for the **ChatGPT desktop app** on Linux. The Windows version of the app already has this update-checker feature.
It checks the signed OpenAI package repository and reminds you about newer app versions. It never installs an update without your confirmation.

Supports the [Linux desktops supported by OpenAI](https://learn.chatgpt.com/docs/linux/linux-app): Ubuntu 24.04/26.04, Debian 13, Fedora 43/44, and current Arch Linux (x64 or ARM64).
ChatGPT must already be installed from its official repository. A user systemd session and desktop notifications are required.

## Demo

[![Watch the ChatGPT Linux update notifier demo](assets/chatgpt-update-notifier-loop-action.gif)](https://youtu.be/zwd-9nPpz-s)

[Watch the full update flow on YouTube](https://youtu.be/zwd-9nPpz-s)

## Get started

Download and run the installation script. This will start a guided wizard.

```bash
curl -fsSLo chatgpt-update-notifier-install.sh https://raw.githubusercontent.com/aakashH242/chatgpt-update-notifier/refs/heads/main/install.sh &&
bash chatgpt-update-notifier-install.sh
```
Run this as your normal user, not with `sudo`. Keep the downloaded script if you want to re-run it later. If the notifier file is not beside it, the installer downloads one project archive so both files come from the same snapshot.

The wizard checks that ChatGPT is installed, shows what it will change, and asks before installing any missing tools. If `kdialog` or `zenity` is already available, it also asks whether you want the mouse-friendly manager. Nothing extra is installed for the GUI. On Arch, installing a missing tool may upgrade your **whole system**; the wizard warns you and asks first. It never upgrades ChatGPT by itself.

## Updating ChatGPT

When a newer ChatGPT package is available, the notification shows both versions. **Install update** opens a visible terminal and shows the exact package-manager command. Manual mode asks Yes/No before running it; optional one-click mode starts only after you press the button. You can instead choose **Silence this version**; a later release will notify you again.

If ChatGPT is open, the updater can close it before upgrading and reopen it afterward. Manual mode asks what to do. One-click mode follows the preferences in your config. Force-close is never used unless you explicitly allow it.

Before the package manager upgrades ChatGPT, the notifier saves the exact currently installed package for rollback. If that package is no longer cached or available from the signed OpenAI repository, manual mode asks whether to continue without protection; one-click mode stops safely.

Update alerts request 15 seconds on screen by default. Expiring or closing one does not silence it; only an explicit silence/dismiss action does. Your desktop may override the requested display time.

## Rolling back ChatGPT

After an update succeeds, the notification offers **Roll back to OLD_VERSION**. You can also open **ChatGPT Update Notifier** from your application menu to check, roll back, list saved versions, or clear silences—no command typing needed. The launcher uses `kdialog` or `zenity` when enabled, and otherwise opens the terminal menu.

The notifier keeps the latest three valid rollback copies by default under `~/.local/state/chatgpt-update-notifier/rollbacks`. Set `rollback_versions` to `1–1000`, or `0` to keep every version. Each copy contains the exact package, its checksum, and verified metadata; Arch copies also include the matching signature.

You can also roll back via the terminal by running the `chatgpt-update-notifier rollback` command. This will list the available old versions and let you select the one you want to roll back to. For further roll back options, see the [CLI Commands](#cli-commands) section.

## Updating the notifier

The notifier checks its own [VERSION](VERSION) on every timer run and whenever you open its manager. When a release is available, **Update notifier** opens the existing update flow: changelog, exact installer command, and confirmation. Nothing self-installs in the background.

## Uninstalling

Use the matching uninstaller kept with the installed notifier:

```bash
~/.local/bin/chatgpt-update-notifier uninstall
```

Your config, silence state, rollback packages, metadata cache, and any system packages you approved installing are kept. The installer prints their exact locations in one copyable `rm -r -- ...` command if you also want to remove that saved data.

This keeps working after a notifier update; it does not depend on a previously downloaded installer script.



## CLI Commands

You can run these from a terminal too. The command lives at `~/.local/bin/chatgpt-update-notifier` if that directory is not on your `PATH`.

- `chatgpt-update-notifier --version` shows the installed notifier version and this GitHub repo.
- `chatgpt-update-notifier --help` shows the commands and a link back to this README.
- `chatgpt-update-notifier --update` checks for a newer notifier and walks you through the update.
- `chatgpt-update-notifier manage` opens the native or terminal manager.
- `chatgpt-update-notifier check-now` checks for a ChatGPT update immediately.
- `chatgpt-update-notifier silence` stops ChatGPT app reminders for the currently available version.
- `chatgpt-update-notifier --silence-notifier` dismisses the currently available notifier release.
- `chatgpt-update-notifier upgrade` shows the ChatGPT package command and asks before running it.
- `chatgpt-update-notifier rollback` shows a numbered rollback menu.
- `chatgpt-update-notifier rollback --list` lists saved versions without changing anything.
- `chatgpt-update-notifier rollback VERSION` restores that saved version.
- `chatgpt-update-notifier uninstall` removes the notifier while keeping its config, state, rollback packages, and cache.

## Configuration

The installer creates the config file at `~/.config/chatgpt-update-notifier/config`.
You can change it any time; the next run picks up the new values without a service reload.

```ini
# Check for updates this often. Use 15-minute steps from 15 minutes to one week (10080).
interval_minutes=60

# How long the desktop will keep the update notification visible in seconds. (1-600).
# You can still hide it sooner.
notification_seconds=15

# true = ask your desktop notification service to play its standard alert sound.
# Your desktop controls the actual sound and may ignore this request.
play_sound=true

# After asking ChatGPT to close normally, wait this long before deciding it is stuck (1-60).
shutdown_timeout_seconds=10

# true = one-click mode after you press "Install update".
# The terminal skips its Yes/No questions, but sudo may still ask for your password.
assume_yes=false

# One-click mode only: close ChatGPT before upgrading if it was already open.
stop_app=true

# One-click mode only: give you this long to save your work before closing ChatGPT (0-180).
stop_delay_seconds=30

# One-click mode only: force-close ChatGPT if a normal close fails.
# Keep this false unless you are okay with possibly losing unsaved work.
force_kill=false

# One-click mode only: reopen ChatGPT after upgrading if it was open before.
# The notifier will not open an app that was already closed.
restart_app=true

# One-click mode only: if the old app is still open after upgrading, wait this long before restarting it (0-180).
restart_delay_seconds=30

# Number of saved rollback versions to keep (1-1000). Use 0 to keep every version.
rollback_versions=3

# true = use kdialog or zenity for a mouse-launched manager when one is available.
# false = always open the terminal manager from the application-menu icon.
enable_gui=true
```

If the config is missing, unreadable, or invalid, update checks pause, and you will get a notification to address the issue.
Re-run `bash chatgpt-update-notifier-install.sh` to recreate a missing config or explicitly reset a damaged one.

## Troubleshooting

If an online check fails, the notifier logs the error and tries again on the next timer tick. To see what happened, run:

```bash
journalctl --user -u chatgpt-update-notifier.service
```

If your desktop does not show notification buttons, use the application-menu launcher or the CLI commands above. If no supported terminal app is available, update or roll back from an existing terminal with `upgrade`, `rollback`, or `--update`.

## Contributing

Bug reports and focused pull requests are welcome. Open an issue before a large change so we can agree on the simplest approach first.

The root `chatgpt-update-notifier` script is the CLI entry point and orchestrator. Cohesive implementation modules live in `core/` and are sourced from the matching installed release.

To explore the code graph locally, refresh the `.consequences` index, then run `python3 tools/build_consequences_viewer.py` and open `.consequences/viewer.html` in a browser. The viewer is an offline snapshot: rebuild it after source changes. It uses Python's standard library only and is not part of the installed notifier.

- Keep the utility Bash-only and avoid new dependencies unless they are truly necessary.
- Preserve the visible confirmation step: updates must never install silently.
- Run the checks below before submitting a pull request.
- In the pull request, mention which Linux distribution you tested.

```bash
bash tests/test.sh
bash -n chatgpt-update-notifier install.sh core/*.sh tests/test.sh tests/test-container.sh
shellcheck -S warning chatgpt-update-notifier install.sh core/*.sh tests/test.sh tests/test-container.sh
docker compose run --rm ubuntu
docker compose run --rm debian
docker compose run --rm fedora
docker compose run --rm arch
```

The Compose checks exercise installation, distro command selection, reinstall, and uninstall in disposable distro containers. If ShellCheck or Docker Compose is unavailable, run the checks you can and mention the omitted ones in the pull request.
