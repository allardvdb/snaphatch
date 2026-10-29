# snaphatch

One-button scanning workflow for Fujitsu ScanSnap scanners on Linux.

Press the scanner button → get a PDF. That's it. snaphatch passes your scans on to [Paperless-ngx](https://docs.paperless-ngx.com/) (or to a folder) instead of keeping them, like a serving hatch.

Formerly **ix500-linux**; see [Moving from ix500-linux](#moving-from-ix500-linux) if you installed it under that name.

Originally written for the [ScanSnap iX500](https://www.fujitsu.com/global/products/computing/peripheral/scanners/scansnap/ix500/), but the scripts and udev rule auto-detect any ScanSnap model supported by the SANE `fujitsu` backend (iX500, S1500, etc.).

## Why snaphatch

I ran a paperless office on my MacBook: ScanSnap Home scanned from the iX500 into DEVONthink. When I moved that workflow to Linux and migrated my DEVONthink library into [Paperless-ngx](https://docs.paperless-ngx.com/), there was no ScanSnap Home for Linux, so the scanner's button did nothing. I needed something that would munch whatever is in the iX500 when I press the button and drop it into Paperless.

snaphatch does exactly that and nothing more: it scans, cleans up (blank pages out, colour only where it's needed, small PDFs) and passes the result on. Like a serving hatch, it keeps nothing itself: Paperless (or a folder) does the OCR and the archiving.

## Features

- **One-button scanning** - press the hardware button, get a PDF
- **Duplex A4 color** - scans both sides automatically
- **Smart blank detection** - removes empty back pages, also when the other side shows through
- **Auto color/grayscale** - converts B&W pages to grayscale for smaller files
- **Compact PDFs** - JPEG-compressed pages (~1.5 MB per page instead of ~33 MB uncompressed)
- **Three output modes** - upload to [Paperless-ngx](https://docs.paperless-ngx.com/) via API, write to a Paperless consume folder, or save locally with OCR
- **Clickable notifications** - open the result directly from the notification
- **Runs only while the scanner is connected** - udev starts the button service when you plug the scanner in, systemd stops it when you unplug it

### Paperless-ngx API mode (recommended)
When `PAPERLESS_URL` and `PAPERLESS_TOKEN` are set, scans are uploaded directly to Paperless-ngx via its API. Paperless handles OCR, archiving and search. Paperless keeps the uploaded original unchanged, so the PDF is compressed before upload. No created date is sent: Paperless takes the date from the document itself.

### Paperless-ngx folder mode
When `PAPERLESS_CONSUME_DIR` is set, scans are written directly to the Paperless consume folder. Paperless picks them up from there.

### Local mode
Without Paperless configured, scans are processed locally with ocrmypdf (Dutch + English OCR, auto-rotate, deskew, cleanup) and saved to `~/Documents/snaphatch/` (your documents folder, as set by `xdg-user-dir`).

## Requirements

- **just** - task runner
- **sane-backends** (`scanimage`) - scanner driver
- **ImageMagick** (`magick`) - image processing and PDF creation
- **libnotify** (`notify-send`), **xdg-utils** (`xdg-open`), **xdg-terminal-exec** - desktop notifications

Local mode only:
- **ocrmypdf** - OCR and PDF creation
- **tesseract** with `nld` and `eng` language data

Paperless API mode only:
- **curl** - API upload

Tests only:
- **pdfimages** (poppler-utils)

Run `just check` to see which dependencies are installed, and `just test` to run the tests.

## Installation

```bash
just install
```

The interactive installer detects the scanner, asks for mode and preferences, configures settings, installs files, and activates the service. Re-running it offers to keep the current settings; it still checks that the saved scanner is connected and lets you choose again if it isn't.

It installs:

| What | Where |
|---|---|
| The `snaphatch` command | `~/.local/bin/snaphatch` (a symlink) |
| The scripts | `~/.local/lib/snaphatch/` |
| The button service | `~/.config/systemd/user/snaphatch.service` |
| The udev rule | `/etc/udev/rules.d/99-snaphatch.rules` (needs `sudo`) |
| Your settings | `~/.config/snaphatch/snaphatch.conf` |

`~/.local/bin` must be on your `PATH`; the installer warns if it isn't.

### Moving from ix500-linux
snaphatch was called ix500-linux before. Running `just install` on an ix500-linux install moves it over automatically:

- your settings move from `~/.config/environment.d/scanner.conf` to `~/.config/snaphatch/snaphatch.conf`, including lines you added by hand;
- the old `scan-button.service`, `scan` and `scan-button-poll` scripts and `99-scansnap.rules` are removed (a different program called `scan` is left alone);
- scans in `~/Documents/scanner-inbox/failed/` and pages in `removed/` move to their new places below, without overwriting anything;
- earlier local-mode scans stay in `~/Documents/scanner-inbox/`.

The old install keeps working until the new one is in place, so an interrupted install leaves it as it was. Apps that were already running keep the old settings in their environment until you next log out.

## Usage

### One-button scanning
1. Put documents in the feeder
2. Press the blue Scan button on the scanner
3. Wait for desktop notification "Scan Complete"
4. Click the notification to open the result

### Manual scanning
```bash
snaphatch scan                  # Auto-named: scan-YYYY-MM-DD-HHMMSS.pdf
snaphatch scan my-document      # Custom name: my-document.pdf
```

While the button service is running, it keeps the scanner busy, so a manual scan pauses the service and starts it again when it's done.

### Service management
```bash
snaphatch status    # Show service status
snaphatch logs      # Follow service logs
snaphatch restart   # Restart the service
```

From the repository: `just uninstall` removes snaphatch (it asks before removing your settings; your scans stay).

## Configuration

Settings are stored in `~/.config/snaphatch/snaphatch.conf` (managed by `just install`, readable by you only, as it holds the Paperless token). `snaphatch scan` reads it every time, so a change applies to the next manual scan at once; the button service reads it when it starts, so run `snaphatch restart` after a change. No logging out is needed. Settings you add by hand, such as `BLANK_THRESHOLD`, are kept when you re-run the installer. A value set in the environment, such as `PAPERLESS_URL=… snaphatch scan`, wins over the file.

| Variable | Description |
|---|---|
| `SCANNER_DEVICE` | SANE device string (auto-detected if unset) |
| `COLOR_DETECT` | `true` (default) or `false` — auto-detect color vs grayscale per page |
| `PAPERLESS_URL` | Paperless-ngx base URL (API mode) |
| `PAPERLESS_TOKEN` | Paperless-ngx API token (API mode) |
| `PAPERLESS_CA` | CA certificate file for a Paperless behind a private CA, such as Caddy's internal CA (API mode, optional; system trust if unset) |
| `PAPERLESS_CONSUME_DIR` | Path to Paperless consume folder (folder mode) |
| `BLANK_THRESHOLD` | Ink coverage (% of the page) below which a page counts as blank (default `0.02`) |
| `JPEG_QUALITY` | JPEG quality of the PDF pages (default `85`) |

### Scanner options (in `snaphatch-scan`, only those the connected scanner supports)

| Option | Value | Purpose |
|--------|-------|---------|
| `--swcrop` | yes | Auto-crop borders |
| `--swdespeck` | 2 | Remove small artifacts |
| `--overscan` | On | Better feed handling |
| `--prepick` | On | Pre-pick next page (faster) |
| `--buffermode` | On | Faster processing |

### OCR options (local mode only, in `snaphatch-scan`)

| Option | Value | Purpose |
|--------|-------|---------|
| `-l` | nld+eng | Languages (Dutch + English) |
| `--rotate-pages-threshold` | 2 | Aggressive rotation fix |
| `-O` | 3 | Maximum optimization |
| `--jpeg-quality` | 60 | Good compression |

Lossy JBIG2 is deliberately not used: it can swap look-alike characters, such as digits in amounts.

### Blank page detection
The scanner's own blank-page skip (`--swskip`) counts all darkish pixels, so text showing through from the other side makes a blank back look like a page. Instead, snaphatch turns each page into hard black and white at 50% gray, which drops the light gray bleed-through, and removes pages with less than `BLANK_THRESHOLD` (0.02%) ink. A 3% border is ignored to skip edge shadows. A page of text has a few percent ink; a signature alone is around 0.07%.

Removed pages are kept as JPEG in `~/.local/state/snaphatch/removed/` for 30 days. The "Scan Complete" notification says how many were removed, and its "Show" button opens that folder.

### Scans that can't be delivered
A scan is never thrown away. If the upload to Paperless fails or times out, the consume folder can't be written, OCR fails, or the scanner stops with an error partway through (such as a paper jam), the scan is saved as a PDF in `~/Documents/snaphatch/failed/`. The "Scan Failed" notification says why and where, and has an "Open folder" button. A partial scan after a jam is not delivered, so you can rescan the whole document. These files are not deleted automatically.

### Color detection
A page counts as color when more than 0.5% of its pixels have over 15% chroma; other pages are converted to grayscale. Chroma is used rather than HSL saturation, because near-white paper with a faint tint has a high HSL saturation.

## How it works

```
┌─────────────┐     ┌──────────────┐     ┌─────────────────┐
│  Button     │────▶│ snaphatch-   │────▶│ snaphatch-scan  │
│  pressed    │     │ poll         │     │                 │
└─────────────┘     └──────────────┘     └─────────────────┘
                                                  │
                    ┌─────────────────────────────┘
                    ▼
┌─────────────┐     ┌──────────────┐     ┌─────────────────┐
│  scanimage  │────▶│ ImageMagick  │────▶│ Paperless API / │
│  (SANE)     │     │ (PDF)        │     │ folder / OCR    │
└─────────────┘     └──────────────┘     └─────────────────┘
```

1. **Button poll service** checks scanner button every 100ms
2. **scanimage** captures duplex color TIFF pages
3. **ImageMagick** removes blank pages, detects color vs grayscale, creates a JPEG-compressed PDF
4. Delivery: **Paperless API** upload, **Paperless folder** write, or local **ocrmypdf**
5. **Clickable notification** confirms completion

## Tested on

- **OS**: [Bluefin](https://projectbluefin.io/) (Fedora Silverblue based)
- **Scanners**: Fujitsu ScanSnap iX500, ScanSnap S1500
- **SANE**: sane-backends with fujitsu driver

Should work on any Linux with SANE support for the scanner. The udev rule matches any USB device from Fujitsu (vendor `04c5`) whose product string contains "ScanSnap", so other models supported by SANE's `fujitsu` backend should work out of the box. Models that need a different backend, such as `epjitsu` for the S1100 and S1300i, are not supported: the button service logs that it found no supported scanner and stops.

Temporary page images are written to `~/.cache/snaphatch/` and removed after each scan.

The service is started by udev and bound to the scanner (`BindsTo=dev-scansnap.device`), so it runs for every logged-in user while a ScanSnap is connected, and stops when it is disconnected. This needs no root command or user name in the udev rule. With two ScanSnaps connected at once, both share the `/dev/scansnap` alias; this setup is not tested.

## Credits

- [corporategoth](https://github.com/corporategoth) - support for all ScanSnap models, progress notifications and reusing an existing install ([#3](https://github.com/allardvdb/snaphatch/pull/3))
- [oliver-](https://github.com/oliver-) - testing on an iX500 and bug reports
- [Rida Ayed's ix500 Linux guide](https://ridaayed.com/posts/setup_fujitsu_ix500_scanner_linux/) - scanner options and swskip threshold
- [foxey/scanbdScanSnapIntegration](https://github.com/foxey/scanbdScanSnapIntegration) - inspiration for button daemon
- [OCRmyPDF](https://ocrmypdf.readthedocs.io/) - excellent OCR tool

## License

MIT
