# Chapter 15 — Constraints and Referential Integrity

Chapters 13 and 14 chose containers for values. A column type narrows what *can* be
stored; a constraint narrows what *should* be. Between the two sits every bad row you will
ever have to clean up.

The argument you will have about this chapter is whether validation belongs in the
database or the application. It is not really a choice. Your application is one of several
writers — there is also the migration script, the data-fix someone ran at 2 a.m., the ETL
job, and the next application, by people who never read your validation module. A
constraint is the only rule that applies to all of them.

Everything below is DDL, so it runs in a throwaway database:

```bash
createdb ch15_scratch
psql -d ch15_scratch
```

---

## 15.1 What the sample schema does not enforce

Ask the `retail` database what it actually guarantees:

```sql
SELECT conname, contype FROM pg_constraint
WHERE  conrelid = 'customers'::regclass
ORDER  BY conname;
```

```text
          conname           | contype 
----------------------------+---------
 customers_pkey             | p
 customers_referred_by_fkey | f
(2 rows)
```

A primary key and one foreign key — `customers.referred_by` really does carry a
self-reference, so the referral graph cannot point at a customer who does not exist.

`loyalty_tier` carries nothing. It is bare `text`, nullable, with no `CHECK`, and today it
holds `bronze` (225), `silver` (200), `gold` (183) and NULL (392). Nothing prevents
tomorrow's `Gold`, `GOLD`, `platinum`, `''` or `'gold '`. Each arrives silently, each
splits a group in a report, and each is found months later by an analyst who assumed the
column had a domain. Practice Session 15.1 fixes it.

`contype` codes the kind: `p` primary key, `f` foreign key, `u` unique, `c` check, `x`
exclusion. There is no code for `NOT NULL`, because on PostgreSQL 15 it is not a row in
`pg_constraint` at all but a flag on the column (`pg_attribute.attnotnull`) — which is why
it has no name to drop, only `ALTER TABLE ... ALTER COLUMN ... DROP NOT NULL`.

## 15.2 `NOT NULL` and `CHECK`

```sql
CREATE TABLE customers (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email        text NOT NULL CONSTRAINT customers_email_lower CHECK (email = lower(email)),
    name         text NOT NULL,
    city         text,
    loyalty_tier text NOT NULL DEFAULT 'none'
                 CONSTRAINT customers_tier_known
                 CHECK (loyalty_tier IN ('none','bronze','silver','gold')),
    credit_limit numeric(12,2) NOT NULL DEFAULT 0
                 CONSTRAINT customers_credit_nonneg CHECK (credit_limit >= 0)
);
```

Name your constraints. Left alone PostgreSQL generates `customers_loyalty_tier_check`, and
that name is what the application sees in the error. `customers_tier_known` says what the
rule is; the generated name says only which column.

```sql
INSERT INTO customers (email, name, city, loyalty_tier, credit_limit) VALUES
  ('anita.rao@example.com',      'Anita Rao',      'Bengaluru',  'gold',   250000.00),
  ('harpreet.singh@example.com', 'Harpreet Singh', 'Chandigarh', 'silver',  80000.00),
  ('meera.banerjee@example.com', 'Meera Banerjee', NULL,         'none',        0.00);
```

Now the failures, which are the point.

```sql
INSERT INTO customers (email, name) VALUES ('arjun.iyer@example.com', NULL);
```

```text
ERROR:  null value in column "name" of relation "customers" violates not-null constraint
DETAIL:  Failing row contains (4, arjun.iyer@example.com, null, null, none, 0.00).
```

```sql
INSERT INTO customers (email, name, loyalty_tier)
VALUES ('arjun.iyer@example.com', 'Arjun Iyer', 'platinum');
```

```text
ERROR:  new row for relation "customers" violates check constraint "customers_tier_known"
DETAIL:  Failing row contains (5, arjun.iyer@example.com, Arjun Iyer, null, platinum, 0.00).
```

