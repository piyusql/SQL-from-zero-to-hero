# Chapter 32 — Locking, Deadlocks, and Concurrency Patterns

Chapter 30 showed that readers and writers do not block each other. What MVCC cannot remove
is writers colliding: two transactions on one row, a migration asking for a table every query
is using, a worker pool fighting over one queue. This chapter covers what PostgreSQL locks
and in which mode, how to refuse to wait, how a deadlock forms and how to design it out,
and the patterns for read-then-write logic.

The demonstrations use two or three `psql` sessions. Type the steps in the order shown; each
transcript was captured in that order, each step issued once the previous had finished or
was confirmed blocked. Terminals ran `psql -q` (no command tags such as
`UPDATE 1`), and `A=>`, `B=>` are session labels. Create the scratch databases and tables,
and run `\pset null '(null)'` in each terminal:

```bash
createdb ch32_lab
createdb ch32_other
psql -X -d ch32_lab
```

```sql
CREATE TABLE accounts (
    id      int PRIMARY KEY,
    holder  text NOT NULL,
    balance numeric(12,2) NOT NULL CHECK (balance >= 0)
);
INSERT INTO accounts (id, holder, balance) VALUES
    (1, 'Kavya Nair', 10000), (2, 'Rohan Deshmukh', 5000), (3, 'Imran Qureshi', 2500);

CREATE TABLE ledger (
    id         int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_id int NOT NULL REFERENCES accounts (id),
    amount     numeric(12,2) NOT NULL
);

CREATE TABLE jobs (
    id         int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payload    text NOT NULL,
    status     text NOT NULL DEFAULT 'queued',
    claimed_by text
);
INSERT INTO jobs (payload) SELECT 'dispatch SW-' || (1000 + g) FROM generate_series(1, 8) AS g;

CREATE TABLE coach (
    id         int PRIMARY KEY,
    seats_left int NOT NULL CHECK (seats_left >= 0),
    version    int NOT NULL DEFAULT 1
);
INSERT INTO coach VALUES (1, 10, 1);
```

---

## 32.1 Table locks: eight modes, one matrix

