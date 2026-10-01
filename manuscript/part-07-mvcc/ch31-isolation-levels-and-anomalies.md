# Chapter 31 — Isolation Levels and Anomalies

Chapter 29, *Transactions in Practice*, said a transaction is all-or-nothing. It said less
about what a transaction sees while others run beside it. The SQL standard defines four
isolation levels by the anomalies each may allow. PostgreSQL implements three, and its
behaviour departs from the standard's table in ways that matter: some levels are stronger
than the standard demands, and one name is an alias. Chapter 30, *MVCC Internals*,
explained snapshots; here two or three `psql` sessions race, in an order fixed by hand, and
every anomaly is *reproduced*, not described.

You need two terminals and a scratch database. `tickets` is used later, in 31.5:

```bash
createdb ch31_db
psql -X -d ch31_db -f schema.sql
```

```sql
DROP TABLE IF EXISTS tickets, wards, accounts, doctors, control, receipts CASCADE;
CREATE TABLE accounts (id int PRIMARY KEY, owner text NOT NULL, balance numeric(10,2) NOT NULL);
INSERT INTO accounts VALUES (1, 'Anita Rao', 1000), (2, 'Rajesh Kumar', 1000);
CREATE TABLE doctors (name text PRIMARY KEY, ward text NOT NULL, on_call boolean NOT NULL);
INSERT INTO doctors VALUES ('Dr Priya Menon', 'Kochi ICU', true), ('Dr Arjun Iyer', 'Kochi ICU', true);
CREATE TABLE control (id int PRIMARY KEY, batch int NOT NULL);
INSERT INTO control VALUES (1, 1);
CREATE TABLE receipts (id serial PRIMARY KEY, batch int NOT NULL, amount numeric(10,2) NOT NULL);
CREATE OR REPLACE VIEW si_locks AS   -- predicate locks held in this database only
  SELECT locktype, relation::regclass AS rel, count(*)
  FROM pg_locks
  WHERE mode = 'SIReadLock' AND database = (SELECT oid FROM pg_database WHERE datname = current_database())
  GROUP BY 1, 2 ORDER BY 1, 2;
```

```sql
CREATE TABLE tickets (id int PRIMARY KEY, holder text, seat int);
INSERT INTO tickets SELECT g, 'holder ' || g, g FROM generate_series(1, 100000) g;
ANALYZE tickets;
```

Run `psql -X -P null='(null)' -d ch31_db` in each terminal. Transcripts show the prompt
(`A=>`, `B=>`, `C=>`) and you type the lines in the order printed. A line such as
`-- B is now waiting for A` is not typed: B's statement is hanging on a lock, and output
that follows *without* a prompt is that statement finishing after A commits. Errors use
`\set VERBOSITY verbose`, which prints the SQLSTATE (`40001`, `40P01`) after `ERROR:`. The
`LOCATION:` line is a server source line, and process ids in messages will differ on your
machine.

## 31.1 What PostgreSQL offers, and what it does not

Three real levels: **Read Committed** (the default), **Repeatable Read** and
**Serializable**. The fourth, Read Uncommitted, is accepted and quietly upgraded. A holds an
uncommitted change; B asks to read uncommitted data:

```text
A=> BEGIN;
BEGIN
A=> UPDATE accounts SET balance = 700 WHERE id = 1;
UPDATE 1
B=> BEGIN ISOLATION LEVEL READ UNCOMMITTED;
BEGIN
B=> SHOW transaction_isolation;
 transaction_isolation
-----------------------
 read uncommitted
(1 row)
B=> SELECT balance FROM accounts WHERE id = 1;
 balance
---------
 1000.00
(1 row)
A=> COMMIT;
COMMIT
B=> SELECT balance FROM accounts WHERE id = 1;
 balance
---------
  700.00
(1 row)
B=> COMMIT;
COMMIT
```

B reports `read uncommitted` and sees 1000.00, not A's 700.00. After A commits, B's next
statement sees 700.00: that is Read Committed under another name. **PostgreSQL has no dirty
reads at any level**; `READ UNCOMMITTED` exists so standard-conforming code runs.