The `DETAIL:` line prints the whole rejected tuple — the most useful thing in a PostgreSQL
error message, and the reason to surface it in application logs rather than swallow it. It
renders an absent value as the bare word `null`, the server's tuple format rather than
psql's `\pset null`. And identity values 4 and 5 were consumed by inserts that failed:
sequences are not transactional, so identity columns have gaps (Chapter 20).

### A `CHECK` that is NULL is a `CHECK` that passed

Chapter 7's three-valued logic, arriving where you did not expect it. **A `CHECK` fails
only when it evaluates to false. NULL is not false, so the row is accepted.**

```sql
CREATE TABLE shipment (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    placed_on   date NOT NULL,
    shipped_on  date,
    CONSTRAINT shipped_after_placed CHECK (shipped_on > placed_on)
);

INSERT INTO shipment (placed_on, shipped_on) VALUES
    (DATE '2026-03-01', DATE '2026-03-03'),
    (DATE '2026-03-02', NULL);
```

```text
INSERT 0 2
```

Both rows went in. The second one's expression is `NULL > DATE '2026-03-02'`, which is
NULL, which is not false. Here that is what you want — an unshipped order has no delay to
validate — and the danger is when it is *not*, because the constraint then looks like it
is protecting you and is not. A rule that must reject the absent case has to say so:
`CHECK (shipped_on IS NOT NULL AND shipped_on > placed_on)`. A genuinely false value is
rejected as expected: `(DATE '2026-03-04', DATE '2026-03-01')` fails.

Two limits before you design around `CHECK`. It sees only **the row being written** — no
subqueries, no other tables, no aggregates — and must be **immutable**, so
`CHECK (placed_on <= current_date)` is rejected: a row legal when written must stay legal
when the table is next scanned or restored from a dump. Cross-row rules need an exclusion
constraint (section 15.7) or a trigger (Chapter 43).

> **In production —** a `CHECK` list is the cheapest way to give a `text` column a domain,
> and it beats an `ENUM` when the set of values will change: adding a value is
> `DROP CONSTRAINT` plus `ADD CONSTRAINT ... NOT VALID`, not an `ALTER TYPE` you cannot run
> inside a transaction. Chapter 21 chooses between a lookup table, an `ENUM` and a `CHECK`.

## 15.3 `UNIQUE`, and what NULL does to it

`ALTER TABLE customers ADD CONSTRAINT customers_email_key UNIQUE (email)` gives the column
a uniqueness rule and, unavoidably, an index — a `UNIQUE` constraint *is* a unique B-tree
index, which `\d customers` then lists as
`"customers_email_key" UNIQUE CONSTRAINT, btree (email)`. That index is maintained on every
write and occupies space, which is why the sample datasets ship without unique constraints
beyond the primary keys.

Now the behaviour that surprises people. By default **NULLs are all distinct from each
other**, so a nullable unique column accepts any number of them: given
`gst_registration(customer_id bigint PRIMARY KEY, gstin text UNIQUE)`, three customers with
a NULL `gstin` all insert cleanly. That is the standard's rule and usually right — two
customers who have not supplied a GST number are not duplicates of each other.

When NULL means *none* and there may be only one *none*, declare the column
`UNIQUE NULLS NOT DISTINCT (gstin)` instead. One real GSTIN and one NULL go in; a second
NULL does not:

```text
ERROR:  duplicate key value violates unique constraint "gst_strict_gstin_key"
DETAIL:  Key (gstin)=(null) already exists.
```

> **Version note —** `UNIQUE NULLS NOT DISTINCT` requires PostgreSQL 15. On 14 and earlier
> the workaround is a unique index on `coalesce(col, <sentinel>)`, which needs a sentinel
> the column can never legitimately hold.

### Unique index or unique constraint?

A `CREATE UNIQUE INDEX` enforces uniqueness just as well, and does two things a constraint
cannot: it can be **partial** and it can be built on an **expression**. The partial form is
how you make soft delete work:

```sql
CREATE TABLE coupon (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code       text NOT NULL,
    deleted_at timestamptz
);
CREATE UNIQUE INDEX coupon_code_live ON coupon (code) WHERE deleted_at IS NULL;

INSERT INTO coupon (code, deleted_at) VALUES ('DIWALI20', now()), ('DIWALI20', NULL);
INSERT INTO coupon (code) VALUES ('DIWALI20');
```

```text
ERROR:  duplicate key value violates unique constraint "coupon_code_live"
DETAIL:  Key (code)=(DIWALI20) already exists.
```

One live `DIWALI20`, any number of retired ones — a plain `UNIQUE (code)` cannot express
that. The cost is that a **partial** unique index cannot be a foreign key target. A full
one can: an FK needs a unique index over exactly the referenced columns, not a named
constraint.

### And primary keys

A primary key is `UNIQUE` plus `NOT NULL`, plus one thing neither gives you: there can be
only one per table, so PostgreSQL treats it as *the* identity of a row. That singularity is
what lets the planner apply Chapter 8's functional-dependency rule, and it is what a
foreign key points at by default. Additional candidate keys are legitimate — they are
`UNIQUE NOT NULL`. Which column to choose is Chapter 20.

## 15.4 Foreign keys, and choosing `ON DELETE`

```sql
CREATE TABLE orders (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES customers(id),
    placed_on   date   NOT NULL DEFAULT current_date,
    total       numeric(12,2) NOT NULL CHECK (total >= 0)
);
CREATE TABLE order_item (
    id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id bigint NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    sku      text   NOT NULL,
    quantity int    NOT NULL CHECK (quantity > 0)
);
```

A foreign key enforces one sentence: *every non-NULL value in this column exists over
there.* It is checked both when the child is written
(`INSERT INTO orders (customer_id, total) VALUES (9999, 2450.00)`) and when the parent is
deleted (`DELETE FROM customers WHERE id = 1`):

```text
ERROR:  insert or update on table "orders" violates foreign key constraint "orders_customer_id_fkey"
DETAIL:  Key (customer_id)=(9999) is not present in table "customers".
```

```text
ERROR:  update or delete on table "customers" violates foreign key constraint "orders_customer_id_fkey" on table "orders"
DETAIL:  Key (id)=(1) is still referenced from table "orders".
```

That second error is `ON DELETE NO ACTION`, the default, and it is the right default: the
database refuses to guess what you meant. The alternatives:

| `ON DELETE` | Effect when the parent row is deleted | Use it when |
|---|---|---|
| `NO ACTION` (default) | Error; deferrable to commit | The child is an independent fact — almost always |
| `RESTRICT` | Error, immediate, **not** deferrable | You want the failure at the statement |
| `CASCADE` | Delete the child rows too | The child has no meaning without the parent |
| `SET NULL` | Null the referencing column | The link is optional information |
| `SET DEFAULT` | Set the column default, which must exist in the parent | Rare — an "unassigned" placeholder row |

`NO ACTION` and `RESTRICT` look identical until the constraint is `DEFERRABLE`: `NO ACTION`
then waits until commit, so a transaction may delete the parent first and the children
afterwards, whereas `RESTRICT` fires on the spot regardless.

`CASCADE` is the one to be deliberate about. It is correct for `order_item`, which is part
of an order and not a thing in its own right: `DELETE FROM orders WHERE id = 1` takes that
order's two line items with it, silently and correctly.

> **Trap —** `ON DELETE CASCADE` on the wrong edge is the most destructive default in
> schema design, because cascades chain. One from `customers` reaches `orders`, one from
> `orders` reaches `order_item`, so a single `DELETE FROM customers WHERE id = 42` removes
> three tables' worth of history, commits, and looks like a success. Put `CASCADE` only
> where the child is *part of* the parent, and never on anything a finance or audit team
> will want to read next year (Chapter 22, soft delete versus archive).

`SET NULL` fits an optional link, which is the shape of a referral —
`ALTER TABLE customers ADD COLUMN referred_by bigint REFERENCES customers(id) ON DELETE SET NULL;`
Delete a referrer and their referees keep their rows, having lost only the attribution.

