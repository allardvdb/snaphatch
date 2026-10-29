# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

One-button scanning workflow for Fujitsu ScanSnap scanners on Linux. Press the hardware button, get a PDF. Supports three delivery modes: upload to Paperless-ngx via API, write to a Paperless consume folder, or local OCR via ocrmypdf. Pure bash scripts orchestrated by a `justfile`.

The project name is a historical artifact — it started as iX500-specific, but now auto-detects any ScanSnap model supported by the SANE `fujitsu` backend. Scanner detection matches `fujitsu:ScanSnap [^:]+:\d+` across `scanimage -L` output, and the udev rule matches USB vendor `04c5` + product string containing "ScanSnap".

## Architecture

The system has four components forming a hardware-to-PDF pipeline:

1. **`99-scansnap.rules`** — Udev rule template that auto-starts the systemd user service when any ScanSnap (USB vendor `04c5`, product string matching `*ScanSnap*`) is plugged in, and stops it on disconnect. Contains a `__USERNAME__` placeholder that `just install` substitutes with the invoking user — do not install this file by hand.
2. **`scan-button.service`** — Systemd user service that runs the polling script; restarts on failure with 5s delay
3. **`scan-button-poll`** — Bash script polling the scanner button every 0.1s via `scanimage -A`; triggers `scan` on press with 3s debounce; sends clickable desktop notifications (open Paperless/file on success, view logs on failure)
4. **`scan`** — Bash script that drives the actual scanning: duplex TIFF capture at 300 DPI with bleed margin → blank page removal (ink coverage after a 50% threshold, so bleed-through does not count) → optional per-page color/grayscale detection (chroma) → JPEG-compressed PDF via ImageMagick → delivery via API upload, consume folder, or local OCR. Removed blank pages are saved as JPEG in `~/Documents/scanner-inbox/removed/` and pruned after 30 days. Its page-processing functions (`is_blank`, `is_color`, `make_pdf`, `paperless_curl`) sit above `main`, which only runs when the file is executed, not sourced

**Output coupling:** `scan-button-poll` builds its notifications by parsing `scan`'s stdout: the `Done: <path> (<N> pages, <size>)` line (file to open; the path may contain spaces), the `Removed N blank page(s)` line, and on failure the last line starting with `Error:`, `Upload failed` or `No pages`. Changing those messages in `scan` breaks the notifications; `tests/test-poll.sh` covers the parsing.

**Notification ownership:** when `scan-button-poll` runs `scan`, it exports `NOTIFY_ID` (the ID of its "Starting scan…" popup, possibly empty) and sends the final notification itself; `scan` only replaces that popup with progress stages. A standalone `scan` run creates its own popup and replaces it with a final, expiring notification on exit. Progress updates must not use `-u low`: GNOME never shows low-urgency banners and keeps the old urgency for the notification that replaces them.

### Three modes

Determined automatically by environment variables:

- **Paperless API mode** (`PAPERLESS_URL` + `PAPERLESS_TOKEN` set): Creates PDF with ImageMagick, uploads (TLS verified; `PAPERLESS_CA` for a private CA; no `created` field, so Paperless takes the document date from the content) to Paperless-ngx via `POST /api/documents/post_document/`. Paperless handles OCR, archiving, etc.
- **Paperless folder mode** (`PAPERLESS_CONSUME_DIR` set): Creates PDF with ImageMagick, writes directly to the Paperless consume folder. Paperless picks it up from there.
- **Local mode** (none of the above set): Runs `ocrmypdf` with Dutch+English OCR, saves to `~/Documents/scanner-inbox/`

### Configuration

All scanner settings are stored in `~/.config/environment.d/scanner.conf` so they're available to both the shell and systemd user services.

