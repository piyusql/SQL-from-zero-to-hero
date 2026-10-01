# Chapter 29 — Transactions in Practice

Every statement in PostgreSQL runs inside a transaction; the only question is whose, and
for how long. Most incidents in this part of the book (a table that will not take an
`ALTER`, a queue that stops moving, a table that bloats for no visible reason) start with a
transaction somebody forgot they had opened.

This chapter is the working vocabulary: what `BEGIN` changes, why one failed statement
ruins the rest of a transaction, what savepoints cost, what ACID does and does not promise
here, why DDL can be rolled back, and the *idle in transaction* session that holds locks and
cleanup back while doing nothing. Row versioning is Chapter 30, *MVCC Internals*; what
concurrent transactions see of each other is Chapter 31; lock modes are Chapter 32.

Everything runs in a scratch database with a tiny table, so you can break it freely:

```bash
createdb ch29_scratch
```

```sql
\c ch29_scratch
\pset null '(null)'

CREATE TABLE account (
  id      int PRIMARY KEY,
  owner   text NOT NULL,
  balance numeric(12,2) NOT NULL CHECK (balance >= 0)
);
INSERT INTO account VALUES
  (1, 'Rajesh Kumar',    50000),
  (2, 'Priya Menon',     12000),
  (3, 'Harpreet Singh',    800);
```

Run these with `psql -q`, which hides command tags (`UPDATE 1`). Where a tag is the point,
it is shown.

## 29.1 Every statement is already a transaction

Type a bare `UPDATE` and PostgreSQL wraps it in `BEGIN` and `COMMIT` for you. That is
*autocommit*, and it is the server's behaviour, not a psql feature. `BEGIN` does one thing:
it suspends the automatic `COMMIT` until you send one. The transaction id proves it. `\gset`
stores a result in a psql variable, and `pg_current_xact_id()` returns the id of the
current transaction, assigning one if needed:

```sql
SELECT pg_current_xact_id() AS t1 \gset
SELECT pg_current_xact_id() AS t2 \gset
BEGIN;
SELECT pg_current_xact_id() AS t3 \gset
SELECT pg_current_xact_id() AS t4 \gset
COMMIT;
SELECT :'t1' <> :'t2' AS autocommit_two_xacts, :'t3' = :'t4' AS begin_one_xact;
```

```text
 autocommit_two_xacts | begin_one_xact
----------------------+----------------
 t                    | t
(1 row)
```

Two bare statements, two transactions; two after `BEGIN`, one. Ids differ on every run, so
the query compares them. `ROLLBACK` discards every change made since `BEGIN`:

```sql
BEGIN;
UPDATE account SET balance = balance - 5000 WHERE id = 1;
SELECT id, balance FROM account WHERE id = 1;
ROLLBACK;
SELECT id, balance FROM account WHERE id = 1;
```

```text
 id | balance
----+----------
  1 | 45000.00
(1 row)

 id | balance
----+----------
  1 | 50000.00
(1 row)
```

The first `SELECT` sees the debit because it is your own transaction; the second sees
nothing. A business operation is usually several statements, and autocommit makes each
permanent on its own: a transfer that debits and then crashes before crediting has
destroyed money. One transaction makes them succeed together or not at all. That is
atomicity, and the rest of the chapter is the ways it is harder to keep than it looks.

## 29.2 One error poisons the whole transaction

Priya is owed INR 5,000 from Harpreet, who has INR 800. The transfer credits Priya first, then
debits Harpreet, and the `CHECK (balance >= 0)` constraint stops the debit. Run the whole
script, this time with command tags visible:

```sql
BEGIN;
UPDATE account SET balance = balance + 5000 WHERE id = 2;
UPDATE account SET balance = balance - 5000 WHERE id = 3;
UPDATE account SET balance = balance + 1 WHERE id = 1;
COMMIT;
```

```text
BEGIN
UPDATE 1
ERROR:  new row for relation "account" violates check constraint "account_balance_check"
DETAIL:  Failing row contains (3, Harpreet Singh, -4200.00).
ERROR:  current transaction is aborted, commands ignored until end of transaction block
ROLLBACK
```

The debit failed. The next statement was not attempted: PostgreSQL refuses every command in
a failed transaction until it ends. And `COMMIT` did not fail; it returned the tag
`ROLLBACK`. Code that swallows the first error and carries on to `commit()` gets no second
exception telling it the work was discarded. Treat any error inside a transaction as the end
of that transaction unless you have a savepoint (29.3).

