# Chapter 4 — Creating and Altering Tables

Creating a table is the easy half of this chapter and you will have it in ten minutes.
The other half is the one that matters for the next fifty: knowing, before you press
return, whether the `ALTER TABLE` you just typed will finish in a millisecond or rewrite
two hundred gigabytes.

That distinction is not advanced material. It is introduced here, in the fourth chapter,
because it shapes every schema decision you make from now until Chapter 52 — and because
the people who learn it late learn it during an outage.

---

## 4.1 `CREATE TABLE`

```sql
CREATE TABLE products (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku         text        NOT NULL UNIQUE,
    name        text        NOT NULL,
    category    text        NOT NULL,
    price       numeric(10,2) NOT NULL CHECK (price >= 0),
    in_stock    boolean     NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now()
);
```

Every line there is a decision, and most of them are covered properly later — types in
Part IV, constraints in Chapter 15, identity strategy in Chapter 20. Four things are worth
saying immediately, because they are defaults you should adopt now and stop thinking
about.

**`NOT NULL` unless you have a reason.** Nullable is the default in SQL and it is the
wrong default for most columns. A nullable column is a column where every future query
must decide what absence means. Make that decision once, at design time, by disallowing
it. Chapter 7 will show you what nullable columns cost when you get it wrong.

**`timestamptz`, never `timestamp`.** Chapter 14 makes the full argument. For now: the
version without a time zone silently discards the offset, and there is no recovering it.

**`numeric` for money, never `float`.** Binary floating point cannot represent 0.10
exactly. Chapter 13 shows the resulting reporting discrepancy.

**`GENERATED ALWAYS AS IDENTITY`, not `SERIAL`.** `SERIAL` is older PostgreSQL-specific
syntax that creates a sequence and wires it up as a default. `IDENTITY` is the SQL
standard spelling, it owns the sequence properly, and `ALWAYS` prevents an application
from accidentally supplying its own value and desynchronising the sequence — a genuinely
common production bug. Chapter 20 covers the whole argument.

### Two variants worth knowing now

```sql
CREATE TEMP TABLE scratch (id int);       -- dies with your session
CREATE UNLOGGED TABLE staging (id int);   -- not written to the WAL
```

A **temporary** table is visible only to the session that created it and disappears when
that session ends. It lives in a per-session schema that sits ahead of everything on your
`search_path`, which means a temp table can shadow a real one of the same name — an
excellent debugging mystery if you do not know it is possible.

An **unlogged** table skips the write-ahead log. Writes are substantially faster because
they are not being written twice. The price is absolute: the table is **truncated** after
a crash, and it is not replicated to standbys. That makes it correct for exactly one
thing — data you can regenerate, like a bulk-load staging area or a rebuildable cache.
Using it for anything you would miss is a data-loss incident waiting for a power cut.

## 4.2 `ALTER TABLE`, and the only question that matters

PostgreSQL's DDL is transactional, which is a real advantage over several competitors —
you can wrap a migration in `BEGIN`, discover it is wrong, and `ROLLBACK` with the schema
untouched. Chapter 29 covers that.

But whether a statement is *safe to run on a live system* has nothing to do with
transactions. It comes down to three tiers.

| Tier | What happens | Cost on a big table |
|---|---|---|
| **Metadata only** | A catalog row changes. The data on disk is untouched. | Microseconds to milliseconds |
| **Scan to validate** | Every row is read to check a condition. Nothing is written. | Seconds to minutes |
| **Full rewrite** | A whole new copy of the table is built, then swapped in. | Minutes to hours, plus double the disk |

Here are real measurements. A table of two million rows, 158 MB, on PostgreSQL 15.10:

| Operation | Time | Rewrote? |
|---|---:|---|
| `ADD COLUMN c1 text` | 1.055 ms | no |
| `ADD COLUMN c2 text DEFAULT 'hello'` | 1.139 ms | no |
| `ADD COLUMN c3 int NOT NULL DEFAULT 42` | 0.891 ms | no |
| `ADD COLUMN c4 uuid DEFAULT gen_random_uuid()` | **2,694 ms** | **yes** |
| `ALTER COLUMN code TYPE varchar(50)` *(from `varchar(20)`)* | 1.279 ms | no |
| `ALTER COLUMN code TYPE text` | 1.548 ms | no |
| `ALTER COLUMN code TYPE varchar(30)` *(from `text`)* | **1,134 ms** | **yes** |
| `ALTER COLUMN id TYPE bigint` *(from `int`)* | **1,037 ms** | **yes** |
| `ALTER COLUMN amount TYPE numeric(12,2)` *(from `numeric(10,2)`)* | 1.059 ms | no |
| `ALTER COLUMN label SET NOT NULL` | 136.9 ms | no — but scanned |
| `ALTER COLUMN label DROP NOT NULL` | 1.214 ms | no |
| `DROP COLUMN c4` | 6.876 ms | no |
| `RENAME COLUMN c1 TO c1_renamed` | 0.860 ms | no |

