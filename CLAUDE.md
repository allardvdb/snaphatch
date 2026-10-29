# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

snaphatch: one-button scanning for Fujitsu ScanSnap scanners on Linux. Press the hardware button, get a PDF. Supports three delivery modes: upload to Paperless-ngx via API, write to a Paperless consume folder, or local OCR via ocrmypdf. Pure bash scripts orchestrated by a `justfile`.

It was called ix500-linux until it grew beyond the iX500; it auto-detects any ScanSnap model supported by the SANE `fujitsu` backend. Scanner detection matches `fujitsu:ScanSnap [^:]+:\d+` across `scanimage -L` output, and the udev rule matches USB vendor `04c5` + product string containing "ScanSnap". `just install` migrates an ix500-linux install (see Installation).

## Architecture

The system has these components forming a hardware-to-PDF pipeline. The scripts are installed together in `~/.local/lib/snaphatch/`; only `~/.local/bin/snaphatch` (a symlink) is on `PATH`.

1. **`99-snaphatch.rules`** — Udev rule that tags any ScanSnap (USB vendor `04c5`, product string matching `*ScanSnap*`) for systemd, gives it the alias `/dev/scansnap` and sets `SYSTEMD_USER_WANTS=snaphatch.service`, so every logged-in user's manager starts the service when it is connected. No `RUN` and no user name. It deliberately has no `ACTION=="add"`: a rule that sets `TAG+="systemd"` must also match "change" events, or the device unit disappears after the first one
2. **`snaphatch.service`** — Systemd user service that runs `snaphatch-poll`; restarts on failure with 5s delay. It reads the config with `EnvironmentFile=`. `BindsTo=dev-scansnap.device` stops it when the scanner is disconnected. It has no `[Install]` section: udev starts it, also at login when the scanner is already connected. Starting or restarting it without a scanner connected waits up to 90s for the device, so `just install` and `snaphatch restart` check `dev-scansnap.device` first
3. **`snaphatch-poll`** — Bash script polling the scanner button every 0.1s via `scanimage -A`; runs `snaphatch-scan` on press with 3s debounce; sends clickable desktop notifications (open Paperless/file on success, "Show" for removed blank pages, view logs and "Open folder" on failure). Without `SCANNER_DEVICE` it retries detection for ~30s, then exits 0 (so `Restart=on-failure` doesn't loop) when no ScanSnap the fujitsu backend supports is found, e.g. an epjitsu model
4. **`snaphatch-scan`** — Bash script that drives the actual scanning: duplex TIFF capture at 300 DPI with bleed margin → blank page removal (ink coverage after a 50% threshold, so bleed-through does not count) → optional per-page color/grayscale detection (chroma) → JPEG-compressed PDF via ImageMagick → delivery via API upload, consume folder, or local OCR. Removed blank pages are saved as JPEG in `~/.local/state/snaphatch/removed/` and pruned after 30 days. A scan is never lost: when it can't be delivered (scanimage fails after one or more pages, e.g. a jam; a failed upload; an unwritable consume folder; failed OCR), `keep_failed` puts a PDF in `<documents>/snaphatch/failed/` (never pruned) and the error line says where. A partial scan after a jam is not delivered. Its page-processing functions (`is_blank`, `is_color`, `make_pdf`, `paperless_curl`, `documents_dir`) sit above `main`, which only runs when the file is executed, not sourced
5. **`snaphatch`** — The command: `scan [name]` runs `snaphatch-scan`; `status`, `logs` and `restart` wrap `systemctl`/`journalctl` for `snaphatch.service`. It finds the other scripts next to itself through `readlink -f`, so it works through the symlink
6. **`snaphatch-config.sh`** — Sourced by `snaphatch-scan` and `snaphatch-poll`: `load_config` parses the config file (never sources it), exporting only known keys that aren't already set in the environment

**Output coupling:** `snaphatch-poll` builds its notifications by parsing `snaphatch-scan`'s stdout: the `Done: <path> (<N> pages, <size>)` line (file to open; the path may contain spaces), the `Removed N blank page(s), kept in <dir>` line (count and "Show" folder), and on failure the last line starting with `Error:`, `Upload failed` or `No pages`, plus `; scan kept as <path>` for "Open folder". Changing those messages breaks the notifications; `tests/test-poll.sh` covers the parsing.

**Notification ownership:** when `snaphatch-poll` runs `snaphatch-scan`, it exports `NOTIFY_ID` (the ID of its "Starting scan…" popup, possibly empty) and sends the final notification itself; `snaphatch-scan` only replaces that popup with progress stages. A standalone run creates its own popup and replaces it with a final, expiring notification on exit. Progress updates must not use `-u low`: GNOME never shows low-urgency banners and keeps the old urgency for the notification that replaces them.

### Three modes

Determined automatically by the settings:

- **Paperless API mode** (`PAPERLESS_URL` + `PAPERLESS_TOKEN` set): Creates PDF with ImageMagick, uploads (TLS verified; `PAPERLESS_CA` for a private CA; no `created` field, so Paperless takes the document date from the content) to Paperless-ngx via `POST /api/documents/post_document/`. Paperless handles OCR, archiving, etc.
- **Paperless folder mode** (`PAPERLESS_CONSUME_DIR` set): Creates PDF with ImageMagick, writes directly to the Paperless consume folder. Paperless picks it up from there.
- **Local mode** (none of the above set): Runs `ocrmypdf` with Dutch+English OCR, saves to `<documents>/snaphatch/`

### Locations

| What | Where |
|---|---|
| Config | `${XDG_CONFIG_HOME:-~/.config}/snaphatch/snaphatch.conf` (mode 600; `SNAPHATCH_CONFIG` overrides) |
| Local-mode output | `<documents>/snaphatch/` |
| Undeliverable scans | `<documents>/snaphatch/failed/` |
| Removed blank pages | `${XDG_STATE_HOME:-~/.local/state}/snaphatch/removed/` |
| Working pages | `${XDG_CACHE_HOME:-~/.cache}/snaphatch/scan.XXXXXX/` (removed after each scan) |

`<documents>` is `xdg-user-dir DOCUMENTS`, or `~/Documents` when that's missing or answers `$HOME`.

### Configuration

The config file holds plain `KEY=value` lines (valid for systemd's `EnvironmentFile=`). Known keys (the installer manages the first six; `BLANK_THRESHOLD` and `JPEG_QUALITY` are added by hand, and the installer keeps any line it doesn't manage, including comments):
- `SCANNER_DEVICE` — SANE device string (detected at install time, falls back to auto-detect if unset)
- `COLOR_DETECT` — `true` (default) or `false`; whether to auto-detect color vs grayscale per page
- `PAPERLESS_URL` — Paperless-ngx base URL (API mode)
- `PAPERLESS_TOKEN` — Paperless-ngx API token (API mode)
- `PAPERLESS_CA` — CA certificate file for TLS verification (API mode, optional)
- `PAPERLESS_CONSUME_DIR` — Path to Paperless consume folder (folder mode)
- `BLANK_THRESHOLD` — ink coverage % below which a page is blank (default `0.02`)
- `JPEG_QUALITY` — JPEG quality of the PDF pages (default `85`)

A value already in the environment wins over the file (`PAPERLESS_URL=… snaphatch scan`). The key list lives in `snaphatch-config.sh` (`SNAPHATCH_KEYS`) and, because the installer runs before that file is installed, again in the justfile.

## Usage

Day to day, through the installed command:

| Command | Description |
|---|---|
| `snaphatch scan [name]` | Scan now (`name.pdf`, default `scan-YYYY-MM-DD-HHMMSS`) |
| `snaphatch status` | Show service status |
| `snaphatch logs` | Follow service logs |
| `snaphatch restart` | Restart the service (only when the scanner is connected) |

From the repository, via `just`:

| Command | Description |
|---|---|
| `just` | List available recipes |
| `just install` | Full interactive install (mode selection, scanner detection, config, activate, migration) |
| `just check` | Check dependencies for all modes |
| `just test` | Run all test suites (no scanner, network or root needed) |
| `just uninstall` | Remove snaphatch and any ix500-linux leftovers; asks before removing the config; keeps scans |

## Development

- **The service runs installed copies.** `just install` copies the scripts to `~/.local/lib/snaphatch/`. Edits in the repo only take effect after re-running `just install` (or copying the scripts there), then `snaphatch restart`.
- **Config changes:** `snaphatch-scan` reads the config file on every run; the service reads it (`EnvironmentFile=`) when it starts, so run `snaphatch restart` after editing it. Nothing is pushed into the session environment, and no logout is needed.
- **The installer stops the service** while it detects the scanner (the poll loop makes `scanimage -L` return nothing), and an `EXIT` trap starts it again if the install stops early, but only if it was running before. During a migration that is the old `scan-button.service`: the old install is removed only after the new one is in place.
- **Tests:** `just test` runs all five suites; run one with `bash tests/test-<name>.sh`. `test-scan.sh` sources `snaphatch-scan` (with `SNAPHATCH_CONFIG` pointing nowhere) and checks the page functions on synthetic ImageMagick pages. `test-upload.sh` runs `snaphatch-scan` end-to-end with fake `scanimage`, `curl`, `notify-send`, `systemctl`, `ocrmypdf` and `xdg-user-dir` first on `PATH` and temporary XDG directories, and checks curl, scanimage and notify-send arguments, the config file, the paths, kept scans and the manual-scan pause. `test-poll.sh` sources `snaphatch-poll`, which then stops after defining its functions, and checks its output parsing. `test-install.sh` runs `just install` and `just uninstall` with scripted answers against a temporary `HOME` and `SNAPHATCH_UDEV_DIR`, with fake `systemctl`, `sudo`, `udevadm`, `scanimage`, `lsusb` and `curl` first on `PATH` (it refuses to run if a real one would be used; the fake `sudo` only runs `rm` inside the test directory), including the migration from an ix500-linux install. `test-cli.sh` checks the `snaphatch` dispatcher. Tests need `magick` and `pdfimages` (poppler-utils).
- **Manual scan:** the poll loop holds the scanner, so a manual run stops `snaphatch.service` while it scans and starts it again from the `EXIT` trap. It never does this when the service itself runs `snaphatch-scan` (inherited `NOTIFY_ID`, or its own cgroup is the service's), since stopping the service would kill the scan.

## Installation

```bash
just install
```

The interactive installer detects the scanner, asks for mode and preferences, writes the config, installs the scripts, unit and udev rule, and activates the service. On an ix500-linux install it migrates automatically: settings from `~/.config/environment.d/scanner.conf` (then removed, and its variables cleared with `systemctl --user unset-environment`), removal of `scan-button.service`, the old `~/.local/bin/scan` and `scan-button-poll` (only if they carry our header line) and `99-scansnap*.rules`, and moving `~/Documents/scanner-inbox/failed/` and `removed/` without overwriting. Earlier local-mode scans stay in `~/Documents/scanner-inbox/`.

## Dependencies

**Build/install:**
- **just** — task runner (`just install`, `just check`, etc.)

**All modes:**
- **SANE** (`scanimage`) — scanner driver interface
- **ImageMagick** (`magick`) — image manipulation and color analysis
- **notify-send**, **xdg-open**, **xdg-terminal-exec** — desktop notifications
- **xdg-user-dir** (optional) — the documents folder; `~/Documents` without it

**Local mode only:**
- **ocrmypdf** — OCR and PDF creation
- **Tesseract** with `nld` and `eng` trained data

**Paperless API mode only:**
- **curl** — API upload

**Tests only:**
- **pdfimages** (poppler-utils)

## Key Parameters

| Parameter | Value | Location |
|---|---|---|
| Scan resolution | 300 DPI | `snaphatch-scan` |
| Bleed margin | 10 mm | `snaphatch-scan` |
| Blank page threshold | 0.02% ink below 50% gray | `snaphatch-scan` (`BLANK_THRESHOLD`) |
| Ignored border (blank/color detection) | 3% per side | `snaphatch-scan` (`SHAVE`) |
| Removed blank pages kept | 30 days | `snaphatch-scan` (`REMOVED_KEEP_DAYS`) |
| Undeliverable scans kept | until deleted by hand | `snaphatch-scan` (`FAILED_DIR`) |
| Upload timeouts | 10s to connect, 300s in total | `snaphatch-scan` (`paperless_curl`) |
| PDF page compression | JPEG, quality 85 | `snaphatch-scan` (`JPEG_QUALITY`) |
| Color detection | `COLOR_DETECT` (default: true) | `snaphatch.conf` / `snaphatch-scan` |
| Color threshold | >0.5% of pixels with >15% chroma | `snaphatch-scan` |
| Button poll interval | 0.1s | `snaphatch-poll` |
| Debounce period | 3s | `snaphatch-poll` |
| OCR languages | `nld+eng` | `snaphatch-scan` (local mode only) |
| ocrmypdf JPEG quality | 60 | `snaphatch-scan` (local mode only) |

## Conventions

- `snaphatch-scan` uses `WORKDIR` (not `TMPDIR`) for its temp directory to avoid shadowing the standard env var.
- `snaphatch-scan` loads the config before its defaults (`BLANK_THRESHOLD`, `JPEG_QUALITY`), which would otherwise shadow the file's values.
- Color/grayscale detection runs in both Paperless and local modes when enabled — it reduces upload/file size.
- When `COLOR_DETECT=false`, all pages are converted to grayscale (no ImageMagick analysis).
- Local-mode OCR deliberately avoids lossy JBIG2: it can swap look-alike digits in amounts.
- API uploads must not send a `created` field; `tests/test-upload.sh` guards this.
- All dependencies are in `/usr/bin`; no Homebrew paths needed in the service file.
- The scripts find each other relative to their own location (`BASH_SOURCE`, `readlink -f` in the dispatcher).
- Scanner detection in both `snaphatch-scan` and `snaphatch-poll` uses the regex `fujitsu:ScanSnap [^:]+:\d+` so any ScanSnap model is matched; the installer lists all detected devices and asks the user to pick when more than one is present.
- `snaphatch-scan` probes `scanimage -A` per run and only passes options the specific scanner exposes (via a `has_opt` helper). The iX500 has `--overscan`/`--prepick` but the S1500 does not — setting those on an S1500 produces a "readonly option" warning. Keep this probe in place when adding new scan options.
- On failure, `snaphatch-poll`'s "View Logs" notification action opens a terminal wrapped in `sh -c '…; printf "Press Enter…"; read -r _'` — without the trailing `read`, the terminal exits before the user can see anything. Keep it POSIX: `/bin/sh` is dash on Debian/Ubuntu, where `read -rp` fails.

## Platform

Developed on Bluefin (Fedora Silverblue). Commits on feature branches are unsigned; PRs are squash-merged on GitHub, which signs the resulting commit on `master`.
