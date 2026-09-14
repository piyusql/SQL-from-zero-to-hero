# Open Errata

Outstanding defects in drafted chapters. Closed items are deleted, not archived — git
history is the archive.

**Provenance note.** CLAUDE.md previously cited this file as holding 17 open Part III
defects, but the file had never been written to disk and is absent from git history. The
list below comes from a fresh verification pass over Part III on 2026-09-14, in which
every SQL block in chapters 9–12 and workbooks 9–12 was re-executed against
PostgreSQL 15.10. Four blockers found in that pass were fixed the same day and are not
listed here.

---

## Method note — timing claims are not currently trustworthy

The verification container has **4 vCPUs**, and identical queries vary by roughly 3×
depending on what else is running (110–316 ms observed for one query across ten runs).

This produced a real false positive during the pass: a reported 1.5× speedup in ch11 §11.7
disappeared to 1.09× when re-measured on an idle box, and was briefly confirmed on
contaminated measurements before being caught.

**Standing rule for future parts:** never take a timing measurement while other work is
running against the container, and quote a median of at least ten alternating runs rather
than a single figure. Prefer deterministic evidence — row counts, plan node types, cost
estimates, buffer counts, `pg_relation_size()`, lock modes from `pg_locks` — wherever it
can carry the argument instead.

---

## Part III — Combining Data

### Convention violations: abridged `EXPLAIN` output

CONVENTIONS.md requires output "formatted exactly as `psql` prints it". These blocks have
had interior plan lines removed, not just headers and footers. Every retained number is
correct, so this is presentation rather than fabrication — but it is the same class of
edit that hides real defects, and it is applied inconsistently within a single file.

| Location | Defect |
|---|---|
| `ch10-subqueries-and-exists.md:121-131`, `:140-150` | `Buffers: shared hit=43000` dropped from the `Aggregate` node; `Batches:`/`Buckets:` and per-node `Buffers:` dropped from the join block |
| `ch10-subqueries-and-exists.md:301-315` | Two separate plans pasted into one block with `-- EXISTS` / `-- IN` appended to the root node lines. psql prints neither the comments nor the abridgement. `Rows Removed by Filter: 2228` and the `Buckets:` line dropped from each |
| `exercises/ch10.md:196-206` | Same abridgement as the chapter's 10.3 block. Note Step 2 of the same file (lines 83, 90) *keeps* `Buffers` on identical node types |
| `exercises/ch09.md:531` | Ends with `(10 rows)`. Every other EXPLAIN block in Part III omits both the `QUERY PLAN` header and the row footer — including two in this same file at lines 1305 and 1340. Part II *does* keep the header, so Part III already diverges from Part II; pick one and apply it |

### Unrunnable or incomplete fences

| Location | Defect |
|---|---|
| `ch12-ctes-and-recursive-queries.md:263-268` | Fence has no `WITH RECURSIVE chart` prefix; run as printed it errors with `relation "chart" does not exist`. Prose says "change only the outer query", so intent is clear, but the block is not runnable standalone |
| `ch12-ctes-and-recursive-queries.md:343-356` | Fence contains `SET statement_timeout = '3s';` plus the query. psql prints `SET` before the error; the output block omits it |
| `exercises/ch12.md:1090-1106` | Fence holds four statements (`SET`, `pg_stat_reset()`, the query, the stats select); the output block shows only the last result |

### Incorrect claims

| Location | Defect |
|---|---|
| `exercises/ch11.md:229` | "…and it cannot use a hash join on those conditions." The corrected join printed directly above contains `w.id = b.id`, and 15.10 plans it as a **`Hash Anti Join`**, demoting the two `IS NOT DISTINCT FROM` clauses to a `Join Filter`. It is those clauses that cannot be hash keys — a hash join is still used. Drop the equality column and it does fall back to a nested loop, which is presumably what was meant |
| `exercises/ch11.md:506` | "Unlike timings, these counters do not move between runs… quote the buffer numbers rather than the clock." True of the `temp read=7333 written=7356` counters, which reproduce exactly. False of the **shared** counters in the same block: the total (67420) is stable but the `hit`/`read` split moves with cache state (`hit=16223 read=51197` printed; `hit=20608 read=46812` and `hit=20736 read=46684` observed). Narrow the claim to the counters it actually holds for |
| `exercises/ch10.md:434` | "Two exact, one within 4%." The `NOT EXISTS` estimate is 728 against an actual 759 — 4.08% low, or 4.26% of the estimate. Not within 4% on either reading |

### Needs re-measurement on an idle machine

| Location | Defect |
|---|---|
| `exercises/ch09.md:1430` | "the broken one lands between 0.7 and 1.7 seconds and the fixed one between 2.1 and 5.9 seconds". Six alternating runs gave 0.70–1.83 s and 1.74–5.02 s. The load-bearing claims all hold — the fixed form never came out ahead, ratio roughly 2×–5× — but both stated floors are off. Re-measure per the method note above |
| `exercises/ch09.md:1395`, `:1398`, `:1400`, `:1403`, `:1405` | The `retail_lg` "fix (a)" plan shows `Gather Merge (actual rows=45)`, `Sort (actual rows=15 loops=3)`, `Sort Method: quicksort Memory: 25kB`, `Partial HashAggregate (actual rows=15 loops=3)`, `Batches: 1 Memory Usage: 24kB`. Five runs gave `63`, `21`, `28kB`, `21`, `32kB` every time. The book's numbers are internally consistent with a run where the leader barely participated, so this reads as unreproducible variance rather than fabrication, and the prose's claims about the block all hold. Re-run and repaste |