The level is chosen before the first query of the transaction:

```text
B=> BEGIN;
BEGIN
B=> SELECT 1 AS first_query;
 first_query
-------------
           1
(1 row)
B=> SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
ERROR:  SET TRANSACTION ISOLATION LEVEL must be called before any query
```

When does the snapshot exist? At the first statement, not at `BEGIN`. B begins, A
commits, then B's first query runs:

```text
B=> BEGIN ISOLATION LEVEL REPEATABLE READ;
BEGIN
A=> UPDATE accounts SET balance = 700 WHERE id = 1;
UPDATE 1
B=> SELECT balance FROM accounts WHERE id = 1;
 balance
---------
  700.00
(1 row)
B=> COMMIT;
COMMIT
```

B sees 700.00 because its snapshot did not exist until its first `SELECT`. A database can change its own default, which runs a legacy application at another level
without touching its code. `ALTER DATABASE` applies to *new* sessions only (do this to a
scratch database, never a shared one):

```text
C=> ALTER DATABASE ch31_db SET default_transaction_isolation = 'repeatable read';
ALTER DATABASE
-- reconnect A: the setting applies to new sessions
A=> SHOW default_transaction_isolation;
 default_transaction_isolation
-------------------------------
 repeatable read
(1 row)
A=> SHOW transaction_isolation;
 transaction_isolation
-----------------------
 repeatable read
(1 row)
C=> ALTER DATABASE ch31_db RESET default_transaction_isolation;
ALTER DATABASE
-- reconnect A again
A=> SHOW transaction_isolation;
 transaction_isolation
-----------------------
 read committed
(1 row)
```

## 31.2 Read Committed: a fresh snapshot per statement

At Read Committed a statement sees everything committed before *it* started, so two
statements in one transaction can disagree. B runs the same aggregate twice while A inserts
a row and updates another, first at Read Committed, then at Repeatable Read:

```text
B=> BEGIN ISOLATION LEVEL READ COMMITTED;
BEGIN
B=> SELECT count(*) AS n, sum(balance) AS total FROM accounts WHERE balance >= 500;
 n |  total
---+---------
 2 | 2000.00
(1 row)
A=> INSERT INTO accounts VALUES (3, 'Meera Banerjee', 900);
INSERT 0 1
A=> UPDATE accounts SET balance = balance - 100 WHERE id = 1;
UPDATE 1
B=> SELECT count(*) AS n, sum(balance) AS total FROM accounts WHERE balance >= 500;
 n |  total
---+---------
 3 | 2800.00
(1 row)
B=> COMMIT;
COMMIT
-- (reset: row 3 removed, balance restored)
B=> BEGIN ISOLATION LEVEL REPEATABLE READ;
BEGIN
B=> SELECT count(*) AS n, sum(balance) AS total FROM accounts WHERE balance >= 500;
 n |  total
---+---------
 2 | 2000.00
(1 row)
A=> INSERT INTO accounts VALUES (3, 'Meera Banerjee', 900);
INSERT 0 1
A=> UPDATE accounts SET balance = balance - 100 WHERE id = 1;
UPDATE 1
B=> SELECT count(*) AS n, sum(balance) AS total FROM accounts WHERE balance >= 500;
 n |  total
---+---------
 2 | 2000.00
(1 row)
B=> COMMIT;
COMMIT
-- (reset: row 3 removed, balance restored)
```

At Read Committed B's second query reports three rows and 2,800.00 instead of two and
2,000.00. That is a **non-repeatable read** (an existing row changed) and a **phantom** (a
new row matches the predicate). At Repeatable Read nothing moves. The standard permits
phantoms at Repeatable Read; PostgreSQL does not, because its Repeatable Read is snapshot
isolation and one snapshot serves the whole transaction. If you learned isolation levels
from a textbook table, correct that premise.

## 31.3 Lost updates, and the re-check that surprises

A **lost update** is two transactions computing a new value from the same old one, so the
second write discards the first. It depends on *where the arithmetic runs*. Inside the
`UPDATE`, Read Committed is safe: B waits for A's row lock, then adds 50 to the *new* row
version (both increments survive; Practice Session 31.1 runs it). With the arithmetic in
the application, Read Committed loses A's update, and Repeatable Read refuses the write:

