#!/usr/bin/env bash
# Builds the Spanish user manual PDF from the Markdown chapters.
#
# The chapters are plain Markdown with headings, numbered and bulleted lists,
# bold text and inline code, so this script converts that subset itself instead
# of depending on pandoc or a Markdown library. Print it with a Chromium-family
# browser in headless mode.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
out="$here/manual-lda-inventory.pdf"
html="$(mktemp -t lda-manual).html"
trap 'rm -f "$html"' EXIT
browser=""
for candidate in \
  "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"; do
  if [ -x "$candidate" ]; then browser="$candidate"; break; fi
done
if [ -z "$browser" ]; then
  echo "No Chromium-family browser found to print the PDF." >&2
  exit 1
fi

python3 - "$here" "$html" <<'PY'
import html as escape
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
target = Path(sys.argv[2])

chapters = sorted(p for p in root.glob("[0-9][0-9]-*.md"))
if not chapters:
    sys.exit("no chapters found")

STYLE = """
@page { size: A4; margin: 20mm 18mm; }
body { font-family: -apple-system, "Helvetica Neue", Arial, sans-serif;
       font-size: 11.5pt; line-height: 1.5; color: #1d1d1f; }
h1 { font-size: 20pt; margin: 0 0 10pt; padding-bottom: 6pt;
     border-bottom: 2px solid #2f6f4f; page-break-before: always; }
h1:first-of-type { page-break-before: avoid; }
h2 { font-size: 14pt; margin: 16pt 0 6pt; color: #2f6f4f; }
h3 { font-size: 12pt; margin: 12pt 0 4pt; }
p { margin: 0 0 8pt; }
ol, ul { margin: 0 0 10pt 18pt; padding: 0; }
li { margin-bottom: 4pt; }
code { font-family: ui-monospace, Menlo, monospace; font-size: 0.92em;
       background: #f2f2f4; padding: 1pt 3pt; border-radius: 3px; }
.title { text-align: center; page-break-after: always; }
.title h1 { border: 0; page-break-before: avoid; font-size: 26pt; }
.title p { color: #555; }
"""

def inline(text: str) -> str:
    text = escape.escape(text, quote=False)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    return text

body: list[str] = []
for chapter in chapters:
    lines = chapter.read_text(encoding="utf-8").splitlines()
    state = {"list": None}
    paragraph: list[str] = []

    def flush_paragraph() -> None:
        if paragraph:
            body.append("<p>" + inline(" ".join(paragraph)) + "</p>")
            paragraph.clear()

    def close_list() -> None:
        if state["list"]:
            body.append(f"</{state['list']}>")
            state["list"] = None

    for line in lines:
        stripped = line.strip()
        heading = re.match(r"^(#{1,3})\s+(.*)$", stripped)
        ordered = re.match(r"^\d+[.)]\s+(.*)$", stripped)
        bulleted = re.match(r"^[-*]\s+(.*)$", stripped)
        if heading:
            flush_paragraph(); close_list()
            level = len(heading.group(1))
            body.append(f"<h{level}>{inline(heading.group(2))}</h{level}>")
        elif ordered or bulleted:
            flush_paragraph()
            kind = "ol" if ordered else "ul"
            if state["list"] != kind:
                close_list()
                body.append(f"<{kind}>")
                state["list"] = kind
            body.append("<li>" + inline((ordered or bulleted).group(1)) + "</li>")
        elif not stripped:
            flush_paragraph(); close_list()
        else:
            paragraph.append(stripped)
    flush_paragraph(); close_list()

target.write_text(
    "<!doctype html><html lang=\"es\"><head><meta charset=\"utf-8\">"
    "<title>Manual de usuario — LDA Inventory</title>"
    f"<style>{STYLE}</style></head><body>"
    "<div class=\"title\"><h1>Manual de usuario</h1>"
    "<p>LDA Inventory · versión 1.0</p></div>"
    + "\n".join(body)
    + "</body></html>",
    encoding="utf-8",
)
PY

"$browser" --headless --disable-gpu --no-pdf-header-footer \
  --print-to-pdf="$out" "file://$html" >/dev/null 2>&1

# Set LDA_MANUAL_HTML to keep the intermediate HTML for inspection.
if [ -n "${LDA_MANUAL_HTML:-}" ]; then
  cp "$html" "$LDA_MANUAL_HTML"
fi

if [ ! -s "$out" ]; then
  echo "The browser did not produce $out" >&2
  exit 1
fi
echo "Wrote $out"