```sql
SELECT id, balance FROM account ORDER BY id;
```

```text
 id | balance
----+----------
  1 | 50000.00
  2 | 12000.00
  3 |   800.00
(3 rows)
```

Nothing moved, which is right. Now the trap. psql's `ON_ERROR_ROLLBACK` lets a session carry
on after an error; the psql documentation says it does so by sending an invisible
`SAVEPOINT` before every statement. Run the same script with it on:

```sql
\set ON_ERROR_ROLLBACK on
BEGIN;
UPDATE account SET balance = balance + 5000 WHERE id = 2;
UPDATE account SET balance = balance - 5000 WHERE id = 3;
COMMIT;
\set ON_ERROR_ROLLBACK off
SELECT id, balance, sum(balance) OVER () AS total FROM account ORDER BY id;
```

```text
ERROR:  new row for relation "account" violates check constraint "account_balance_check"
DETAIL:  Failing row contains (3, Harpreet Singh, -4200.00).
 id | balance  |  total
----+----------+----------
  1 | 50000.00 | 67800.00
  2 | 17000.00 | 67800.00
  3 |   800.00 | 67800.00
(3 rows)
```

The debit failed and the credit committed. Priya has INR 17,000, and the accounts hold INR 67,800
where they held INR 62,800. `ON_ERROR_ROLLBACK` is for someone typing by hand and fixing typos.
Never use it in a script that changes data: it turns "stop at the first error" into "keep
going and commit whatever worked". Put the books back:

```sql
UPDATE account SET balance = 12000 WHERE id = 2;
```

> **In production —** `psql -v ON_ERROR_STOP=1` stops a script at the first error, and
> `psql -1` wraps the file in one `BEGIN`/`COMMIT`. Use both for every migration file;
> Session 29.1 does.

## 29.3 Savepoints: undo part of a transaction

A savepoint is a named mark inside a transaction. `ROLLBACK TO SAVEPOINT` undoes everything
since the mark and, unlike `ROLLBACK`, leaves the transaction usable. You choose where the
mark goes:

```sql
BEGIN;
UPDATE account SET balance = balance + 250 WHERE id = 1;
SAVEPOINT transfer;
UPDATE account SET balance = balance + 5000 WHERE id = 2;
UPDATE account SET balance = balance - 5000 WHERE id = 3;
ROLLBACK TO SAVEPOINT transfer;
SELECT id, balance FROM account ORDER BY id;
COMMIT;
```

```text
ERROR:  new row for relation "account" violates check constraint "account_balance_check"
DETAIL:  Failing row contains (3, Harpreet Singh, -4200.00).
 id | balance
----+----------
  1 | 50250.00
  2 | 12000.00
  3 |   800.00
(3 rows)
```

The INR 250 credit survives; the failed transfer's credit to Priya was undone with the failed
debit. `RELEASE SAVEPOINT` discards the mark without undoing anything, and savepoints nest.

Savepoints are not free. Each one that goes on to write creates a *subtransaction* with its
own transaction id. `xmin` is the id of the transaction that created a row version
(Chapter 30 takes it apart) and `pg_current_xact_id()::xid` is the top-level id, so a row
written after a savepoint gives itself away:

```sql
BEGIN;
UPDATE account SET balance = balance + 1 WHERE id = 1;
SAVEPOINT s1;
UPDATE account SET balance = balance + 1 WHERE id = 2;
SELECT id, xmin = pg_current_xact_id()::xid AS top_level_xid
FROM account WHERE id IN (1, 2) ORDER BY id;
ROLLBACK;
```

```text
 id | top_level_xid
----+---------------
  1 | t
  2 | f
(2 rows)
```

PL/pgSQL hides the same mechanism: a `BEGIN ... EXCEPTION WHEN ... END` block is a
savepoint, whether or not an error is raised.

```sql
BEGIN;
UPDATE account SET balance = balance + 1 WHERE id = 1;
DO $$
BEGIN
  BEGIN
    UPDATE account SET balance = balance + 1 WHERE id = 2;
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
END $$;
SELECT id, xmin = pg_current_xact_id()::xid AS top_level_xid
FROM account WHERE id IN (1, 2) ORDER BY id;
ROLLBACK;
```

```text
 id | top_level_xid
----+---------------
  1 | t
  2 | f
(2 rows)
```