Every statement locks each table it touches first, in a mode that depends on the statement.
This script asks the lock table what each took (`\gset` swallows a query's output):

```sql
\pset format unaligned
\pset tuples_only on
\set held 'SELECT string_agg(mode, '', '' ORDER BY mode) FROM pg_locks WHERE relation = ''accounts''::regclass AND pid = pg_backend_pid()'

\echo -n 'SELECT                    '
BEGIN; SELECT count(*) FROM accounts \gset
:held; ROLLBACK;
\echo -n 'SELECT ... FOR UPDATE     '
BEGIN; SELECT id FROM accounts WHERE id = 1 FOR UPDATE \gset
:held; ROLLBACK;
\echo -n 'UPDATE                    '
BEGIN; UPDATE accounts SET holder = holder WHERE id = 1;
:held; ROLLBACK;
\echo -n 'ANALYZE                   '
BEGIN; ANALYZE accounts;
:held; ROLLBACK;
\echo -n 'CREATE INDEX              '
BEGIN; CREATE INDEX ON accounts (holder);
:held; ROLLBACK;
\echo -n 'ADD COLUMN                '
BEGIN; ALTER TABLE accounts ADD COLUMN branch text;
:held; ROLLBACK;
\pset format aligned
\pset tuples_only off
```

```text
SELECT                    AccessShareLock
SELECT ... FOR UPDATE     RowShareLock
UPDATE                    RowExclusiveLock
ANALYZE                   ShareUpdateExclusiveLock
CREATE INDEX              ShareLock
ADD COLUMN                AccessExclusiveLock
```

Reads and writes take the three weakest modes, and **the weak modes do not conflict with
each other**. Two `UPDATE`s on one table both hold `ROW EXCLUSIVE` and neither waits at
table level; row locks (32.2) decide whether they wait. The strong modes belong to DDL and
maintenance.

Which pairs conflict? The documentation has the matrix; here it is derived. For each mode,
session A holds `LOCK TABLE ... IN <mode> MODE`, and session B requests each of the eight
with `NOWAIT`. `X` means B was refused. The script is Practice Session 32.1.

```text
held \ asked   AS   RS   RX  SUX    S  SRX    X   AX
AS               .    .    .    .    .    .    .    X
RS               .    .    .    .    .    .    X    X
RX               .    .    .    .    X    X    X    X
SUX              .    .    .    X    X    X    X    X
S                .    .    X    X    .    X    X    X
SRX              .    .    X    X    X    X    X    X
X                .    X    X    X    X    X    X    X
AX               X    X    X    X    X    X    X    X
```

AS is `ACCESS SHARE`, RS `ROW SHARE`, RX `ROW EXCLUSIVE`, SUX `SHARE UPDATE EXCLUSIVE`, S
`SHARE`, SRX `SHARE ROW EXCLUSIVE`, X `EXCLUSIVE`, AX `ACCESS EXCLUSIVE`. The matrix is
symmetric and matches the documentation cell for cell. Three readings matter:

- **AS conflicts only with AX.** A plain `SELECT` waits only for statements that take AX:
  most `ALTER TABLE` forms (`ADD COLUMN` above), `TRUNCATE`, an explicit `LOCK TABLE`.
- **RX conflicts with S.** `CREATE INDEX` without `CONCURRENTLY` holds `SHARE`, blocking
  every writer and no reader.
- **SUX conflicts with itself.** `ANALYZE` took it above; a second `ANALYZE` waits.

> **Trap —** A lock request that cannot be granted joins a queue, and every later request
> that conflicts with *it* waits behind it, even if it conflicts with nothing held. Chapter 24
> staged a `SELECT` stuck behind an `ALTER TABLE` stuck behind a forgotten open transaction.
> Which `ALTER TABLE` forms take which mode is Chapter 52 and Appendix C.

---

## 32.2 Row locks: four modes, stored in the row

Table locks stop at the table door. Two transactions changing one row are arbitrated by
**row locks**, in four modes from weakest to strongest: `FOR KEY SHARE`, `FOR SHARE`,
`FOR NO KEY UPDATE`, `FOR UPDATE`. The same experiment, with two sessions locking one row
and `NOWAIT` on the second:

```text
held \ asked   KEY SHARE  SHARE  NO KEY UPDATE  UPDATE
KEY SHARE          .        .          .          X
SHARE              .        .          X          X
NO KEY UPDATE      .        X          X          X
UPDATE             X        X          X          X
```

`FOR UPDATE` conflicts with all four; `KEY SHARE` conflicts with nothing else. The reason
is foreign keys. An `UPDATE` that leaves key columns alone takes `NO KEY UPDATE`; a `DELETE`,
or an `UPDATE` of a key column, takes `FOR UPDATE`. Inserting a child row makes the
foreign-key check lock the parent row `FOR KEY SHARE`: the parent cannot vanish before you
commit, but anything that leaves its key alone proceeds. A inserts a ledger row for
account 1 and stays open (B ran `\set VERBOSITY terse` to drop error context lines, whose
tuple addresses vary).

```text
A=> BEGIN;
A=> INSERT INTO ledger (account_id, amount) VALUES (1, 500);
B=> UPDATE accounts SET holder = 'Kavya S. Nair' WHERE id = 1;
B=> SET lock_timeout = '200ms';
B=> UPDATE accounts SET id = 100 WHERE id = 1;
ERROR:  canceling statement due to lock timeout
B=> DELETE FROM accounts WHERE id = 1;
ERROR:  canceling statement due to lock timeout
B=> RESET lock_timeout;
A=> ROLLBACK;
B=> UPDATE accounts SET holder = 'Kavya Nair' WHERE id = 1;
```

The non-key `UPDATE` went through while A's child insert was uncommitted; changing the key,
or deleting, waited until `lock_timeout` cancelled it. A foreign-key check is a lock
acquisition you did not write, which matters in 32.5. Chapter 22 measured the other half of
the bill: without an index on the child column, a parent delete scanned all 20,001 child rows.

**Row locks are not in the lock table.** Session A locks one row and reads its own locks;
session B asks `pgrowlocks` (contrib: `CREATE EXTENSION pgrowlocks`), which reads the heap.

```text
A=> BEGIN;
A=> SELECT id FROM accounts WHERE id = 1 FOR UPDATE \gset
A=> SELECT locktype, relation::regclass AS rel, mode, granted
A-> FROM pg_locks
A-> WHERE pid = pg_backend_pid() AND locktype <> 'virtualxid'
A->   AND relation IS DISTINCT FROM 'pg_locks'::regclass
A-> ORDER BY 1, 2;
   locktype    |      rel      |     mode      | granted
---------------+---------------+---------------+---------
 relation      | accounts      | RowShareLock  | t
 relation      | accounts_pkey | RowShareLock  | t
 transactionid | (null)        | ExclusiveLock | t
(3 rows)

B=> SELECT locked_row, multi, modes FROM pgrowlocks('accounts');
 locked_row | multi |     modes
------------+-------+----------------
 (0,1)      | f     | {"For Update"}
(1 row)
```

`pg_locks` shows the table, its index and A's transaction ID, and nothing that names the
row. The lock is in the row: its `xmax` holds A's transaction ID, flagged lock-only, and
`pgrowlocks` decodes it. So a transaction can lock any number of rows, and **locking a row
is a write**: it dirties the heap page, so `SELECT ... FOR UPDATE` over a wide range is
not read-only work.

A waiter waits for the *transaction* that holds the row. B updates the locked row, and
observer session O asks who is blocked and by whom:

```text
B=> UPDATE accounts SET holder = 'Kavya Nair' WHERE id = 1;
O=> SELECT left(w.query, 30) AS waiting, h.state AS holder_state,
O->        left(h.query, 30) AS holder_last_query
O-> FROM pg_stat_activity w
O-> JOIN pg_stat_activity h ON h.pid = ANY (pg_blocking_pids(w.pid))
O-> WHERE w.datname = current_database();
            waiting             |    holder_state     |       holder_last_query
--------------------------------+---------------------+--------------------------------
 UPDATE accounts SET holder = ' | idle in transaction | SELECT locktype, relation::reg
(1 row)

A=> ROLLBACK;
```

The holder is `idle in transaction` and shows its *last* statement, not the one that took
the lock: `pg_stat_activity` tells you who is blocking, not why (Chapter 39 builds the
incident query on this). The waiter requests a `ShareLock` on the holder's transaction ID
and gets it when that transaction ends; the deadlock message in 32.5 spells this out.

---

## 32.3 Refusing to wait: `NOWAIT`, `SKIP LOCKED`, `lock_timeout`

By default a session waits for a lock indefinitely. Session A holds row 1; B tries each
alternative:

```text
B=> \set VERBOSITY terse
A=> BEGIN;
A=> SELECT id FROM accounts WHERE id = 1 FOR UPDATE \gset
B=> SELECT id FROM accounts WHERE id = 1 FOR UPDATE NOWAIT;
ERROR:  could not obtain lock on row in relation "accounts"
B=> \echo :LAST_ERROR_SQLSTATE
55P03
B=> SELECT id FROM accounts ORDER BY id FOR UPDATE SKIP LOCKED;
 id
----
  2
  3
(2 rows)

B=> SET lock_timeout = '200ms';
B=> SELECT id FROM accounts WHERE id = 1 FOR UPDATE;
ERROR:  canceling statement due to lock timeout
B=> \echo :LAST_ERROR_SQLSTATE
55P03
B=> RESET lock_timeout;
A=> ROLLBACK;
```

- **`NOWAIT`** errors at once if a selected row is locked. Use it where the right response
  to contention is "retry".
- **`SKIP LOCKED`** silently omits locked rows: B got accounts 2 and 3. The view is
  *inconsistent by design*: wrong for reports, right for queues.
- **`lock_timeout`** waits up to a limit, then cancels the statement. It covers every lock
  wait, DDL included, and is the only one that helps a statement with no `NOWAIT` clause.

Both errors carry SQLSTATE `55P03`. Put `SET LOCAL lock_timeout = '2s'` (a placeholder
value) on UI-facing writes and on every DDL statement.

`FOR UPDATE ... LIMIT n` takes locks as rows are returned, so it locks exactly the rows it
returns. Two worker sessions on the `jobs` table of the next section: W1 locks two jobs, and W2 asks for every job with `SKIP LOCKED`:

```text
W1=> BEGIN;
W1=> SELECT id FROM jobs ORDER BY id LIMIT 2 FOR UPDATE;
 id
----
  1
  2
(2 rows)

W2=> SELECT id FROM jobs ORDER BY id FOR UPDATE SKIP LOCKED;
 id
----
  3
  4
  5
  6
  7
  8
(6 rows)

W1=> ROLLBACK;
```

W2 got the other six.

---

## 32.4 A job queue on `SKIP LOCKED`

A table of jobs and several workers is the classic contention problem. The wrong answers
are one worker at a time, or workers picking the same job. The right one is a claim query
where each worker takes the first job nobody else holds:

```sql
CREATE FUNCTION claim_job(worker text) RETURNS TABLE (id int, payload text)
LANGUAGE sql AS $$
    UPDATE jobs SET status = 'running', claimed_by = worker
    WHERE jobs.id = (SELECT j.id FROM jobs j
                     WHERE j.status = 'queued'
                     ORDER BY j.id LIMIT 1
                     FOR UPDATE SKIP LOCKED)
    RETURNING jobs.id, jobs.payload
$$;
```

`jobs` holds eight Swiggy-style dispatch jobs, all `queued`. Three workers each open a
transaction and claim one while the earlier claims are uncommitted; observer O looks in the
middle:

```text
W1=> BEGIN;
W2=> BEGIN;
W3=> BEGIN;
W1=> SELECT * FROM claim_job('w1');
 id |     payload
----+------------------
  1 | dispatch SW-1001
(1 row)

W2=> SELECT * FROM claim_job('w2');
 id |     payload
----+------------------
  2 | dispatch SW-1002
(1 row)

W3=> SELECT * FROM claim_job('w3');
 id |     payload
----+------------------
  3 | dispatch SW-1003
(1 row)

O=> SELECT status, count(*) FROM jobs GROUP BY status;
 status | count
--------+-------
 queued |     8
(1 row)

W1=> COMMIT;
W2=> COMMIT;
W3=> COMMIT;
```

Jobs 1, 2 and 3, no waiting: each worker skipped the rows the others had locked. O sees
eight `queued` rows because nothing is committed. Now the workers claim in rotation, in
autocommit, until the queue is empty, and a count checks that every job was claimed
exactly once:

```text
W1=> SELECT count(*) AS jobs,
W1->        count(*) FILTER (WHERE status = 'running') AS claimed,
W1->        count(*) FILTER (WHERE status = 'queued') AS still_queued,
W1->        count(DISTINCT id) AS distinct_ids,
W1->        count(claimed_by) AS with_worker
W1-> FROM jobs;
 jobs | claimed | still_queued | distinct_ids | with_worker
------+---------+--------------+--------------+-------------
    8 |       8 |            0 |            8 |           8
(1 row)

W1=> SELECT claimed_by, array_agg(id ORDER BY id) AS ids FROM jobs GROUP BY 1 ORDER BY 1;
 claimed_by |   ids
------------+---------
 w1         | {1,4,7}
 w2         | {2,5,8}
 w3         | {3,6}
(3 rows)
```

Eight jobs, eight claimed, eight distinct IDs, none left. With plain `FOR UPDATE`, a second
worker waits for the first's transaction and then takes the next row: correct, but
single-file (Practice Session 32.2 runs it). A crashed worker needs no cleanup while its
claim is held open: its transaction rolls back and the job is `queued` again (also 32.2). That argues for claiming inside the transaction that does the work, which costs an open
transaction per job in flight: fine for seconds, wrong for minutes (Chapter 29's
idle-in-transaction hazard). For long jobs, commit the claim, record a lease expiry, and
requeue expired leases from a reaper. Either way delivery is at-least-once.

> **In production —** Queue tables churn. Delete or archive finished rows, give the table
> aggressive autovacuum settings (Chapter 37), and order the claim by an indexed column, or
> every claim sorts the backlog.

---

## 32.5 Deadlocks

A deadlock is a cycle: A waits for B and B waits for A. After `deadlock_timeout` (default
1 s) a waiting session runs the detector and, if it finds a cycle, cancels one transaction.
The standard recipe is two UPI-style transfers between accounts 1 and 2 in opposite
directions, each debiting first. Both sessions run `SET deadlock_timeout = '3s'` first (a
wider margin keeps the outcome reproducible on a busy machine), and A blocks first.

```text
A=> BEGIN;
A=> UPDATE accounts SET balance = balance - 1000 WHERE id = 1;
B=> BEGIN;
B=> UPDATE accounts SET balance = balance - 500 WHERE id = 2;
A=> UPDATE accounts SET balance = balance + 1000 WHERE id = 2;
B=> UPDATE accounts SET balance = balance + 500 WHERE id = 1;
-- A's waiting UPDATE returns:
ERROR:  deadlock detected
DETAIL:  Process 161664 waits for ShareLock on transaction 222108; blocked by process 161665.
Process 161665 waits for ShareLock on transaction 222107; blocked by process 161664.
HINT:  See server log for query details.
CONTEXT:  while updating tuple (0,2) in relation "accounts"
A=> \echo :LAST_ERROR_SQLSTATE
40P01
A=> ROLLBACK;
-- B's waiting UPDATE returns:
B=> COMMIT;
A=> SELECT id, balance FROM accounts ORDER BY id;
 id | balance
----+----------
  1 | 10500.00
  2 |  4500.00
  3 |  2500.00
(3 rows)
```

Read the error as a structure. `Process X waits for ShareLock on transaction T; blocked by
process Y` is one edge of the cycle and the next line is the other; `ShareLock on
transaction` means a row-level wait, as in 32.2. The statements are not in the client
message (the `HINT`), and the SQLSTATE is `40P01`. Your process and transaction numbers will
differ.

The victim was **A**, which started waiting first: its timer expired first and its check
found the cycle. B, which closed the loop, survived; its `UPDATE` completed once A rolled
back, and the balances show only B's transfer. Do not write code that depends on which
session loses.

The statements are in the server log, and only there:

```text
2026-09-30 16:43:01.996 GMT [161664] DETAIL:  Process 161664 waits for ShareLock on transaction 222108; blocked by process 161665.
	Process 161665 waits for ShareLock on transaction 222107; blocked by process 161664.
	Process 161664: UPDATE accounts SET balance = balance + 1000 WHERE id = 2;
	Process 161665: UPDATE accounts SET balance = balance + 500 WHERE id = 1;
```

That pairs each process with its statement, which is how you find the two code paths.
(`log_lock_waits` shows waits before they become deadlocks; Chapter 39.)

**Prevention is lock ordering.** A cycle needs two transactions taking the same locks in
opposite orders. The same two transfers, each beginning with a locking read sorted by
primary key:

```text
A=> BEGIN;
A=> SELECT id FROM accounts WHERE id IN (1, 2) ORDER BY id FOR UPDATE;
 id
----
  1
  2
(2 rows)

B=> BEGIN;
B=> SELECT id FROM accounts WHERE id IN (1, 2) ORDER BY id FOR UPDATE;
A=> UPDATE accounts SET balance = balance - 1000 WHERE id = 1;
A=> UPDATE accounts SET balance = balance + 1000 WHERE id = 2;
A=> COMMIT;
-- B's waiting SELECT returns:
 id
----
  1
  2
(2 rows)

B=> UPDATE accounts SET balance = balance - 500 WHERE id = 2;
B=> UPDATE accounts SET balance = balance + 500 WHERE id = 1;
B=> COMMIT;
B=> SELECT id, balance FROM accounts ORDER BY id;
 id | balance
----+----------
  1 | 10000.00
  2 |  5000.00
  3 |  2500.00
(3 rows)
```

B's locking read waited for A. Nothing deadlocked, both transfers applied, and the balances
are back at 10,000 and 5,000. The policy: **lock everything you will touch up front, in one
statement, `ORDER BY` the key**. A multi-row `UPDATE` or `DELETE` has no `ORDER BY`, so two
over overlapping ranges can lock in different orders; lock first with the sorted
`SELECT ... FOR UPDATE`.

> **Trap —** Foreign-key checks take locks you did not write. A session holding a parent row
> `FOR UPDATE` blocks another's child insert (32.2), and if it then touches a row the second
> holds, the cycle is invisible in application code. Practice Session 32.1 builds one.

Ordering does not catch everything, so keep two backstops: `lock_timeout`, and **retry on
`40P01`**. The cancelled transaction rolled back completely, so rerun the whole
transaction, not the failed statement, a bounded number of times.

---

## 32.6 Advisory locks

An advisory lock is a lock on a number you choose; PostgreSQL enforces it and gives it
meaning to no one. It is the right tool when the thing to serialise is not a row: one
instance runs the nightly settlement, one migration at a time. The transaction-level form is
released at `COMMIT` or `ROLLBACK`, and `try` returns false instead of waiting. Midway, A
reads the lock table: the lock is there with `locktype = 'advisory'`, the key 42 in `objid`
(`classid` holds the high half of a bigint key).

```text
A=> BEGIN;
A=> SELECT pg_try_advisory_xact_lock(42) AS got;
 got
-----
 t
(1 row)

B=> BEGIN;
B=> SELECT pg_try_advisory_xact_lock(42) AS got;
 got
-----
 f
(1 row)

A=> SELECT locktype, classid, objid, objsubid, mode, granted
A-> FROM pg_locks
A-> WHERE locktype = 'advisory'
A->   AND database = (SELECT oid FROM pg_database WHERE datname = current_database());
 locktype | classid | objid | objsubid |     mode      | granted
----------+---------+-------+----------+---------------+---------
 advisory |       0 |    42 |        1 | ExclusiveLock | t
(1 row)

A=> COMMIT;
B=> SELECT pg_try_advisory_xact_lock(42) AS got;
 got
-----
 t
(1 row)

B=> COMMIT;
```

The session-level form, `pg_advisory_lock`, outlives the transaction and is released only
by `pg_advisory_unlock` or by disconnecting. Keys are per database: session C, connected to
`ch32_other`, gets the same key that B could not.

```text
A=> BEGIN;
A=> SELECT pg_try_advisory_lock(7) AS got;
 got
-----
 t
(1 row)

A=> ROLLBACK;
B=> SELECT pg_try_advisory_lock(7) AS same_db;
 same_db
---------
 f
(1 row)

C=> SELECT pg_try_advisory_lock(7) AS other_db;
 other_db
----------
 t
(1 row)

B=> SET client_min_messages = warning;
B=> SELECT pg_advisory_unlock(7) AS released;
WARNING:  you don't own a lock of type ExclusiveLock
 released
----------
 f
(1 row)
```

A took the lock inside a transaction and rolled back, and the lock stayed. B's attempt to
unlock A's lock returned `f` with a warning (shown because B raised `client_min_messages`;
this container defaults it to `error`).

