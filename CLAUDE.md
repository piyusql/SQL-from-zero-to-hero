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
| `ERRATA-OPEN.md` | **Outstanding defects.** 12 open in Part III, all minor; also holds the standing rule on how to take a timing measurement. |

Style exemplars: `manuscript/part-01-foundations/ch01-*.md` (conceptual) and
`manuscript/part-02-core-sql/ch08-*.md` (measurement-heavy). Workbook exemplar:
`manuscript/exercises/ch08.md`.

## The rule that matters most

**Nothing ships unverified.** Every SQL statement and every pasted output block must have
been executed against a real server, and the output printed must be what actually came
back. This is not ceremony — an errata pass over Parts I–II found 21 defects, and a full
re-verification of Part III on 2026-09-14 found four blockers and twelve minor items. In
every case the failures clustered in blocks that were hand-edited or asserted rather than
run, including several written by Claude and approved by Claude.

Corollaries learned the hard way:

- **Never hand-edit pasted output.** Re-run it. A rule one character short is how a
  fabricated block gives itself away.
- **Never assert a performance claim you have not measured.** Two shipped claims were
  wrong this way; both overstated the effect.
- **Never measure while anything else is running against the container.** It has 4 vCPUs;
  the same query varied 110–316 ms depending on load. On 2026-09-14 this produced a
  *false* errata — a reported 1.5× speedup that was 1.09× on an idle box, confirmed by
  Claude on contaminated numbers before being caught. Quote a median of ten or more
  alternating runs, and when parallelising chapter work across subagents, forbid them
  timing claims entirely and take the measurements yourself afterwards.
- **Prefer deterministic evidence over the clock** wherever it can carry the argument:
  row counts, plan node types, cost and row estimates, buffer counts,
  `pg_relation_size()`, `pg_column_size()`, lock modes from `pg_locks`.
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
make install       # one-time: mdbook, poppler, libpq, Chrome (idempotent)
make serve         # browsable site at localhost:3000        (./book.sh serve)
make build         # static site                             (./book.sh build)
make pdf           # SQL-from-zero-to-hero.pdf               (./book.sh pdf; run `make stop` first)
make               # every other target: words, stats, todo, db-check, db-clean, psql ...
```

`.book-src/` and `.book-out/` are generated — never edit them, and both are gitignored along
with `*.pdf`. `serve`, `build` and `pdf` all share those two folders, so never run one while
another is running.

The PDF is printed by headless Chrome in about ten chunks and joined with `pdfunite`. Things
learned the hard way, all handled in `book.sh`:

- Chrome silently fails to print the whole book in one go, and sometimes never exits, so the
  script prints chunks and stops Chrome itself.
- The chapter running header uses one CSS *named page* per chapter (a literal title each), so a
  chunk of many chapters still gets the right header. One chunk per chapter would also work but
  repeats every embedded font per chunk: 59 chunks made a 20 MB PDF, ten make 6 MB.
- The header's fading line must be an **opaque** gradient. An `rgba` gradient is stored as an
  image on every page (+13 MB).
- The theme is pinned to light: mdbook picks "ayu" (dark) when headless Chrome reports
  `prefers-color-scheme: dark`, giving grey text on a black canvas.
- The page-number offset is a unique token (`@@PAGEOFFSET@@`), not the word `OFFSET`, which
  appears in chapter text.
- The cover is its own one-page document with zero margin, cropped to A4.

## State as of 2026-09-30

- **Done and verified:** Parts I and II (chapters 1–8), Part III (9–12). Part III went through a
  second full re-verification on 2026-09-14 — every SQL block re-executed — which found four
  blockers (all fixed) and twelve minor items (see `ERRATA-OPEN.md`).
- **Drafted:** Part IV (13–17, `manuscript/part-04-types/`), not re-run since it was written.
- **Drafted and independently re-run on 2026-09-30:** Part V (18–24, `manuscript/part-05-design/`),
  Part VI (25–28, `manuscript/part-06-advanced-querying/`) and Part VII (29–32,
  `manuscript/part-07-mvcc/`). Book total: 32 chapters, 32 workbook files, 88 practice sessions.
  Part VII's multi-session demos were replayed from each agent's two-`psql` harness on an idle
  container; the lock-mode matrix in ch32 was also rebuilt independently and matches cell for cell.
  Known run-to-run differences there: process and transaction ids in deadlock messages (wb-ch31). Parts V and VI were written by parallel
  subagents, then every ```sql/```bash block in every chapter and workbook was re-run from scratch
  and every ```text block compared with the real output. Known, deliberate differences:
  ch20/wb-ch20 (UUID index sizes vary ~1% with random insert order; the UUIDv4 load WAL varies from
  1.28 to 4.17 GB and the chapter says so; one random UUID variant digit), wb-ch27 (a GiST buffer
  count that varies 233–274), ch19 (an ASCII diagram, not query output).
- **Length:** many Part V chapters exceed the 4,000-word house length because of real pasted
  output (4,700–6,400). Accepted; Part VI stayed within 4,161.
- **Open work:** `ERRATA-OPEN.md`, plus any `BENCHMARK-TODO` markers left in drafts.
- Git identity for this repo is set locally to Piyus Gupta
  <piyusgupta01@gmail.com>; the machine's global config is a different, work identity, so
  do not rely on it.

## Working with subagents

**Concurrency chapters (Part VII):** each agent builds a small harness that owns several `psql`
processes and orders events by polling `pg_stat_activity`/`pg_locks`, never by `sleep`; a
replay of those harnesses on an idle container is the independent check. Tell agents never to
`pkill` by pattern (one did, and could have killed another agent's session). pids and xids differ
on every run, so pasted blocks must not depend on them. Vacuum/HOT numbers shift if anything
else is writing anywhere on the server, so re-check them on an idle container.


Parallelising chapters across subagents works well, with two caveats learned in practice:

1. **Brief them fully.** Point at `CONVENTIONS.md`, the exemplars, the dataset README, and
   the verification environment. A thin brief produces plausible prose with fabricated
   output.
2. **Verify their claims independently.** Spot-check the headline numbers yourself rather
   than accepting a report. They have been honest and repeatedly right — including when
   correcting the brief — but the checking is what makes that trustworthy.