```text
-- Read Committed: the arithmetic runs in the application
A=> BEGIN;
BEGIN
B=> BEGIN;
BEGIN
A=> SELECT balance FROM accounts WHERE id = 2;
 balance
---------
 1000.00
(1 row)
B=> SELECT balance FROM accounts WHERE id = 2;
 balance
---------
 1000.00
(1 row)
A=> UPDATE accounts SET balance = 1100 WHERE id = 2;
UPDATE 1
A=> COMMIT;
COMMIT
B=> UPDATE accounts SET balance = 1050 WHERE id = 2;
UPDATE 1
B=> COMMIT;
COMMIT
B=> SELECT balance FROM accounts WHERE id = 2;
 balance
---------
 1050.00
(1 row)
-- Repeatable Read: the same application-side update
A=> BEGIN ISOLATION LEVEL REPEATABLE READ;
BEGIN
B=> BEGIN ISOLATION LEVEL REPEATABLE READ;
BEGIN
A=> SELECT balance FROM accounts WHERE id = 2;
 balance
---------
 1050.00
(1 row)
B=> SELECT balance FROM accounts WHERE id = 2;
 balance
---------
 1050.00
(1 row)
A=> UPDATE accounts SET balance = 1150 WHERE id = 2;
UPDATE 1
A=> COMMIT;
COMMIT
B=> UPDATE accounts SET balance = 1100 WHERE id = 2;
ERROR:  40001: could not serialize access due to concurrent update
LOCATION:  ExecUpdate, nodeModifyTable.c:2378
B=> ROLLBACK;
ROLLBACK
```

The first block ends at 1050.00: A committed 1100.00, B wrote a value computed from a stale
read, and A's 100 vanished without an error. At Repeatable Read the same B statement fails
with `40001: could not serialize access due to concurrent update`. The row changed after B's
snapshot, and the level will not let B overwrite what it never saw. B's transaction is
aborted and must be retried from `BEGIN`.

At Read Committed, after a lock wait, PostgreSQL re-evaluates the `WHERE` clause against the
*new* version of the row (an "EvalPlanQual" recheck). Usually that is what you want. It can
change the answer:

```text
A=> BEGIN;
BEGIN
B=> BEGIN;
BEGIN
A=> UPDATE accounts SET balance = balance - 800 WHERE id = 1;
UPDATE 1
B=> UPDATE accounts SET balance = balance - 500 WHERE id = 1 AND balance >= 500;
-- B is now waiting for A
A=> COMMIT;
COMMIT
UPDATE 0
B=> COMMIT;
COMMIT
B=> SELECT id, balance FROM accounts ORDER BY id;
 id | balance
----+---------
  1 |  200.00
  2 | 1000.00
(2 rows)
```

B's snapshot said 1000.00, so `balance >= 500` matched. After A's commit the row holds
200.00, the recheck fails, and B silently updates nothing: `UPDATE 0`, no error. Check the
row count. It is also why one guarded `UPDATE` is the cheapest correct pattern at this
level, and a `SELECT` followed by an `UPDATE` is not.

## 31.4 Repeatable Read still permits write skew

**Write skew**: two transactions read an overlapping set, each decides from what it read, and
each writes a *different* row, so no row-level conflict fires. The invariant is "at least
one doctor stays on call". Both check that two are on call, and both go off:

```text
A=> BEGIN ISOLATION LEVEL REPEATABLE READ;
BEGIN
B=> BEGIN ISOLATION LEVEL REPEATABLE READ;
BEGIN
A=> SELECT count(*) FROM doctors WHERE on_call;
 count
-------
     2
(1 row)
B=> SELECT count(*) FROM doctors WHERE on_call;
 count
-------
     2
(1 row)
A=> UPDATE doctors SET on_call = false WHERE name = 'Dr Priya Menon';
UPDATE 1
B=> UPDATE doctors SET on_call = false WHERE name = 'Dr Arjun Iyer';
UPDATE 1
A=> COMMIT;
COMMIT
B=> COMMIT;
COMMIT
A=> SELECT name, on_call FROM doctors ORDER BY name;
      name      | on_call
----------------+---------
 Dr Arjun Iyer  | f
 Dr Priya Menon | f
(2 rows)
```