> **Trap —** Session-level advisory locks and a transaction-mode pooler do not mix.
> Consecutive statements from one client may run on different backends, so the lock lands on
> a connection the client may not see again, and its `pg_advisory_unlock` may run on another
> and return `f`, as B's did. The lock leaks until that connection closes. Use
> `pg_advisory_xact_lock`, which is pool-safe (Chapter 50 covers the pooler).

Two features that pick the same integer serialise each other silently: keep a registry of
keys. If a row exists to lock, lock the row.

---

## 32.7 Read, then write: lost updates

The commonest concurrency bug is a silent one. An IRCTC-style booking reads `seats_left`,
computes the new value in the application and writes it back. Two bookings interleave:

```text
A=> SELECT seats_left FROM coach WHERE id = 1;
 seats_left
------------
         10
(1 row)

B=> SELECT seats_left FROM coach WHERE id = 1;
 seats_left
------------
         10
(1 row)

A=> UPDATE coach SET seats_left = 9 WHERE id = 1;
B=> UPDATE coach SET seats_left = 9 WHERE id = 1;
A=> SELECT seats_left FROM coach WHERE id = 1;
 seats_left
------------
          9
(1 row)
```

Two seats sold, the count moved by one, no error. Three fixes.

**Make the change atomic in SQL.** `SET seats_left = seats_left - 1` needs no read. The
second `UPDATE` waits for the first to commit, then applies to the *new* value:

