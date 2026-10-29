# ix500-linux

One-button scanning workflow for Fujitsu ScanSnap scanners on Linux.

Press the scanner button → get a PDF. That's it.

Originally written for the [ScanSnap iX500](https://www.fujitsu.com/global/products/computing/peripheral/scanners/scansnap/ix500/), but the scripts and udev rule auto-detect any ScanSnap model supported by the SANE `fujitsu` backend (iX500, S1500, etc.).

## Features

- **One-button scanning** - press the hardware button, get a PDF
- **Duplex A4 color** - scans both sides automatically
- **Smart blank detection** - removes empty back pages, also when the other side shows through
- **Auto color/grayscale** - converts B&W pages to grayscale for smaller files
- **Compact PDFs** - JPEG-compressed pages (~1.5 MB per page instead of ~33 MB uncompressed)
- **Three output modes** - upload to [Paperless-ngx](https://docs.paperless-ngx.com/) via API, write to a Paperless consume folder, or save locally with OCR
- **Clickable notifications** - open the result directly from the notification
- **Robust disconnect handling** - no crashes when scanner is unplugged

### Paperless-ngx API mode (recommended)
When `PAPERLESS_URL` and `PAPERLESS_TOKEN` are set, scans are uploaded directly to Paperless-ngx via its API. Paperless handles OCR, archiving and search. Paperless keeps the uploaded original unchanged, so the PDF is compressed before upload. No created date is sent: Paperless takes the date from the document itself.

### Paperless-ngx folder mode
When `PAPERLESS_CONSUME_DIR` is set, scans are written directly to the Paperless consume folder. Paperless picks them up from there.

### Local mode
Without Paperless configured, scans are processed locally with ocrmypdf (Dutch + English OCR, auto-rotate, deskew, cleanup) and saved to `~/Documents/scanner-inbox/`.

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

## Usage

### One-button scanning
1. Put documents in the feeder
2. Press the blue Scan button on the scanner
3. Wait for desktop notification "Scan Complete"
4. Click the notification to open the result

### Manual scanning
```bash
scan                  # Auto-named: scan-YYYY-MM-DD-HHMMSS.pdf
scan my-document      # Custom name: my-document.pdf
```

### Service management
```bash
just status    # Show service status
just logs      # Follow service logs
just restart   # Restart the service
just uninstall # Remove everything
```

## Configuration

Settings are stored in `~/.config/environment.d/scanner.conf` (managed by `just install`). Settings you add by hand, such as `BLANK_THRESHOLD`, are kept when you re-run the installer, and it applies them to the running service:

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

### Scanner options (in `scan`)

| Option | Value | Purpose |
|--------|-------|---------|
| `--swcrop` | yes | Auto-crop borders |
| `--swdespeck` | 2 | Remove small artifacts |
| `--overscan` | On | Better feed handling |
| `--prepick` | On | Pre-pick next page (faster) |
| `--buffermode` | On | Faster processing |

### OCR options (local mode only, in `scan`)

| Option | Value | Purpose |
|--------|-------|---------|
| `-l` | nld+eng | Languages (Dutch + English) |
| `--rotate-pages-threshold` | 2 | Aggressive rotation fix |
| `-O` | 3 | Maximum optimization |
| `--jpeg-quality` | 60 | Good compression |

Lossy JBIG2 is deliberately not used: it can swap look-alike characters, such as digits in amounts.

### Blank page detection
The scanner's own blank-page skip (`--swskip`) counts all darkish pixels, so text showing through from the other side makes a blank back look like a page. Instead, `scan` turns each page into hard black and white at 50% gray, which drops the light gray bleed-through, and removes pages with less than `BLANK_THRESHOLD` (0.02%) ink. A 3% border is ignored to skip edge shadows. A page of text has a few percent ink; a signature alone is around 0.07%.

Removed pages are kept as JPEG in `~/Documents/scanner-inbox/removed/` for 30 days, and the notification says how many were removed.

### Color detection
A page counts as color when more than 0.5% of its pixels have over 15% chroma; other pages are converted to grayscale. Chroma is used rather than HSL saturation, because near-white paper with a faint tint has a high HSL saturation.

## How it works

```
┌─────────────┐     ┌──────────────┐     ┌─────────────────┐
│  Button     │────▶│ scan-button  │────▶│ scan script     │
│  pressed    │     │ -poll        │     │                 │
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

Should work on any Linux with SANE support for the scanner. The udev rule matches any USB device from Fujitsu (vendor `04c5`) whose product string contains "ScanSnap", so additional models should work out of the box.

## Credits

- [Rida Ayed's ix500 Linux guide](https://ridaayed.com/posts/setup_fujitsu_ix500_scanner_linux/) - scanner options and swskip threshold
- [foxey/scanbdScanSnapIntegration](https://github.com/foxey/scanbdScanSnapIntegration) - inspiration for button daemon
- [OCRmyPDF](https://ocrmypdf.readthedocs.io/) - excellent OCR tool

## License

MIT
