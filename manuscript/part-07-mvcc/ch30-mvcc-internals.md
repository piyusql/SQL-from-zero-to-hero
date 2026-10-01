# Chapter 30 — MVCC Internals

Chapter 29 gave you transactions. This chapter is how PostgreSQL keeps a transaction's
promises without making readers wait for writers. The mechanism is MVCC (multi-version
concurrency control), and its price is that **every `UPDATE` leaves a corpse behind**.

Bloat, vacuum lag, indexes larger than their tables, and the transaction-id wraparound that
can stop a database all follow from that decision. Chapter 31 covers what readers may see,
Chapter 32 the locks writers take, Chapter 37 the cleanup (`VACUUM`, autovacuum, bloat).

Everything runs in a scratch database with two contrib extensions: `pageinspect` (read a
page's raw bytes) and `pgstattuple` (count live and dead versions exactly). Two-session
steps are labelled `-- Session A` and `-- Session B`: two terminals, in the order shown.
Use `psql -q`.

```bash
createdb ch30_scratch
```

Transaction ids differ on every server and every run: compare them *to each other*, never
to the numbers printed here. On a busy server, other sessions' ids also appear in snapshots.

---

## 30.1 Every row version carries two transaction ids

Every row version has hidden system columns. `xmin` is the id of the transaction that
created it; `xmax` is the id of the one that deleted or replaced it (0 if none has);
`ctid` is its physical address, page then slot.

```sql
\c ch30_scratch
\pset null '(null)'
CREATE EXTENSION pageinspect;
CREATE EXTENSION pgstattuple;

-- autovacuum off on scratch tables only, so nothing tidies up under us.
CREATE TABLE acct (id int PRIMARY KEY, holder text, balance numeric)
  WITH (autovacuum_enabled = false);
INSERT INTO acct VALUES (1, 'Anita Rao', 5000), (2, 'Rajesh Kumar', 7500);

SELECT ctid, xmin, xmax, id, balance FROM acct;
```

```text
 ctid  |  xmin  | xmax | id | balance
-------+--------+------+----+---------
 (0,1) | 184266 |    0 |  1 |    5000
 (0,2) | 184266 |    0 |  2 |    7500
(2 rows)
```

One transaction created both rows. Now change one balance.

```sql
UPDATE acct SET balance = balance - 500 WHERE id = 1;
SELECT ctid, xmin, xmax, id, balance FROM acct;
```

```text
 ctid  |  xmin  | xmax | id | balance
-------+--------+------+----+---------
 (0,2) | 184266 |    0 |  2 |    7500
 (0,3) | 184267 |    0 |  1 |    4500
(2 rows)
```

Anita's row moved from `(0,1)` to `(0,3)` with a new `xmin`. `UPDATE` does not modify a
row: it writes a new version and marks the old one replaced. `SELECT` shows only the
version visible to you; `pageinspect` shows all of them:

```sql
SELECT lp, t_xmin, t_xmax, t_ctid, lp_len
FROM heap_page_items(get_raw_page('acct', 0)) ORDER BY lp;
```

```text
 lp | t_xmin | t_xmax | t_ctid | lp_len
----+--------+--------+--------+--------
  1 | 184266 | 184267 | (0,3)  |     43
  2 | 184266 |      0 | (0,2)  |     46
  3 | 184267 |      0 | (0,3)  |     43
(3 rows)
```

Three physical tuples for two logical rows. Slot 1 is the old version: its `t_xmax` equals
the `t_xmin` of slot 3, the updater, and its `t_ctid` points forward to slot 3, which is
current and points at itself. Following `t_ctid` is the *update chain*, how a concurrent
updater finds the latest version (Chapter 31).

> **Trap —** `ctid` is an address, not an identity. It changes on every update. Never
> store it or use it as a key.

`DELETE` only sets `xmax`; it frees nothing.

**A premise worth correcting: a non-zero `xmax` does not mean "deleted".** `SELECT ... FOR
UPDATE` also writes the locker's id into `xmax`, on a row that stays live.

```sql
BEGIN;
SELECT id FROM acct WHERE id = 1 FOR UPDATE;
SELECT lp, t_xmax <> 0 AS xmax_set, t_ctid,
       'HEAP_XMAX_LOCK_ONLY' = ANY((heap_tuple_infomask_flags(t_infomask, t_infomask2)).raw_flags) AS lock_only
FROM heap_page_items(get_raw_page('acct', 0)) WHERE lp = 3;
ROLLBACK;
```

```text
 id
----
  1
(1 row)

 lp | xmax_set | t_ctid | lock_only
----+----------+--------+-----------
  3 | t        | (0,3)  | t
(1 row)
```

`xmax` is set, `t_ctid` still points at itself, and the `HEAP_XMAX_LOCK_ONLY` infomask bit
says this is a lock, not a deletion. Reading an `xmax` takes the infomask bits *and* whether
that transaction committed. Chapter 32 covers locks.

---

## 30.2 Snapshots decide which version you see

Each query needs a rule for which version is "the" row. The rule is a **snapshot**, taken
per statement (Read Committed) or per transaction (Repeatable Read, Serializable). It is
`xmin`, the oldest transaction still running; `xmax`, the first id not yet assigned, so
everything at or above it is "the future"; and `xip`, the ids in between still running.
It prints as `xmin:xmax:xip`.

A version is visible when its `xmin` committed and is not in the future or in `xip`, and
its `xmax` is unset, aborted, or not visible to the snapshot. Readers skip versions they
cannot see, so they never wait on writers. Session A updates without committing:

```sql
-- Session A
BEGIN;
UPDATE acct SET balance = balance - 500 WHERE id = 1;
SELECT txid_current() AS a_xid;
```

```text
 a_xid
--------
 184269
(1 row)
```

Session B reads the same row and gets the old version, A's id in `xmax`: A has not
committed, so its deletion does not count. B is not blocked.

```sql
-- Session B
SELECT ctid, xmin, xmax, balance FROM acct WHERE id = 1;
```

```text
 ctid  |  xmin  |  xmax  | balance
-------+--------+--------+---------
 (0,3) | 184267 | 184269 |    4500
(1 row)
```

To see A in `xip`, B first consumes an id of its own, so that A's id falls below the
snapshot's `xmax`:

```sql
-- Session B
SELECT txid_current() AS b_xid;
SELECT pg_current_snapshot() AS snapshot;
```

```text
 b_xid
--------
 184270
(1 row)

       snapshot
----------------------
 184269:184271:184269
(1 row)
```

That reads `a_xid:b_xid+1:a_xid`: nothing older than A is running, `b_xid+1` and up is the
future, A is in progress. A commits; B's next statement takes a fresh snapshot:

```sql
-- Session A
COMMIT;
```

```sql
-- Session B
SELECT ctid, xmin, xmax, balance FROM acct WHERE id = 1;
```

```text
 ctid  |  xmin  | xmax | balance
-------+--------+------+---------
 (0,4) | 184269 |    0 |    4000
(1 row)
```

B sees the new version at a new `ctid`: Read Committed, a snapshot per statement. With
`REPEATABLE READ` the snapshot is taken once and held:

```sql
-- Session B
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT ctid, xmin, xmax, balance FROM acct WHERE id = 1;
```

```text
 ctid  |  xmin  | xmax | balance
-------+--------+------+---------
 (0,4) | 184269 |    0 |    4000
(1 row)
```

```sql
-- Session A
BEGIN;
UPDATE acct SET balance = balance - 500 WHERE id = 1;
SELECT txid_current() AS a_xid;
COMMIT;
```

```text
 a_xid
--------
 184271
(1 row)
```

```sql
-- Session B
SELECT ctid, xmin, xmax, balance FROM acct WHERE id = 1;
COMMIT;
SELECT ctid, xmin, xmax, balance FROM acct WHERE id = 1;
```

```text
 ctid  |  xmin  |  xmax  | balance
-------+--------+--------+---------
 (0,4) | 184269 | 184271 |    4000
(1 row)

 ctid  |  xmin  | xmax | balance
-------+--------+------+---------
 (0,5) | 184271 |    0 |    3500
(1 row)
```

B still sees `(0,4)` although A committed: A's id is at or above B's snapshot `xmax`, so for
B that transaction has not happened yet. After `COMMIT`, a new snapshot sees `(0,5)`.

---

## 30.3 Write amplification: the whole row, every time

A new version is a complete copy of the row. Change a four-byte integer in a 944-byte row
and you write 944 bytes. A `profile` table with a `bio` of about a kilobyte:

```sql
CREATE TABLE profile (id int PRIMARY KEY, holder text, bio text, logins int DEFAULT 0)
  WITH (autovacuum_enabled = false);
INSERT INTO profile
SELECT g, 'holder ' || g, (SELECT string_agg(md5(g || '-' || i), '') FROM generate_series(1, 28) i), 0
FROM generate_series(1, 2000) g;

SELECT pg_relation_size('profile') / 8192 AS pages, tuple_count, tuple_len / tuple_count AS avg_row_bytes
FROM pgstattuple('profile');
```

```text
 pages | tuple_count | avg_row_bytes
-------+-------------+---------------
   250 |        2000 |           944
(1 row)
```

Now bump `logins` three times, in one transaction so nothing can be reclaimed in between:

```sql
BEGIN;
UPDATE profile SET logins = logins + 1;
UPDATE profile SET logins = logins + 1;
UPDATE profile SET logins = logins + 1;
COMMIT;

SELECT pg_relation_size('profile') / 8192 AS pages, tuple_count, dead_tuple_count, dead_tuple_len
FROM pgstattuple('profile');
```

```text
 pages | tuple_count | dead_tuple_count | dead_tuple_len
-------+-------------+------------------+----------------
  1000 |        2000 |             6000 |        5664000
(1 row)
```

2,000 live rows, 6,000 dead versions, a table four times its size, from one integer. Counters like `logins` in wide rows are the worst case: the cost is the width of the row,
not of the column.

The exception is a value stored out of line. Values over about 2 KB go to the table's
TOAST relation, and an `UPDATE` that does not touch one leaves it alone. Same table, with a
4 KB `bio` forced out of line:

```sql
CREATE TABLE profile_x (LIKE profile INCLUDING ALL) WITH (autovacuum_enabled = false);
ALTER TABLE profile_x ALTER COLUMN bio SET STORAGE EXTERNAL;
INSERT INTO profile_x
SELECT g, 'holder ' || g, (SELECT string_agg(md5(g || '-' || i), '') FROM generate_series(1, 130) i), 0
FROM generate_series(1, 2000) g;

SELECT pg_relation_size('profile_x') / 8192 AS heap_pages,
       pg_relation_size((SELECT reltoastrelid FROM pg_class WHERE relname = 'profile_x')) / 8192 AS toast_pages;

BEGIN;
UPDATE profile_x SET logins = logins + 1;
UPDATE profile_x SET logins = logins + 1;
UPDATE profile_x SET logins = logins + 1;
COMMIT;

SELECT pg_relation_size('profile_x') / 8192 AS heap_pages,
       pg_relation_size((SELECT reltoastrelid FROM pg_class WHERE relname = 'profile_x')) / 8192 AS toast_pages,
       dead_tuple_count, dead_tuple_len
FROM pgstattuple('profile_x');
```

```text
 heap_pages | toast_pages
------------+-------------
         17 |        1334
(1 row)

 heap_pages | toast_pages | dead_tuple_count | dead_tuple_len
------------+-------------+------------------+----------------
         67 |        1334 |             6000 |         382812
(1 row)
```

Still 6,000 dead versions, but 64-byte ones; the 4 KB values were never copied. A hot
column sharing a row with a large one is the case for splitting the table (Chapter 22).

---

## 30.4 Dead tuples, and who decides when they die

A dead version can be removed once **no snapshot that could still see it exists**. The
oldest such snapshot is the *horizon*; `VACUUM` reclaims what is behind it.

```sql
CREATE TABLE ledger (id int PRIMARY KEY, holder text, balance numeric)
  WITH (autovacuum_enabled = false);
INSERT INTO ledger
SELECT g, (ARRAY['Anita Rao','Rajesh Kumar','Priya Menon','Arjun Iyer','Fatima Sheikh','Harpreet Singh'])[1 + g % 6], 1000
FROM generate_series(1, 10000) g;
```

Session B takes a snapshot and goes idle, the "idle in transaction" of Chapter 29. Session
A updates every row and runs `VACUUM`:

```sql
-- Session B
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT count(*) FROM ledger;
```

```text
 count
-------
 10000
(1 row)
```

```sql
-- Session A
UPDATE ledger SET balance = balance + 1;
VACUUM ledger;
SELECT pg_relation_size('ledger') / 8192 AS pages, tuple_count, dead_tuple_count
FROM pgstattuple('ledger');
```

```text
 pages | tuple_count | dead_tuple_count
-------+-------------+------------------
   128 |       10000 |            10000
(1 row)
```

`VACUUM` ran, and all 10,000 dead versions are still there, because B's snapshot might
still need them. The culprit is findable:

```sql
SELECT state, backend_xmin IS NOT NULL AS holds_horizon
FROM pg_stat_activity
WHERE datname = 'ch30_scratch' AND pid <> pg_backend_pid() AND backend_xmin IS NOT NULL;
```

```text
        state        | holds_horizon
---------------------+---------------
 idle in transaction | t
(1 row)
```

B commits, `VACUUM` runs again:

```sql
-- Session B
COMMIT;
```

```sql
-- Session A
VACUUM ledger;
SELECT pg_relation_size('ledger') / 8192 AS pages, tuple_count, dead_tuple_count, round(free_percent) AS free_pct
FROM pgstattuple('ledger');
```

```text
 pages | tuple_count | dead_tuple_count | free_pct
-------+-------------+------------------+----------
   128 |       10000 |                0 |       50
(1 row)
```

The dead versions are gone but the table is still 128 pages: **`VACUUM` makes space
reusable; it does not return it to the operating system.** The next round of updates fills
that space instead of extending the file:

```sql
UPDATE ledger SET balance = balance + 1;
SELECT pg_relation_size('ledger') / 8192 AS pages, dead_tuple_count FROM pgstattuple('ledger');
```

```text
 pages | dead_tuple_count
-------+------------------
   128 |            10000
(1 row)
```

128 pages against 64 when fresh is the floor for a table that rewrites every row between
vacuums. A table vacuum cannot clean keeps growing past it.

**Premise check: `VACUUM`'s horizon is per database.** It is widely repeated that one open
transaction anywhere in the cluster blocks vacuum everywhere. On this server (PostgreSQL
15.10) it does not. Repeat the test with the open transaction in `retail`, and make it a
writer, holding a transaction id:

```sql
-- Session C (connected to retail)
BEGIN;
SELECT txid_current() > 0 AS has_xid;
```

```text
 has_xid
---------
 t
(1 row)
```

```sql
-- Session A
UPDATE ledger SET balance = balance + 1;
VACUUM ledger;
SELECT dead_tuple_count FROM pgstattuple('ledger');
```

```text
 dead_tuple_count
------------------
                0
(1 row)
```

```sql
-- Session C (connected to retail)
ROLLBACK;
```

Vacuum was not held back. A long transaction in the *same* database is the usual cause of
stuck vacuum; replication slots and prepared transactions also hold a horizon, which I have
not reproduced here. I alert on the age of `backend_xmin` and on `idle in
transaction` sessions, and set `idle_in_transaction_session_timeout` (Chapter 29).

> **In production —** `pg_stat_user_tables.n_dead_tup` is an *estimate*: graph it, do not
> assert on it. `pgstattuple` is exact but reads the whole table, so keep it off a hot
> terabyte table. Monitoring and repair are Chapter 37.

---

## 30.5 HOT updates: the fast path that skips the indexes

An index entry points at a heap `ctid`. A plain update creates a new version at a new
`ctid`, so **every index on the table needs a new entry**, even those on unchanged columns:
with five indexes, one `UPDATE` becomes six writes. A **heap-only tuple (HOT) update**
avoids that, and requires two things:

1. no indexed column changes, and
2. the new version fits on the *same page* as the old one.

The index keeps pointing at the first version, and a read follows the chain within the page.

```sql
CREATE TABLE one (id int PRIMARY KEY, status text, city text)
  WITH (autovacuum_enabled = false);
CREATE INDEX one_city ON one (city);
INSERT INTO one VALUES (1, 'new', 'Pune');
UPDATE one SET status = 'packed';
UPDATE one SET status = 'shipped';

SELECT lp, t_ctid,
       'HEAP_HOT_UPDATED' = ANY(f.raw_flags) AS hot_updated,
       'HEAP_ONLY_TUPLE' = ANY(f.raw_flags) AS heap_only
FROM heap_page_items(get_raw_page('one', 0)),
     LATERAL heap_tuple_infomask_flags(t_infomask, t_infomask2) f
ORDER BY lp;
```

```text
 lp | t_ctid | hot_updated | heap_only
----+--------+-------------+-----------
  1 | (0,2)  | t           | f
  2 | (0,3)  | t           | t
  3 | (0,3)  | f           | t
(3 rows)
```

Slot 1 is the only version an index entry points to; slots 2 and 3 are *heap-only*, and no
index knows they exist. `status` is not indexed, so those updates were HOT. Change the
indexed `city` and the rules change:

```sql
SELECT pg_sleep(2) \g /dev/null
SELECT n_tup_upd, n_tup_hot_upd FROM pg_stat_user_tables WHERE relname = 'one';
UPDATE one SET city = 'Kochi';
SELECT pg_sleep(2) \g /dev/null
SELECT n_tup_upd, n_tup_hot_upd FROM pg_stat_user_tables WHERE relname = 'one';
```

```text
 n_tup_upd | n_tup_hot_upd
-----------+---------------
         2 |             2
(1 row)

 n_tup_upd | n_tup_hot_upd
-----------+---------------
         3 |             2
(1 row)
```

Two updates, both HOT; the third was not. (The `pg_sleep` lets the asynchronous statistics
flush.) Now scale, on one row: 300 autocommit updates of `status`, then 300 of `city`.

```sql
\o /dev/null
SELECT format('UPDATE one SET status = %L', 's' || i) FROM generate_series(1, 300) i \gexec
\o
SELECT pg_relation_size('one') / 8192 AS heap_pages;
SELECT lp_flags, count(*), max(lp_len) AS max_bytes
FROM heap_page_items(get_raw_page('one', 0)) GROUP BY 1 ORDER BY 1;
SELECT lp, lp_flags FROM heap_page_items(get_raw_page('one', 0)) WHERE lp_flags IN (2, 3) ORDER BY lp;
SELECT ctid AS index_entry_points_at FROM bt_page_items('one_city', 1) ORDER BY itemoffset;
```

```text
 heap_pages
------------
          1
(1 row)

 lp_flags | count | max_bytes
----------+-------+-----------
        0 |    27 |         0
        1 |   138 |        39
        2 |     1 |         0
        3 |     1 |         0
(4 rows)

 lp | lp_flags
----+----------
  1 |        3
  4 |        2
(2 rows)

 index_entry_points_at
-----------------------
 (0,4)
 (0,1)
(2 rows)
```

One page, though 304 versions of up to 40 bytes were written, more than 8 KB. HOT chains
are **pruned**: when a page runs short of room, whichever backend touches it next removes
dead heap-only versions on the spot, no `VACUUM` involved. The flags are 0 unused, 1
normal, 2 redirect, 3 dead. Slot 4 is a redirect: the `city` index entry for Kochi points
there, and it forwards to the live end of the chain. Slot 1 is dead, a stub with no data,
kept because the index entry for Pune still points at it. Only `VACUUM` can clear that.
Now `city`:

```sql
\o /dev/null
SELECT format('UPDATE one SET city = %L', 'c' || i) FROM generate_series(1, 300) i \gexec
\o
SELECT pg_sleep(2) \g /dev/null
SELECT n_tup_upd, n_tup_hot_upd FROM pg_stat_user_tables WHERE relname = 'one';
SELECT 'one_pkey' AS idx, count(*) AS entries FROM bt_page_items('one_pkey', 1)
UNION ALL
SELECT 'one_city', count(*) FROM bt_page_items('one_city', 1);
```

```text
 n_tup_upd | n_tup_hot_upd
-----------+---------------
       603 |           302
(1 row)

   idx    | entries
----------+---------
 one_pkey |     302
 one_city |     302
(2 rows)
```

All 301 updates of `city` were non-HOT (603 updates, 302 HOT). One live row has 302
entries in *each* of its two indexes, including the primary key, whose column never
changed. Index entries are not pruned like heap-only tuples; they wait for `VACUUM`. That
is index bloat, and it is why indexing a constantly updated column costs more than the
index's read benefit suggests (Chapter 33).

> **In production —** Before adding an index, check whether the column is updated: an index
> on `status` or `updated_at` makes every update of it non-HOT. Watch `n_tup_hot_upd /
> n_tup_upd` in `pg_stat_user_tables`.

> **Trap —** Pruning runs inside ordinary statements, on *that statement's snapshot*, and a
> snapshot's `xmin` is the oldest transaction id running anywhere in the cluster. An open
> transaction that has written something, in any database, switches pruning off everywhere,
> although `VACUUM` in 30.4 ignored it. A writer in `retail`, and a fresh table here:

```sql
-- Session C (connected to retail)
BEGIN;
SELECT txid_current() > 0 AS has_xid;
```

```text
 has_xid
---------
 t
(1 row)
```

```sql
-- Session A
CREATE TABLE one2 (id int PRIMARY KEY, status text) WITH (autovacuum_enabled = false);
INSERT INTO one2 VALUES (1, 'new');
\o /dev/null
SELECT format('UPDATE one2 SET status = %L', 's' || i) FROM generate_series(1, 300) i \gexec
\o
SELECT pg_relation_size('one2') / 8192 AS heap_pages;
```

```text
 heap_pages
------------
          2
(1 row)
```

```sql
-- Session C (connected to retail)
ROLLBACK;
```

Same 300 updates as `one`, but two pages: nothing could be pruned. This is also why the next
section's figures come from a quiet server; on a busy one your HOT percentages will be
lower.

---

## 30.6 `fillfactor`: leave room on purpose

Condition 2 needs room on the page, and a table loaded to 100% has none. `fillfactor` makes
`INSERT` stop filling a page at N%, keeping the rest for new versions. Four copies of one
table, same workload: 20 rounds, each updating a different tenth of the rows (`status`,
unindexed; `city` is indexed).

```sql
SELECT format('CREATE TABLE ff%s (id int PRIMARY KEY, city text, status text) WITH (fillfactor = %s, autovacuum_enabled = false)', f, f)
FROM unnest(ARRAY[100, 90, 80, 70]) f \gexec
SELECT format('CREATE INDEX ON ff%s (city)', f) FROM unnest(ARRAY[100, 90, 80, 70]) f \gexec
SELECT format($q$INSERT INTO ff%s SELECT g, (ARRAY['Pune','Kochi','Indore','Jaipur','Chennai'])[1 + g %% 5], 'new' FROM generate_series(1, 10000) g$q$, f)
FROM unnest(ARRAY[100, 90, 80, 70]) f \gexec

SELECT c.relname, pg_relation_size(c.oid) / 8192 AS heap_at_load,
       (SELECT sum(pg_relation_size(i.indexrelid) / 8192) FROM pg_index i WHERE i.indrelid = c.oid) AS index_at_load
FROM pg_class c WHERE c.relname ~ '^ff[0-9]+$' ORDER BY substr(c.relname, 3)::int DESC;
```

```text
 relname | heap_at_load | index_at_load
---------+--------------+---------------
 ff100   |           55 |            42
 ff90    |           60 |            42
 ff80    |           68 |            42
 ff70    |           78 |            42
(4 rows)
```

```sql
\o /dev/null
SELECT format('UPDATE %s SET status = %L WHERE id %% 10 = %s', t, 's' || r, r % 10)
FROM generate_series(1, 20) r, unnest(ARRAY['ff100', 'ff90', 'ff80', 'ff70']) t
ORDER BY r, t \gexec
\o
SELECT pg_sleep(2) \g /dev/null

SELECT c.relname, pg_relation_size(c.oid) / 8192 AS heap_pages,
       round(100.0 * s.n_tup_hot_upd / s.n_tup_upd) AS hot_pct,
       (SELECT sum(pg_relation_size(i.indexrelid) / 8192) FROM pg_index i WHERE i.indrelid = c.oid) AS index_pages
FROM pg_class c JOIN pg_stat_user_tables s ON s.relid = c.oid
WHERE c.relname ~ '^ff[0-9]+$' ORDER BY substr(c.relname, 3)::int DESC;
```

```text
 relname | heap_pages | hot_pct | index_pages
---------+------------+---------+-------------
 ff100   |        108 |      50 |          75
 ff90    |        102 |      65 |          72
 ff80    |         79 |      92 |          43
 ff70    |         78 |     100 |          42
(4 rows)
```

At 70 the table loads 42% larger (78 pages against 55), but all 20,000 updates were HOT,
it never grew, and its indexes stayed at their built 42 pages. At 100 it loaded smallest
and ended largest: 108 pages, half its updates non-HOT, 75 index pages.

I would not set 70 everywhere; it wastes space on append-only and rarely updated tables.
Candidates are small hot ones (counters, job-state rows). Start at 90 or 80.

> **Trap —** `ALTER TABLE ... SET (fillfactor = 70)` affects only pages written afterwards:

```sql
ALTER TABLE ff100 SET (fillfactor = 70);
SELECT pg_relation_size('ff100') / 8192 AS pages_after, reloptions FROM pg_class WHERE relname = 'ff100';
```

```text
 pages_after |                reloptions
-------------+------------------------------------------
         108 | {autovacuum_enabled=false,fillfactor=70}
(1 row)
```

Rewriting a live table is a Chapter 37 job.

---

## 30.7 Freezing and wraparound

A transaction id is 32 bits, and visibility compares ids *circularly*: about 2.1 billion
are "older" than any id and 2.1 billion "newer". A row written 2.1 billion transactions
ago would suddenly compare as newer than now and vanish from every snapshot. That is
**transaction id wraparound**. The defence is **freezing**: `VACUUM` marks old, all-visible
versions as frozen ("visible to everyone, whatever the ids say") and advances the table's
`relfrozenxid` past them.

```sql
CREATE TABLE frz (id int PRIMARY KEY, note text) WITH (autovacuum_enabled = false);
INSERT INTO frz SELECT g, 'x' FROM generate_series(1, 1000) g;

SELECT age(relfrozenxid) AS table_age FROM pg_class WHERE relname = 'frz';
```

```text
 table_age
-----------
         2
(1 row)
```

`age` counts transactions since that id. Spend five thousand ids and look again:

```sql
\o /dev/null
SELECT 'SELECT txid_current()' FROM generate_series(1, 5000) \gexec
\o
SELECT age(relfrozenxid) AS table_age FROM pg_class WHERE relname = 'frz';
```

```text
 table_age
-----------
      5004
(1 row)
```

Now freeze:

```sql
VACUUM (FREEZE) frz;
SELECT age(relfrozenxid) AS table_age FROM pg_class WHERE relname = 'frz';
SELECT t_xmin, (heap_tuple_infomask_flags(t_infomask, t_infomask2)).combined_flags AS flags
FROM heap_page_items(get_raw_page('frz', 0)) WHERE lp = 1;
```

```text
 table_age
-----------
         0
(1 row)

 t_xmin |       flags
--------+--------------------
 185351 | {HEAP_XMIN_FROZEN}
(1 row)
```

The age is back near zero and the row carries `HEAP_XMIN_FROZEN`. Its `t_xmin` is still the
original id: freezing sets a flag rather than overwriting it.

Wraparound itself I did not try to reproduce; it takes two billion transactions. The
trigger is a setting:

```sql
SHOW autovacuum_freeze_max_age;
```

```text
 autovacuum_freeze_max_age
---------------------------
 200000000
(1 row)
```

At that age (200 million by default) autovacuum starts an *anti-wraparound* vacuum on any
table whose `relfrozenxid` has reached it; per the documentation, even if autovacuum is
disabled and the table has no dead rows. This is the unexpected multi-hour vacuum on a big,
quiet, insert-only table: it must read all of it to freeze it. If freezing cannot progress
(a long transaction, an abandoned replication slot), age keeps climbing until, a few
million ids short of the limit, the server stops accepting writes until a manual vacuum
finishes. I have not reproduced that.

> **In production —** Graph `age(datfrozenxid)` and per-table `age(relfrozenxid)`. Past 500
> million is a ticket; past a billion, an incident. Tuning and the runbook are Chapter 37.

---

```bash
dropdb ch30_scratch
```

---

## Summary

- `UPDATE` writes a new version and sets `xmax` on the old one; old `t_xmax` equals new
  `t_xmin`, old `t_ctid` points forward. `DELETE` only sets `xmax`. `ctid` is an address,
  not an identity. A non-zero `xmax` can be a mere lock (`HEAP_XMAX_LOCK_ONLY`).
- A snapshot is `xmin:xmax:xip`. Readers skip versions they cannot see, so they never wait.
  Read Committed snapshots per statement, Repeatable Read per transaction.
- Write amplification is the width of the row: one integer changed, 944 bytes rewritten,
  6,000 dead versions from three updates of 2,000 rows. Unchanged TOASTed values are not
  copied.
- `VACUUM` removes only what is behind the horizon, and makes space reusable rather than
  returning it. An idle transaction in the same database held back all 10,000 dead
  versions; a writer in another database held back none.
- HOT needs no indexed column changed and room on the page. 300 HOT updates stayed on one
  page; 301 non-HOT ones left 302 entries in each of two indexes. Any open writer on the
  server switches pruning off.
- `fillfactor` 70 took HOT updates from 50% to 100% and stopped growth, for 42% more space
  at load. `ALTER` does not touch existing pages.
- Freezing defeats id wraparound; anti-wraparound vacuum starts at
  `autovacuum_freeze_max_age` whether you want it or not.

**Exercises:** Practice Sessions 30.1–30.3 accompany this chapter and are in the
workbook at the back of the book.

**Next:** Chapter 31, *Isolation Levels and Anomalies*, takes the snapshot rules from 30.2
and reproduces every anomaly each isolation level allows.
