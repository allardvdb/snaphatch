# Rename to snaphatch and move files to their proper places

Date: 2026-10-29
Status: approved design, not yet implemented

## Goal

Finish the rename from ix500-linux to snaphatch. In the same change, put every file where the XDG base directory spec and systemd's `file-hierarchy(7)` expect it, and move existing installs over automatically.

Success looks like:

- Nothing installed or written uses the old names (`scan`, `scan-button-*`, `scanner.conf`, `scanner-inbox`). The one exception is local-mode scans made before the rename, which stay where they are.
- The Paperless token is no longer in every process of the user's session.
- A manual scan uses exactly the same settings as the button service, whatever the login session's environment is.
- Running `just install` on an old install migrates it: the config, the data that has to move, and removal of the old files. Running it twice changes nothing more, and an aborted install leaves the old one working.
- Day-to-day commands work without the git checkout.

## Background: problems with the current layout

- **Config:** `~/.config/environment.d/scanner.conf` holds the token. `environment.d` exports every variable to every process of the session, and is only read at login. This caused a manual scan to fail TLS verification: the session predated `PAPERLESS_CA`.
- **Command:** `scan` is a generic command name in `~/.local/bin`. `scan-button-poll` is internal, but it's on `PATH` too.
- **Data:** `~/Documents/scanner-inbox/` mixes documents (local-mode output, undeliverable scans) with a self-pruning safety net (removed blank pages).
- **Temporary pages:** they go to `/tmp`, which is RAM on Fedora. A page is about 33 MB as TIFF.

## 1. Names and locations

| What | Old | New |
|---|---|---|
| Command | `~/.local/bin/scan` | `~/.local/bin/snaphatch`, a symlink to `~/.local/lib/snaphatch/snaphatch` |
| Subcommands | (only `scan`) | `snaphatch scan [name]`, `status`, `logs`, `restart` |
| Scan script | `~/.local/bin/scan` | `~/.local/lib/snaphatch/snaphatch-scan` |
| Poll script | `~/.local/bin/scan-button-poll` | `~/.local/lib/snaphatch/snaphatch-poll` |
| Unit | `scan-button.service` | `snaphatch.service` |
| udev rule | `/etc/udev/rules.d/99-scansnap.rules` | `/etc/udev/rules.d/99-snaphatch.rules` |
| Device alias | `/dev/scansnap` | unchanged: it names the scanner, not the program |
| Config | `~/.config/environment.d/scanner.conf` | `${XDG_CONFIG_HOME:-~/.config}/snaphatch/snaphatch.conf`, mode 600 |
| Local-mode output | `~/Documents/scanner-inbox/` | `<documents>/snaphatch/` |
| Undeliverable scans | `~/Documents/scanner-inbox/failed/` | `<documents>/snaphatch/failed/` |
| Removed blank pages | `~/Documents/scanner-inbox/removed/` | `${XDG_STATE_HOME:-~/.local/state}/snaphatch/removed/` |
| Temporary pages | `mktemp -d` in `/tmp` | `mktemp -d` under `${XDG_CACHE_HOME:-~/.cache}/snaphatch/` |

`<documents>` is `xdg-user-dir DOCUMENTS`, or `~/Documents` when `xdg-user-dir` is missing.

In the repo, the files are renamed the same way: `snaphatch`, `snaphatch-scan`, `snaphatch-poll`, `snaphatch.service` and `99-snaphatch.rules`. The README, CLAUDE.md, the installer's header and the config file header all say snaphatch.

Out of scope:
- the GitHub repo, already named `snaphatch`;
- the name of a local clone's directory;
- the CA certificate file, whose path is just a config value.

## 2. Config and code

### Config file

