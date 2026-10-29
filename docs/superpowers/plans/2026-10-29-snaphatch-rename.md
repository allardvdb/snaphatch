# Rename to snaphatch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename ix500-linux to snaphatch, move every installed and written file to its XDG/`file-hierarchy(7)` location, add a `snaphatch` command, and migrate existing installs automatically in `just install`.

**Architecture:** The scripts are installed together in `~/.local/lib/snaphatch/`, with one symlink on `PATH`. The config moves out of `environment.d` into `~/.config/snaphatch/snaphatch.conf`. systemd reads that file with `EnvironmentFile=`, and the scripts read it with a shared parser. The installer still does everything, including the migration of an old install, in an order that keeps the old install working until the new one is in place.

**Tech Stack:** bash, `just`, systemd user units, udev, ImageMagick, curl, notify-send. The tests are plain bash scripts with fake commands put first on `PATH`.

**Spec:** `docs/superpowers/specs/2026-10-29-snaphatch-rename-design.md`. Read it before starting. This plan doesn't repeat its tables.

## Global Constraints

- **Branch:** `rename/snaphatch`. It ends as one PR with these seven commits. `just test` must pass after every commit.
- **Commits** are signed with a FIDO key that has to be touched. Tell the user before each `git commit`.
- **No real system commands in tests.** No test may run the real `systemctl`, `sudo`, `udevadm` or `scanimage`. Every suite that could reach them puts fakes first on `PATH` and refuses to run otherwise, the pattern already used in `tests/test-install.sh` and `tests/test-upload.sh`.
- **Output coupling stays.** The output formats the poll script parses stay byte-for-byte the same:
  - `Done: <path> (<N> pages, <size>)`
  - `Removed N blank page(s), kept in <dir>`
  - `Error: …` and `Error: <reason>; scan kept as <path>`
  - `Upload failed (HTTP …)`
  - `No pages scanned (feeder empty?)`
- **Exact names:**
  - **Unit and udev:** unit `snaphatch.service`, rule `99-snaphatch.rules`, device alias `/dev/scansnap` (unchanged), device unit `dev-scansnap.device`.
  - **Config:** `${SNAPHATCH_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/snaphatch/snaphatch.conf}`, mode 600.
  - **Installed files:** lib directory `~/.local/lib/snaphatch/`; scripts `snaphatch`, `snaphatch-scan`, `snaphatch-poll`; symlink `~/.local/bin/snaphatch`.
  - **Data folders:**
    - documents: `xdg-user-dir DOCUMENTS`, falling back to `$HOME/Documents`;
    - output: `<documents>/snaphatch/`;
    - undeliverable scans: `<documents>/snaphatch/failed/`;
    - removed pages: `${XDG_STATE_HOME:-$HOME/.local/state}/snaphatch/removed/`;
    - working directories: `mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/snaphatch/scan.XXXXXX"`.
- **Known config keys:** `SCANNER_DEVICE COLOR_DETECT PAPERLESS_URL PAPERLESS_TOKEN PAPERLESS_CA PAPERLESS_CONSUME_DIR BLANK_THRESHOLD JPEG_QUALITY`.
- **Rules directory:** the installer and uninstaller use `UDEV_RULES_DIR="${SNAPHATCH_UDEV_DIR:-/etc/udev/rules.d}"` for every rules path, both detecting and writing. Tests point `SNAPHATCH_UDEV_DIR` at a temporary directory, so the result never depends on the rules in the host's real `/etc`.
- **Recognising our old scripts:** a file is ours if it contains `# scan - Quick scan from` or `# scan-button-poll - Poll ScanSnap button`.
- **Public repo:** no host names, family details or private issue numbers in code, comments, commits or docs.

## Review Focus

