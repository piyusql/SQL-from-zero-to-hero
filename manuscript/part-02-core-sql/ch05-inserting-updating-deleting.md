# Chapter 5 — Inserting, Updating, and Deleting Data

Chapter 4 built the tables. This chapter puts rows in them and takes them out, which
sounds like the easiest thing in the book and contains two of the most expensive
mistakes people make.

The first is loading data a row at a time when the database offers something two orders
of magnitude faster. The second is assuming that "insert it if it is not there, otherwise
update it" is a single safe operation — it can be, but only if you write it the specific
way that is.

---

## 5.1 `INSERT`

```sql
INSERT INTO products (sku, name, category, price)
VALUES ('SKU-90001', 'Brass Diya Set', 'decor', 1250.00);
```

Column names are optional and you should always write them anyway. Omit them and the
statement depends on the physical column order, which means the day someone adds a column
your insert starts putting the price in the wrong place — or, if you are fortunate, fails
loudly.

Several rows go in one statement, and this matters more than it looks:

```sql
INSERT INTO products (sku, name, category, price) VALUES
    ('SKU-90002', 'Terracotta Planter',  'decor',   890.00),
    ('SKU-90003', 'Copper Water Bottle', 'kitchen', 1499.00),
    ('SKU-90004', 'Jute Floor Lamp',     'lighting', 3200.00);
```

## 5.2 Why one row at a time is so slow

Here is the same twenty thousand rows loaded three ways, all inside a single transaction
so that commit cost is not the variable:

| Method | Time |
|---|---:|
| 20,000 single-row `INSERT` statements | **3.99 s** |
| 20,000 rows as multi-row `INSERT`s, 1,000 per statement | **0.06 s** |
| 20,000 rows via `COPY` | **0.03 s** |

Sixty-six times faster for batching, 133× for `COPY`. The rows are identical; only the
number of statements changed.

The reason is that the per-*statement* cost dominates. Every statement is parsed,
rewritten, planned and executed, and — if it came over a network — carries a round trip
in each direction. Twenty thousand statements pay that twenty thousand times. Twenty
multi-row statements pay it twenty times. The actual work of writing the rows is nearly
identical in all three cases.

> **In production —** this is the single most common cause of "our nightly import takes
> four hours". The import is almost never I/O-bound; it is a loop in application code
> issuing one `INSERT` per iteration, usually because an ORM made that the path of least
> resistance. Batch it and four hours becomes four minutes. Chapter 50 covers the
> application side.

All three measurements were taken inside a single transaction. Take the wrapper away and
each of the twenty thousand inserts becomes its own transaction, which must flush the WAL
to durable storage before it returns:

| 20,000 single-row `INSERT`s | Time |
|---|---:|
| inside one transaction | 3.81 s |
| autocommit, one transaction each | 5.88 s |

About 1.5× on this machine — real, but smaller than the folklore suggests, because the
container's storage has a cheap `fsync`. On hardware where a flush genuinely costs
milliseconds the multiplier is far larger, and that is the case people are remembering
when they tell you to wrap your import in a transaction. The advice is right; the size of
the win depends entirely on your storage.

## 5.3 `COPY`, and `\copy`

`COPY` is PostgreSQL's bulk path. It bypasses the per-statement machinery entirely and
streams rows.

```sql
COPY products (sku, name, category, price) FROM '/data/products.csv' CSV HEADER;
```

```text
\copy products (sku, name, category, price) FROM 'products.csv' CSV HEADER
```

Chapter 2 introduced the distinction and it is worth restating, because getting it wrong
is a support ticket: **`COPY` reads a file on the server's filesystem and needs elevated
privileges. `\copy` is a `psql` meta-command that reads the file on your machine and
streams it over the connection.** On your laptop they look identical because the server
is also your laptop. Against a production database they are entirely different, and
`\copy` is almost always the one you want.

`COPY` accepts `CSV`, `HEADER`, `DELIMITER`, `NULL`, and `FORCE_NULL`, and it can read
from a program's output. It is also the fastest way *out*:

```sql
COPY (SELECT * FROM orders WHERE placed_at >= '2026-01-01') TO STDOUT CSV HEADER;
```

> **Trap —** `COPY` is all-or-nothing. One malformed row aborts the entire load and you
> get a single error naming a line number, having written nothing. On a two-hour import
> of somebody else's export, that is the whole two hours.

### Staging, and `INSERT ... SELECT`

The answer to dirty input is not to make `COPY` more forgiving — it cannot be. It is to
give it somewhere harmless to land. Load into a staging table whose columns are all
`text`, so nothing can fail to parse, then promote the rows that are actually valid:

```sql
INSERT INTO stock (sku, qty)
SELECT sku, qty::int
FROM   staging_stock
WHERE  qty ~ '^[0-9]+$'
RETURNING sku, qty;
```