> **Version note —** PostgreSQL 15 adds a column list: `... ON DELETE SET NULL (y)` nulls
> only `y` of a composite key, where earlier versions null all of it. Related: a composite
> FK defaults to `MATCH SIMPLE`, under which a key with *any* NULL column is not checked at
> all. `MATCH FULL` demands it be wholly NULL or wholly non-NULL.

## 15.5 A foreign key is not an index

PostgreSQL indexes the *referenced* side automatically, because a foreign key requires a
unique index there. It does **not** index the referencing side, and the sample datasets
deliberately ship without those indexes (Chapter 33).

That matters on every parent delete, because PostgreSQL must find the children pointing at
the row. Build a pair of tables large enough to show it — these two carry the rest of the
chapter as well:

```sql
CREATE TABLE warehouse (id int PRIMARY KEY, code text NOT NULL UNIQUE, city text NOT NULL);
INSERT INTO warehouse
SELECT g, 'WH-' || lpad(g::text, 4, '0'),
       (ARRAY['Mumbai','Delhi','Bengaluru','Hyderabad','Chennai',
              'Kolkata','Pune','Ahmedabad','Jaipur','Kochi'])[1 + g % 10]
FROM   generate_series(1, 500) g;

CREATE TABLE dispatch (id bigint PRIMARY KEY, warehouse_id int NOT NULL,
                       dispatched_on date NOT NULL, weight_kg numeric(10,2) NOT NULL);
INSERT INTO dispatch
SELECT g, 1 + (g % 500), DATE '2024-01-01' + (g % 700), (g % 5000) / 10.0
FROM   generate_series(1, 3000000) g;
ANALYZE warehouse; ANALYZE dispatch;
```

`warehouse_id` is unindexed, and this is the lookup a referential-integrity trigger runs
for each deleted parent:

```sql
EXPLAIN SELECT 1 FROM dispatch WHERE warehouse_id = 7 FOR KEY SHARE;
```

```text
                              QUERY PLAN                              
----------------------------------------------------------------------
 LockRows  (cost=0.00..56668.70 rows=5970 width=10)
   ->  Seq Scan on dispatch  (cost=0.00..56609.00 rows=5970 width=10)
         Filter: (warehouse_id = 7)
(3 rows)
```

A full scan of the child table, per deleted parent row. Add the index and the same lookup
becomes a `Bitmap Index Scan on dispatch_warehouse_id_idx` under the `LockRows` node, with
the estimated total cost falling from 56668.70 to 12816.09.

Deleting twenty childless parents takes 1,534 ms without that index and 0.443 ms with it.

**Index every foreign key column you will ever delete or update a parent of.** The only
exception is a child whose parents are immutable and never removed; there the index is
pure write overhead. Chapter 33 covers the trade-off.

## 15.6 Deferrable constraints

Some legal end states are unreachable one statement at a time. Swapping two values in a
unique column is the canonical case.

```sql
CREATE TABLE menu_slot (
    id       int  PRIMARY KEY,
    label    text NOT NULL,
    position int  NOT NULL,
    CONSTRAINT menu_slot_position_key UNIQUE (position)
);
INSERT INTO menu_slot VALUES (1,'Groceries',1), (2,'Electronics',2), (3,'Apparel',3);

BEGIN;
UPDATE menu_slot SET position = 2 WHERE id = 1;
UPDATE menu_slot SET position = 1 WHERE id = 2;
COMMIT;
```

```text
BEGIN
ERROR:  duplicate key value violates unique constraint "menu_slot_position_key"
DETAIL:  Key ("position")=(2) already exists.
ERROR:  current transaction is aborted, commands ignored until end of transaction block
ROLLBACK
```

The transaction's *end state* is valid. It is the intermediate state, after the first
`UPDATE`, that is not. A `DEFERRABLE` constraint is checked at commit instead of at
statement end:

```sql
ALTER TABLE menu_slot DROP CONSTRAINT menu_slot_position_key;
ALTER TABLE menu_slot ADD CONSTRAINT menu_slot_position_key
    UNIQUE (position) DEFERRABLE INITIALLY IMMEDIATE;

BEGIN;
SET CONSTRAINTS menu_slot_position_key DEFERRED;
UPDATE menu_slot SET position = 2 WHERE id = 1;
UPDATE menu_slot SET position = 1 WHERE id = 2;
COMMIT;
```

That commits. Declare `DEFERRABLE INITIALLY IMMEDIATE`, as here, not `INITIALLY DEFERRED`:
the constraint then behaves normally for every transaction that does not ask for
otherwise, and the one that needs the relaxation opts in with `SET CONSTRAINTS`.
`INITIALLY DEFERRED` moves *every* violation to commit time, turning a precise
statement-level error into a mystery at the end of a long transaction.

Only `UNIQUE`, `PRIMARY KEY`, foreign keys and `EXCLUDE` can be deferred. Append
`DEFERRABLE` to a `CHECK` and:

```text
ERROR:  CHECK constraints cannot be marked DEFERRABLE
```

The other use is circular references — two tables that each require a row in the other.
Make one direction deferrable and a single transaction can insert both.

> **Trap —** a deferrable unique constraint cannot be used by `ON CONFLICT` (Chapter 5).

## 15.7 Exclusion constraints

`UNIQUE` asks whether two rows are *equal*. Sometimes the rule is that they must not
*overlap*, which no unique index can express. An **exclusion constraint** generalises
uniqueness to any operator: it rejects a row if, for some existing row, every listed
operator returns true. Overlap needs a GiST index, and GiST over a scalar column like
`room_id` needs the `btree_gist` extension, which is in `contrib`:

```sql
CREATE EXTENSION btree_gist;

CREATE TABLE room_booking (
    id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    room_id int  NOT NULL,
    guest   text NOT NULL,
    stay    daterange NOT NULL,
    CONSTRAINT room_booking_no_overlap
        EXCLUDE USING gist (room_id WITH =, stay WITH &&)
);
```

Without it the `CREATE TABLE` fails with
`data type integer has no default operator class for access method "gist"`. Read the
constraint as: reject a new row if there is an existing row with **the same** `room_id`
**and** an **overlapping** `stay`.

```sql
INSERT INTO room_booking (room_id, guest, stay) VALUES
  (204, 'Meera Banerjee', daterange('2026-04-10','2026-04-14')),
  (204, 'Arjun Iyer',     daterange('2026-04-14','2026-04-17')),
  (301, 'Fatima Sheikh',  daterange('2026-04-11','2026-04-13'));

INSERT INTO room_booking (room_id, guest, stay)
VALUES (204, 'Rajesh Kumar', daterange('2026-04-13','2026-04-16'));
```

```text
ERROR:  conflicting key value violates exclusion constraint "room_booking_no_overlap"
DETAIL:  Key (room_id, stay)=(204, [2026-04-13,2026-04-16)) conflicts with existing key (room_id, stay)=(204, [2026-04-10,2026-04-14)).
```

Two things in that output. The back-to-back bookings — one ending 14 April, the next
starting 14 April — were both accepted, because `daterange` is half-open by default:
`[2026-04-10,2026-04-14)` includes the 10th and excludes the 14th. Getting that convention
wrong is how a booking system loses a night; ranges are Chapter 16's subject. And the error
names the row it conflicted with, which is what you show the user.

Why this matters more than it looks: an application that asks *"is this room free?"* and
then inserts has a race between the two statements, and two concurrent bookings both see a
free room. The constraint has no such gap — Practice Session 15.2 reproduces the race in
two terminals.

## 15.8 `NOT VALID`, then `VALIDATE`

Adding a constraint to an empty table is free. Adding one to a table that already holds
three million rows is a migration, and this is where people get paged. The problem is not
the scan — it is the lock held during the scan. Read it straight out of `pg_locks`, from
inside the transaction that took it:

```sql
BEGIN;
ALTER TABLE dispatch ADD CONSTRAINT dispatch_warehouse_fk
    FOREIGN KEY (warehouse_id) REFERENCES warehouse(id);
SELECT c.relname, l.mode
FROM   pg_locks l JOIN pg_class c ON c.oid = l.relation
WHERE  l.pid = pg_backend_pid()
AND    c.relname IN ('dispatch', 'warehouse')
ORDER  BY c.relname, l.mode;
ROLLBACK;
```

```text
  relname  |         mode          
-----------+-----------------------
 dispatch  | AccessShareLock
 dispatch  | ShareRowExclusiveLock
 warehouse | AccessShareLock
 warehouse | RowShareLock
 warehouse | ShareRowExclusiveLock
(5 rows)
```

`ShareRowExclusiveLock` on both tables — the child being altered and the parent being
referenced. (`RowShareLock` on `warehouse` is the validating scan reading it; the
`AccessShareLock` entries are the `pg_locks` query itself.) That mode permits reads and
blocks writes, and is held for as long as the scan takes. Selects keep working; every
`INSERT`, `UPDATE` and `DELETE` against either table queues behind it — including writes
to a parent that has nothing wrong with it.

Split the operation. `NOT VALID` records the constraint without scanning. Same transaction,
same lock query, two extra words:

```sql
ALTER TABLE dispatch ADD CONSTRAINT dispatch_warehouse_fk
    FOREIGN KEY (warehouse_id) REFERENCES warehouse(id) NOT VALID;
```

```text
  relname  |         mode          
-----------+-----------------------
 dispatch  | AccessShareLock
 dispatch  | ShareRowExclusiveLock
 warehouse | AccessShareLock
 warehouse | ShareRowExclusiveLock
(4 rows)
```

**The same lock mode**, minus the `RowShareLock` the vanished scan would have taken. This
is the part that gets misreported: `NOT VALID` does not lower the lock level, it removes
the scan,
so the strong lock is taken and released rather than held for a three-million-row read. The
statement must still acquire `ShareRowExclusiveLock`, so it queues behind any long-running
transaction touching either table — and while it waits, everything behind *it* waits too.
Set `lock_timeout` and retry rather than let a migration take a site down. Chapter 52,
*Schema Migrations on Live Systems*, covers the retry pattern; Appendix C tabulates the
lock level of every `ALTER TABLE`.

Measured, that window is 0.57 ms against 135 ms; the scan moves to `VALIDATE`, which
holds only `ShareUpdateExclusiveLock` and lets writes through.

An unvalidated constraint is recorded but not trusted:

```sql
SELECT conname, contype, convalidated FROM pg_constraint
WHERE  conrelid = 'dispatch'::regclass ORDER BY conname;
```

```text
        conname        | contype | convalidated 
-----------------------+---------+--------------
 dispatch_pkey         | p       | t
 dispatch_warehouse_fk | f       | f
(2 rows)
```

`convalidated = f` means only that existing rows were not checked. **New writes are
enforced from the moment the constraint exists** — `INSERT INTO dispatch VALUES (3000002,
8888, DATE '2026-03-02', 9.10);` is rejected:

```text
ERROR:  insert or update on table "dispatch" violates foreign key constraint "dispatch_warehouse_fk"
DETAIL:  Key (warehouse_id)=(8888) is not present in table "warehouse".
```

The bleeding stops immediately; the backlog is cleaned up on your schedule. Then validate:

```sql
BEGIN;
ALTER TABLE dispatch VALIDATE CONSTRAINT dispatch_warehouse_fk;
SELECT c.relname, l.mode
FROM   pg_locks l JOIN pg_class c ON c.oid = l.relation
WHERE  l.pid = pg_backend_pid()
AND    c.relname IN ('dispatch', 'warehouse')
ORDER  BY c.relname, l.mode;
COMMIT;
```

