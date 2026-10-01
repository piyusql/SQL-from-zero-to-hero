# Chapter 22 — The Table Design Checklist

This chapter covers what every table carries *around* its business columns. It is a
checklist because these decisions are cheap on day one and expensive on day one thousand:
adding `tenant_id` to a table with 450,000 rows rewrites it, partitioning a live table is a
migration project, and an audit trail started after the incident is an empty table.

Each item is tied to the failure it prevents and says when I would skip it. Chapter 15's
constraints and Chapter 20's key choice are assumed. There are no timings here; the
evidence is buffer counts, page counts, WAL bytes and error messages.

```bash
createdb ch22_scratch
psql -d ch22_scratch
```

---

## 22.1 What a bare table gives you

The table a deadline produces:

```sql
\pset null '(null)'
CREATE TABLE invoice_bare (
    id        serial,
    customer  text,
    amount    numeric,
    status    text
);
INSERT INTO invoice_bare (customer, amount, status) VALUES ('Anita Rao', 12500, 'open');
UPDATE invoice_bare SET status = 'paid' WHERE id = 1;

INSERT INTO invoice_bare (id, customer, amount, status) VALUES (1, NULL, -5, 'banana');
SELECT * FROM invoice_bare;

SELECT (SELECT count(*) FROM pg_constraint WHERE conrelid = 'invoice_bare'::regclass) AS constraints,
       (SELECT count(*) FROM pg_index      WHERE indrelid = 'invoice_bare'::regclass) AS indexes;
```

```text
 id | customer  | amount | status
----+-----------+--------+--------
  1 | Anita Rao |  12500 | paid
  1 | (null)    |     -5 | banana
(2 rows)

 constraints | indexes
-------------+---------
           0 |       0
(1 row)
```


The last `INSERT` succeeded: two rows with `id = 1`, one with no customer, one for minus
five rupees, one with status `banana`. The catalog says why. Nothing records who created
the row or who changed `open` to `paid`.

## 22.2 The standard columns

Every table holding business data gets the same set. This is the one I copy into a new
project unchanged:

```sql
CREATE FUNCTION app_user() RETURNS text LANGUAGE sql STABLE AS
$$ SELECT coalesce(nullif(current_setting('app.actor', true), ''), session_user) $$;

CREATE FUNCTION touch_row() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.created_at  := OLD.created_at;
    NEW.created_by  := OLD.created_by;
    NEW.updated_at  := now();
    NEW.updated_by  := app_user();
    NEW.row_version := OLD.row_version + 1;
    RETURN NEW;
END $$;

CREATE TABLE customer (          -- the parent, trimmed to what the foreign key needs
    id          bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   int         NOT NULL,
    name        text        NOT NULL,
    email       text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, email)
);

CREATE TABLE invoice (
    id          bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   int           NOT NULL,
    invoice_no  text          NOT NULL,
    customer_id bigint        NOT NULL,
    amount      numeric(12,2) NOT NULL CHECK (amount >= 0),
    status      text          NOT NULL DEFAULT 'open'
                CHECK (status IN ('open', 'paid', 'void')),
    created_at  timestamptz   NOT NULL DEFAULT now(),
    created_by  text          NOT NULL DEFAULT app_user(),
    updated_at  timestamptz   NOT NULL DEFAULT now(),
    updated_by  text          NOT NULL DEFAULT app_user(),
    row_version int           NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, invoice_no),
    FOREIGN KEY (tenant_id, customer_id) REFERENCES customer (tenant_id, id)
);
CREATE INDEX invoice_customer_idx ON invoice (tenant_id, customer_id);

CREATE TRIGGER invoice_touch BEFORE UPDATE ON invoice
    FOR EACH ROW EXECUTE FUNCTION touch_row();
```


What each piece prevents:

1. **`id bigint GENERATED ALWAYS AS IDENTITY`.** Duplicate keys (22.1), and hand-supplied
   ids. Key choice is Chapter 20.
2. **`created_at timestamptz DEFAULT now()`.** The first incident question is *when*.
   Never `timestamp` (Chapter 14).
3. **`created_by`, `updated_by`.** The second question is *who*. The connection is a
   pooled application role, so the application names the user with `SET LOCAL app.actor`
   inside the transaction; `app_user()` falls back to the login role.
4. **`updated_at`, `updated_by`, `row_version`, set by a trigger.** An application that
   "remembers" fails when the second writer, script or migration arrives. The trigger
   also makes `created_*` immutable. These columns are the *latest* change, not a history
   (22.3).
5. **`row_version`.** The lost update: two users edit one invoice and the later save
   silently wins. The writer sends the version it read; the `UPDATE` matches nothing if
   someone got there first.

`meera.banerjee` creates rows; `arjun.iyer` updates one and *tries to forge* `created_by`
and `row_version` in the same statement:

```sql
BEGIN;
SET LOCAL app.actor = 'meera.banerjee';
INSERT INTO customer (tenant_id, name, email)
VALUES (1, 'Anita Rao', 'anita@example.in'), (2, 'Harpreet Singh', 'harpreet@example.in');
INSERT INTO invoice (tenant_id, invoice_no, customer_id, amount) VALUES (1, 'INV-0001', 1, 12500.00);
COMMIT;

BEGIN;
SET LOCAL app.actor = 'arjun.iyer';
UPDATE invoice SET status = 'paid', created_by = 'someone.else', row_version = 99
WHERE  invoice_no = 'INV-0001';
COMMIT;

SELECT invoice_no, status, created_by, updated_by, row_version FROM invoice;
SHOW app.actor;
```

```text
 invoice_no | status |   created_by   | updated_by | row_version
------------+--------+----------------+------------+-------------
 INV-0001   | paid   | meera.banerjee | arjun.iyer |           2
(1 row)

 app.actor
-----------

(1 row)
```


The forgery is discarded and `updated_by` is Arjun. `SHOW` prints an empty string because
`SET LOCAL` reverted at `COMMIT`.

> **Trap —** Plain `SET app.actor` lasts for the session. Behind a transaction-mode pooler
> the next client on that connection inherits the previous user's name and the trail
> blames the wrong person. Use `SET LOCAL` or `set_config(..., true)` in every transaction.

The optimistic-lock update, using the version the writer read (1 is stale, 2 is current):

```sql
UPDATE invoice SET amount = 1 WHERE invoice_no = 'INV-0001' AND row_version = 1 RETURNING row_version;
UPDATE invoice SET amount = 1 WHERE invoice_no = 'INV-0001' AND row_version = 2 RETURNING row_version;
```

```text
 row_version
-------------
(0 rows)

 row_version
-------------
           3
(1 row)
```


**What it costs.** These columns are paid on every row. Load 20,000 invoices (the table
used from here on) and measure:

```sql
INSERT INTO customer (tenant_id, name, email)
SELECT 1, 'Customer ' || g, 'c' || g || '@example.in' FROM generate_series(1, 200) g;
INSERT INTO invoice (tenant_id, invoice_no, customer_id, amount)
SELECT 1, 'BULK-' || lpad(g::text, 6, '0'), 3 + g % 200, 100 + g % 5000
FROM   generate_series(1, 20000) g;
ANALYZE invoice;

SELECT count(*) AS invoices,
       round(avg(pg_column_size(created_at) + pg_column_size(created_by) + pg_column_size(updated_at)
                 + pg_column_size(updated_by) + pg_column_size(row_version)), 1) AS standard_column_bytes,
       round(avg(pg_column_size(i.*)), 1) AS row_bytes
FROM   invoice i;
```

```text
 invoices | standard_column_bytes | row_bytes
----------+-----------------------+-----------
    20001 |                  38.0 |     120.0
(1 row)
```


38 of 120 bytes, a third of this narrow row (`created_by` is the short string `postgres`).
On invoices that is irrelevant; on a ten-billion-row append-only event table it is the
reason to skip the `_by` columns and keep `created_at`.

## 22.3 The audit trail

`updated_by` says who touched a row last. An audit trail says what the row looked like
before. The dependable build is a trigger writing old and new row as `jsonb` into an
`audit` schema table (Chapter 21); Chapter 43 covers triggers generally.

> **Version note —** The WAL measurements below use `pg_walinspect`, new in PostgreSQL 15
> and superuser-only by default. The helper filters by transaction id because
> `pg_current_wal_lsn()` differences count *every* session's WAL, and reports bytes
> **excluding full-page images**, which depend on checkpoint timing rather than the
> statement.

```sql
CREATE EXTENSION pg_walinspect;

CREATE FUNCTION wal_of(x xid, from_lsn pg_lsn)
RETURNS TABLE (records bigint, wal_bytes bigint) LANGUAGE sql AS $$
    SELECT count(*), coalesce(sum(record_length - fpi_length), 0)::bigint
    FROM   pg_get_wal_records_info(from_lsn, pg_current_wal_flush_lsn())
    WHERE  xid = x $$;
```


```sql
CREATE SCHEMA audit;
CREATE TABLE audit.row_log (
    id         bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    actor      text        NOT NULL DEFAULT app_user(),
    txid       bigint      NOT NULL DEFAULT txid_current(),
    table_name text        NOT NULL,
    op         text        NOT NULL,
    row_id     bigint,
    old_row    jsonb,
    new_row    jsonb
);
CREATE INDEX row_log_lookup ON audit.row_log (table_name, row_id, id);

CREATE FUNCTION audit.log_row() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
    INSERT INTO audit.row_log (table_name, op, row_id, old_row, new_row)
    VALUES (TG_TABLE_NAME, TG_OP,
            CASE WHEN TG_OP = 'DELETE' THEN OLD.id ELSE NEW.id END,
            CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) END,
            CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) END);
    RETURN NULL;
END $$;

CREATE TRIGGER invoice_audit AFTER INSERT OR UPDATE OR DELETE ON invoice
    FOR EACH ROW EXECUTE FUNCTION audit.log_row();
```


`SECURITY DEFINER` lets the application write to the trail without holding any privilege
on it. Insert, update and delete, captured, then the no-op update rolled back:

```sql
BEGIN;
SET LOCAL app.actor = 'fatima.sheikh';
INSERT INTO invoice (tenant_id, invoice_no, customer_id, amount) VALUES (1, 'INV-0010', 1, 4200.00);
UPDATE invoice SET amount = 4800.00 WHERE invoice_no = 'INV-0010';
DELETE FROM invoice WHERE invoice_no = 'INV-0010';
COMMIT;

SELECT id, actor, op, row_id, old_row->>'amount' AS old_amount, new_row->>'amount' AS new_amount
FROM   audit.row_log ORDER BY id;

BEGIN;
UPDATE invoice SET status = status WHERE invoice_no = 'INV-0001';
SELECT count(*) AS audit_rows_after_noop_update FROM audit.row_log;
ROLLBACK;
```

```text
 id |     actor     |   op   | row_id | old_amount | new_amount
----+---------------+--------+--------+------------+------------
  1 | fatima.sheikh | INSERT |  20002 | (null)     | 4200.00
  2 | fatima.sheikh | UPDATE |  20002 | 4200.00    | 4800.00
  3 | fatima.sheikh | DELETE |  20002 | 4800.00    | (null)
(3 rows)

 audit_rows_after_noop_update
------------------------------
                            4
(1 row)
```


The last statement is a warning: an `UPDATE` that changes nothing still adds a row (3 to 4),
which is what an ORM saving every column does. Fix that at the source before filtering in
the trigger. The old/new pair also answers "which fields changed" for tables nobody has
written a report for.

**What it does not capture.** Say this to the auditor:

```sql
BEGIN;
TRUNCATE invoice;
SELECT (SELECT count(*) FROM invoice) AS invoices, (SELECT count(*) FROM audit.row_log) AS audit_rows;
ROLLBACK;

BEGIN;
SET LOCAL session_replication_role = replica;
UPDATE invoice SET amount = 1 WHERE invoice_no = 'INV-0001';
SELECT (SELECT count(*) FROM audit.row_log) AS audit_rows,
       (SELECT row_version FROM invoice WHERE invoice_no = 'INV-0001') AS row_version;
ROLLBACK;

BEGIN;
ALTER TABLE invoice DISABLE TRIGGER invoice_audit;
DELETE FROM invoice WHERE invoice_no = 'INV-0001';
SELECT count(*) AS audit_rows FROM audit.row_log;
ROLLBACK;
```

```text
 invoices | audit_rows
----------+------------
        0 |          3
(1 row)

 audit_rows | row_version
------------+-------------
          3 |           3
(1 row)

 audit_rows
------------
          3
(1 row)
```


`TRUNCATE` emptied the table and the trail stayed at 3 rows: row triggers do not fire for
it. Under `session_replication_role = replica` (used by logical-replication apply) the
`UPDATE` wrote no audit row *and* skipped `touch_row`: `row_version` stayed at 3. And an owner who disables the trigger deletes rows invisibly. Two of these have
fixes:

```sql
CREATE FUNCTION audit.log_truncate() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
    INSERT INTO audit.row_log (table_name, op) VALUES (TG_TABLE_NAME, 'TRUNCATE');
    RETURN NULL;
END $$;

CREATE TRIGGER invoice_audit_truncate BEFORE TRUNCATE ON invoice
    FOR EACH STATEMENT EXECUTE FUNCTION audit.log_truncate();
ALTER TABLE invoice ENABLE ALWAYS TRIGGER invoice_audit;

BEGIN;
TRUNCATE invoice;
SELECT op, row_id FROM audit.row_log ORDER BY id DESC LIMIT 1;
ROLLBACK;

BEGIN;
SET LOCAL session_replication_role = replica;
UPDATE invoice SET amount = 1 WHERE invoice_no = 'INV-0001';
SELECT (SELECT count(*) FROM audit.row_log) AS audit_rows,
       (SELECT row_version FROM invoice WHERE invoice_no = 'INV-0001') AS row_version;
ROLLBACK;

SELECT tgname, tgenabled FROM pg_trigger
WHERE  tgrelid = 'invoice'::regclass AND NOT tgisinternal ORDER BY tgname;
```

```text
    op    | row_id
----------+--------
 TRUNCATE | (null)
(1 row)

 audit_rows | row_version
------------+-------------
          4 |           3
(1 row)

         tgname         | tgenabled
------------------------+-----------
 invoice_audit          | A
 invoice_audit_truncate | O
 invoice_touch          | O
(3 rows)
```


The statement-level trigger logged the `TRUNCATE`, and `ENABLE ALWAYS` (`A` in
`tgenabled`) made the audit trigger fire under `replica`: the count went from 3 to 4.
`tgenabled <> 'O'` is worth a monitoring query. The third gap is privilege, so try it
with a role holding only DML on the two tables:

```sql
CREATE ROLE ch22_app LOGIN;
GRANT USAGE ON SCHEMA public TO ch22_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON invoice, customer TO ch22_app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO ch22_app;

\c ch22_scratch ch22_app
UPDATE invoice SET status = 'void' WHERE invoice_no = 'INV-0001' RETURNING updated_by;
SELECT count(*) FROM audit.row_log;
TRUNCATE invoice;
ALTER TABLE invoice DISABLE TRIGGER invoice_audit;
SET session_replication_role = replica;
\c ch22_scratch postgres
SELECT actor, op, new_row->>'status' AS new_status FROM audit.row_log ORDER BY id DESC LIMIT 1;
```

```text
 updated_by
------------
 ch22_app
(1 row)

ERROR:  permission denied for schema audit
LINE 1: SELECT count(*) FROM audit.row_log;
                             ^
ERROR:  permission denied for table invoice
ERROR:  must be owner of table invoice
ERROR:  permission denied to set parameter "session_replication_role"
  actor   |   op   | new_status
----------+--------+------------
 ch22_app | UPDATE | void
(1 row)
```


The update was audited (`actor` is the role itself, as nobody set `app.actor`). The role
cannot read the trail, truncate, disable the trigger or change the replication role.
What escapes is the **superuser and the table owner**; keep the application on neither.
No trigger design captures them. That tier is the server log (`pgaudit`, Part X).

**What it costs.** Two identical copies of the invoice table, one with the audit trigger,
and the same 1,000-row `UPDATE` on each:

```sql
CREATE TABLE invoice_off (LIKE invoice INCLUDING ALL);
CREATE TABLE invoice_on  (LIKE invoice INCLUDING ALL);
INSERT INTO invoice_off OVERRIDING SYSTEM VALUE SELECT * FROM invoice ORDER BY id;
INSERT INTO invoice_on  OVERRIDING SYSTEM VALUE SELECT * FROM invoice ORDER BY id;
CREATE TRIGGER off_touch BEFORE UPDATE ON invoice_off FOR EACH ROW EXECUTE FUNCTION touch_row();
CREATE TRIGGER on_touch  BEFORE UPDATE ON invoice_on  FOR EACH ROW EXECUTE FUNCTION touch_row();
CREATE TRIGGER on_audit  AFTER INSERT OR UPDATE OR DELETE ON invoice_on
    FOR EACH ROW EXECUTE FUNCTION audit.log_row();

SELECT pg_current_wal_insert_lsn() AS l0 \gset
BEGIN;
SELECT txid_current() AS x \gset
UPDATE invoice_off SET status = 'paid' WHERE id % 20 = 4;
COMMIT;
SELECT 'audit off' AS variant, records, pg_size_pretty(wal_bytes) AS wal FROM wal_of(:'x'::xid, :'l0');

SELECT pg_current_wal_insert_lsn() AS l0 \gset
BEGIN;
SELECT txid_current() AS x \gset
UPDATE invoice_on SET status = 'paid' WHERE id % 20 = 4;
COMMIT;
SELECT 'audit on' AS variant, records, pg_size_pretty(wal_bytes) AS wal FROM wal_of(:'x'::xid, :'l0');

SELECT count(*) AS log_rows, pg_size_pretty(pg_total_relation_size('audit.row_log')) AS log_size
FROM   audit.row_log WHERE table_name = 'invoice_on';
```

```text
  variant  | records |  wal
-----------+---------+--------
 audit off |    6050 | 486 kB
(1 row)

 variant  | records |   wal
----------+---------+---------
 audit on |    9087 | 1412 kB
(1 row)

 log_rows | log_size
----------+----------
     1000 | 944 kB
(1 row)
```


About three times the WAL (2.9× by bytes): the same 1,000 rows wrote 486 kB without the
trigger and 1,412 kB with it, and each change adds a trail row of about 950 bytes with
its two indexes. That is fair for `invoice`. It is the
reason not to audit a table taking 20,000 updates a second: audit where "who changed
this" will be asked, and give hot tables the `updated_*` columns only.

## 22.4 Delete policy: hard, soft or archive

Decide per table on day one; the choice reaches every unique constraint and query. My order:

1. **Hard `DELETE`, old row held by the audit trail.** The default. Nothing else in the
   design changes.
2. **Archive:** `DELETE ... RETURNING` into an archive table in one statement. For tables
   whose live set must stay small while history is kept.
3. **Soft delete** (`deleted_at`): only when the business undeletes things or a child
   must keep pointing at the row.

A soft-deleted row is still personal data (an erasure request is not met by `deleted_at`),
does not cascade to children, and still occupies every unique constraint:

```sql
CREATE TABLE member (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id  int  NOT NULL,
    email      text NOT NULL,
    deleted_at timestamptz,
    UNIQUE (tenant_id, email)
);
INSERT INTO member (tenant_id, email) VALUES (1, 'priya.menon@example.in');
UPDATE member SET deleted_at = now() WHERE email = 'priya.menon@example.in';
INSERT INTO member (tenant_id, email) VALUES (1, 'priya.menon@example.in');
```

```text
ERROR:  duplicate key value violates unique constraint "member_tenant_id_email_key"
DETAIL:  Key (tenant_id, email)=(1, priya.menon@example.in) already exists.
```


Priya deleted her account and cannot sign up again. The fix is a unique index over live
rows only, with two consequences:

```sql
ALTER TABLE member DROP CONSTRAINT member_tenant_id_email_key;
CREATE UNIQUE INDEX member_email_live ON member (tenant_id, email) WHERE deleted_at IS NULL;

INSERT INTO member (tenant_id, email) VALUES (1, 'priya.menon@example.in');
INSERT INTO member (tenant_id, email) VALUES (1, 'priya.menon@example.in');
INSERT INTO member (tenant_id, email) VALUES (1, 'priya.menon@example.in')
ON CONFLICT (tenant_id, email) WHERE deleted_at IS NULL DO NOTHING;
CREATE TABLE member_note (
    id int, tenant_id int, email text,
    FOREIGN KEY (tenant_id, email) REFERENCES member (tenant_id, email));
```

```text
ERROR:  duplicate key value violates unique constraint "member_email_live"
DETAIL:  Key (tenant_id, email)=(1, priya.menon@example.in) already exists.
ERROR:  there is no unique constraint matching given keys for referenced table "member"
```


The re-signup works, a second live one fails, `ON CONFLICT` must repeat the index
predicate, and a partial unique index **cannot be a foreign-key target**.

Now the read cost: 500,000 tickets, 100 per customer, and a query for the 20 newest *live*
tickets of 50 customers. Two identical tables, one with an ordinary index and one with
the index restricted to `deleted_at IS NULL`.

```sql
CREATE TABLE ticket_full (
    id          bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id int         NOT NULL,
    ref         text        NOT NULL,
    created_at  timestamptz NOT NULL,
    deleted_at  timestamptz,
    body        text        NOT NULL
);
INSERT INTO ticket_full (customer_id, ref, created_at, body)
SELECT g % 5000, 'TKT-' || lpad(g::text, 7, '0'),
       timestamptz '2026-01-01' + g * interval '1 minute', repeat('x', 100)
FROM   generate_series(1, 500000) g;
CREATE TABLE ticket_partial (LIKE ticket_full INCLUDING ALL);
INSERT INTO ticket_partial OVERRIDING SYSTEM VALUE SELECT * FROM ticket_full ORDER BY id;

CREATE INDEX ticket_full_cust    ON ticket_full    (customer_id, created_at DESC);
CREATE INDEX ticket_partial_cust ON ticket_partial (customer_id, created_at DESC)
    WHERE deleted_at IS NULL;
VACUUM ANALYZE ticket_full;
VACUUM ANALYZE ticket_partial;

SELECT pg_relation_size('ticket_full') / 8192 AS heap_pages,
       pg_relation_size('ticket_full_cust') / 8192    AS full_index_pages,
       pg_relation_size('ticket_partial_cust') / 8192 AS partial_index_pages;
```

```text
 heap_pages | full_index_pages | partial_index_pages
------------+------------------+---------------------
      10205 |             1928 |                1928
(1 row)
```


This soft-deletes 0%, 50%, then 90% of rows (by a hash of the id, so it repeats), runs
`VACUUM` after each step (hence `\gexec`: `VACUUM` cannot run in a function) and records
buffers from `EXPLAIN (ANALYZE, BUFFERS)`. Parallelism is pinned off; each figure is a
second run.

```sql
SET max_parallel_workers_per_gather = 0;

CREATE FUNCTION live_buffers(t regclass) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE j jsonb;
BEGIN
    EXECUTE format($q$EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON, TIMING OFF, SUMMARY OFF)
        SELECT sum(length(t.ref)) FROM generate_series(1, 50) c,
        LATERAL (SELECT ref FROM %s
                 WHERE customer_id = c AND deleted_at IS NULL
                 ORDER BY created_at DESC LIMIT 20) t$q$, t) INTO j;
    RETURN (j -> 0 -> 'Plan' ->> 'Shared Hit Blocks')::bigint
         + (j -> 0 -> 'Plan' ->> 'Shared Read Blocks')::bigint;
END $$;

CREATE TABLE soft_result (dead_pct int, live_rows bigint, buffers_full bigint, buffers_partial bigint);

SELECT stmt FROM unnest(ARRAY[0, 50, 90]) AS pct,
LATERAL unnest(ARRAY[
    format('UPDATE ticket_full    SET deleted_at = now() WHERE deleted_at IS NULL AND abs(hashint4(id::int)) %% 100 < %s', pct),
    format('UPDATE ticket_partial SET deleted_at = now() WHERE deleted_at IS NULL AND abs(hashint4(id::int)) %% 100 < %s', pct),
    'VACUUM ANALYZE ticket_full',
    'VACUUM ANALYZE ticket_partial',
    'DO $$ BEGIN PERFORM live_buffers(''ticket_full''), live_buffers(''ticket_partial''); END $$',  -- warm-up
    format('INSERT INTO soft_result SELECT %s, (SELECT count(*) FROM ticket_full WHERE deleted_at IS NULL), live_buffers(''ticket_full''), live_buffers(''ticket_partial'')', pct)
]) WITH ORDINALITY AS s(stmt, n)
ORDER BY pct, n
\gexec

SELECT * FROM soft_result ORDER BY dead_pct;

SELECT pg_relation_size('ticket_full') / 8192 AS heap_pages,
       pg_relation_size('ticket_full_cust') / 8192    AS full_index_pages,
       pg_relation_size('ticket_partial_cust') / 8192 AS partial_index_pages;
```