1. **Config values with spaces or `=` in them,** such as a CA path with spaces, or a token containing `=`. The whole value is kept, apart from one pair of surrounding quotes. Covered by `config: keeps spaces and = in values`, Task 2.
2. **`xdg-user-dir DOCUMENTS` returning `$HOME`.** It does that when no documents folder is configured. Scans should then go to `$HOME/Documents/snaphatch`, not loose into `$HOME/snaphatch`. Covered by `paths: home as documents falls back`, Task 3.
3. **`~/.local/bin` not on `PATH`.** The installer should say that `snaphatch` won't be found and how to fix it, instead of reporting success silently. Covered by `fresh: warns when ~/.local/bin is not on PATH`, Task 4.
4. **Old and new config both present,** for example a re-run after a migration that was partly done by hand. The new config wins, and the old `environment.d` file is still removed. Covered by `migration: new config wins over old`, Task 5.
5. **A name in the old `failed/` that already exists in the new `failed/`.** That file is skipped and reported, and neither copy is overwritten or lost. Covered by `migration: name clash is skipped and kept`, Task 5.

---

### Task 1: Rename the files and names

**Files:**
- Rename with `git mv`:
  - `scan` → `snaphatch-scan`
  - `scan-button-poll` → `snaphatch-poll`
  - `scan-button.service` → `snaphatch.service`
  - `99-scansnap.rules` → `99-snaphatch.rules`
- Modify:
  - `snaphatch-scan`: header comment; `pause_service` and `resume_service` use `snaphatch.service`, and the cgroup check uses `'/snaphatch\.service$'`.
  - `snaphatch-poll`: header; `SCAN_SCRIPT="$SCRIPT_DIR/snaphatch-scan"`; "View Logs" uses `journalctl --user -u snaphatch.service`.
  - `snaphatch.service`: `Description=snaphatch scan button`, `ExecStart=%h/.local/lib/snaphatch/snaphatch-poll`.
  - `99-snaphatch.rules`: `SYSTEMD_USER_WANTS` becomes `snaphatch.service`; header comment.
  - `justfile`, `install`:
    - copy `snaphatch-scan` and `snaphatch-poll` to `~/.local/lib/snaphatch/` (mode 755);
    - install the unit as `snaphatch.service` and the rule as `$UDEV_RULES_DIR/99-snaphatch.rules`, introducing `UDEV_RULES_DIR` (see Global Constraints), and use it for the existing check for the old `99-scansnap-ix500.rules` as well;
    - all `systemctl` calls use `snaphatch.service`;
    - the header says snaphatch.
  - `justfile`, `uninstall`: the same new names.
- Tests:
  - `tests/test-scan.sh`: source `snaphatch-scan`.
  - `tests/test-poll.sh`: source `snaphatch-poll`.
  - `tests/test-upload.sh`: run `snaphatch-scan`; expect `--user stop snaphatch.service` and `--user start --no-block snaphatch.service`.
  - `tests/test-install.sh`: expect the new unit, lib path and rule name.

**Interfaces:**
- Produces: the file names above, and the install location `~/.local/lib/snaphatch/{snaphatch-scan,snaphatch-poll}`, which every later task uses.

Old installs are not cleaned up yet; that's Task 5. Until then, an install over an old one leaves both units in place. That's acceptable inside the branch.

- [ ] **Step 1: Update the tests to the new names.** In `test-install.sh`, the "keep" scenario checks:
  - `[ -x "$WORK/keep/.local/lib/snaphatch/snaphatch-scan" ]` and `-x …/snaphatch-poll`;
  - `grep -qx 'ExecStart=%h/.local/lib/snaphatch/snaphatch-poll' "$WORK/keep/.config/systemd/user/snaphatch.service"`;
  - the sudo log contains `install -m 0644 $ROOT/99-snaphatch.rules $WORK/keep/udev/99-snaphatch.rules`. The `install()` helper sets `SNAPHATCH_UDEV_DIR="$WORK/$run/udev"` and creates that directory;
  - the systemctl log contains `--user restart snaphatch.service`.

  Update every existing `scan-button.service` expectation the same way.