```text
  relname  |           mode           
-----------+--------------------------
 dispatch  | AccessShareLock
 dispatch  | ShareUpdateExclusiveLock
 warehouse | AccessShareLock
 warehouse | RowShareLock
(4 rows)
```

**That is the payoff.** `ShareUpdateExclusiveLock` on the child and `RowShareLock` on the
parent: neither conflicts with `INSERT`, `UPDATE` or `DELETE`, so the long scan runs
against a live, writable table. It does conflict with itself and with `VACUUM`, `ANALYZE`
and other DDL, so do not run two at once.

If the table really does contain bad rows, `VALIDATE` fails with the same error shape,
naming one offending value — a poor way to clean a million rows. Find them all at once with
an anti-join, repair, then re-run `VALIDATE`:

```sql
SELECT d.id, d.warehouse_id
FROM   dispatch d LEFT JOIN warehouse w ON w.id = d.warehouse_id
WHERE  w.id IS NULL;
```

```text
   id    | warehouse_id 
---------+--------------
 3000001 |         9999
(1 row)
```

`CHECK` constraints take the same two-step, with one difference worth knowing before you
plan a window. The same lock query around
`ALTER TABLE dispatch ADD CONSTRAINT dispatch_weight_nonneg CHECK (weight_kg >= 0) NOT VALID;`
reports a heavier lock, not a lighter one:

```text
 relname  |        mode         
----------+---------------------
 dispatch | AccessExclusiveLock
(1 row)
```

`AccessExclusiveLock` blocks reads as well as writes, and adding a `CHECK` takes it with or
without `NOT VALID`. Here too `NOT VALID` shortens the window rather than weakening the
lock, and `VALIDATE CONSTRAINT` again takes `ShareUpdateExclusiveLock`.

---

## Summary

- A constraint is the only validation rule that applies to every writer. Name every one.
- **A `CHECK` rejects a row only when the expression is false.** NULL is not false, so a
  nullable column slips past every comparison-based `CHECK`. Spell out the NULL case or add
  `NOT NULL`. A `CHECK` also sees only the current row, and must be immutable.
- **`UNIQUE` treats NULLs as distinct from each other by default**, so a nullable unique
  column accepts many NULLs. `UNIQUE NULLS NOT DISTINCT` (PostgreSQL 15) inverts that.
- A partial unique index does what `UNIQUE` cannot — one live row per key under soft delete
  — at the cost of not being usable as a foreign key target.
- **Choose `ON DELETE` deliberately.** `NO ACTION` is the right default. `CASCADE` belongs
  only where the child is part of the parent, because cascades chain and commit quietly.
- **PostgreSQL does not index the referencing side of a foreign key.** Without that index,
  every parent delete sequentially scans the child table.
- Defer with `DEFERRABLE INITIALLY IMMEDIATE` plus `SET CONSTRAINTS`, never
  `INITIALLY DEFERRED` by default. `NOT NULL` and `CHECK` cannot be deferred at all.
- An exclusion constraint generalises uniqueness to any operator, and unlike an
  application's "is it free?" check it has no race.
- **`NOT VALID` removes the scan, not the lock.** Adding a foreign key takes
  `ShareRowExclusiveLock` on *both* tables either way, and adding a `CHECK` takes
  `AccessExclusiveLock` either way — but `VALIDATE CONSTRAINT` then takes only
  `ShareUpdateExclusiveLock` plus `RowShareLock` on the parent, neither of which blocks
  writes. That is what makes the two-step worth doing. Chapter 52 covers live migrations;
  Appendix C tabulates every lock level.

**Exercises:** Practice Sessions 15.1–15.3 accompany this chapter and are in the workbook
at the back of the book.

**Next:** Chapter 16, *PostgreSQL-Native Types* — arrays, ranges and multiranges, `ENUM`
and the `ALTER` it will not let you run in a transaction, `uuid`, `inet`, composite types
and `DOMAIN`. The `daterange` you just excluded overlaps on gets its proper treatment.
