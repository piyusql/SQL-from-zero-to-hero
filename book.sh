#!/usr/bin/env bash
# Build, serve and export the book. Usage: ./book.sh {serve|build|pdf}
set -euo pipefail
cd "$(dirname "$0")"

SRC=.book-src
OUT=.book-out
PDF="SQL-from-zero-to-hero.pdf"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# Explicit order. Do not rely on glob sort: "99-appendices" sorts before "part-01".
SECTIONS=(
  00-front-matter
  part-01-foundations part-02-core-sql part-03-combining-data part-04-types
  part-05-design part-06-advanced-querying part-07-mvcc part-08-performance
  part-09-programmability part-10-administration part-11-scale part-12-capstone
  exercises
  99-appendices
)

part_title() {
  case "$1" in
    exercises)                  echo "Workbook — Practice Sessions" ;;
    part-01-foundations)        echo "Part I — Foundations" ;;
    part-02-core-sql)           echo "Part II — Core SQL" ;;
    part-03-combining-data)     echo "Part III — Combining Data" ;;
    part-04-types)              echo "Part IV — Data Types and Integrity" ;;
    part-05-design)             echo "Part V — Enterprise Database Design" ;;
    part-06-advanced-querying)  echo "Part VI — Advanced Querying" ;;
    part-07-mvcc)               echo "Part VII — Transactions, Concurrency and MVCC" ;;
    part-08-performance)        echo "Part VIII — Performance Engineering" ;;
    part-09-programmability)    echo "Part IX — Programmability" ;;
    part-10-administration)     echo "Part X — Administration and Operations" ;;
    part-11-scale)              echo "Part XI — Applications at Scale" ;;
    part-12-capstone)           echo "Part XII — Capstone" ;;
    99-appendices)              echo "Appendices" ;;
    *)                          echo "" ;;
  esac
}

# First markdown H1 in the file, minus the "# ".
chapter_title() {
  grep -m1 '^# ' "$1" | sed 's/^# //' || basename "$1" .md
}

# Drop a finished cover image at cover/cover.{jpg,jpeg,png} and it becomes page 1.
# Absent, the book builds without one rather than failing.
add_cover() {
  local art
  art=$(ls cover/cover.pdf cover/cover.jpg cover/cover.jpeg cover/cover.png 2>/dev/null | head -1) || true
  [[ -n ${art:-} ]] || { echo "note: no cover at cover/cover.{pdf,jpg,png} — building without a cover."; return; }

  # A PDF cover (e.g. exported from a design tool) is rasterised to PNG first.
  if [[ $art == *.pdf ]]; then
    command -v pdftoppm >/dev/null || {
      echo "note: cover/cover.pdf needs poppler to rasterise — brew install poppler. Skipping cover."; return; }
    pdftoppm -f 1 -l 1 -r 200 -png -singlefile "$art" "$SRC/.cover-raster"
    art="$SRC/.cover-raster.png"
  fi

  # Inline as a data URI: print.html and the per-chapter pages sit at different
  # depths, and a relative src that works in one breaks in the other.
  local mime="image/png"
  [[ $art == *.jpg || $art == *.jpeg ]] && mime="image/jpeg"
  {
    printf '<div class="cover-page"><img alt="cover" src="data:%s;base64,' "$mime"
    base64 < "$art" | tr -d '\n'
    printf '"></div>\n'
  } > "$SRC/00-front-matter/00-cover.md"
  echo "cover: ${art##*/} ($(du -h "$art" | cut -f1))"
}