> **In production —** The PostgreSQL documentation and source say each backend caches 64
> subtransaction ids, and past that other sessions must consult `pg_subtrans` to decide what
> is visible, slowing concurrent queries. I have not reproduced that, and PostgreSQL 15 has
> no view counting a backend's subtransactions, so the 64 is documented, not measured. The
> rule stands regardless: no savepoint or `EXCEPTION` block inside a per-row loop. Check
> whether your ORM or driver adds savepoints for you (nested-transaction helpers and the
> JDBC `autosave` option can).

## 29.4 ACID, with the Postgres footnotes

**Atomicity** is 29.1 to 29.3, with one exception that surprises people: sequences are not
transactional. `nextval` must never block on another session's uncommitted work, so it
cannot be undone:

```sql
CREATE TABLE payment (
  id         int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_id int NOT NULL REFERENCES account (id),
  amount     numeric(12,2) NOT NULL
);

BEGIN;
INSERT INTO payment (account_id, amount) VALUES (1, 100) RETURNING id;
ROLLBACK;
INSERT INTO payment (account_id, amount) VALUES (1, 100) RETURNING id;
```

```text
 id
----
  1
(1 row)

 id
----
  2
(1 row)
```

The rolled-back insert consumed id 1, so the committed one got 2. Gaps are normal and
permanent. If the business requires gapless numbers (invoice numbers in some tax regimes),
use a counter row updated inside the transaction, at the price of serialising every writer.

**Consistency** on PostgreSQL means your constraints hold at commit: the checks, keys and
foreign keys of Chapter 15. Most are checked per statement, which is too early for some
legitimate work. A foreign key declared `DEFERRABLE INITIALLY DEFERRED` is checked at
`COMMIT`, so a child row can go in before its parent:

```sql
CREATE TABLE booking (
  id         int PRIMARY KEY,
  account_id int NOT NULL REFERENCES account (id) DEFERRABLE INITIALLY DEFERRED
);

BEGIN;
INSERT INTO booking VALUES (1, 77);
INSERT INTO account VALUES (77, 'Anita Rao', 0);
COMMIT;

BEGIN;
INSERT INTO booking VALUES (2, 88);
COMMIT;
```

```text
ERROR:  insert or update on table "booking" violates foreign key constraint "booking_account_id_fkey"
DETAIL:  Key (account_id)=(88) is not present in table "account".
```

The first transaction commits, because account 77 exists by `COMMIT`. The second fails *at
`COMMIT`*, so with deferred constraints your error handling must cover `COMMIT`. Unique,
primary key, foreign key and exclusion constraints can be deferred; a `CHECK` cannot
(`DEFERRABLE` on one is a syntax error).

**Isolation** is what concurrent transactions see of each other: Chapter 31. The default,
`READ COMMITTED`, is weaker than most people assume.

**Durability** is the promise that a committed transaction survives a crash, and on
PostgreSQL it is a setting:

```sql
SHOW synchronous_commit;
```

```text
 synchronous_commit
--------------------
 on
(1 row)
```

With `on`, `COMMIT` returns after the commit record is flushed to the write-ahead log.
`SET LOCAL synchronous_commit = off` returns earlier: a crash can lose the last moments of
commits already reported successful, without corrupting the database. Reasonable for
click-stream data, set per transaction; wrong for money. Not benchmarked here; the WAL is
Part X.

## 29.5 Transactional DDL

Oracle and MySQL commit implicitly around most DDL, so a migration that fails halfway leaves
you halfway migrated. In PostgreSQL, DDL is transactional. Add a column, build an index and
drop a table in one transaction, then change your mind:

```sql
BEGIN;
ALTER TABLE account ADD COLUMN kyc_done boolean NOT NULL DEFAULT false;
CREATE INDEX account_owner_idx ON account (owner);
DROP TABLE booking;
SELECT to_regclass('booking') AS booking_table,
       to_regclass('account_owner_idx') AS owner_index,
       (SELECT count(*) FROM pg_attribute
        WHERE attrelid = 'account'::regclass AND attname = 'kyc_done') AS kyc_column;
ROLLBACK;
SELECT to_regclass('booking') AS booking_table,
       to_regclass('account_owner_idx') AS owner_index,
       (SELECT count(*) FROM pg_attribute
        WHERE attrelid = 'account'::regclass AND attname = 'kyc_done') AS kyc_column;
```

```text
 booking_table |    owner_index    | kyc_column
---------------+-------------------+------------
 (null)        | account_owner_idx |          1
(1 row)

 booking_table | owner_index | kyc_column
---------------+-------------+------------
 booking       | (null)      |          0
(1 row)
```