- [ ] **Step 2: Run `just test`.** Expected: FAIL. The sourced files are missing, and the install checks fail.
- [ ] **Step 3: Do the renames and edits** listed under Files.
- [ ] **Step 4: Run `just test` and `grep -rn 'scan-button\|99-scansnap\.rules' --exclude-dir=docs --exclude-dir=.git .`.** Expected: all suites pass. The grep may only hit the `rm` of old rule files in `uninstall`.
- [ ] **Step 5: Commit**: "Rename the scripts, unit and udev rule to snaphatch".

### Task 2: The config file, read by the service and the scripts

**Files:**
- Create: `snaphatch-config.sh`. It's sourced, not executed, and installed to `~/.local/lib/snaphatch/` next to the scripts. (The spec says both scripts call `load_config`; a shared file keeps a single parser.)
- Modify:
  - `snaphatch-scan` and `snaphatch-poll`: `source "$SCRIPT_DIR/snaphatch-config.sh"`, then `load_config`. In `snaphatch-scan`, call it at the start of `main`, so sourcing for tests has no side effects. In `snaphatch-poll`, call it after the source guard.
  - `snaphatch.service`: add `EnvironmentFile=-%h/.config/snaphatch/snaphatch.conf`; remove the `environment.d` comment.
  - `justfile` `install`:
    - `ENV_FILE` becomes the new config path, and `ENV_DIR` its folder;
    - write the file, then `chmod 600` it;
    - install `snaphatch-config.sh` (mode 644);
    - remove the whole "push to systemd" block (`ENV_VARS`, `set-environment`, `unset-environment PAPERLESS_CA`), since the restart reads the file;
    - `read_var` and the "keep unmanaged lines" logic stay as they are.
- Tests: `tests/test-upload.sh`, `tests/test-install.sh`.

**Interfaces:**
- Produces:
  - `load_config [FILE]`. With no argument, it reads `${SNAPHATCH_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/snaphatch/snaphatch.conf}`. For each line `KEY=value` where `KEY` is a known key and is **unset** in the environment (`[ -z "${KEY+set}" ]`), it exports `KEY` with one pair of surrounding `"` or `'` quotes stripped. Blank lines, `#` comments, unknown keys and malformed lines are skipped. A missing file returns 0. It never `source`s the file.
  - `SNAPHATCH_KEYS`: the space-separated list of known keys, which Task 5 reuses.

- [ ] **Step 1: Write the failing tests in `test-upload.sh`.** `run_scan` gets `SNAPHATCH_CONFIG="$WORK/$run.conf"` (the file only exists when a test writes it), and `XDG_CONFIG_HOME="$WORK/xdg-config"`. New runs:
  - `cfgca`: the config contains `PAPERLESS_CA="/etc/my ca.pem"`. Check `config: value from file reaches curl`: lines `--cacert` and `/etc/my ca.pem` appear in `cfgca-curl-args`.
  - `cfgenv`: the config contains `PAPERLESS_URL=https://from-file.example`, and the run passes `PAPERLESS_URL=https://from-env.example`. Check `config: environment wins`: the curl args end with `https://from-env.example/api/documents/post_document/`.
  - `cfgeq`: the config contains `PAPERLESS_TOKEN=abc=def==` and `PAPERLESS_CA='/etc/a b.pem'`, plus a `# comment`, `NOT_OURS=1` and `garbage line`. The run passes `PAPERLESS_TOKEN=` unset via `env -u`. Check `config: keeps spaces and = in values`: the curl args contain `Authorization: Token abc=def==` and `/etc/a b.pem`.