```text
 dead_pct | live_rows | buffers_full | buffers_partial
----------+-----------+--------------+-----------------
        0 |    500000 |         1153 |            1153
       50 |    249778 |         2160 |            1157
       90 |     50275 |         5183 |             685
(3 rows)

 heap_pages | full_index_pages | partial_index_pages
------------+------------------+---------------------
      15528 |             3852 |                1928
(1 row)
```


With nothing deleted the tables are identical, 1,153 buffers. At 50% dead, the ordinary
index needs 2,160, nearly double, because half of each customer's index entries lead to
heap rows that are fetched and discarded; the partial index stays at 1,157. At 90%,
5,183 against 685. The ordinary index also doubled to 3,852 pages while the partial stayed
at 1,928, and the heap grew from 10,205 to 15,528 pages while 90% of the live content
disappeared: a soft delete is an `UPDATE`, which writes a new row version.

The cost is negligible when few rows are deleted and large when dead rows outnumber live
ones. A partial index removes the read cost, not the size. Archiving removes both:

```sql
CREATE TABLE ticket_archive (LIKE ticket_full INCLUDING DEFAULTS);

WITH moved AS (
    DELETE FROM ticket_full WHERE deleted_at IS NOT NULL RETURNING *
)
INSERT INTO ticket_archive SELECT * FROM moved;

VACUUM ANALYZE ticket_full;
SELECT live_buffers('ticket_full') AS warm_up \gset
SELECT (SELECT count(*) FROM ticket_full) AS live, (SELECT count(*) FROM ticket_archive) AS archived,
       live_buffers('ticket_full') AS buffers;
VACUUM FULL ticket_full;
SELECT pg_relation_size('ticket_full') / 8192 AS heap_pages_after_vacuum_full;
```

```text
 live  | archived | buffers
-------+----------+---------
 50275 |   449725 |     700
(1 row)

 heap_pages_after_vacuum_full
------------------------------
                         1027
(1 row)
```


The query is back to 700 buffers with the ordinary index. The table was 15,528 pages
before the archive; `VACUUM FULL` left 1,027.

> **In production —** `VACUUM FULL` takes an `ACCESS EXCLUSIVE` lock; archive often enough
> that the live table never needs it. `VACUUM` also cannot remove rows an old open
> transaction can still see: on a busy shared server one verification run of this block
> reported 5,183 buffers instead of 700 for that reason (Chapter 30). If you keep soft delete, give application code a
> `_live` view: the query that forgets `deleted_at IS NULL` is the one that leaks.

## 22.5 Tenant readiness

If the system will hold more than one customer's data, every table carries `tenant_id`
from the first migration. Chapter 21 compares the tenancy models and Chapter 44 turns the
column into row-level security. Two design decisions must already be made.

**Make foreign keys carry the tenant.** A plain foreign key checks that the parent exists,
not that it belongs to the same tenant:

```sql
CREATE TABLE invoice_plain (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   int    NOT NULL,
    customer_id bigint NOT NULL REFERENCES customer (id)
);
INSERT INTO invoice_plain (tenant_id, customer_id) VALUES (1, 2);

SELECT i.tenant_id AS invoice_tenant, c.tenant_id AS customer_tenant
FROM   invoice_plain i JOIN customer c ON c.id = i.customer_id;

INSERT INTO invoice (tenant_id, invoice_no, customer_id, amount) VALUES (1, 'INV-0002', 2, 500);
```

```text
 invoice_tenant | customer_tenant
----------------+-----------------
              1 |               2
(1 row)

ERROR:  insert or update on table "invoice" violates foreign key constraint "invoice_tenant_id_customer_id_fkey"
DETAIL:  Key (tenant_id, customer_id)=(1, 2) is not present in table "customer".
```


The plain-FK invoice for tenant 1 points at a tenant 2 customer and PostgreSQL is content.
Row-level security will not catch it: it filters what a session sees, it does not validate
references. The composite key `(tenant_id, id)` on the parent and a composite foreign key
on the child, as `invoice` has, rejects it at the constraint (second statement). The price
is one extra unique index on the parent.

**Add the column now.** Adding `tenant_id` later is cheap only with a constant default,
and a constant is the wrong tenant for every row. The backfill is a rewrite:

```sql
CREATE TABLE ticket_t AS
SELECT id, customer_id, ref, created_at, body FROM ticket_archive;

SELECT pg_current_wal_insert_lsn() AS l0 \gset
BEGIN;
SELECT txid_current() AS x \gset
ALTER TABLE ticket_t ADD COLUMN tenant_id int NOT NULL DEFAULT 1;
COMMIT;
SELECT pg_relation_size('ticket_t') AS table_bytes, records FROM wal_of(:'x'::xid, :'l0');

SELECT pg_current_wal_insert_lsn() AS l0 \gset
BEGIN;
SELECT txid_current() AS x \gset
UPDATE ticket_t SET tenant_id = customer_id % 20 + 1;
COMMIT;
SELECT pg_relation_size('ticket_t') AS table_bytes, records, pg_size_pretty(wal_bytes) AS wal FROM wal_of(:'x'::xid, :'l0');
```