Environment variables (the installer only manages the first five plus `PAPERLESS_CONSUME_DIR`; `BLANK_THRESHOLD` and `JPEG_QUALITY` are added by hand, and the installer keeps any line it doesn't manage, including comments, and pushes those settings to the service too):
- `SCANNER_DEVICE` — SANE device string (detected at install time, falls back to auto-detect if unset)
- `COLOR_DETECT` — `true` (default) or `false`; whether to auto-detect color vs grayscale per page
- `PAPERLESS_URL` — Paperless-ngx base URL (API mode)
- `PAPERLESS_TOKEN` — Paperless-ngx API token (API mode)
- `PAPERLESS_CA` — CA certificate file for TLS verification (API mode, optional)
- `BLANK_THRESHOLD` — ink coverage % below which a page is blank (default `0.02`)
- `JPEG_QUALITY` — JPEG quality of the PDF pages (default `85`)
- `PAPERLESS_CONSUME_DIR` — Path to Paperless consume folder (folder mode)

## Usage

All operations are run via `just`:

| Command | Description |
|---|---|
| `just` | List available recipes |
| `just install` | Full interactive install (mode selection, scanner detection, config, activate) |
| `just check` | Check dependencies for all modes |
| `just test` | Run the page-processing, upload, poll-parsing and installer tests (no scanner, network or root needed) |
| `just status` | Show service status |
| `just logs` | Follow service logs |
| `just restart` | Restart the service |
| `just uninstall` | Remove installed files, service, and udev rules |

## Development

- **The service runs installed copies.** `just install` copies `scan` and `scan-button-poll` to `~/.local/bin/`. Edits in the repo only take effect after re-running `just install` (or copying the scripts there), then `just restart`.
- **Config changes need a fresh environment.** `environment.d` is only read at login; the installer also pushes values with `systemctl --user set-environment`. After editing `scanner.conf` by hand, re-run `just install` (keeping the current values), push them yourself, or log out and in.
- **The installer stops the service** while it detects the scanner (the poll loop makes `scanimage -L` return nothing), and an `EXIT` trap starts it again if the install stops early, but only if it was running before.
- **Tests:** `just test` runs all four suites; run one with `bash tests/test-scan.sh`, `bash tests/test-upload.sh`, `bash tests/test-poll.sh` or `bash tests/test-install.sh`. `test-scan.sh` sources `scan` and checks the page functions on synthetic ImageMagick pages. `test-upload.sh` runs `scan` end-to-end in API mode with fake `scanimage`, `curl` and `notify-send` put first on `PATH` (standalone, as if started by the poll script, and with a failed upload), and inspects the curl, scanimage and notify-send arguments. `test-poll.sh` sources `scan-button-poll`, which then stops after defining its functions, and checks its output parsing. `test-install.sh` runs `just install` with scripted answers against a temporary `HOME`, with fake `systemctl`, `sudo`, `udevadm`, `scanimage`, `lsusb` and `curl` first on `PATH` (it refuses to run if a real `systemctl` or `sudo` would be used), and checks the written config, the pushed environment and the service restarts. Tests need `magick` and `pdfimages` (poppler-utils).
- **Manual scan:** `scan [name]` writes `name.pdf` (default `scan-YYYY-MM-DD-HHMMSS`).

## Installation

```bash
just install
```

The interactive installer detects the scanner, asks for mode and preferences, configures settings, installs files, and activates the service. If upgrading from an older install with `paperless.conf`, the installer migrates settings automatically.

## Dependencies

**Build/install:**
- **just** — task runner (`just install`, `just check`, etc.)

**Both modes:**
- **SANE** (`scanimage`) — scanner driver interface
- **ImageMagick** (`magick`) — image manipulation and color analysis
- **notify-send**, **xdg-open**, **xdg-terminal-exec** — desktop notifications

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
| Scan resolution | 300 DPI | `scan` |
| Bleed margin | 10 mm | `scan` |
| Blank page threshold | 0.02% ink below 50% gray | `scan` (`BLANK_THRESHOLD`) |
| Ignored border (blank/color detection) | 3% per side | `scan` (`SHAVE`) |
| Removed blank pages kept | 30 days | `scan` (`REMOVED_KEEP_DAYS`) |
| PDF page compression | JPEG, quality 85 | `scan` (`JPEG_QUALITY`) |
| Color detection | `COLOR_DETECT` env var (default: true) | `scanner.conf` / `scan` |
| Color threshold | >0.5% of pixels with >15% chroma | `scan` |
| Button poll interval | 0.1s | `scan-button-poll` |
| Debounce period | 3s | `scan-button-poll` |
| OCR languages | `nld+eng` | `scan` (local mode only) |
| ocrmypdf JPEG quality | 60 | `scan` (local mode only) |

## Conventions

- The `scan` script uses `WORKDIR` (not `TMPDIR`) for its temp directory to avoid shadowing the standard env var.
- Color/grayscale detection runs in both Paperless and local modes when enabled — it reduces upload/file size.
- When `COLOR_DETECT=false`, all pages are converted to grayscale (no ImageMagick analysis).
- Local-mode OCR deliberately avoids lossy JBIG2: it can swap look-alike digits in amounts.
- API uploads must not send a `created` field; `tests/test-upload.sh` guards this.
- All dependencies are in `/usr/bin`; no Homebrew paths needed in the service file.
- `scan-button-poll` resolves the `scan` script path relative to its own location via `BASH_SOURCE`.
- Scanner detection in both `scan` and `scan-button-poll` uses the regex `fujitsu:ScanSnap [^:]+:\d+` so any ScanSnap model is matched; the installer lists all detected devices and asks the user to pick when more than one is present.
- `scan` probes `scanimage -A` per run and only passes options the specific scanner exposes (via a `has_opt` helper). The iX500 has `--overscan`/`--prepick` but the S1500 does not — setting those on an S1500 produces a "readonly option" warning. Keep this probe in place when adding new scan options.
- On failure, `scan-button-poll`'s "View Logs" notification action opens a terminal wrapped in `sh -c '…; printf "Press Enter…"; read -r _'` — without the trailing `read`, the terminal exits before the user can see anything. Keep it POSIX: `/bin/sh` is dash on Debian/Ubuntu, where `read -rp` fails.

## Platform

Developed on Bluefin (Fedora Silverblue). Git commits are signed with a FIDO security key.