- [ ] **Step 2: Write the failing tests in `test-install.sh`:**
  - in "keep": `[ "$(stat -c %a "$(conf keep)")" = 600 ]`;
  - `grep -qx 'EnvironmentFile=-%h/.config/snaphatch/snaphatch.conf' …/snaphatch.service`;
  - `! grep -q set-environment "$WORK/keep-systemctl"`.

  `conf()` and the `install()` helper now use `$WORK/$run/.config/snaphatch/snaphatch.conf`. The existing scenarios write their starting config there, and the old-location starting config is Task 5's job. The check `pushes hand-added settings` is replaced by `keeps hand-added settings`, which already exists.
- [ ] **Step 3: Run both suites.** Expected: FAIL on the new checks.
- [ ] **Step 4: Implement `snaphatch-config.sh`, the script calls, the unit line and the installer changes.**
- [ ] **Step 5: Run `just test`.** Expected: all suites pass.
- [ ] **Step 6: Commit**: "Read the config from ~/.config/snaphatch, in the service and the scripts".

### Task 3: The new paths: documents, state, cache

**Files:**
- Modify `snaphatch-scan`:
  - `REMOVED_DIR`, `FAILED_DIR`, the local-mode `OUTDIR` and `WORKDIR` move to the paths under Global Constraints;
  - create the cache parent with `mkdir -p` before `mktemp -d`;
  - the comment "never pruned" stays on `FAILED_DIR`.
- Tests: `tests/test-upload.sh`.

**Interfaces:**
- Produces: `documents_dir`. It prints `xdg-user-dir DOCUMENTS` when that command exists and prints a path other than `$HOME`; otherwise `$HOME/Documents`. It's used by `snaphatch-scan` here and by the installer's migration in Task 5. The installer has its own copy, because the justfile can't source from the lib directory before installing it.