Inside, the table is gone and the index and column exist; after `ROLLBACK` the table is back
and the other two never were. Put a whole migration in one transaction and a failure at step
7 leaves the database at step 0. This is the biggest operational advantage PostgreSQL has
over its competitors.

It has limits. Some commands refuse to run inside a block:

```sql
BEGIN;
CREATE INDEX CONCURRENTLY account_balance_idx ON account (balance);
ROLLBACK;
BEGIN;
VACUUM account;
ROLLBACK;
BEGIN;
CREATE DATABASE ch29_never;
ROLLBACK;
```

```text
ERROR:  CREATE INDEX CONCURRENTLY cannot run inside a transaction block
ERROR:  VACUUM cannot run inside a transaction block
ERROR:  CREATE DATABASE cannot run inside a transaction block
```

`CREATE INDEX CONCURRENTLY` (Chapter 33) needs transactions of its own, `VACUUM` cannot
run in one, and `CREATE DATABASE` touches files outside the catalog. (`REINDEX
CONCURRENTLY`, `DROP DATABASE` and `CREATE TABLESPACE` refuse the same way.) A migration
that needs a concurrent index build is therefore *not* atomic: run it as its own step after
the transactional part commits, and check afterwards for an `INVALID` index left by a failed
build.

Older folklore adds `ALTER TYPE ... ADD VALUE` to that list. On PostgreSQL 12 and later it is
allowed in a transaction block, with a different restriction:

```sql
CREATE TYPE ticket_status AS ENUM ('open', 'closed');
BEGIN;
ALTER TYPE ticket_status ADD VALUE 'escalated';
SELECT 'escalated'::ticket_status;
ROLLBACK;
```

```text
ERROR:  unsafe use of new value "escalated" of enum type ticket_status
LINE 1: SELECT 'escalated'::ticket_status;
               ^
HINT:  New enum values must be committed before they can be used.
```

The statement succeeded; *using* the new value before commit is what fails.

> **Version note —** PostgreSQL 15 allows `ALTER TYPE ... ADD VALUE` in a transaction block
> but not use of the new value in that same transaction. A migration that adds an enum label
> and inserts a row with it must commit in between, or it fails.

Transactional does not mean harmless. DDL takes strong locks, and locks are held until the
transaction ends, not until the statement ends. Type these in three terminals, in this
order: A starts a migration and pauses, B is an ordinary reader, C is a reader with a
`lock_timeout`. Backend PIDs differ on every run, so the queries identify sessions by
`application_name`, set with `PGAPPNAME` when each connected:

```sql
-- Session A
BEGIN;
ALTER TABLE account ADD COLUMN branch text;
```

```sql
-- Session B
SELECT count(*) FROM account;
```

```sql
-- Session C
SET lock_timeout = '5s';
SELECT count(*) FROM account;
```

```sql
-- Session A
SELECT a.application_name AS session, l.mode, l.granted
FROM pg_locks l JOIN pg_stat_activity a USING (pid)
WHERE l.relation = 'account'::regclass AND a.datname = current_database()
ORDER BY l.granted DESC, a.application_name;
```

```text
  session  |        mode         | granted
-----------+---------------------+---------
 session_a | AccessExclusiveLock | t
 session_b | AccessShareLock     | f
 session_c | AccessShareLock     | f
(3 rows)
```

A's `ALTER` holds `AccessExclusiveLock` and has not committed. B and C ran plain `SELECT`s,
which need only `AccessShareLock`, and both are queued behind it: one open DDL transaction
makes the table unreadable. C gave itself a deadline and gives up:

```text
ERROR:  canceling statement due to lock timeout
LINE 1: SELECT count(*) FROM account;
                             ^
```

Roll back A, and B is released:

```sql
-- Session A
ROLLBACK;
```

```text
 count
-------
     4
(1 row)
```

C failed cleanly and can retry; B, with no timeout, would have waited as long as A held the
lock. Put `SET lock_timeout` at the top of every migration; the rest of the pattern (short
locks, retry loops, `NOT VALID` constraints) is Chapter 52, *Zero-Downtime Schema Changes*.

## 29.6 Idle in transaction

The worst transaction is the one doing nothing. A session that ran `BEGIN`, wrote a row, and
then went to call a payment gateway, wait for a user, or died on an unhandled exception
shows in `pg_stat_activity` as `idle in transaction`. It keeps every lock it took and holds
back cleanup for the whole database. Session A opens a transaction, updates a row and goes
quiet. Session B updates the same row:

```sql
-- Session A
BEGIN;
UPDATE account SET balance = balance WHERE id = 1;
```

