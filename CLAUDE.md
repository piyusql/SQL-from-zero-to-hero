# CLAUDE.md

Orientation for a Claude Code session working in this repository.

## What this is

**SQL from Zero to Hero** — *Mastering Postgres from First Query to Terabyte Scale*, by
**Andy W. Pearson**, the shared pen name of three authors (Anand K Gupta, Tarun Kumar
"Dablu", Piyus Kumar). 54 chapters planned across 12 parts, plus a workbook of practice
sessions at the back.

Read these before doing anything substantive:

| File | What it is |
|---|---|
| `CONVENTIONS.md` | **Binding.** Voice, length, workbook split, NULL rendering, Indian data, verification rule. Follow it over habit. |
| `TOC.md` | The full 54-chapter plan |
| `README.md` | Progress table and build instructions |
| `ERRATA-OPEN.md` | **Outstanding defects.** Currently 17 open in Part III, 4 of them factually wrong. |

Style exemplars: `manuscript/part-01-foundations/ch01-*.md` (conceptual) and
`manuscript/part-02-core-sql/ch08-*.md` (measurement-heavy). Workbook exemplar:
`manuscript/exercises/ch08.md`.

## The rule that matters most

**Nothing ships unverified.** Every SQL statement and every pasted output block must have
been executed against a real server, and the output printed must be what actually came
back. This is not ceremony — an errata pass over Parts I–II found 21 defects, and a second
over Part III found 17. In both cases the failures clustered in blocks that were
hand-edited or asserted rather than run, including several written by Claude and approved
by Claude.

Corollaries learned the hard way:

- **Never hand-edit pasted output.** Re-run it. A rule one character short is how a
  fabricated block gives itself away.
- **Never assert a performance claim you have not measured.** Two shipped claims were
  wrong this way; both overstated the effect.
- **`n_live_tup` is an estimate.** Use `count(*)` when exactness matters. This bit us.
- **Say plainly when a premise you were given is wrong.** It has happened repeatedly and
  is the most valuable thing a subagent has done.

## Verification environment

```bash
export PATH="/opt/homebrew/opt/libpq/bin:$PATH"
export PGHOST=127.0.0.1 PGPORT=5431 PGUSER=postgres
psql -P null='(null)' -d retail -c "SELECT version();"
```

- Container `pk017347-test-pgdb`, **PostgreSQL 15.10**, host port **5431**, user
  `postgres`, no password. Requires Colima running (`colima start`).
- **Never use port 5432.** `pk017347-pgdb` lives there and is the user's real working
  database.
- 15.10 is deliberate: it is the book's stated minimum, so anything needing 16+ fails
  here rather than in a reader's hands.
- **Always pass `-P null='(null)'`.** A blank NULL cell is an errata.
- `retail`, `hr`, `telemetry` (small) and `retail_lg` (exactly 2,000,000 orders /
  5,004,129 order_items) are loaded. Treat them as **read-only**; create scratch
  databases for anything that writes, and drop them.

## Layout

```
manuscript/
├── 00-front-matter/           preface, how to use this book
├── part-01-foundations/ …     chapters, prose only — no practice sessions
├── exercises/chNN.md          the workbook; sessions live here
└── 99-appendices/
datasets/                      retail / telemetry / hr, small and large
cover/cover.html               live cover mockup
book.sh                        serve | build | pdf
```

Chapters end: body → `## Summary` → `**Exercises:**` pointer → `**Next:**`.
Workbook sessions are `## Practice Session N.M` (H2) with Goal / Setup / Task / Solution.

## Building

```bash
./book.sh serve    # browsable site at localhost:3000
./book.sh build    # static site
./book.sh pdf      # SQL-from-zero-to-hero.pdf
```

Needs `mdbook` and Google Chrome. `.book-src/` and `.book-out/` are generated — never
edit them, and both are gitignored along with `*.pdf`.

## State as of 2026-09-14

- **Done and verified:** Parts I and II (chapters 1–8), Part III (9–12). 12 chapters,
  12 workbook files, 32 practice sessions.
- **Next to write:** Part IV, chapters 13–17 (data types and integrity).
- **Open work:** `ERRATA-OPEN.md`.
- Git identity for this repo is set locally to Piyus Gupta
  <piyusgupta01@gmail.com>; the machine's global config is a different, work identity, so
  do not rely on it.

## Working with subagents

Parallelising chapters across subagents works well, with two caveats learned in practice:

1. **Brief them fully.** Point at `CONVENTIONS.md`, the exemplars, the dataset README, and
   the verification environment. A thin brief produces plausible prose with fabricated
   output.
2. **Verify their claims independently.** Spot-check the headline numbers yourself rather
   than accepting a report. They have been honest and repeatedly right — including when
   correcting the brief — but the checking is what makes that trustworthy.