```text
 sku | qty
-----+-----
 A-1 |  10
 A-3 |   8
(2 rows)
```

The third row held `not a number` and stayed in staging, where you can look at it,
report it, and decide — rather than discovering it as a failed import at 3am with no
indication of which of four million lines was responsible.

`INSERT ... SELECT` is worth knowing in its own right: it is how you copy between tables,
populate a summary table, or backfill a new column in batches. The source can be any
query at all, including one that joins several tables.

Make the staging table `UNLOGGED` (Chapter 4) — it is regenerable by definition, and
skipping the WAL makes the load meaningfully faster. Chapter 21 makes staging schemas
part of the design rather than an improvisation.

## 5.4 `UPDATE`

```sql
UPDATE products
SET    price = price * 1.05,
       name  = trim(name)
WHERE  category = 'lighting';
```

Two things to internalise now, both of which get a full chapter later.

**An `UPDATE` is not an edit in place.** PostgreSQL writes a *new* version of the row and
marks the old one dead. Updating one column of a wide row rewrites the whole row, every
index entry that changes has to be maintained, and the dead version stays on disk until
vacuum reclaims it. This is why `UPDATE` is considerably more expensive than people
expect, why updating a billion rows in one statement is a bad idea, and why a table that
is updated heavily grows even when the row count does not. Chapter 30 explains the
mechanism; Chapter 37 explains the cleanup.

**Batch large updates.** A single statement touching fifty million rows holds locks for
its entire duration, generates an enormous amount of WAL, and cannot be interrupted
usefully. Chapter 36 has the batching pattern.

> **Trap —** `UPDATE` with no `WHERE` updates every row, silently and successfully. There
> is no confirmation prompt. The habit worth building: write the `WHERE` clause *first*,
> run it as a `SELECT`, confirm the row count, then convert it to an `UPDATE`.

## 5.5 `DELETE`

```sql
DELETE FROM orders WHERE status = 'cancelled' AND placed_at < '2025-01-01';
```

Same warning about the missing `WHERE`, and the same MVCC consequence: `DELETE` marks
rows dead, it does not free space. A table you have deleted ninety percent of occupies
the same disk until it is vacuumed, and even then the file usually does not shrink —
the space becomes available for reuse rather than returned to the operating system.
Chapter 37 is where that becomes an operational problem worth understanding.

When you want *all* the rows, `TRUNCATE` from Chapter 4 is enormously faster than
`DELETE`, because it discards the underlying files rather than marking rows one by one.

## 5.6 `RETURNING`

`INSERT`, `UPDATE` and `DELETE` can all hand back the rows they touched. This is a
genuine PostgreSQL advantage and underused.

The examples from here to the end of the chapter use one small table. Create it if you
want to follow along:

```sql
CREATE TABLE stock (
    sku        text PRIMARY KEY,
    qty        int NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO stock (sku, qty) VALUES ('A-1', 10), ('A-2', 5);
```

```sql
INSERT INTO stock (sku, qty) VALUES ('B-7', 22)
RETURNING sku, qty, updated_at;
```

```text
 sku | qty |          updated_at
-----+-----+------------------------------
 B-7 |  22 | 2026-09-14 13:33:23.90017+00
(1 row)
```

Without it you would insert, then issue a second query to discover the server-generated
`updated_at` — two round trips, and a race if you tried to find the row by its other
columns.

`RETURNING` also works on `DELETE`, which makes archiving one statement:

```sql
WITH removed AS (
    DELETE FROM orders WHERE status = 'cancelled' RETURNING *
)
INSERT INTO orders_archive SELECT * FROM removed;
```

That is a data-modifying CTE, and Chapter 12 covers the form properly.

## 5.7 Upsert: `INSERT ... ON CONFLICT`

The everyday requirement: insert this row, or if it already exists, update it.

```sql
INSERT INTO stock (sku, qty) VALUES ('A-1', 99), ('A-3', 7)
ON CONFLICT (sku) DO UPDATE
SET qty = EXCLUDED.qty, updated_at = now()
RETURNING sku, qty, (xmax = 0) AS was_inserted;
```

```text
 sku | qty | was_inserted
-----+-----+--------------
 A-1 |  99 | f
 A-3 |   7 | t
(2 rows)
```

Three things in that statement are worth knowing.

**`EXCLUDED` is the row you tried to insert.** Inside the `DO UPDATE`, the target table's
name refers to the existing row and `EXCLUDED` to the proposed one, which is how you
write "take the new value" (`SET qty = EXCLUDED.qty`) as opposed to "add to the old one"
(`SET qty = stock.qty + EXCLUDED.qty`).

**The conflict target must be backed by a unique constraint or index.** There is no
inferring it:

```text
ERROR:  there is no unique or exclusion constraint matching the ON CONFLICT specification
```