Two million rows is small. Scale that table to two hundred million and the millisecond
operations are still milliseconds, while the 2.7-second one is closer to five minutes with
the table locked throughout.

### Reading the table

**Adding a column is free — even with a default.** This surprises people who learned
PostgreSQL before version 11. Adding a column with a constant default used to rewrite the
table to write that value into every row. Since 11, the default is stored once in the
catalog and materialised as rows are read. `ADD COLUMN ... NOT NULL DEFAULT 42` on two
million rows took **0.891 ms**.

> **Trap —** that fast path requires the default to be **non-volatile**. A constant
> qualifies. `gen_random_uuid()` does not, because every row needs a *different* value, so
> every row must actually be written. That is the 2,694 ms line — three thousand times
> slower than its neighbours, from a change that looks almost identical. The same applies
> to `random()` and `clock_timestamp()`.
>
> If you need a per-row generated value on a large existing table, add the column without
> a default and backfill in batches. Chapter 52 shows the pattern.

**Widening a type is usually free; narrowing never is.** `varchar(20)` → `varchar(50)` is
metadata only, because every existing value is already valid under the new type.
`varchar` → `text` likewise. But `text` → `varchar(30)` must check every row for
compliance, and PostgreSQL implements that as a rewrite. `numeric(10,2)` →
`numeric(12,2)` is free for the same reason — the stored representation does not change.

This is the operational argument behind the advice in Chapter 13: prefer `text` with a
`CHECK` constraint over `varchar(n)`. Not because `varchar` is slower — the two are
identical in storage — but because *changing your mind* about a `CHECK` is cheap and
changing your mind about `varchar(n)` downward is a rewrite.

**`int` → `bigint` rewrites.** Every value physically changes from four bytes to eight.
There is no way around it. This is why Chapter 20 argues for `bigint` primary keys from
the start: the eight bytes you save today are paid back with interest the week you
discover a two-billion-row ceiling on a table you cannot take offline.

**`SET NOT NULL` is the middle tier.** At 136.9 ms it is a hundred times slower than the
metadata operations and ten times faster than the rewrites, because it reads every row to
confirm none is NULL but writes nothing. On a very large table that scan is minutes, with
the table locked. Chapter 52 shows how to avoid it entirely using a validated `CHECK`
constraint.

**`DROP COLUMN` does not reclaim space.** At 6.876 ms it clearly did not rewrite anything.
PostgreSQL marks the column dropped in the catalog and stops showing it; the data stays on
disk in every existing row until those rows are rewritten for some other reason. On a
table where you have dropped several wide columns, the disk usage does not move. Chapter
37 covers reclaiming it.

## 4.3 How to know for certain: `relfilenode`

You do not have to guess or memorise. Every table's physical storage is identified by a
number, and **a rewrite gets a new one.**

```sql
SELECT relfilenode FROM pg_class WHERE relname = 'big';
```

Run it before and after. Unchanged means the data on disk was untouched. Changed means
PostgreSQL built an entirely new copy.

```text
-- ADD COLUMN c3 int NOT NULL DEFAULT 42
relfilenode before: 26411
relfilenode after : 26411        -- untouched

-- ADD COLUMN c4 uuid DEFAULT gen_random_uuid()
relfilenode before: 26411
relfilenode after : 26421        -- rewritten
```

This is the definitive test, it takes five seconds, and it works for any operation on any
version. When you are unsure whether a migration is safe, restore a copy of production,
run it, and compare the number. That is a far better use of an afternoon than reading
release notes and hoping.

> **In production —** a rewrite also needs enough free disk for a **second complete copy**
> of the table and its indexes, at the same time. A 400 GB table needs 400 GB free. Running
> out mid-rewrite rolls the operation back, which is the good outcome; the bad one is a
> full disk taking the whole cluster down.

## 4.4 The lock is the real cost

Everything above measures how long the statement takes to do its work. In production that
is frequently not what hurts you.

Almost every `ALTER TABLE` acquires an `ACCESS EXCLUSIVE` lock — the strongest there is,
conflicting with everything including plain `SELECT`. It is held for the duration. For a
one-millisecond metadata change that sounds harmless.

It is not, and here is why. Three sessions against the 2-million-row table:

- **Session A** opens a transaction, runs a read, and leaves the transaction open.
- **Session B** runs `ALTER TABLE big ADD COLUMN queued_demo int` — one millisecond of
  actual work.
- **Session C** runs `SELECT 1 FROM big LIMIT 1` — trivially fast, and it needs only
  `ACCESS SHARE`, which does not conflict with session A at all.

Six seconds in:

```text
  pid  |        state        | wait_event_type |                    query                    | blocked_by 
-------+---------------------+-----------------+---------------------------------------------+------------
 13257 | idle in transaction | Client          | SELECT count(*) FROM big;                   | {}
 13269 | active              | Lock            | ALTER TABLE big ADD COLUMN queued_demo int; | {13257}
 13278 | active              | Lock            | SELECT 1 FROM big LIMIT 1;                  | {13269}
```

And the timings when it finally cleared:

```text
B (ALTER):     Time: 13191.322 ms (00:13.191)
C (SELECT 1):  Time: 11178.705 ms (00:11.179)
```

Read that chain carefully, because it is the single most important operational fact in
this chapter.

Session B could not start: it needs `ACCESS EXCLUSIVE` and A holds a conflicting lock, so
it **joins the queue**. Session C needs only `ACCESS SHARE`, which is perfectly compatible
with what A holds — on its own it would have run instantly. But PostgreSQL's lock queue is
**ordered**. C arrived after B, and it will not jump ahead of a waiting exclusive request.
So C waits for B, which waits for A.

A one-millisecond schema change blocked a trivial read for eleven seconds. Now imagine C
is not one query but every request your application makes. This is how a "harmless"
migration takes down a service: not by being slow, but by getting stuck behind something
slow and then blocking everything that arrives after it.

> **In production —** never run DDL without a lock timeout:
>
> ```sql
> SET lock_timeout = '3s';
> ALTER TABLE big ADD COLUMN queued_demo int;
> ```
>
> Now the `ALTER` gives up after three seconds instead of queueing indefinitely and taking
> the application down with it. You retry later, when the long transaction has finished.
> Failing fast is the correct behaviour here, and Chapter 52 builds a full migration
> pattern on it.

The corollary: before any DDL on a busy table, check for long-running transactions.
A single forgotten `BEGIN` in an open `psql` window is enough.

## 4.5 Dropping and emptying

```sql
DROP TABLE products;                  -- fails if anything references it
DROP TABLE products CASCADE;          -- drops the dependents too
TRUNCATE products;                    -- empties it
TRUNCATE products RESTART IDENTITY;   -- and resets the identity sequence
```

`TRUNCATE` is not `DELETE FROM`. `DELETE` marks every row dead one at a time, generating
WAL for each, leaving the space to be reclaimed later by vacuum. `TRUNCATE` discards the
underlying files and creates empty ones — effectively instant regardless of size.

The trade-offs are real. `TRUNCATE` takes an `ACCESS EXCLUSIVE` lock, so it has exactly
the queueing behaviour described above. It does not fire row-level triggers. And it cannot
be used on a table referenced by a foreign key unless you truncate that table too, or say
`CASCADE`.

Both are transactional — this rolls back cleanly, which people find reassuring the first
time they try it:

```sql
BEGIN;
TRUNCATE products;
ROLLBACK;   -- the rows are still there
```

> **Trap —** `DROP TABLE ... CASCADE` silently drops every dependent object: views,
> foreign keys from other tables, and anything else pointing at it. It does not list them
> first and it does not ask. Before typing `CASCADE`, run `\d tablename` and read the
> `Referenced by:` section, or check what depends on it in the catalog. `CASCADE` in a
> migration script is how people discover, a week later, that a reporting view no longer
> exists.

---

## Summary

- Default to `NOT NULL`, `timestamptz`, `numeric` for money, and
  `GENERATED ALWAYS AS IDENTITY` for surrogate keys.
- Unlogged tables are faster and are emptied by a crash. Use them only for data you can
  regenerate.
- Every `ALTER TABLE` falls in one of three tiers: metadata only (microseconds), scan to
  validate (proportional to rows, writes nothing), or full rewrite (proportional to rows,
  needs double the disk).
- Adding a column with a **constant** default is free. With a **volatile** default it
  rewrites the table — measured at 0.891 ms versus 2,694 ms on the same two million rows.
- Widening a type is usually free; narrowing rewrites. `int` → `bigint` always rewrites,
  which is the argument for `bigint` keys from day one.
- `DROP COLUMN` is instant and reclaims no space.
- **`relfilenode` changes if and only if the table was rewritten.** This is the definitive
  test; use it instead of guessing.
- The lock is usually the real cost. `ACCESS EXCLUSIVE` conflicts with everything, the
  lock queue is ordered, and a blocked `ALTER` blocks every query that arrives behind it —
  even ones that would not have conflicted. A 1 ms change blocked a trivial `SELECT` for
  11 seconds.
- **Always `SET lock_timeout` before DDL on a live system.** Failing fast is the correct
  outcome.

**Exercises:** Practice Sessions 4.1–4.2 accompany this chapter and are in
the workbook at the back of the book.

**Next:** Chapter 5 puts data into these tables and takes it out again — `INSERT`,
`UPDATE`, `DELETE`, `COPY` for bulk loads, `RETURNING`, and the upsert that looks atomic
and is not quite.