generate_src() {
  rm -rf "$SRC"
  mkdir -p "$SRC"
  cp -R manuscript/. "$SRC"/
  add_cover

  {
    echo "# Summary"
    echo
    for name in "${SECTIONS[@]}"; do
      dir="$SRC/$name/"
      files=("$dir"*.md)
      [[ -e ${files[0]} ]] || continue          # skip parts not written yet

      title=$(part_title "$name")
      [[ -n $title ]] && { echo; echo "# $title"; echo; }

      for f in "${files[@]}"; do
        rel=${f#"$SRC"/}
        [[ $rel == *00-cover.md ]] && { echo "[Cover]($rel)"; continue; }
        # front matter has no part heading, so render it as an unnumbered prefix chapter
        if [[ -z $title ]]; then
          echo "[$(chapter_title "$f")]($rel)"
        else
          echo "- [$(chapter_title "$f")]($rel)"
        fi
      done
    done
  } > "$SRC/SUMMARY.md"
}

# Chrome dies silently (exit 0, no PDF) when asked to lay out the whole book in
# one go, and sometimes never exits after writing a PDF that did succeed. So:
# split print.html at chapter breaks into chunks, print each with its own
# throwaway profile, stop Chrome as soon as the file appears, then join them.
print_pdf() {
  tmp=$(mktemp -d)   # global: the EXIT trap runs after this function returns
  trap 'pkill -f "user-data-dir=${tmp:-/nonexistent}" 2>/dev/null || true; rm -rf "${tmp:-}" "$OUT"/.chunk-*.html' EXIT

  local n
  n=$(python3 - "$OUT" "${CHUNK_CHAPTERS:-6}" <<'PY'
import html, re, sys
out, per = sys.argv[1], int(sys.argv[2])
h = open(f"{out}/print.html").read()
parts = re.split(r'(?=<div style="break-before: page)', h)
head, chapters = parts[0], parts[1:]
tail = "</main></div></div></body></html>"

# Running header without one Chrome run per chapter (which repeats every embedded font once per
# chunk: 59 chunks made a 20 MB PDF, 10 chunks make 6 MB). Each chapter is wrapped in its own
# CSS *named page*, and each named page has its own literal header, so a chunk of many chapters
# still gets the right chapter name on every page. The fade is an OPAQUE gradient on purpose: with
# alpha (rgba) Chrome stores it as an image on every page, about 17 KB each, +13 MB over the book.
def title_of(ch):
    m = re.search(r'<h1[^>]*>(.*?)</h1>', ch, flags=re.S)
    t = html.unescape(re.sub(r'<[^>]+>', '', m.group(1))).strip() if m else ""
    return t.replace("\\", "\\\\").replace('"', '\\"')

pagecss, wrapped = [], []
for k, ch in enumerate(chapters):
    # the last fragment also carries mdbook's closing tags and scripts: wrap only the chapter
    end = ch.rfind("</main>") if k == len(chapters) - 1 else -1
    body_part, rest = (ch[:end], ch[end:]) if end != -1 else (ch, "")
    pagecss.append('@page pg%d{@top-center{content:"%s";width:178mm;text-align:right;'
                   'font:italic 9pt Georgia,serif;color:#666;vertical-align:bottom;padding-bottom:6.5mm;'
                   'background:linear-gradient(to right,#fff,#6e6e6e 70%%) '
                   'no-repeat left calc(100%% - 3.5mm) / 100%% 0.35mm}}' % (k, title_of(ch)))
    # The named page already starts a new page; mdbook's own break div on top of it makes a blank one.
    body_part = re.sub(r'^<div style="break-before: page[^>]*>', '<div>', body_part)
    wrapped.append('<div style="page:pg%d">%s</div>%s' % (k, body_part, rest))

# chunk 0 is the cover alone (written specially below)
groups = [wrapped[i:i+per] for i in range(0, len(wrapped), per)]
chunks = [[]] + groups
for i, c in enumerate(chunks):
    if i == 0:
        # The cover is its own document so nothing from the book chrome (padding,
        # margins, page numbers) can reach it: the artwork fills the whole A4 page.
        img = re.search(r'<img alt="cover"[^>]*>', head)
        cover = ("<!DOCTYPE html><meta charset=utf-8><style>@page{size:A4;margin:0}"
                 "html,body{margin:0;padding:0}img{display:block;width:210mm;height:297mm;object-fit:cover}"
                 "</style>" + (img.group(0) if img else ""))
        open(f"{out}/.chunk-000.html", "w").write(cover)
        continue
    body = re.sub(r'<div class="cover-page">.*?</div>', '', head, flags=re.S)
    # mdbook picks its theme from prefers-color-scheme, and headless Chrome can report "dark",
    # which prints white pages with grey text on a black canvas. A book is always the light theme.
    body = body.replace('window.matchMedia("(prefers-color-scheme: dark)").matches ? default_dark_theme : default_light_theme', 'default_light_theme')
    # Chunk i's named pages are the global ones for its chapters; give each chunk only its own rules.
    first = (i - 1) * per
    # body takes the first chapter's page name, or the stray page before it would be a blank page
    style = ("<style>html{counter-reset:page @@PAGEOFFSET@@}body{page:pg%d}" % first
             + "".join(pagecss[first:first + len(c)]) + "</style>")
    open(f"{out}/.chunk-{i:03d}.html", "w").write(body + style + "".join(c) + tail)
print(len(chunks))
PY
)

  # Chrome restarts page numbering per chunk, so feed each chunk the page count so far.
  local i pdf pid t pages=0 html
  for ((i = 0; i < n; i++)); do
    printf -v pdf '%s/%03d.pdf' "$tmp" "$i"
    html="$OUT/.chunk-$(printf %03d "$i").html"
    sed -i "" "s/@@PAGEOFFSET@@/$pages/" "$html"
    "$CHROME" --headless --disable-gpu --no-pdf-header-footer \
      --user-data-dir="$tmp/profile" --disable-component-update --virtual-time-budget=60000 \
      --print-to-pdf="$pdf" "file://$PWD/$html" >/dev/null 2>&1 &
    pid=$!
    for ((t = 0; t < 300; t++)); do            # up to ~10 min per chunk
      [[ -s $pdf ]] && { sleep 1; break; }
      kill -0 "$pid" 2>/dev/null || break
      sleep 2
    done
    kill "$pid" 2>/dev/null || true; pkill -f "user-data-dir=$tmp" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    [[ -s $pdf ]] || { echo "chunk $i/$n produced no PDF" >&2; return 1; }
    pages=$((pages + $(pdfinfo "$pdf" | awk '/^Pages:/{print $2}')))
    echo "  chunk $((i + 1))/$n ok"
  done
  pdfunite "$tmp"/[0-9]*.pdf "$PWD/$PDF"
}

case "${1:-serve}" in
  serve)
    generate_src
    echo "Serving at http://localhost:3000 — Ctrl-C to stop."
    echo "Note: edits need a re-run; mdbook watches $SRC, not manuscript/."
    mdbook serve --open
    ;;

  build)
    generate_src
    mdbook build
    echo "Built: $OUT/index.html"
    ;;

  pdf)
    generate_src
    mdbook build
    [[ -x $CHROME ]] || { echo "Chrome not found at $CHROME" >&2; exit 1; }
    command -v pdfunite >/dev/null || { echo "pdfunite missing — brew install poppler" >&2; exit 1; }
    print_pdf
    echo "Wrote $PDF ($(du -h "$PDF" | cut -f1))"
    ;;

  *)
    echo "Usage: ./book.sh {serve|build|pdf}" >&2
    exit 1
    ;;
esac