```text
A=> BEGIN;
A=> UPDATE coach SET seats_left = seats_left - 1 WHERE id = 1;
B=> BEGIN;
B=> UPDATE coach SET seats_left = seats_left - 1 WHERE id = 1;
A=> COMMIT;
B=> COMMIT;
A=> SELECT seats_left FROM coach WHERE id = 1;
 seats_left
------------
          8
(1 row)
```

Eight left, correctly. Use this whenever the new value is a function of the old one; I
reach for it first and it covers most cases.

**Pessimistic locking:** `SELECT ... FOR UPDATE`, decide, write. The second session waits
*at the read* and sees the committed value:

```text
A=> BEGIN;
A=> SELECT seats_left FROM coach WHERE id = 1 FOR UPDATE;
 seats_left
------------
         10
(1 row)

B=> BEGIN;
B=> SELECT seats_left FROM coach WHERE id = 1 FOR UPDATE;
A=> UPDATE coach SET seats_left = 9 WHERE id = 1;
A=> COMMIT;
-- B's waiting SELECT returns:
 seats_left
------------
          9
(1 row)

B=> UPDATE coach SET seats_left = 8 WHERE id = 1;
B=> COMMIT;
A=> SELECT seats_left FROM coach WHERE id = 1;
 seats_left
------------
          8
(1 row)
```