Both commits succeed and nobody is on call, at Repeatable Read, without an error. Snapshot
isolation catches conflicts on the *same row*. These rows differ, and the invariant lives in
a *count* that neither transaction wrote.

## 31.5 Serializable: SSI

At Serializable, PostgreSQL uses Serializable Snapshot Isolation (SSI): snapshot isolation
plus tracking of the read/write dependencies between transactions. It records *reads* as
`SIReadLock`s that nobody waits on, and aborts one transaction when the dependencies form a
cycle that no serial order could produce. Reset the rota (`UPDATE doctors SET on_call =
true`) and repeat the previous run with `SERIALIZABLE` on both `BEGIN` lines. From the two
updates on:

```text
A=> UPDATE doctors SET on_call = false WHERE name = 'Dr Priya Menon';
UPDATE 1
B=> UPDATE doctors SET on_call = false WHERE name = 'Dr Arjun Iyer';
UPDATE 1
A=> COMMIT;
COMMIT
B=> COMMIT;
ERROR:  40001: could not serialize access due to read/write dependencies among transactions
DETAIL:  Reason code: Canceled on identification as a pivot, during commit attempt.
HINT:  The transaction might succeed if retried.
LOCATION:  PreCommit_CheckForSerializationFailure, predicate.c:4879
A=> SELECT name, on_call FROM doctors ORDER BY name;
      name      | on_call
----------------+---------
 Dr Arjun Iyer  | t
 Dr Priya Menon | f
(2 rows)
```

A commits. **B fails on `COMMIT`**, not on a statement. Serialization failures arise on any
statement *and* on commit, so the retry must wrap the commit too. One doctor stays on call.

The bookkeeping is visible in `pg_locks`, and the view `si_locks` from the schema filters
it to your database. Locks start at tuple granularity and are *promoted* to page and then
relation locks as a transaction reads more, to bound memory:

```text
A=> BEGIN ISOLATION LEVEL SERIALIZABLE;
BEGIN
A=> SET LOCAL enable_seqscan = off;
SET
A=> SELECT id FROM tickets WHERE id = 7;
 id
----
  7
(1 row)
A=> SELECT * FROM si_locks;
 locktype |     rel      | count
----------+--------------+-------
 page     | tickets_pkey |     1
 tuple    | tickets      |     1
(2 rows)
A=> SELECT id FROM tickets WHERE id IN (7, 8, 9);
 id
----
  7
  8
  9
(3 rows)
A=> SELECT * FROM si_locks;
 locktype |     rel      | count
----------+--------------+-------
 page     | tickets      |     1
 page     | tickets_pkey |     1
(2 rows)
A=> COMMIT;
COMMIT
A=> BEGIN ISOLATION LEVEL SERIALIZABLE;
BEGIN
A=> SELECT count(*) FROM tickets WHERE seat = 7;
 count
-------
     1
(1 row)
A=> SELECT * FROM si_locks;
 locktype |   rel   | count
----------+---------+-------
 relation | tickets |     1
(1 row)
A=> COMMIT;
COMMIT
```

The one-row read holds a `tuple` lock on `tickets` plus a `page` lock on the primary-key
index. Three rows from one page collapse the heap lock to a `page` lock (the default
`max_pred_locks_per_page` is 2; I did not change it). With no index on `seat` the scan
holds a `relation` lock. Coarser locks mean more apparent conflicts, which is the source of
SSI's **false positives**. Two transactions each read and update one seat, and the seats
are unrelated:

```text
-- no index on seat: each SELECT scans the whole table
A=> BEGIN ISOLATION LEVEL SERIALIZABLE;
BEGIN
B=> BEGIN ISOLATION LEVEL SERIALIZABLE;
BEGIN
A=> SELECT holder FROM tickets WHERE seat = 7;
  holder
----------
 holder 7
(1 row)
B=> SELECT holder FROM tickets WHERE seat = 8;
  holder
----------
 holder 8
(1 row)
A=> UPDATE tickets SET holder = 'Kavya Reddy' WHERE seat = 7;
UPDATE 1
B=> UPDATE tickets SET holder = 'Imran Sheikh' WHERE seat = 8;
UPDATE 1
A=> COMMIT;
COMMIT
B=> COMMIT;
ERROR:  40001: could not serialize access due to read/write dependencies among transactions
DETAIL:  Reason code: Canceled on identification as a pivot, during commit attempt.
HINT:  The transaction might succeed if retried.
LOCATION:  PreCommit_CheckForSerializationFailure, predicate.c:4879
```

B is aborted although either order of the two would give the same result. A second run,
with an index on `seat` and seats 7 and 90,000, committed both. A third, with the index and
neighbouring seats 7 and 8, failed again, consistent with page-level locks: both rows and
both index entries sit on shared pages. A false positive costs a retry, not a wrong answer,
and the levers are an index on the predicate and smaller transactions.

> **Trap —** Serializable without an index on the columns you filter by is not only slow, it
> is abort-prone. A sequential scan takes a relation-level `SIReadLock`, and any writer to
> that table can conflict with it.

### The read-only anomaly

Even a transaction that writes nothing can observe a state that never existed. A control row
holds the current batch. A reads it, intending to insert a receipt into that batch; B closes
the batch; C, read-only, reports the closed batch's total. At Repeatable Read:

```text
A=> BEGIN ISOLATION LEVEL REPEATABLE READ;
BEGIN
A=> SELECT batch FROM control WHERE id = 1;
 batch
-------
     1
(1 row)
B=> BEGIN ISOLATION LEVEL REPEATABLE READ;
BEGIN
B=> UPDATE control SET batch = batch + 1 WHERE id = 1;
UPDATE 1
B=> COMMIT;
COMMIT
C=> BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
BEGIN
C=> SELECT batch FROM control WHERE id = 1;
 batch
-------
     2
(1 row)
C=> SELECT coalesce(sum(amount), 0) AS batch_1_total FROM receipts WHERE batch = 1;
 batch_1_total
---------------
             0
(1 row)
C=> COMMIT;
COMMIT
A=> INSERT INTO receipts (batch, amount) VALUES (1, 100);
INSERT 0 1
A=> COMMIT;
COMMIT
A=> SELECT batch, amount FROM receipts;
 batch | amount
-------+--------
     1 | 100.00
(1 row)
```

