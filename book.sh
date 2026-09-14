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
    "$CHROME" --headless --disable-gpu --no-pdf-header-footer \
      --virtual-time-budget=60000 \
      --print-to-pdf="$PWD/$PDF" \
      "file://$PWD/$OUT/print.html" 2>/dev/null
    echo "Wrote $PDF ($(du -h "$PDF" | cut -f1))"
    ;;

  *)
    echo "Usage: ./book.sh {serve|build|pdf}" >&2
    exit 1
    ;;
esac