```sql
-- Session B
UPDATE account SET balance = balance + 500 WHERE id = 1 RETURNING id, balance;
```

B is stuck. From a third connection, the diagnosis:

```sql
-- Session C
SELECT a.application_name AS session, a.state, a.wait_event_type AS waiting_on,
       a.backend_xid IS NOT NULL AS has_xid,
       (SELECT string_agg(b.application_name, ',') FROM pg_stat_activity b
        WHERE b.pid = ANY (pg_blocking_pids(a.pid))) AS blocked_by,
       left(a.query, 32) AS last_statement
FROM pg_stat_activity a
WHERE a.datname = current_database() AND a.pid <> pg_backend_pid()
  AND a.application_name IN ('session_a', 'session_b')
ORDER BY a.application_name;
```

```text
  session  |        state        | waiting_on | has_xid | blocked_by |          last_statement
-----------+---------------------+------------+---------+------------+----------------------------------
 session_a | idle in transaction | Client     | t       | (null)     | UPDATE account SET balance = bal
 session_b | active              | Lock       | t       | session_a  | UPDATE account SET balance = bal
(2 rows)
```

`session_a` is `idle in transaction`, waiting on `Client` (the server is waiting for that
client to send something), and `query` still shows the last statement it ran. `session_b` is
`active`, waiting on a `Lock`, and `pg_blocking_pids()` names its blocker. In a real incident
add `now() - xact_start` to see how long the transaction has been open; it is left out here
because it is a clock. Chapter 39 turns this query into a diagnostic routine and Chapter 48
into a monitor.

In an emergency, terminate the blocker, not the victim:

```sql
-- Session C
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
WHERE datname = current_database() AND application_name = 'session_a'
  AND state = 'idle in transaction';
```

```text
 pg_terminate_backend
----------------------
 t
(1 row)
```

```text
 id | balance
----+----------
  1 | 50750.00
(1 row)
```

B's update has gone through. What does A see when it next sends anything?

```sql
-- Session A
SELECT 1;
```

```text
FATAL:  terminating connection due to administrator command
server closed the connection unexpectedly
	This probably means the server terminated abnormally
	before or while processing the request.
connection to server was lost
```

The connection, and the transaction with it, is gone; A's update rolled back, so B's row is
INR 50,250 (the 29.3 balance) plus B's INR 500. Terminating is a last resort. The application must
survive losing a connection mid-transaction, and the work it was doing is lost, which is why
you would rather prevent this.

### It also holds back cleanup

Locks are the visible cost. The invisible one: an open transaction may still need old row
versions, so `VACUUM` cannot remove them. A session holding a snapshot shows a non-null
`backend_xmin`. Here a `REPEATABLE READ` session (Chapter 31) takes a snapshot and idles
while a table, with autovacuum off to keep the counts deterministic, is emptied and vacuumed:

```sql
CREATE TABLE visit AS SELECT g AS id FROM generate_series(1, 1000) g;
ALTER TABLE visit SET (autovacuum_enabled = false);
```

```sql
-- Session A
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT count(*) FROM visit;
```

```text
 count
-------
  1000
(1 row)
```

```sql
-- Session C
SELECT application_name AS session, state, backend_xmin IS NOT NULL AS holds_horizon
FROM pg_stat_activity
WHERE datname = current_database() AND pid <> pg_backend_pid()
  AND application_name = 'session_a';
DELETE FROM visit;
```

```text
  session  |        state        | holds_horizon
-----------+---------------------+---------------
 session_a | idle in transaction | t
(1 row)
```

```bash
psql -X -d ch29_scratch -c 'VACUUM (VERBOSE) visit' 2>&1 | grep 'tuples:' | sed 's/, oldest xmin.*//'
```

```text
tuples: 0 removed, 1000 remain, 1000 are dead but not yet removable
```

All 1,000 rows are dead and none can be removed, because A's snapshot might still need them.
(The `sed` drops the trailing `oldest xmin`, an id that differs every run.) End A and vacuum
again:

```sql
-- Session C
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
WHERE datname = current_database() AND application_name = 'session_a';
```

```text
 pg_terminate_backend
----------------------
 t
(1 row)
```

```bash
psql -X -d ch29_scratch -c 'VACUUM (VERBOSE) visit' 2>&1 | grep 'tuples:' | sed 's/, oldest xmin.*//'
```

```text
tuples: 1000 removed, 0 remain, 0 are dead but not yet removable
```

