# Writing Conventions

These are binding for every chapter. When in doubt, follow this file over habit.

## Environment

- **Every command in this book is run on macOS or Linux.** Terminal and `psql`. No Windows
  paths, no PowerShell, no `C:\`. If a Windows reader needs help, they get WSL2 in one
  sentence in Chapter 2 and nothing further.
- **PostgreSQL 15 or newer is a prerequisite.** Readers install it in Chapter 2 before
  anything else. We do not write defensively for PG 11–14.
- When behaviour changed in a specific version, flag it inline:
  > **Version note —** `MERGE` requires PostgreSQL 15. On 14 and earlier, use
  > `INSERT ... ON CONFLICT`.
- Assume a local cluster on `localhost:5432` unless a chapter says otherwise.

## Verification Environment

**Nothing ships unverified.** Every SQL statement and every piece of shown output must be
executed against a real server before its chapter is marked drafted, and the output pasted
in must be the output that actually came back.

The authoring machine verifies against the user's local test container:

```bash
export PATH="/opt/homebrew/opt/libpq/bin:$PATH"
export PGHOST=127.0.0.1 PGPORT=5431 PGUSER=postgres
psql -d postgres -c "SELECT version();"
```

- Container `pk017347-test-pgdb`, **PostgreSQL 15.10** (Bitnami image), host port **5431**
- User `postgres`, no password, empty cluster — safe to create and drop databases freely
- Clean up scratch databases when a chapter is done

> **Never use port 5432.** A separate container, `pk017347-pgdb`, listens there and is the
> user's real working database. Always pass `-p 5431` explicitly; a bare `-h localhost`
> defaults to 5432 and would hit it.

Verifying against 15.10 is deliberate: it is exactly the book's stated minimum, so anything
requiring 16+ fails here rather than silently shipping to a reader who cannot run it.

## Practice Sessions

**Practice Sessions do not live in chapters.** They live in a workbook at the back of the
book, one file per chapter:

```
manuscript/exercises/ch06.md
```

- H1 is `# Chapter 6 Exercises — Querying Fundamentals`. Individual sessions are **H2**
  (`## Practice Session 6.1 — …`), since the file's H1 is the chapter title.
- The chapter itself ends: body → `## Summary` → Exercises pointer → `**Next:**`. The
  pointer reads:

  ```
  **Exercises:** Practice Sessions 6.1–6.3 accompany this chapter and are in the
  workbook at the back of the book.
  ```

- Workbook files have **no length limit**. Never trim a session to hit a word count.
- Sessions are standalone: a reader working from the workbook has the chapter in the
  other hand but should not need to re-read it. Do not write "as described above" —
  there is no above.

- Numbered **`p.q`** — `p` is the chapter number, `q` is the session number inside that
  chapter. Chapter 9's third session is **Practice Session 9.3**. Numbering never restarts
  inside a chapter and never continues across chapters.
- Every session has four parts, in this order:
  1. **Goal** — one sentence, stated as an outcome.
  2. **Setup** — runnable SQL or shell. Must work from the sample datasets alone.
  3. **Task** — what the reader does.
  4. **Solution** — complete, with a short note on *why*, not just *what*.
- A session must be runnable start to finish without reading the solution first.
- Sessions never depend on a *later* chapter. They may depend on earlier ones.

  **One standing exemption:** Part II cannot demonstrate a join fan-out without a join, so
  Sessions 6.3 and 8.1 reach forward to Chapter 9, and 6.3 glimpses `EXISTS` (Chapter 10).
  Both say so inline and neither requires the reader to already understand the construct
  to finish the task. Any further exemption needs the same treatment: flag it in the
  session text, and never make the forward material load-bearing.

## Sample Datasets

Three datasets, reused throughout so knowledge compounds instead of resetting:

| Dataset     | Shape                                     | Used for                         |
|-------------|-------------------------------------------|----------------------------------|
| `retail`    | customers, orders, order_items, products  | joins, aggregation, design       |
| `telemetry` | high-volume time-series events            | partitioning, indexing, EXPLAIN  |
| `hr`        | employees, departments, hierarchy         | recursion, window functions      |

Datasets live in `datasets/`. Each has a small (`-sm`, ~10k rows) and a large (`-lg`,
10M+ rows) variant. Performance chapters use `-lg`; everything else uses `-sm`.

## Cultural References — Indian, not European

All human-readable example data in this book is **Indian**. This applies to the sample
datasets and to any example invented inline in prose.