```text
 table_bytes | records
-------------+---------
    75194368 |      13
(1 row)

 table_bytes | records |  wal
-------------+---------+--------
   153575424 |  899451 | 115 MB
(1 row)
```


The metadata-only `ADD COLUMN` wrote 13 WAL records and left the table at 75,194,368
bytes. The backfill of 449,725 rows wrote 899,451 records and over 100 MB of WAL, and the
table doubled to 153,575,424 bytes with the old versions awaiting `VACUUM`. That table had
no indexes; every real one must also be rebuilt to lead with `tenant_id`. Skip `tenant_id`
on global lookup tables (states, currencies) only.

## 22.6 Decide on partitioning before go-live

Do not partition every table. Do decide, for every table that grows without bound,
*before go-live*, because there is no conversion:

```sql
ALTER TABLE ticket_full PARTITION BY RANGE (created_at);

CREATE TABLE event (
    id         bigint      GENERATED ALWAYS AS IDENTITY,
    created_at timestamptz NOT NULL,
    payload    text        NOT NULL,
    PRIMARY KEY (id)
) PARTITION BY RANGE (created_at);
```

```text
ERROR:  syntax error at or near "PARTITION"
LINE 1: ALTER TABLE ticket_full PARTITION BY RANGE (created_at);
                                ^
ERROR:  unique constraint on partitioned table must include all partitioning columns
DETAIL:  PRIMARY KEY constraint on table "event" lacks column "created_at" which is part of the partition key.
```


A live table is converted by building a partitioned one and copying. The
second error is the design constraint: the primary key must include the partition column,
so the identifier becomes `(id, created_at)`, and a referencing table must carry the
timestamp too:

```sql
CREATE TABLE event (
    id         bigint      GENERATED ALWAYS AS IDENTITY,
    created_at timestamptz NOT NULL,
    payload    text        NOT NULL,
    PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);
CREATE TABLE event_2026_01 PARTITION OF event FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE event_2026_02 PARTITION OF event FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');

CREATE TABLE event_note (
    id       bigint PRIMARY KEY,
    event_id bigint NOT NULL REFERENCES event (id)
);

CREATE TABLE event_note (
    id       bigint PRIMARY KEY,
    event_id bigint      NOT NULL,
    event_at timestamptz NOT NULL,
    FOREIGN KEY (event_id, event_at) REFERENCES event (id, created_at)
);
```

```text
ERROR:  there is no unique constraint matching given keys for referenced table "event"
```


The reason to partition is usually **retention**, not speed. The same 233,280 rows,
removed two ways:

```sql
DROP TABLE event_note;

INSERT INTO event (created_at, payload)
SELECT timestamptz '2026-01-01' + (g % 50) * interval '1 day' + g * interval '1 second', repeat('e', 80)
FROM   generate_series(1, 400000) g;
CREATE TABLE event_flat (LIKE event INCLUDING ALL);
INSERT INTO event_flat (created_at, payload) SELECT created_at, payload FROM event;

SELECT tableoid::regclass AS part, count(*) FROM event GROUP BY 1 ORDER BY 1;

SELECT pg_current_wal_insert_lsn() AS l0 \gset
BEGIN;
SELECT txid_current() AS x \gset
DELETE FROM event_flat WHERE created_at < '2026-02-01';
COMMIT;
SELECT 'DELETE, one month' AS what, records, pg_size_pretty(wal_bytes) AS wal FROM wal_of(:'x'::xid, :'l0');

SELECT pg_current_wal_insert_lsn() AS l0 \gset
BEGIN;
SELECT txid_current() AS x \gset
DROP TABLE event_2026_01;
COMMIT;
SELECT 'DROP PARTITION' AS what, records, pg_size_pretty(wal_bytes) AS wal FROM wal_of(:'x'::xid, :'l0');
```

```text
     part      | count
---------------+--------
 event_2026_01 | 233280
 event_2026_02 | 166720
(2 rows)

       what        | records |  wal
-------------------+---------+-------
 DELETE, one month |  233281 | 12 MB
(1 row)

      what      | records |    wal
----------------+---------+------------
 DROP PARTITION |      53 | 4093 bytes
(1 row)
```


Deleting one month took 233,281 WAL records and about 12 MB, and leaves dead rows to
vacuum; dropping the partition took 53 records and a few kilobytes. My rule: partition when data leaves in
bulk by date or whole-table maintenance is becoming unschedulable. Do not partition for
query speed without measuring (Chapter 38). Otherwise take the cheap precaution: keep a
`created_at` you could partition on.

## 22.7 The day-one index plan