- **Format:** plain `KEY=value` lines plus `#` comments, which is valid for systemd's `EnvironmentFile=`. The installer writes it with mode 600. It keeps lines it doesn't manage (such as `BLANK_THRESHOLD`, `JPEG_QUALITY` and comments), as it does now.
- **The service** reads it with `EnvironmentFile=-%h/.config/snaphatch/snaphatch.conf`. The `-` means a missing file is not an error. systemd reads it on every (re)start, so the installer no longer pushes values with `systemctl --user set-environment` or `unset-environment`.
- **`snaphatch-scan` and `snaphatch-poll`** call `load_config` at start:
  - **Location:** `${SNAPHATCH_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/snaphatch/snaphatch.conf}`.
  - **Parsing:** the file is parsed, never executed with `source`. Blank lines and `#` comments are skipped, as are lines that aren't `KEY=value` with a known key. One pair of surrounding `"` or `'` quotes is stripped.
  - **Known keys:** `SCANNER_DEVICE`, `COLOR_DETECT`, `PAPERLESS_URL`, `PAPERLESS_TOKEN`, `PAPERLESS_CA`, `PAPERLESS_CONSUME_DIR`, `BLANK_THRESHOLD`, `JPEG_QUALITY`.
  - **Precedence:** a key that is already set in the environment wins. This keeps `PAPERLESS_URL=… snaphatch scan` working, and keeps the service's own `EnvironmentFile=` values in charge.
  - `SNAPHATCH_CONFIG` exists for tests and for running with another config.

### `snaphatch` dispatcher

`~/.local/lib/snaphatch/snaphatch` resolves its own location through the symlink, with `readlink -f`, and then:

| Command | Does |
|---|---|
| `snaphatch scan [name]` | `exec`s `snaphatch-scan [name]` from its own directory |
| `snaphatch status` | `systemctl --user status snaphatch.service` |
| `snaphatch logs` | `journalctl --user -u snaphatch.service -f` |
| `snaphatch restart` | restarts the service when `dev-scansnap.device` is active; otherwise says the service starts when the scanner is connected |
| no argument, unknown subcommand | prints usage to stderr and exits 2 |
| `-h`, `--help`, `help` | prints usage to stdout and exits 0 |

The `status`, `logs` and `restart` recipes are removed from the `justfile`. `just install`, `just uninstall`, `just check` and `just test` stay.

### Scripts

- **`snaphatch-scan`** (formerly `scan`). Behaviour is unchanged apart from:
  - the paths in section 1;
  - `load_config`;
  - `snaphatch.service` in `pause_service` and `resume_service`, including the cgroup check (`/snaphatch.service$`);
  - the working directory `mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/snaphatch/scan.XXXXXX"`, with the parent created first. It is still removed by the `EXIT` trap.

  The page functions stay above `main` and can be sourced.
- **`snaphatch-poll`** (formerly `scan-button-poll`):
  - it finds `snaphatch-scan` next to itself;
  - it calls `load_config`;
  - "View Logs" uses `journalctl --user -u snaphatch.service`.
- **"Show" button.** `snaphatch-scan` already prints `Removed N blank page(s), kept in <dir>`. A new poll-script function, `removed_dir`, reads `<dir>` from that line. When it is set, "Scan Complete" gets the action `show=Show`, which runs `xdg-open <dir>`. This applies to button scans only. After a manual run, the folder is printed in the terminal.
- **Output coupling** stays as it is: the `Done:`, `Removed N blank page(s)` and `Error:` lines that the poll script parses do not change format.

## 3. Migration in `just install`

The order is chosen so that the old install keeps working until the new one is in place. If the installer exits early, the existing `EXIT` trap starts the service that was running before. It covers `scan-button.service` too.

1. **Detect the old install.** The installer looks for:
   - `~/.config/environment.d/scanner.conf` and `paperless.conf`;
   - `~/.config/systemd/user/scan-button.service`;
   - `~/.local/bin/scan` and `scan-button-poll`;
   - `/etc/udev/rules.d/99-scansnap.rules` and `99-scansnap-ix500.rules`;
   - `~/Documents/scanner-inbox/failed/` and `removed/`.

   Old scripts count only if they are ours: the file contains the header line `# scan - Quick scan from` or `# scan-button-poll - Poll ScanSnap button`. A different program called `scan` is never touched.
2. **Read existing settings.** If the new config doesn't exist, the installer reads the old `scanner.conf` (or `paperless.conf`) for its defaults and for the lines it doesn't manage. "Keep current values" then works as it does now.
3. **Stop the services** for scanner detection: both `scan-button.service` and `snaphatch.service`, whichever are active. Remember which were active, for the trap.
4. **Install the new setup:**
   - the scripts in `~/.local/lib/snaphatch/`, executable;
   - the symlink `~/.local/bin/snaphatch`;
   - `~/.config/systemd/user/snaphatch.service`;
   - `/etc/udev/rules.d/99-snaphatch.rules`;
   - the new config, mode 600.
5. **Remove the old install,** only what was found:
   - **Unit:** disable `scan-button.service` and remove its unit file, then `daemon-reload`.
   - **Scripts:** remove our old `~/.local/bin/scan` and `scan-button-poll`.
   - **udev:** `sudo rm` the old rule files, in the same `sudo` step as installing the new rule; then reload udev and trigger it.
   - **Config:** remove `environment.d/scanner.conf` and `paperless.conf`. Run `systemctl --user unset-environment` for every known key and every key from the old file's extra lines. Tell the user that apps that are already running keep the old values until they next log out.