- **Names** — Indian names drawn across regions (Rajesh Kumar, Anita Rao, Priya Menon,
  Arjun Iyer, Fatima Sheikh, Harpreet Singh, Meera Banerjee). Do not draw from one region
  only.
- **Cities** — Mumbai, Delhi, Bengaluru, Hyderabad, Chennai, Kolkata, Pune, Ahmedabad,
  Jaipur, Kochi, Lucknow, Chandigarh, Indore, Coimbatore.
- **States/regions** — Maharashtra, Karnataka, Tamil Nadu, Delhi NCR, Gujarat, West
  Bengal, Telangana, Kerala.
- **Countries** — `IN` dominant, with a realistic minority from India's major trade and
  diaspora partners (`SG`, `AE`, `US`, `GB`, `AU`, `MY`). No European codes.
- **Money** — amounts are plausible INR magnitudes. Stored as `numeric`; never embed a
  currency symbol in data.

No Munich, Bavaria, `'DE'`, London or Paris — in datasets or in prose. When a filter needs
good selectivity, prefer `city` over `country`, since `IN` dominates the country column
and makes for a dull predicate.

## Voice

- Written from the chair of someone who has run PostgreSQL at terabyte scale for twenty
  years. Opinionated where experience justifies an opinion; explicit when something is a
  genuine trade-off.
- **Say what you would actually do.** "Default to `timestamptz`" beats "there are several
  considerations when choosing a temporal type."
- Name the failure mode. Every recommendation should be traceable to something that breaks
  in production if you ignore it.
- No cheerleading, no "simply", no "just". If it were simple the reader would not be here.

## Two Audiences, Kept Apart

The book serves two readers and the structure protects that split:

- **Application engineers** who write and tune queries → Parts I–IX, XI
- **Platform owners** who run the cluster → Parts VII–XII

Cluster-operation material (`pg_dump`, replication, `pg_hba.conf`, WAL tuning) stays in
Part X. It does not leak into the performance chapters, because someone responsible for
application stability often has no access to the infrastructure layer. When a performance
chapter needs an ops concept, it cross-references Part X rather than teaching it inline.

## Chapter Length

Since Practice Sessions moved to the workbook, house length applies to **chapter prose
only** and is **2,500–4,000 words** including code and output (`wc -w` on the file).

Across Parts I–III the twelve drafted chapters run 2,118–4,432, median 3,632. The spread
is not drift, it is subject matter: a conceptual chapter (1–3, 5) runs ~2,500, and one
that measures things and pastes plans (7, 9, 10, 12) runs ~4,000+. Do not pad a short
chapter to reach a floor, and **do not cut verified measurements to reach a ceiling** —
if a chapter is long because it contains real output that earns its place, say so and
leave it. Prose padding is the thing the limit exists to prevent.

Workbook files are **not** counted and have no limit.

- Up to **4,500** is acceptable for a designated keystone chapter — Ch 21, 22, 34, 39, 52.
  Chapter 34 (`EXPLAIN`) may go further; it is the chapter the book was written around.
- Over house length, cut rather than justify. The usual culprits: a practice-session
  solution re-explaining something the body already covered, a third example proving a
  point two already made, or material that belongs to a later chapter and should be a
  one-line forward reference instead.
- A long chapter is usually two chapters, or one chapter plus a forward reference. Say so
  rather than shipping it oversized.

## Formatting

- Chapter files: `manuscript/part-NN-slug/chNN-slug.md`
- One `#` H1 per file: `# Chapter N — Title`
- SQL keywords uppercase, identifiers `snake_case` lowercase.
- Fenced code blocks always carry a language tag: ```sql, ```bash, ```text
- Query output is shown as ```text, formatted exactly as `psql` prints it.
- **NULL is always printed as `(null)`.** Chapter 2 tells the reader to
  `\pset null '(null)'`, and every output block in the book assumes it. Do not use `␀`
  or any other non-ASCII marker — it is a font risk in print and PDF, and an inconsistent
  marker makes readers doubt output that is actually correct. If a chapter shows NULLs,
  restate the `\pset` line near its first use.
- Cross-references by chapter number and name: "see Chapter 34, *Deep Dive: EXPLAIN*".
- Callouts use blockquote + bold lead:
  - `> **Version note —**`
  - `> **In production —**`
  - `> **Trap —**`

## Book Metadata

- **Title:** SQL from Zero to Hero
- **Subtitle:** Mastering Postgres from First Query to Terabyte Scale
- **Author (combined pen name for three authors):** Andy W. Pearson
- **Cover art:** original painting, used at full bleed. Mockup in `cover/cover.html`.
- **Trim size:** 7.5 × 9.25 in