**`(xmax = 0)` tells you which rows were inserted and which were updated.** `RETURNING`
alone cannot distinguish them — both come back looking the same. `xmax` is a system
column holding the transaction that deleted or locked a row version; on a freshly
inserted row it is zero, on one your statement updated it is not. It is a trick rather
than an API, but it is the standard one, and Chapter 30 explains why it works.

### Where it is not quite atomic

`ON CONFLICT DO UPDATE` genuinely is atomic and concurrency-safe for the conflict it
names: it takes a lock on the conflicting row, so two sessions upserting the same key
serialise rather than one losing. That is the whole reason to prefer it over
`SELECT`-then-`INSERT`-or-`UPDATE`, which has a race between the `SELECT` and the write
that no amount of care in application code closes.

But two edges catch people.

**`DO NOTHING` does not lock the conflicting row, and `RETURNING` stays silent about it.**

```sql
INSERT INTO stock (sku, qty) VALUES ('A-1', 1), ('A-9', 4)
ON CONFLICT (sku) DO NOTHING
RETURNING sku, qty;
```

```text
 sku | qty
-----+-----
 A-9 |   4
(1 row)
```

Two rows went in, one came back. `A-1` conflicted, was skipped, and is simply absent from
the output — indistinguishable from a row that was never submitted. Code that upserts a
batch and counts `RETURNING` rows to confirm success will silently under-report. If you
need to know what happened to every row, use `DO UPDATE` — even a no-op one like
`SET sku = EXCLUDED.sku` — so every row is returned.

**Multi-row upserts can deadlock.** Two concurrent statements upserting the same set of
keys in different orders can each hold a row the other needs. The fix is to order the
rows consistently — sort the batch by key before submitting it — which is the same
discipline Chapter 32 recommends for locks generally.

## 5.8 `MERGE`

> **Version note —** `MERGE` requires PostgreSQL 15. On 14 and earlier it does not exist
> and `INSERT ... ON CONFLICT` is the only option.

```sql
MERGE INTO stock s
USING (VALUES ('A-2', 50), ('B-1', 3)) AS v(sku, qty) ON s.sku = v.sku
WHEN MATCHED THEN UPDATE SET qty = v.qty
WHEN NOT MATCHED THEN INSERT (sku, qty) VALUES (v.sku, v.qty);
```

```text
MERGE 2
```

`MERGE` is the SQL-standard spelling, it can express several actions at once — including
`WHEN MATCHED THEN DELETE` — and it does not require a unique constraint, because it
joins on an arbitrary condition rather than inferring a conflict.

**It is not, however, a safer upsert, and in one specific way it is a less safe one.**
`ON CONFLICT` is built on PostgreSQL's unique-index machinery and handles a concurrent
insert of the same key by definition. `MERGE` evaluates its join, decides on an action,
and then performs it — and under concurrency the row it decided was absent may exist by
the time it inserts, producing a unique-violation error.

So the honest rule:

- **Upserting on a key? Use `ON CONFLICT`.** It is concurrency-safe and says what you
  mean.
- **Batch-reconciling two tables with mixed insert/update/delete outcomes, where you
  control concurrency?** `MERGE` expresses that in one readable statement and
  `ON CONFLICT` cannot express it at all.

---

## Summary

- Always name your columns in `INSERT`. Positional inserts break the day the schema
  changes.
- Statement overhead dominates bulk loading. Measured on 20,000 rows in one transaction:
  **3.99 s** one row at a time, **0.06 s** batched at 1,000 per statement, **0.03 s** via
  `COPY`.
- `COPY` reads a file on the *server*; `\copy` reads one on *your machine* and streams it.
  Against a remote database, `\copy` is almost always what you want.
- `COPY` is all-or-nothing. Land dirty input in an all-`text` `UNLOGGED` staging table,
  then promote the valid rows with `INSERT ... SELECT`.
- An `UPDATE` writes a new row version and marks the old one dead. It is more expensive
  than it looks, and a heavily updated table grows even at a constant row count.
- `DELETE` does not free space. `TRUNCATE` does, and is vastly faster for emptying a table.
- Write the `WHERE` clause as a `SELECT` first. There is no confirmation prompt.
- `RETURNING` saves a round trip and closes a race; `(xmax = 0)` distinguishes inserted
  rows from updated ones in an upsert.
- `ON CONFLICT DO UPDATE` is genuinely concurrency-safe. `DO NOTHING` does not lock the
  conflicting row and omits it from `RETURNING` entirely — a silent under-report.
- `MERGE` (PostgreSQL 15+) is more expressive but **not** a concurrency-safe upsert. Use
  `ON CONFLICT` for keyed upserts; use `MERGE` for batch reconciliation.

**Exercises:** Practice Sessions 5.1–5.3 accompany this chapter and are in the
workbook at the back of the book.

**Next:** Chapter 6 turns the data around and gets it back out — `SELECT` and its
clauses, and the evaluation order that explains why an alias works in `ORDER BY` but not
in `WHERE`.