Same command, and now all 1,000 rows are removed. The limit is not per table: the oldest open
snapshot in the *whole cluster* sets it, so if `VACUUM` reclaims nothing, look for old
`backend_xmin` values in `pg_stat_activity` before blaming the table. An `idle in
transaction` session left open overnight is a classic cause of bloat; Chapter 37 covers the
recovery.

### Preventing it

`idle_in_transaction_session_timeout` terminates a session that sits idle inside a
transaction for longer than the limit. Set it per database or role, on application roles.
Here, on the scratch database, with a deliberately short limit:

```sql
ALTER DATABASE ch29_scratch SET idle_in_transaction_session_timeout = '1s';
```

```sql
-- Session A
BEGIN;
SHOW idle_in_transaction_session_timeout;
```

```text
 idle_in_transaction_session_timeout
-------------------------------------
 1s
(1 row)
```

A now does nothing and the server ends it (the demonstration polls `pg_stat_activity` until
A's backend is gone rather than sleeping). The next thing A sends:

```sql
-- Session A
SELECT 1;
```

```text
FATAL:  terminating connection due to idle-in-transaction timeout
server closed the connection unexpectedly
	This probably means the server terminated abnormally
	before or while processing the request.
connection to server was lost
```

The setting reached A because A connected after the `ALTER DATABASE`; existing sessions keep
the value they started with. Put it back:

```sql
ALTER DATABASE ch29_scratch RESET idle_in_transaction_session_timeout;
```

> **In production —** A timeout turns a stuck lock queue into an error the application must
> handle. I would start around 30 seconds, above any legitimate pause between statements in
> your code, and set it per role so a batch role with slow steps is not caught. Chapter 50
> covers where these settings belong behind a connection pooler.

## 29.7 The timeout family

Two neighbours bound the other ways a statement can hang. `lock_timeout` (29.5) cancels a
statement that *waits for a lock*; put it on every DDL statement. `statement_timeout`
cancels any statement that runs too long. Both work with `SET LOCAL` inside a transaction:

```sql
SET statement_timeout = '200ms';
SELECT pg_sleep(5);
RESET statement_timeout;
```

```text
ERROR:  canceling statement due to statement timeout
```

One `statement_timeout` for every connection is blunt, because a legitimate report or
`CREATE INDEX` hits it too: set it low on web roles and high on migration and reporting roles.

> **Version note —** `transaction_timeout`, a limit on the whole transaction, arrived in
> PostgreSQL 17. On 15 it does not exist:

```sql
SET transaction_timeout = '30s';
```

```text
ERROR:  unrecognized configuration parameter "transaction_timeout"
```

## Summary

- Every statement runs in a transaction. `BEGIN` only postpones the `COMMIT`; two bare
  statements are two transactions, two statements after `BEGIN` are one.
- A failed statement aborts the whole transaction, and a `COMMIT` sent to it returns the tag
  `ROLLBACK`, not an error. psql's `ON_ERROR_ROLLBACK` hid the failure: a transfer's credit
  committed (INR 17,000 for Priya) while its debit failed. Use `ON_ERROR_STOP` and `-1` for
  scripts.
- `SAVEPOINT` / `ROLLBACK TO` recovers from an error inside a transaction. Every savepoint
  that writes, and every PL/pgSQL `EXCEPTION` block, creates a subtransaction (row `xmin`
  differs from the top-level id); keep them out of per-row loops.
- Sequences and identity columns do not roll back (id 1 was consumed by a rolled-back insert).
  Deferred constraints move failures to `COMMIT`. `synchronous_commit` makes durability a
  per-transaction choice.
- DDL is transactional: a column, an index and a `DROP TABLE` all rolled back. Not
  transactional: `CREATE INDEX CONCURRENTLY`, `VACUUM`, `CREATE DATABASE`, and use of a new enum
  value before commit. `ALTER TYPE ... ADD VALUE` itself is allowed in PostgreSQL 15.
- DDL locks are held until the transaction ends. One open `ALTER` queued two readers
  behind an `AccessExclusiveLock`; `lock_timeout` let one give up.
- An `idle in transaction` session blocked a writer and kept 1,000 dead rows from being
  removed until it was terminated. Set `idle_in_transaction_session_timeout` per role;
  add `statement_timeout` and `lock_timeout` where they fit.

**Exercises:** Practice Sessions 29.1–29.2 accompany this chapter and are in the
workbook at the back of the book.

**Next:** Chapter 30, *MVCC Internals*, opens the row itself: `xmin`, `xmax`, snapshots,
and why an `UPDATE` in PostgreSQL is an insert plus a mark-dead.