6. **Move the data,** without overwriting:
   - every file in `~/Documents/scanner-inbox/failed/` goes to `<documents>/snaphatch/failed/`;
   - every file in `removed/` goes to `<state>/snaphatch/removed/`;
   - a name that is already taken is skipped and reported;
   - emptied old folders are removed with `rmdir`, which removes only empty folders.

   Local-mode PDFs in `~/Documents/scanner-inbox/` stay where they are. The summary mentions them.
7. **Start `snaphatch.service`** when the scanner is connected (the existing `dev-scansnap.device` check). Turn off the trap's restart.
8. **Print a summary** of what was moved, removed, left in place and skipped.

Every step is conditional on what exists, so a second run finds nothing old and changes nothing beyond rewriting the same config.

`just uninstall` removes:
- the new install: the symlink, `~/.local/lib/snaphatch/`, the unit, the udev rule and, after asking, the config;
- any old leftovers it finds, with the same "only if ours" check for the scripts.

It never removes `<documents>/snaphatch/`, `<state>/snaphatch/` or `~/Documents/scanner-inbox/`.

## 4. Tests

All tests use a temporary `HOME` and temporary XDG directories, with fake system commands first on `PATH`. They refuse to run if a real `systemctl`, `sudo` or `udevadm` would be used.

- **`tests/test-scan.sh`** sources `snaphatch-scan`; otherwise unchanged.
- **`tests/test-upload.sh`** keeps all current checks, plus:
  - a value only in `SNAPHATCH_CONFIG` (`PAPERLESS_CA`) reaches curl as `--cacert`;
  - a value in the environment overrides the same key in the file;
  - with a fake `xdg-user-dir` and temporary `XDG_STATE_HOME` and `XDG_CACHE_HOME`:
    - undeliverable scans are in `<documents>/snaphatch/failed/`;
    - removed pages are in `<state>/snaphatch/removed/`;
    - the working directory is under `<cache>/snaphatch/` and is gone afterwards;
  - the manual-scan pause uses `snaphatch.service`.
- **`tests/test-poll.sh`:** `removed_dir` reads the folder from the "Removed" line, including a path with spaces, and is empty without that line.
- **`tests/test-install.sh`** keeps all current scenarios, adapted to the new names, plus:
  - **Fresh install:**
    - the config exists with mode 600;
    - the scripts are in `~/.local/lib/snaphatch/`;
    - the symlink resolves;
    - the unit has `EnvironmentFile=`;
    - the rule was installed as `99-snaphatch.rules`;
    - nothing calls `set-environment`.
  - **Migration:** an old `environment.d/scanner.conf` with a hand-added line, the old unit, our old scripts, old `failed/` and `removed/` files:
    - the values and the hand-added line are in the new config;
    - the old unit, scripts and `scanner.conf` are gone;
    - `unset-environment` was called with the old keys;
    - `sudo rm` was called for the old rules;
    - the data was moved;
    - the old local-mode PDFs are still there.
  - **Foreign `scan`:** a `~/.local/bin/scan` without our header is left alone.
  - **Second run:** nothing old is found and the files are unchanged.
  - **Abort during migration:** the old config, unit and scripts are intact, and `scan-button.service` is started again.
- **New `tests/test-cli.sh`:**
  - no argument and an unknown subcommand print usage and exit 2;
  - `--help` exits 0;
  - `snaphatch scan name` runs `snaphatch-scan` with `name`, using a stub in a temporary copy of the lib directory;
  - the dispatcher works when called through a symlink.

`just test` runs all five suites.

### Hardware test before merging

On a machine with an existing install:
1. `just install` from the branch; check the summary.
2. A button scan.
3. `snaphatch scan test` from a terminal.
4. `snaphatch status` and `snaphatch logs`.
5. Unplug, then plug in again.
6. After the next login, `env | grep PAPERLESS` is empty.

## 5. Delivery

One PR, because the names, paths and migration depend on each other, and users should migrate only once. It is split into commits that can be reviewed one at a time:

1. Rename the files and names.
2. The new config file, read by the service and the scripts.
3. The new paths: documents, state, cache.
4. The `snaphatch` dispatcher.
5. The migration in the installer.
6. The "Show" button.
7. Docs (README, CLAUDE.md).

Each commit keeps `just test` passing.