Right when the logic between read and write is complicated and conflicts are frequent. The
lock lasts the whole transaction: keep it short, never across a user or a network call.

**Optimistic locking:** carry a `version` column and make the write conditional on the
version you read. Zero rows affected *is* the conflict signal:

```text
A=> SELECT seats_left, version FROM coach WHERE id = 1;
 seats_left | version
------------+---------
         10 |       1
(1 row)

B=> SELECT seats_left, version FROM coach WHERE id = 1;
 seats_left | version
------------+---------
         10 |       1
(1 row)

A=> UPDATE coach SET seats_left = 9, version = version + 1 WHERE id = 1 AND version = 1 RETURNING seats_left, version;
 seats_left | version
------------+---------
          9 |       2
(1 row)

B=> UPDATE coach SET seats_left = 9, version = version + 1 WHERE id = 1 AND version = 1 RETURNING seats_left, version;
 seats_left | version
------------+---------
(0 rows)

B=> SELECT seats_left, version FROM coach WHERE id = 1;
 seats_left | version
------------+---------
          9 |       2
(1 row)

B=> UPDATE coach SET seats_left = 8, version = version + 1 WHERE id = 1 AND version = 2 RETURNING seats_left, version;
 seats_left | version
------------+---------
          8 |       3
(1 row)
```