C reports batch 1 closed with a total of 0, and A's receipt then lands in batch 1: the
report is wrong for good. At Serializable, the same interleaving (C's output is identical)
ends:

```text
A=> INSERT INTO receipts (batch, amount) VALUES (1, 100);
ERROR:  could not serialize access due to read/write dependencies among transactions
DETAIL:  Reason code: Canceled on identification as a pivot, during write.
HINT:  The transaction might succeed if retried.
A=> COMMIT;
ROLLBACK
A=> SELECT batch, amount FROM receipts;
 batch | amount
-------+--------
(0 rows)
```

SSI aborts A, the writer, so no receipt lands in the closed batch and the report stays
right. `SERIALIZABLE READ ONLY DEFERRABLE` goes further. It waits until no read-write
transaction can create such a dependency, then runs without `SIReadLock`s and, per the
documentation, cannot be aborted, which suits long reports:

```text
B=> BEGIN ISOLATION LEVEL SERIALIZABLE READ ONLY DEFERRABLE;
BEGIN
B=> SELECT count(*) FROM doctors WHERE on_call;
-- B is waiting for a safe snapshot
A=> COMMIT;
COMMIT
 count
-------
     2
(1 row)
B=> SELECT * FROM si_locks;
 locktype | rel | count
----------+-----+-------
(0 rows)
B=> COMMIT;
COMMIT
```

B stopped at its first query until A finished (`pg_stat_activity` showed wait event
`SafeSnapshot`), and `si_locks` shows nothing held for it.

## 31.6 The matrix, from runs

Each cell is a driven run of that anomaly at that level, classified by what the sessions
returned (`prevented`: the second read matched the first; `40001 error`: a transaction was
aborted):

```text
 anomaly             | read uncommitted | read committed | repeatable read | serializable
---------------------+------------------+----------------+-----------------+--------------
 dirty read          | prevented        | prevented      | prevented       | prevented
 non-repeatable read | allowed          | allowed        | prevented       | prevented
 phantom read        | allowed          | allowed        | prevented       | prevented
 lost update         | allowed          | allowed        | 40001 error     | 40001 error
 write skew          | allowed          | allowed        | allowed         | 40001 error
 read-only anomaly   | allowed          | allowed        | allowed         | 40001 error
```

Two rows differ from the standard's table: phantoms at Repeatable Read, and dirty reads,
prevented everywhere.

## 31.7 Fixing write skew without Serializable

Serializable plus a retry loop is the general answer, and sometimes something cheaper
exists. First, what does *not* work. Locking what you read with `FOR SHARE` is a natural
guess. Both sessions share-lock both rows, each `UPDATE` then waits for the other's share
lock, and the deadlock detector aborts one of them with `40P01` (Practice Session 31.2
shows the run). One doctor stays on call, by accident and at the price of an error and a
retry. Locking with `FOR UPDATE` serialises the two decisions properly:

```text
-- fix attempt 2: FOR UPDATE on the set
A=> BEGIN;
BEGIN
B=> BEGIN;
BEGIN
A=> SELECT name FROM doctors WHERE on_call FOR UPDATE;
      name
----------------
 Dr Priya Menon
 Dr Arjun Iyer
(2 rows)
B=> SELECT name FROM doctors WHERE on_call FOR UPDATE;
-- B is now waiting for A
A=> UPDATE doctors SET on_call = false WHERE name = 'Dr Priya Menon';
UPDATE 1
A=> COMMIT;
COMMIT
     name
---------------
 Dr Arjun Iyer
(1 row)
B=> COMMIT;
COMMIT
```

B waited, and when it resumed its `FOR UPDATE` returned only Dr Arjun Iyer: it re-read the
set and Dr Priya Menon no longer matched. The application counts one row and refuses. At
Repeatable Read the same wait ends in `40001` instead, which is correct but needs a retry.

The other cheap fix makes the invariant a row the database can check: `on_call_count` on a
`wards` row with `CHECK (on_call_count >= 1)`, decremented in the same transaction as the
roster change. The second decrement waits, then violates the constraint. Practice Session
31.2 runs it; locking mechanics belong to Chapter 32, *Locking, Deadlocks, and Concurrency
Patterns*.

## 31.8 The retry loop

If you use Repeatable Read or Serializable, aborts are normal operation: `40001` (and
`40P01`) means *try again*. The rules:

1. Retry the **whole transaction**, reads included. The snapshot is gone, and a decision made
   from the old reads is what got you here.
2. Cap the attempts and back off with jitter, so retries do not collide in lockstep.
3. Retry only `40001` and `40P01`. A `23505` unique violation fails the same way again.
4. Side effects outside the database are not rolled back. Make them idempotent or run them
   after commit; Chapter 50, *Connecting from Application Code*, covers idempotency.

The transaction file below has a `test hook` that runs a rival session on attempt 1 only, so
the failure is arranged rather than hoped for. Run it from a directory holding both files:

```sql
-- leave.sql: a doctor asks to leave the on-call rota.  Variables: who, attempt
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT count(*) > 1 AS may_leave FROM doctors WHERE on_call \gset
-- test hook: on the first attempt only, a rival commits the same request while we hold our snapshot
SELECT :attempt = 1 AS rival \gset
\if :rival
  \! psql -X -q -d ch31_db -v ON_ERROR_STOP=1 -v who="Dr Arjun Iyer" -v attempt=2 -f leave.sql
\endif
\if :may_leave
  UPDATE doctors SET on_call = false WHERE name = :'who';
  COMMIT;
  \echo :who left the rota
\else
  ROLLBACK;
  \echo :who must stay: last doctor on call
\endif
```

```bash
#!/usr/bin/env bash
# usage: retry.sh MAX_ATTEMPTS FILE [psql args]
# Re-runs the WHOLE file on 40001 (serialization_failure) or 40P01 (deadlock_detected).
max=$1; file=$2; shift 2
for ((attempt = 1; attempt <= max; attempt++)); do
  out=$(psql -X -q -d ch31_db -v ON_ERROR_STOP=1 -v VERBOSITY=verbose \
             -v attempt=$attempt "$@" -f "$file" 2>&1)
  status=$?
  echo "$out"
  if [ $status -eq 0 ]; then echo "attempt $attempt: done"; exit 0; fi
  if ! grep -qE 'ERROR:  (40001|40P01):' <<<"$out"; then
    echo "attempt $attempt: not retryable, giving up"; exit 1
  fi
  [ "$attempt" -lt "$max" ] || break
  echo "attempt $attempt: serialization failure, retrying"
  sleep "$(awk -v a="$attempt" 'BEGIN { srand(); printf "%.3f", rand() * 0.05 * 2^a }')"   # exponential backoff, full jitter
done
echo "gave up after $max attempts"; exit 1
```

Reset the rota, then `./retry.sh 5 leave.sql -v who="Dr Priya Menon"`:

```text
Dr Arjun Iyer left the rota
psql:leave.sql:10: ERROR:  40001: could not serialize access due to read/write dependencies among transactions
DETAIL:  Reason code: Canceled on identification as a pivot, during write.
HINT:  The transaction might succeed if retried.
LOCATION:  OnConflict_CheckForSerializationFailure, predicate.c:4820
attempt 1: serialization failure, retrying
Dr Priya Menon must stay: last doctor on call
attempt 2: done
```

Attempt 1 read two doctors on call and was aborted at its `UPDATE`, because the rival had
committed first. Attempt 2 re-ran the whole file, read one doctor on call, and refused.
**The retry produced a different, correct decision**; re-issuing only the failed `UPDATE`
would have taken the last doctor off call.

> **Trap —** `BEGIN ... EXCEPTION WHEN serialization_failure` in PL/pgSQL does not fix this.
> The handler rolls back to a savepoint inside the *same* transaction, whose snapshot is
> unchanged, so the retry sees the same stale data. The loop belongs outside the transaction.

## 31.9 What I would do

- **Default to Read Committed** and write guarded statements: `UPDATE ... SET balance =
  balance - x WHERE balance >= x`, `INSERT ... ON CONFLICT`, unique constraints, and a
  row-count check. No retries needed.
- **Use Repeatable Read** for read-only reports that need one consistent state across
  several queries. Set it per transaction, not per database: a database-wide default lets
  every transaction fail with `40001`. For writes, only with a retry loop.
- **Use Serializable** when an invariant spans several rows that no constraint can express
  and you can afford a retry loop. Index every predicate, keep transactions short, expect
  false positives.
- **If a constraint or one locked row is cheaper, use it.** No abort path needed.

## Summary

- Three isolation levels: `READ UNCOMMITTED` behaves as Read Committed, and no level
  allows dirty reads. The snapshot starts at the first *statement*.
- Read Committed permits non-repeatable reads, phantoms, and lost updates when the
  arithmetic is in the application. After a lock wait it rechecks `WHERE` on the new row, so
  an `UPDATE` can silently match nothing.
- Repeatable Read is snapshot isolation: no phantoms, lost updates become `40001`, write skew
  and the read-only anomaly remain.
- Serializable (SSI) aborts one participant with `40001`, on a statement or on `COMMIT`. It
  needs indexes to avoid relation-level predicate locks and false positives.
- `FOR SHARE` does not fix write skew, it deadlocks. `FOR UPDATE` on the set, or a `CHECK`
  on a counter row, does.
- Retry the whole transaction on `40001` and `40P01` only, bounded, with jitter.

**Exercises:** Practice Sessions 31.1–31.3 accompany this chapter and are in the workbook at
the back of the book.

**Next:** Chapter 32, *Locking, Deadlocks, and Concurrency Patterns*, opens the lock manager
this chapter used without explaining: lock modes, `FOR UPDATE`, `SKIP LOCKED`, advisory
locks and deadlocks.