- [ ] **Step 1: Write the failing tests in `test-upload.sh`.**
  - **Setup:** a fake `xdg-user-dir` in `$WORK/bin` prints `${FAKE_DOCS:-$WORK/home/Docs}`. `run_scan` gets `XDG_STATE_HOME="$WORK/state"` and `XDG_CACHE_HOME="$WORK/cache"`. `FAILED_DIR` in the test becomes `$WORK/home/Docs/snaphatch/failed`, so every existing "keeps the PDF" check moves with it.
  - **Checks:**
    - `paths: removed pages in state`: after the `solo` run (whose page isn't blank), add a `blank` run whose fake page is white (`FAKE_BLANK=1` makes the fake `scanimage` copy a white `page.tiff`). Then `ls "$WORK/state/snaphatch/removed/"blank-*.jpg` succeeds.
    - `paths: working dir in cache and removed`: `[ -d "$WORK/cache/snaphatch" ] && [ -z "$(ls -A "$WORK/cache/snaphatch")" ]`.
    - `paths: local output in documents`: a local-mode run with a passing fake `ocrmypdf` (`FAKE_OCR_OK=1` makes it copy its input to its output) writes `$WORK/home/Docs/snaphatch/localok.pdf`.
    - `paths: home as documents falls back`: with `FAKE_DOCS="$WORK/home"`, a run with HTTP 500 keeps its scan in `$WORK/home/Documents/snaphatch/failed/`.
- [ ] **Step 2: Run `bash tests/test-upload.sh`.** Expected: FAIL on the new checks and on the moved `failed/` checks.
- [ ] **Step 3: Implement `documents_dir` and the path changes.**
- [ ] **Step 4: Run `just test`.** Expected: all suites pass.
- [ ] **Step 5: Commit**: "Put documents, state and temporary pages in their XDG places".

### Task 4: The `snaphatch` command

**Files:**
- Create: `snaphatch`, the dispatcher, mode 755.
- Modify:
  - `justfile` `install`:
    - copy `snaphatch` to the lib directory;
    - `ln -sfn "$HOME/.local/lib/snaphatch/snaphatch" "$HOME/.local/bin/snaphatch"`;
    - when `~/.local/bin` isn't on `PATH`, print `warn "~/.local/bin is not on your PATH: add it to run snaphatch"`;
    - the final message mentions `snaphatch scan`, `snaphatch status` and `snaphatch logs`.
  - `justfile`: remove the `status`, `logs` and `restart` recipes. Move `restart`'s device check into the dispatcher.
  - `justfile` `test`: add `bash tests/test-cli.sh`.
- Test: create `tests/test-cli.sh`.

**Interfaces:**
- Consumes: `snaphatch-scan` in the same directory (Task 1).
- Produces: `snaphatch <scan [name]|status|logs|restart|help|-h|--help>`.
  - The dispatcher resolves its directory with `$(dirname "$(readlink -f "$0")")`.
  - `scan` runs `exec "$DIR/snaphatch-scan" "$@"`.
  - The other commands work as described in the spec's dispatcher table.
  - Usage text begins `Usage: snaphatch <command>`. Without an argument or with an unknown command, it goes to stderr with exit 2. With `help`, `-h` or `--help`, it goes to stdout with exit 0.

- [ ] **Step 1: Write `tests/test-cli.sh`.** It copies `snaphatch` into `$WORK/lib/`, with a stub `snaphatch-scan` that prints `scan-args:$*`, and a symlink at `$WORK/bin/snaphatch`. A fake `systemctl` logs its arguments. Checks:
  - `no argument: usage, exit 2`: stderr contains `Usage: snaphatch`, exit status 2;
  - `unknown command: exit 2`: for `snaphatch frobnicate`;
  - `--help: exit 0`: stdout contains `Usage: snaphatch`;
  - `scan passes the name`: output is `scan-args:my doc`, for `snaphatch scan "my doc"`;
  - `works through the symlink`: the previous check, run through `$WORK/bin/snaphatch`;
  - `restart without scanner: no restart`: with the fake `is-active dev-scansnap.device` answering 3, there's no `restart` in the log, and the output contains `starts when you connect`;
  - `status: calls systemctl`: the log contains `--user status snaphatch.service`.
- [ ] **Step 2: Write the failing install checks in `test-install.sh`:**
  - `fresh: symlink resolves`: `[ "$(readlink -f "$WORK/keep/.local/bin/snaphatch")" = "$WORK/keep/.local/lib/snaphatch/snaphatch" ]`;
  - `fresh: warns when ~/.local/bin is not on PATH`: the install runs with a `PATH` without `$HOME/.local/bin`, and its output contains `is not on your PATH`;
  - in a run whose `PATH` includes `$WORK/keep/.local/bin`, the warning is absent.
- [ ] **Step 3: Run both suites.** Expected: FAIL, since `snaphatch` doesn't exist yet.
- [ ] **Step 4: Implement the dispatcher and the installer changes; remove the three recipes.**
- [ ] **Step 5: Run `just test`.** Expected: all six suites pass.
- [ ] **Step 6: Commit**: "Add the snaphatch command".

### Task 5: The migration in the installer, and uninstall

**Files:**
- Modify `justfile` `install`. Add the migration in the spec's order (section 3, steps 1–8), as helper functions inside the recipe:
  - `find_old_install`: sets `OLD_ENV_FILE`, `OLD_PAPERLESS_CONF`, `OLD_UNIT`, `OLD_SCRIPTS` (an array, ours only) and `OLD_RULES` (an array), plus `OLD_INBOX="$HOME/Documents/scanner-inbox"`.
  - `is_ours FILE`: returns 0 if `FILE` contains one of the two header lines in Global Constraints.
  - `remove_old_install`: section 3, step 5.
  - `move_old_data`: section 3, step 6. It uses `mv -n`, reports each skipped name, and runs `rmdir` on the emptied folders.
  - `print_summary`.

  Other changes:
  - Defaults are read from the new config if it exists; otherwise from `OLD_ENV_FILE`, then `OLD_PAPERLESS_CONF`. The kept lines come from the same file.
  - The stop at the start covers both `scan-button.service` and `snaphatch.service`. The existing trap starts whichever was active.
- Modify `justfile` `uninstall`:
  - remove the new install: the symlink, the lib directory, the unit and `99-snaphatch.rules`;
  - remove the old leftovers, scripts only if `is_ours`;
  - ask `Remove the config ~/.config/snaphatch/snaphatch.conf? [y/N]`;
  - never touch the data folders.
- Test: `tests/test-install.sh`.

**Interfaces:**
- Consumes:
  - `SNAPHATCH_KEYS`: the same list, hard-coded in the justfile, because the justfile can't source the lib file before installing it;
  - `documents_dir` (Task 3): the same logic, duplicated in the justfile.

- [ ] **Step 1: Write the failing scenarios in `test-install.sh`.** A helper `old_install RUN` creates:
  - `$WORK/RUN/.config/environment.d/scanner.conf` with `$API_CONFIG`, including `BLANK_THRESHOLD=0.05`;
  - `$WORK/RUN/.config/systemd/user/scan-button.service`;
  - `$WORK/RUN/udev/99-scansnap.rules` and `99-scansnap-ix500.rules`;
  - `$WORK/RUN/.local/bin/scan` and `scan-button-poll`, each with its header line from Global Constraints;
  - `…/Documents/scanner-inbox/failed/old-fail.pdf`, `…/removed/old-blank.jpg` and `…/scanner-inbox/old-local.pdf`.

  The fake `xdg-user-dir` prints `$HOME/Documents`. The fake `sudo` logs `rm` without running it. Scenarios and checks:
  - **`migrate`:** answers `$'\n'`.
    - `migration: values moved`: the new config has `PAPERLESS_CA=/etc/ca.pem` and `BLANK_THRESHOLD=0.05`, mode 600;
    - `migration: old config removed`: `environment.d/scanner.conf` doesn't exist;
    - `migration: session variables cleared`: the systemctl log has a line starting `--user unset-environment` that contains `PAPERLESS_TOKEN` and `BLANK_THRESHOLD`;
    - `migration: old unit removed`: `scan-button.service` doesn't exist, and the log contains `--user disable scan-button.service`;
    - `migration: old scripts removed`: neither `~/.local/bin/scan` nor `scan-button-poll` exists;
    - `migration: old rules removed`: the sudo log contains `rm -f $WORK/migrate/udev/99-scansnap.rules $WORK/migrate/udev/99-scansnap-ix500.rules`. The fake `sudo` only logs, so the files stay;
    - `migration: failed scans moved`: `Documents/snaphatch/failed/old-fail.pdf` exists, and the old one doesn't;
    - `migration: removed pages moved`: `.local/state/snaphatch/removed/old-blank.jpg` exists;
    - `migration: local scans left in place`: `scanner-inbox/old-local.pdf` still exists;
    - `migration: summary`: the output contains `Migrated from ix500-linux`.
  - **`migrate-again`:** a second `install` on the same home after `migrate`. Check `second run: nothing old found`: the output doesn't contain `Migrated from`, and the new config is byte-identical to the one after the first run (`cmp`).
  - **`foreign`:** `old_install`, but with `~/.local/bin/scan` replaced by `#!/bin/sh\necho other`. Check `migration: foreign scan left alone`: the file still exists with that content.
  - **`both-configs`:** `old_install`, plus a new config containing `PAPERLESS_URL=https://new.example`. Check `migration: new config wins over old`: the new config still has `https://new.example`, and `environment.d/scanner.conf` is gone.
  - **`clash`:** `old_install`, plus an existing `Documents/snaphatch/failed/old-fail.pdf` with the content `new`. Check `migration: name clash is skipped and kept`: both files still exist, the new one still contains `new`, and the output mentions `old-fail.pdf` as skipped.
  - **`migrate-abort`:** `old_install`, answers `$'n\n2\n\n\n\n'` (folder mode without a folder, so the install aborts), `FAKE_ACTIVE=0`. Check `abort: old install intact`: the old config, unit and scripts exist, the systemctl log contains `--user start --no-block scan-button.service`, and there's no `rm` in the sudo log.
- [ ] **Step 2: Write the failing uninstall scenario.** `uninstall` runs `just uninstall` with `$'n\n'` after a fresh install. Check `uninstall: keeps config when declined`: the config exists, and the lib directory and symlink don't.
- [ ] **Step 3: Run `bash tests/test-install.sh`.** Expected: FAIL on the new scenarios.
- [ ] **Step 4: Implement the helpers and the order of steps; then rewrite `uninstall`.**
- [ ] **Step 5: Run `just test`.** Expected: all suites pass, and the old scenarios are unchanged.
- [ ] **Step 6: Commit**: "Migrate old installs automatically in just install".

### Task 6: The "Show" button for removed blank pages

**Files:**
- Modify `snaphatch-poll`:
  - add `removed_dir`;
  - the success branch adds `--action="show=Show"` when it's non-empty;
  - `[ "$ACTION" = "show" ] && xdg-open "$REMOVED_DIR"` in each of the three mode branches.
- Test: `tests/test-poll.sh`.

**Interfaces:**
- Produces: `removed_dir SCAN_OUTPUT`. It prints `<dir>` from the last line matching `^Removed [0-9]+ blank page\(s\), kept in (.*)$`, or nothing.

- [ ] **Step 1: Write the failing tests:**
  - `removed: folder from the line`: for `$'Scanned 6 page(s)\nRemoved 3 blank page(s), kept in /home/me/.local/state/snaphatch/removed\nDone: a.pdf (3 pages, 1M)'`, it prints `/home/me/.local/state/snaphatch/removed`;
  - `removed: path with spaces`: a folder with spaces is kept whole;
  - `removed: nothing when none removed`: empty for output without a `Removed` line.
- [ ] **Step 2: Run `bash tests/test-poll.sh`.** Expected: FAIL, since `removed_dir` isn't defined.
- [ ] **Step 3: Implement `removed_dir` and the action.**
- [ ] **Step 4: Run `just test`.** Expected: all suites pass.
- [ ] **Step 5: Commit**: "Offer Show on Scan Complete when blank pages were removed".

### Task 7: Docs

**Files:**
- Modify `README.md`:
  - title and introduction use snaphatch;
  - installation;
  - usage: `snaphatch scan`, `status`, `logs`, `restart`;
  - configuration: the new path, mode 600, no logout needed;
  - the paths of `failed/` and `removed/`;
  - a "Moving from ix500-linux" section describing what `just install` migrates and that local-mode scans stay in `~/Documents/scanner-inbox/`;
  - credits unchanged.
- Modify `CLAUDE.md`:
  - every name, path and command;
  - the "Config changes need a fresh environment" bullet becomes "the service and the scripts read the config file at every start";
  - the tests bullet lists `test-cli.sh`;
  - the unit description says `EnvironmentFile=`.
- Modify `justfile`: the recipe comments and the uninstall message.

- [ ] **Step 1: Run `grep -rn -i 'ix500-linux\|scanner-inbox\|scanner\.conf\|environment\.d\|scan-button\|\bjust \(status\|logs\|restart\)\b' README.md CLAUDE.md justfile`.** Note every hit.
- [ ] **Step 2: Edit the docs.** The only hits left should be the migration descriptions: README "Moving from ix500-linux", the migration code in the justfile, and the CLAUDE.md note on migration.
- [ ] **Step 3: Run the grep again and `just test`.** Expected: only the intended migration hits remain, and all suites pass.
- [ ] **Step 4: Commit**: "Document the snaphatch command, paths and migration".

### After Task 7

- Push `rename/snaphatch`, and open a PR whose description states the intent from the spec's "Goal", lists the seven commits, and includes the hardware test checklist from the spec.
- **Hardware test before merging:** the user runs `just install` on their existing install, then the checklist from the spec, section 4.
