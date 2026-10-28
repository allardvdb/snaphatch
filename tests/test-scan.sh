#!/bin/bash
# test-scan.sh - Tests for the page-processing functions in ../scan
#
# Builds synthetic A4 pages at 300 DPI with ImageMagick and checks blank-page
# detection, color detection and PDF compression. No scanner needed.
# Run: just test   (or: bash tests/test-scan.sh)

set -u

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scan
source "$TEST_DIR/../scan"

FIXTURES=$(mktemp -d)
trap 'rm -rf "$FIXTURES"' EXIT

PASS=0
FAIL=0

check() {
    local name=$1; shift
    if "$@"; then
        echo "  ok   $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL $name"
        FAIL=$((FAIL + 1))
    fi
}

not() { ! "$@"; }

# A4 at 300 DPI
SIZE=2480x3508

# "Text lines": rows of bars, roughly 5% coverage
LINES=""
for y in $(seq 400 120 3100); do
    LINES+="rectangle 300,$y 2180,$((y + 25)) "
done

# page OUT [MAGICK-ARGS...] - white A4 page (BG overrides the paper color)
page() {
    local out=$1; shift
    magick -size "$SIZE" "xc:${BG:-white}" "$@" "$out"
}

echo "Building fixtures..."
page "$FIXTURES/text.tiff"      -fill black -draw "$LINES"
# Bleed-through: the front side's text shows as light gray on the back
page "$FIXTURES/bleed.tiff"     -fill '#c8c8c8' -draw "$LINES"
page "$FIXTURES/empty.tiff"
# A page with only a signature-sized scribble (~0.07% of the page)
page "$FIXTURES/signature.tiff" -fill black -draw "rectangle 1500,3000 2500,3006"
# Dark scanner shadow along the edge must not count as content
page "$FIXTURES/edge.tiff"      -fill black -draw "rectangle 0,0 40,3508"
# Color logo (~1% of the page) on a text page
page "$FIXTURES/logo.tiff"      -fill black -draw "$LINES" \
                                -fill '#d02020' -draw "rectangle 300,100 900,250"
# Black text on slightly yellowed paper: still grayscale
BG='#f6f1e4' page "$FIXTURES/tinted.tiff" -fill black -draw "$LINES"

echo "Blank-page detection:"
check "text page is not blank"        not is_blank "$FIXTURES/text.tiff"
check "bleed-through page is blank"   is_blank "$FIXTURES/bleed.tiff"
check "empty page is blank"           is_blank "$FIXTURES/empty.tiff"
check "signature page is not blank"   not is_blank "$FIXTURES/signature.tiff"
check "edge shadow is ignored"        is_blank "$FIXTURES/edge.tiff"

echo "Color detection:"
check "page with color logo is color" is_color "$FIXTURES/logo.tiff"
check "black text page is grayscale"  not is_color "$FIXTURES/text.tiff"
check "tinted paper is grayscale"     not is_color "$FIXTURES/tinted.tiff"

echo "PDF compression:"
make_pdf "$FIXTURES/out.pdf" "$FIXTURES/text.tiff" "$FIXTURES/logo.tiff"
# `pdfimages -list` columns, one line per embedded image (masks included)
images()      { pdfimages -list "$FIXTURES/out.pdf" 2>/dev/null | awk 'NR > 2'; }
pdf_pages()   { [ "$(images | wc -l)" -eq 2 ]; }
pdf_is_jpeg() { [ -n "$(images)" ] && ! images | awk '{print $9}' | grep -qvx jpeg; }
pdf_300dpi()  { [ -n "$(images)" ] && ! images | awk '{print $13}' | grep -qvx 300; }
pdf_small()   { [ "$(stat -c %s "$FIXTURES/out.pdf")" -lt $((4 * 1024 * 1024)) ]; }
check "PDF has 2 images, no masks"    pdf_pages
check "all images are JPEG"           pdf_is_jpeg
check "pages are 300 DPI (A4 size)"   pdf_300dpi
check "PDF is under 4 MB"             pdf_small

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