You do not need an indexing strategy on day one (Chapter 33). You need three things: the
primary key, the unique business keys (`UNIQUE (tenant_id, invoice_no)` rejects the
duplicates 22.1 accepted), and **an index on every foreign-key column in the child
table**. PostgreSQL indexes the parent side of a foreign key and not the child side, so
every parent delete has to find the children:

```sql
CREATE VIEW child_reads AS
SELECT seq_scan, seq_tup_read, coalesce(idx_scan, 0) AS idx_scan
FROM   pg_stat_user_tables WHERE relname = 'invoice';

DROP TABLE invoice_plain;
INSERT INTO customer (tenant_id, name, email) VALUES (1, 'Kavya Nair', 'kavya@example.in')
RETURNING id AS lonely_id \gset

DROP INDEX invoice_customer_idx;
DO $$ BEGIN PERFORM pg_sleep(2); END $$;
SELECT * FROM child_reads \gset b_
BEGIN; DELETE FROM customer WHERE id = :lonely_id; ROLLBACK;
DO $$ BEGIN PERFORM pg_sleep(2); END $$;
SELECT 'no FK index' AS variant, seq_scan - :b_seq_scan AS seq_scans,
       seq_tup_read - :b_seq_tup_read AS seq_tuples_read, idx_scan - :b_idx_scan AS index_scans
FROM child_reads;

CREATE INDEX invoice_customer_idx ON invoice (tenant_id, customer_id);
DO $$ BEGIN PERFORM pg_sleep(2); END $$;
SELECT * FROM child_reads \gset b_
BEGIN; DELETE FROM customer WHERE id = :lonely_id; ROLLBACK;
DO $$ BEGIN PERFORM pg_sleep(2); END $$;
SELECT 'FK index' AS variant, seq_scan - :b_seq_scan AS seq_scans,
       seq_tup_read - :b_seq_tup_read AS seq_tuples_read, idx_scan - :b_idx_scan AS index_scans
FROM child_reads;
```

```text
   variant   | seq_scans | seq_tuples_read | index_scans
-------------+-----------+-----------------+-------------
 no FK index |         1 |           20001 |           0
(1 row)

 variant  | seq_scans | seq_tuples_read | index_scans
----------+-----------+-----------------+-------------
 FK index |         0 |               0 |           1
(1 row)
```


Without the index, deleting a customer with no invoices read all 20,001 invoice rows in a
sequential scan; with it, one index scan and none. It stays invisible until the child
table is large. Everything else waits for a slow query and Chapter 34; do not index
`created_at` "in case", or a three-valued status: every index is written on every
insert and update.

## 22.8 The checklist

Copy this into the pull-request template for anything that creates a table.

1. **Key.** Identity primary key (Chapter 20). *Prevents duplicate rows.*
2. **Business key.** `UNIQUE` on the natural identifier, tenant included. *Prevents two
   `INV-0001`.* Skip for pure link tables keyed by the pair.
3. **`created_at`, `created_by`.** `timestamptz` default `now()`. *Prevents "when, who?"*
   Skip `created_by` on very high-volume append-only tables.
4. **`updated_at`, `updated_by`, `row_version`, by trigger.** *Prevents forged or forgotten
   bookkeeping and lost updates.* Skip on immutable tables.
5. **Constraints.** `NOT NULL`, `CHECK`, foreign keys (Chapter 15). *Prevents `banana`.*
6. **Audit.** `jsonb` row trigger, `TRUNCATE` trigger, `ENABLE ALWAYS`, an application
   role that owns nothing. *Prevents "what was it before?"* Skip on hot tables (about 3×
   the WAL per update here).
7. **Delete policy.** Hard delete plus audit; archive for large history; soft delete only
   when the business undeletes, with partial unique indexes and a `_live` view.
   *Prevents the dead-row read tax and the account that cannot re-register.*
8. **Tenant.** `tenant_id` everywhere, in unique keys and composite foreign keys.
   *Prevents cross-tenant references and a rewrite later.* Skip on global lookups.
9. **Partitioning.** Decide per unbounded table now; if partitioned, the key includes the
   partition column and children carry it. *Prevents a live conversion.* Skip when
   nothing leaves in bulk.
10. **Indexes.** Child-side foreign keys and the unique keys; nothing speculative.
    *Prevents parent deletes scanning the child.*

## Summary

- Give every table the same standard columns, maintained by trigger, with the user named
  through `SET LOCAL`. They were 38 of 120 bytes here.
- A `to_jsonb` audit trigger misses `TRUNCATE`, replica-mode writes and owner or superuser
  actions. It cost about 3× the WAL of a 1,000-row update.
- Default to hard delete plus audit. Soft delete breaks unique constraints and taxes reads;
  archive removes the cost.
- `tenant_id` everywhere, in composite keys. Decide partitioning before go-live: the key
  must include the partition column, and dropping a partition is nearly free.
- Index child-side foreign keys on day one.

**Exercises:** Practice Sessions 22.1–22.3 accompany this chapter and are in the workbook at
the back of the book.

**Next:** Chapter 23, *The Column Design Checklist*, goes inside the table: type selection,
`NOT NULL` by default, defaults and generated columns, TOAST and alignment padding, and
marking personal data.