A's write moved the version to 2. B's identical write, conditioned on version 1, matched
nothing (`(0 rows)` from `RETURNING`; drivers report an update count of 0), so B re-read,
reapplied its change and retried. Nothing was held between B's read and write, which suits
rare conflicts and long gaps, such as a person editing a form. The failure mode
is a *hot* row, where retries pile up: use the atomic form or `FOR UPDATE` there.
Chapter 22 put a `row_version` column in the standard table for this reason.

Isolation levels are a third route (`40001` at `REPEATABLE READ` and above; Chapter 31).

---

## Summary

- Every statement takes a table lock first; the weak modes do not conflict among
  themselves and `ACCESS EXCLUSIVE` conflicts with all eight. The matrix derived by
  experiment is the documentation's.
- Row locks have four modes, live in the tuple (`xmax`) rather than `pg_locks`, and dirty
  the page. A foreign-key check takes `FOR KEY SHARE` on the parent: non-key updates pass,
  key changes and deletes wait.
- `NOWAIT` and `lock_timeout` both raise `55P03`. `SKIP LOCKED` gives an inconsistent view
  on purpose: use it for queues, never for reports.
- Deadlock: the session whose timer expires first is cancelled. Prevent with one lock
  order in one sorted statement; retry the whole transaction on `40P01`.
- Advisory locks serialise what is not a row; prefer the transaction-level form.
- Read-then-write: atomic `SET x = x - 1` first, `FOR UPDATE` when the logic needs it, a
  `version` column when the gap is long and conflicts are rare.

**Exercises:** Practice Sessions 32.1–32.3 accompany this chapter and are in the
workbook at the back of the book.

**Next:** Part VII closes here. Part VIII opens with Chapter 33, *Indexing*: B-tree
mechanics, the other index types, and the real cost of every index you add.
