# Chapter 24 — Design Anti-Patterns and Safe Refactoring

Chapters 18 to 23 were about designing a schema on purpose. This one is about the schemas
you inherit, and it has two halves. The first is a handful of recognisable shapes, each a
reasonable shortcut on the day it was written, that have been quietly costing integrity
ever since. The second is that knowing a table is wrong does not let you fix it: it has a
hundred million rows, four services write to it, and there is no window.

The first four sections demonstrate each anti-pattern *failing*, with counts and error
messages rather than adjectives, and say when it is the right call. The last two are the
technique for changing a live schema without stopping it. Everything runs in scratch
databases; nothing below writes to `retail`.

---

## 24.1 Entity-attribute-value: a schema that cannot say what it stores

EAV replaces columns with rows. Instead of a `product` table with `colour` and `weight_g`
columns, one narrow table holds `(product_id, attr_name, attr_value)`. Build the same
50,000 products both ways:

```bash
createdb ch24_eav
psql -d ch24_eav
```

```sql
\pset null '(null)'
SET default_statistics_target = 1000;   -- sample every row, so plans are repeatable
CREATE TABLE product_typed (                       -- the design you should have
    id int PRIMARY KEY, name text NOT NULL,
    colour text NOT NULL, material text NOT NULL,
    weight_g int NOT NULL CHECK (weight_g > 0),
    warranty_months int NOT NULL CHECK (warranty_months >= 0),
    price numeric(10,2) NOT NULL CHECK (price >= 0));
INSERT INTO product_typed
SELECT g, 'Item ' || g,
       (ARRAY['Teak','Indigo','Saffron','Ivory','Charcoal','Sage'])[g % 6 + 1],
       (ARRAY['Wood','Brass','Cotton','Ceramic','Steel'])[g % 5 + 1],
       200 + (g * 37) % 4800, (ARRAY[0,6,12,24,36])[g % 5 + 1],
       round((99 + (g * 53) % 9900)::numeric, 2)
FROM generate_series(1, 50000) g;

CREATE TABLE product_attr (                        -- the same facts as EAV
    product_id int  NOT NULL,
    attr_name  text NOT NULL,
    attr_value text,
    PRIMARY KEY (product_id, attr_name));
INSERT INTO product_attr
SELECT id, a.k, a.v FROM product_typed p
CROSS JOIN LATERAL (VALUES ('colour', p.colour), ('material', p.material),
    ('weight_g', p.weight_g::text), ('warranty_months', p.warranty_months::text),
    ('price', p.price::text)) AS a(k, v);
VACUUM ANALYZE product_typed; VACUUM ANALYZE product_attr;
```

That is 250,000 EAV rows for 50,000 products. Size is the cheap failure; the expensive one
is the query the design exists to answer.

**Failure 1: the question you actually ask.** "Teak products over 4.5 kg with at least 24
months of warranty, every attribute shown." In the typed table that is a `WHERE`. In EAV it
is one self-join per filter, plus one more join and a pivot to turn rows back into columns:

```sql
CREATE VIEW teak_heavy_eav AS
SELECT c.product_id,
       max(a.attr_value) FILTER (WHERE a.attr_name = 'colour')          AS colour,
       max(a.attr_value) FILTER (WHERE a.attr_name = 'material')        AS material,
       max(a.attr_value) FILTER (WHERE a.attr_name = 'weight_g')        AS weight_g,
       max(a.attr_value) FILTER (WHERE a.attr_name = 'warranty_months') AS warranty_months,
       max(a.attr_value) FILTER (WHERE a.attr_name = 'price')           AS price
FROM   product_attr c
JOIN   product_attr w ON w.product_id = c.product_id AND w.attr_name = 'weight_g' AND w.attr_value::int > 4500
JOIN   product_attr y ON y.product_id = c.product_id AND y.attr_name = 'warranty_months' AND y.attr_value::int >= 24
JOIN   product_attr a ON a.product_id = c.product_id
WHERE  c.attr_name = 'colour' AND c.attr_value = 'Teak'
GROUP  BY c.product_id;

SET max_parallel_workers_per_gather = 0;      -- one process, so buffer totals compare
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT * FROM teak_heavy_eav;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT * FROM teak_heavy_eav;     -- second, warm run
```

The block runs the `EXPLAIN` twice; the second, warm plan is below. It is 40-odd lines and
the top carries the finding:

```text
                                                    QUERY PLAN
------------------------------------------------------------------------------------------------------------------
 GroupAggregate (actual rows=344 loops=1)
   Group Key: c.product_id
   Buffers: shared hit=8012
   ->  Sort (actual rows=1720 loops=1)
```

The typed equivalent, run the same way (twice again; the warm plan is shown):

```sql
SET max_parallel_workers_per_gather = 0;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM product_typed WHERE colour = 'Teak' AND weight_g > 4500 AND warranty_months >= 24;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM product_typed WHERE colour = 'Teak' AND weight_g > 4500 AND warranty_months >= 24;
```

```text
                                      QUERY PLAN
---------------------------------------------------------------------------------------
 Seq Scan on product_typed (actual rows=344 loops=1)
   Filter: ((weight_g > 4500) AND (warranty_months >= 24) AND (colour = 'Teak'::text))
   Rows Removed by Filter: 49656
   Buffers: shared hit=467
(4 rows)
```

Both return 344 products. EAV needed **8,012 buffers** and the typed table **467**, and the
typed table did it with a sequential scan and no secondary index. (Plain `ANALYZE` samples rows at random, and the EAV plan moved between builds of this
test, so the setup raises the statistics target to read every row and make it repeatable.)
The obvious rescue is an index on `(attr_name, attr_value)`:

```sql
SET default_statistics_target = 1000;
CREATE INDEX product_attr_name_value ON product_attr (attr_name, attr_value);
ANALYZE product_attr;
SET max_parallel_workers_per_gather = 0;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT * FROM teak_heavy_eav;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT * FROM teak_heavy_eav;     -- second, warm run
```

```text
                                                       QUERY PLAN
------------------------------------------------------------------------------------------------------------------------
 GroupAggregate (actual rows=344 loops=1)
   Group Key: c.product_id
   Buffers: shared hit=8087
   ->  Sort (actual rows=1720 loops=1)
```

The index did not rescue it: 8,087 buffers against 8,012 without it. The planner does use it
now, but for `weight_g` the bitmap scan returns all 50,000 entries for that attribute name to
find 5,193 rows, because the value is text cast to `int` and cannot be range-filtered inside
the index. The other filters are still one primary-key probe per candidate. I dropped it again.

**Failure 2: the database cannot see types.** `attr_value` is `text` because it must hold a
colour and a weight. Try bad writes against each design:

```sql
DROP INDEX product_attr_name_value;
UPDATE product_typed SET price = 'abc' WHERE id = 7;
UPDATE product_typed SET price = -5 WHERE id = 7;
UPDATE product_attr SET attr_value = 'abc' WHERE product_id = 7 AND attr_name = 'price';
INSERT INTO product_attr VALUES (8, 'colur', 'Teak');
```

```text
ERROR:  invalid input syntax for type numeric: "abc"
LINE 1: UPDATE product_typed SET price = 'abc' WHERE id = 7;
                                         ^
ERROR:  new row for relation "product_typed" violates check constraint "product_typed_price_check"
DETAIL:  Failing row contains (7, Item 7, Indigo, Cotton, 459, 12, -5.00).
```

The typed table refused both. The two EAV statements printed nothing, which means they
succeeded, and nothing says so until a report runs:

```sql
SET max_parallel_workers_per_gather = 0;
SELECT avg(attr_value::numeric) FROM product_attr WHERE attr_name = 'price';
SELECT count(*) FILTER (WHERE attr_value > '4500')    AS text_compare,
       count(*) FILTER (WHERE attr_value::int > 4500) AS numeric_compare
FROM product_attr WHERE attr_name = 'weight_g';
SELECT attr_name, count(*) AS n FROM product_attr GROUP BY 1 ORDER BY 2 DESC, 1;
```

```text
ERROR:  invalid input syntax for type numeric: "abc"
 text_compare | numeric_compare
--------------+-----------------
        10921 |            5193
(1 row)

    attr_name    |   n
-----------------+-------
 colour          | 50000
 material        | 50000
 price           | 50000
 warranty_months | 50000
 weight_g        | 50000
 colur           |     1
(6 rows)
```

The average-price report is now broken for everyone, because one bad cell aborts the whole
aggregate. The second query is worse because it does not fail: as text, `'900' > '4500'`, so
the "heavy products" filter returns 10,921 rows where the answer is 5,193. The third shows
`colur` sitting beside the real attributes. EAV gives up `NOT NULL`, `CHECK`, foreign keys,
types and per-attribute statistics, which is the whole of Chapter 15.

> **In production —** EAV is acceptable when your *users* define the attributes at runtime,
> there are thousands of them, and you have measured the ceiling: a marketplace where every
> seller invents product fields. Even then keep the universal attributes (price, weight) as
> columns and put only the open-ended tail in `jsonb` (Chapter 17). EAV that exists because
> nobody wrote down the column list is the other kind; Practice Session 24.1 is the way out.

---

## 24.2 The god table: three hundred columns and no meaning

A god table is one wide table modelling several entities, usually because the first version
was `customer` and each new customer type arrived with a feature request and a nullable
column. Build a lifelike one, sixteen real columns that grew to 301:

```bash
createdb ch24_god
psql -d ch24_god
```

```sql
\pset null '(null)'
CREATE TABLE party_god (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind text NOT NULL, name text NOT NULL, city text, last_login timestamptz,
    dob date, pan text, gender text, employer text,                            -- people
    gstin text, cin text, incorporated_on date, authorised_capital numeric,    -- companies
    registration_no text, trustee_count int, charity_exempt boolean);          -- trusts

SELECT format('ALTER TABLE party_god ADD COLUMN feature_%s text', lpad(n::text, 3, '0'))
FROM generate_series(1, 285) n \gexec

INSERT INTO party_god (kind, name, city, last_login, dob, pan, gender, employer)
SELECT 'person', 'Person ' || g, 'Pune', now(), date '1980-01-01' + g % 9000,
       'PAN' || g, 'F', 'Employer ' || g
FROM generate_series(1, 30000) g;
CREATE TABLE party_slim AS
  SELECT id, kind, name, city, last_login, dob, pan, gender, employer FROM party_god;
ANALYZE party_god;

SELECT count(*) AS columns FROM information_schema.columns WHERE table_name = 'party_god';
SELECT round(avg(null_frac)::numeric, 3) AS avg_null_frac,
       count(*) FILTER (WHERE null_frac = 1) AS columns_always_null
FROM pg_stats WHERE tablename = 'party_god';
SELECT (SELECT pg_column_size(g.*) FROM party_god g WHERE id = 1) AS god_row_bytes,
       (SELECT pg_column_size(s.*) FROM party_slim s WHERE id = 1) AS slim_row_bytes;
```

```text
 columns
---------
     301
(1 row)

 avg_null_frac | columns_always_null
---------------+---------------------
         0.970 |                 292
(1 row)

 god_row_bytes | slim_row_bytes
---------------+----------------
           126 |             86
(1 row)
```

The claim people get wrong is "all those NULLs waste space." A NULL has no data bytes, only
one bit in the row's null bitmap; what the 301-column row pays is the bitmap itself, about 40
bytes on every row. That is real on a narrow row, but it is not why god tables hurt.

**The table has no rules, because none can be stated.** A company has a GSTIN and no date
of birth; a person is the reverse. Nothing in `party_god` says so:

```sql
INSERT INTO party_god (kind, name, city, dob, gstin, registration_no)
VALUES ('company', 'Anita Rao Traders', 'Kochi', DATE '1985-03-02', '32AAACR5055K1Z5', 'TR-771'),
       ('person',  'Vikram Menon',      'Indore', NULL, '23AABCM1234F1Z9', NULL),
       ('shop',    'Kirana Store',      'Jaipur', NULL, NULL, NULL);
SELECT id, kind, name, dob, gstin, registration_no FROM party_god WHERE id > 30000 ORDER BY id;
```

```text
  id   |  kind   |       name        |    dob     |      gstin      | registration_no
-------+---------+-------------------+------------+-----------------+-----------------
 30001 | company | Anita Rao Traders | 1985-03-02 | 32AAACR5055K1Z5 | TR-771
 30002 | person  | Vikram Menon      | (null)     | 23AABCM1234F1Z9 | (null)
 30003 | shop    | Kirana Store      | (null)     | (null)          | (null)
(3 rows)
```

A company with a birthday, a person with a GST number, and a `kind` that does not exist.
A `CHECK ((kind = 'person' AND gstin IS NULL AND ...) OR (kind = 'company' AND ...))` claws
some back, but with three kinds and 285 growth columns it becomes the longest and
least-reviewed line in the schema, and every new kind rewrites it.

**Every consumer pays for every column.** `SELECT *` returns 301 columns to code that wanted
four, the planner works per column, and every `UPDATE` copies the whole wide row. PostgreSQL
caps a table at 1,600 columns; a god table's lifetime is the time it takes to find out.

**The fix is a supertype table plus a subtype table per kind**, so each subtype's columns
can be `NOT NULL` and the shape of the data is the DDL. A `(id, kind)` unique key on the
parent, a composite foreign key from each child, and a `kind` column pinned by `CHECK`
stop a company receiving person details:

```sql
CREATE TABLE party (
    id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind text NOT NULL CHECK (kind IN ('person', 'company')),
    name text NOT NULL, city text,
    UNIQUE (id, kind));
CREATE TABLE party_person (
    party_id bigint PRIMARY KEY,
    kind text NOT NULL DEFAULT 'person' CHECK (kind = 'person'),
    dob date NOT NULL, pan text NOT NULL,
    FOREIGN KEY (party_id, kind) REFERENCES party (id, kind));
CREATE TABLE party_company (
    party_id bigint PRIMARY KEY,
    kind text NOT NULL DEFAULT 'company' CHECK (kind = 'company'),
    gstin text NOT NULL, cin text NOT NULL,
    FOREIGN KEY (party_id, kind) REFERENCES party (id, kind));

INSERT INTO party (kind, name, city) VALUES ('company', 'Anita Rao Traders', 'Kochi');
INSERT INTO party_person (party_id, dob, pan) VALUES (1, DATE '1985-03-02', 'ABCPR1234K');
INSERT INTO party_company (party_id, gstin, cin) VALUES (1, '32AAACR5055K1Z5', NULL);
```

```text
ERROR:  insert or update on table "party_person" violates foreign key constraint "party_person_party_id_kind_fkey"
DETAIL:  Key (party_id, kind)=(1, person) is not present in table "party".
ERROR:  null value in column "cin" of relation "party_company" violates not-null constraint
DETAIL:  Failing row contains (1, company, 32AAACR5055K1Z5, null).
```

Both bad rows are refused by the database, with no application code involved. Chapter 19
covers when the subtype split is worth its joins.

> **In production —** A wide table is not automatically a god table. The test is whether you
> can say, per row, *which subset of columns is meaningful*. If the answer depends on another
> column's value, it is several tables sharing a name.

---

## 24.3 Polymorphic foreign keys: a reference the database cannot check

A comment can attach to an order or a product. The tempting design is a type name and an id,
so one table serves both parents:

```bash
createdb ch24_poly
psql -d ch24_poly
```

```sql
\pset null '(null)'
CREATE TABLE orders   (id int PRIMARY KEY, placed_on date NOT NULL);
CREATE TABLE products (id int PRIMARY KEY, name text NOT NULL);
INSERT INTO orders   SELECT g, DATE '2026-08-01' + g FROM generate_series(1, 100) g;
INSERT INTO products SELECT g, 'Product ' || g FROM generate_series(1, 100) g;

CREATE TABLE comment_poly (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    target_type text   NOT NULL,
    target_id   bigint NOT NULL,
    body        text   NOT NULL);
INSERT INTO comment_poly (target_type, target_id, body) VALUES
    ('order',   17,  'Delivered to gate 2'),
    ('product', 42,  'Colour differs from photo'),
    ('order',   999, 'Belongs to an order that does not exist'),
    ('produkt', 5,   'Belongs to a type that does not exist');
DELETE FROM orders WHERE id = 17;

SELECT c.id, c.target_type, c.target_id
FROM   comment_poly c
WHERE  NOT CASE c.target_type
             WHEN 'order'   THEN EXISTS (SELECT 1 FROM orders   o WHERE o.id = c.target_id)
             WHEN 'product' THEN EXISTS (SELECT 1 FROM products p WHERE p.id = c.target_id)
             ELSE false END
ORDER  BY c.id;
```

```text
 id | target_type | target_id
----+-------------+-----------
  1 | order       |        17
  3 | order       |       999
  4 | produkt     |         5
(3 rows)
```

Every insert succeeded, and so did deleting order 17 from under its comment. A foreign key
names one table and `target_id` points at two, so there is none. The orphan query above is
the whole integrity mechanism: it must be extended for every new parent type, and it tells
you only after the damage.

The database-native alternative is an **exclusive arc**: one nullable, real foreign-key
column per parent, and a `CHECK` that exactly one is set.

```sql
CREATE TABLE comment_arc (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id   int REFERENCES orders   ON DELETE CASCADE,
    product_id int REFERENCES products ON DELETE CASCADE,
    body       text NOT NULL,
    CONSTRAINT exactly_one_parent CHECK (num_nonnulls(order_id, product_id) = 1));
INSERT INTO comment_arc (order_id, body) VALUES (18, 'Delivered to gate 2');
INSERT INTO comment_arc (order_id, body) VALUES (999, 'Belongs to an order that does not exist');
INSERT INTO comment_arc (order_id, product_id, body) VALUES (18, 42, 'Two parents');
INSERT INTO comment_arc (body) VALUES ('No parent');
DELETE FROM orders WHERE id = 18;
SELECT count(*) AS comments_left FROM comment_arc;
```

```text
ERROR:  insert or update on table "comment_arc" violates foreign key constraint "comment_arc_order_id_fkey"
DETAIL:  Key (order_id)=(999) is not present in table "orders".
ERROR:  new row for relation "comment_arc" violates check constraint "exactly_one_parent"
DETAIL:  Failing row contains (3, 18, 42, Two parents).
ERROR:  new row for relation "comment_arc" violates check constraint "exactly_one_parent"
DETAIL:  Failing row contains (4, null, null, No parent).
 comments_left
---------------
             0
(1 row)
```

The missing parent, the two-parent row and the no-parent row are refused, and deleting the
order took its comment with it (`ON DELETE RESTRICT` would refuse instead; either way it is
now a decision). The arc suits two to four parents; beyond that, give each parent its own
comment table and a `UNION ALL` view. Index each foreign-key column; PostgreSQL does not
(Chapter 15). `num_nonnulls()` is the safe check because `CHECK` passes on NULL and this
function never returns it.

---

## 24.4 Two you cannot demonstrate in a scratch database

**JSONB as schema avoidance.** Chapter 17.6 made the case with measurements: a JSONB path
predicate estimated at 5 rows against 3,340 actual, and a mistyped key returning zero rows
instead of an error. The review rule is: if you can list the keys, they are columns. A
blob holding `status`, `customer_id` and `amount` is EAV with better marketing.

**Premature sharding.** This is opinion, labelled as such, because no scratch-database query
can measure a decision that costs two years. Sharding gives up cross-shard joins,
transactions and uniform constraints, and is nearly impossible to reverse. It solves a write
rate or working set beyond one machine, which most systems that reach for it do not have.
The one thing to check is your distance from the ceiling, using the largest tables in this
book:

```bash
psql -d retail_lg
```

```sql
SELECT (SELECT count(*) FROM orders) AS orders, (SELECT count(*) FROM order_items) AS items,
       pg_size_pretty(pg_total_relation_size('orders')) AS orders_total,
       pg_size_pretty(pg_total_relation_size('order_items')) AS items_total,
       pg_size_pretty(pg_database_size(current_database())) AS database;
```

```text
 orders  |  items  | orders_total | items_total | database
---------+---------+--------------+-------------+----------
 2000000 | 5004129 | 349 MB       | 356 MB      | 749 MB
(1 row)
```

Every index included, that is under 750 MB, less than the RAM of a phone. The order of
escalation is a larger machine, read replicas, partitioning one table (Chapter 38), and
only then, if a measured ceiling demands it, sharding (Chapter 53). Each is easier from a
clean single-node schema.

---

## 24.5 Safe refactoring: expand, migrate, contract

Once you know what is wrong, the change has to happen under load. The pattern has three
phases and one rule: **every intermediate state must work with both the old and the new
application.** *Expand*: add the new structure beside the old. *Migrate*: dual-write both
shapes, backfill history in small batches, prove the two agree, then switch readers and
writers. *Contract*: when nothing reads the old structure, drop it. One dangerous,
irreversible step becomes many cheap ones. Chapter 52, *Schema Migrations on Live Systems*,
tabulates the lock level of every `ALTER TABLE` form; here the pattern is applied to one
design problem and each step is proved.

The problem: `customer.full_name` must become `first_name` and `last_name`. Not every Indian
name fits (a single name like Meera has no last name), so the rule is written down once, as
functions, before anything else:

```bash
psql -d retail_lg -Atq -c "\copy (SELECT id, name, email, city FROM customers ORDER BY id) TO '/tmp/customers.csv' CSV"
createdb ch24_split
psql -d ch24_split
```

```sql
\pset null '(null)'
CREATE TABLE customer (id int PRIMARY KEY, full_name text NOT NULL, email text NOT NULL, city text);
\copy customer FROM '/tmp/customers.csv' CSV
CREATE INDEX customer_email ON customer (email);
ANALYZE customer;

CREATE FUNCTION split_first(n text) RETURNS text LANGUAGE sql IMMUTABLE AS
$$ SELECT coalesce(substring(n FROM '^(.*)\s\S+$'), n) $$;
CREATE FUNCTION split_last(n text) RETURNS text LANGUAGE sql IMMUTABLE AS
$$ SELECT substring(n FROM '\s(\S+)$') $$;

SELECT n, split_first(n) AS first_name, split_last(n) AS last_name
FROM (VALUES ('Anita Sheikh'), ('Rajesh Kumar Sharma'), ('Meera')) v(n);
```

```text
          n          |  first_name  | last_name
---------------------+--------------+-----------
 Anita Sheikh        | Anita        | Sheikh
 Rajesh Kumar Sharma | Rajesh Kumar | Sharma
 Meera               | Meera        | (null)
(3 rows)
```

The last word is the last name, everything before it the first, and a single word is a
first name with a NULL last name. The trigger, the backfill and the reconcile query must
all call these same functions, or they disagree by construction and the reconcile reports
drift that is really three implementations.

## 24.6 Splitting a column with no downtime

**Step 1, expand.** Add the columns, nullable, with no default:

```sql
SELECT pg_relation_filenode('customer') AS filenode_before \gset

BEGIN;
SET LOCAL lock_timeout = '2s';
ALTER TABLE customer ADD COLUMN first_name text, ADD COLUMN last_name text;
SELECT mode, granted FROM pg_locks
WHERE  relation = 'customer'::regclass AND pid = pg_backend_pid() ORDER BY mode;
COMMIT;

SELECT pg_relation_filenode('customer') = :filenode_before AS same_file,
       pg_size_pretty(pg_relation_size('customer')) AS heap;
```

```text
        mode         | granted
---------------------+---------
 AccessExclusiveLock | t
(1 row)

 same_file | heap
-----------+-------
 t         | 25 MB
(1 row)
```

`ACCESS EXCLUSIVE` is the strongest lock there is, and the statement is still safe: held for
microseconds, no rewrite (`same_file`, same heap). The danger is the *queue* behind it. The
request waits for every open transaction that has touched the table, and while it waits,
every new query queues behind *it*. Stage that with three sessions and read `pg_locks` (the
`sleep` calls only order the sessions; the evidence is the lock table):

```bash
psql -q -d ch24_split -c "BEGIN; SELECT count(*) AS reader_a FROM customer; SELECT pg_sleep(8); COMMIT;" >/dev/null &
sleep 1
psql -q -d ch24_split -c "SET lock_timeout = '5s'; ALTER TABLE customer ADD COLUMN scratch_col int;" 2>&1 | sed 's/^psql:.*ERROR/ERROR/' &
sleep 1
psql -q -d ch24_split -c "SELECT count(*) AS reader_c FROM customer" >/dev/null &
sleep 1
psql -q -d ch24_split -c "SELECT left(a.query, 38) AS query, l.mode, l.granted
FROM pg_locks l JOIN pg_stat_activity a USING (pid)
WHERE l.relation = 'customer'::regclass AND a.pid <> pg_backend_pid()
ORDER BY l.granted DESC, a.query_start"
wait
```

```text
                 query                  |        mode         | granted
----------------------------------------+---------------------+---------
 BEGIN; SELECT count(*) AS reader_a FRO | AccessShareLock     | t
 SET lock_timeout = '5s'; ALTER TABLE c | AccessExclusiveLock | f
 SELECT count(*) AS reader_c FROM custo | AccessShareLock     | f
(3 rows)

ERROR:  canceling statement due to lock timeout
```

Reader A is idle in a transaction, the `ALTER` cannot be granted, and reader C, a plain
`SELECT` that conflicts with nothing A is doing, waits behind the `ALTER`. One forgotten open
transaction plus one `ALTER` is an outage. `lock_timeout` is the defence: the `ALTER` gave up
after five seconds, the queue drained, and you retry later. Put it on every migration
statement.

**Step 2, dual write.** Before touching an existing row, make every new write fill both
shapes. Old application code keeps writing `full_name`; a trigger derives the new columns.
`CREATE TRIGGER` takes a lock that stops writes but not reads, so it too gets a timeout:

```sql
CREATE FUNCTION customer_split_name() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.first_name := split_first(NEW.full_name);
  NEW.last_name  := split_last(NEW.full_name);
  RETURN NEW;
END $$;

BEGIN;
SET LOCAL lock_timeout = '2s';
CREATE TRIGGER customer_split_name BEFORE INSERT OR UPDATE OF full_name ON customer
  FOR EACH ROW EXECUTE FUNCTION customer_split_name();
SELECT mode, granted FROM pg_locks
WHERE  relation = 'customer'::regclass AND pid = pg_backend_pid() AND mode <> 'AccessShareLock';
COMMIT;
```

```text
         mode          | granted
-----------------------+---------
 ShareRowExclusiveLock | t
(1 row)
```

`SHARE ROW EXCLUSIVE` conflicts with writes and allows reads. `UPDATE OF full_name` means the
trigger fires only when a statement assigns to `full_name`, so the backfill, which never
does, does not pay for it. Triggers are Chapter 43.

**What goes wrong if you skip step 2.** On a scratch copy of the first 60,000 customers,
backfill in batches with no trigger while the application keeps writing. The traffic is
simulated by two statements between the batches, which is what a real writer would do.
The procedure is the batch mechanism: each loop iteration commits, so no transaction stays
open longer than one batch (`COMMIT` in a procedure needs PostgreSQL 11 and a `CALL` outside
any transaction block):

```sql
CREATE PROCEDURE backfill_names(tbl regclass, lo bigint, hi bigint, batch int DEFAULT 50000)
LANGUAGE plpgsql AS $$
DECLARE cur bigint := lo; n bigint;
BEGIN
  WHILE cur < hi LOOP
    EXECUTE format(
      'UPDATE %s SET first_name = split_first(full_name), last_name = split_last(full_name)
       WHERE id > %s AND id <= %s AND first_name IS NULL', tbl, cur, least(cur + batch, hi));
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE 'ids % to %: % rows', cur + 1, least(cur + batch, hi), n;
    COMMIT;                       -- each batch is its own transaction
    cur := cur + batch;
  END LOOP;
END $$;

CREATE TABLE customer_naive AS
  SELECT id, full_name, email, city, NULL::text AS first_name, NULL::text AS last_name
  FROM customer WHERE id <= 60000;
ALTER TABLE customer_naive ADD PRIMARY KEY (id);

CALL backfill_names('customer_naive', 0, 30000, 10000);
INSERT INTO customer_naive (id, full_name, email, city)
  SELECT 60000 + g, 'Farhan Iyer ' || g, 'new' || g || '@example.in', 'Pune'
  FROM generate_series(1, 1000) g;
UPDATE customer_naive SET full_name = 'Sunita Patil' WHERE id BETWEEN 100 AND 599;
CALL backfill_names('customer_naive', 30000, 60000, 10000);

SELECT count(*) FILTER (WHERE first_name IS NULL) AS never_backfilled,
       count(*) FILTER (WHERE first_name IS NOT NULL
             AND (first_name IS DISTINCT FROM split_first(full_name)
               OR last_name  IS DISTINCT FROM split_last(full_name))) AS stale
FROM customer_naive;
```

```text
NOTICE:  ids 1 to 10000: 10000 rows
NOTICE:  ids 10001 to 20000: 10000 rows
NOTICE:  ids 20001 to 30000: 10000 rows
NOTICE:  ids 30001 to 40000: 10000 rows
NOTICE:  ids 40001 to 50000: 10000 rows
NOTICE:  ids 50001 to 60000: 10000 rows
 never_backfilled | stale
------------------+-------
             1000 |   500
(1 row)
```

The reconcile found 1,000 rows the backfill never saw and 500 it had passed and the
application then changed, with no error anywhere. Re-running the backfill until it finds
nothing does not fix this; there is always a row written a millisecond after the last pass.
Only the trigger closes the gap, which is why it comes first. A batch is also a blast radius:
one open batch blocks writers to its rows only, one whole-table statement blocks everyone
(Practice Session 24.2 shows both).

**Step 3, backfill, for real.** The trigger is now in place on `customer`. Backfill 300,000
rows in 50,000-row batches, with the same simulated traffic in the middle:

```sql
SELECT pg_size_pretty(pg_relation_size('customer')) AS heap_before;
CALL backfill_names('customer', 0, 150000);
INSERT INTO customer (id, full_name, email, city)
  SELECT 300000 + g, 'Farhan Iyer ' || g, 'new' || g || '@example.in', 'Pune'
  FROM generate_series(1, 1000) g;
UPDATE customer SET full_name = 'Sunita Patil' WHERE id BETWEEN 100 AND 599;
CALL backfill_names('customer', 150000, 300000);
SELECT pg_size_pretty(pg_relation_size('customer')) AS heap_after_backfill;
VACUUM customer;
SELECT pg_size_pretty(pg_relation_size('customer')) AS heap_after_vacuum;
```

```text
 heap_before
-------------
 25 MB
(1 row)

NOTICE:  ids 1 to 50000: 50000 rows
NOTICE:  ids 50001 to 100000: 50000 rows
NOTICE:  ids 100001 to 150000: 50000 rows
NOTICE:  ids 150001 to 200000: 50000 rows
NOTICE:  ids 200001 to 250000: 50000 rows
NOTICE:  ids 250001 to 300000: 50000 rows
 heap_after_backfill
---------------------
 54 MB
(1 row)

 heap_after_vacuum
-------------------
 54 MB
(1 row)
```

The heap roughly doubled: every backfilled row is a new tuple and the old one is dead until
`VACUUM`, which makes the space reusable but does not shrink the file (Chapter 37). Budget
disk for a full extra copy before you start.

**Step 4, reconcile.** Never switch readers on the strength of "the backfill finished". Prove
agreement over every row, with the same functions the writers used:

```sql
SELECT count(*) AS total,
       count(*) FILTER (WHERE first_name IS NULL) AS missing,
       count(*) FILTER (WHERE first_name IS NOT NULL
             AND (first_name IS DISTINCT FROM split_first(full_name)
               OR last_name  IS DISTINCT FROM split_last(full_name))) AS stale
FROM customer;
```

```text
 total  | missing | stale
--------+---------+-------
 301000 |       0 |     0
(1 row)
```

Zero and zero, against the same traffic that left 1,000 and 500 last time. In production,
run this on a schedule until the old column is gone.

**Step 5, switch, then constrain.** Deploy in two releases: read the new columns while still
writing `full_name`, then write them directly (which needs the trigger reversed or retired;
Chapter 52 works through it). Then `first_name` can earn `NOT NULL`, but `SET NOT NULL` scans
the whole table under `ACCESS EXCLUSIVE`. The safe form adds a `CHECK` as `NOT VALID` (brief
exclusive lock, no scan), validates it under a lock that allows reads and writes, and lets
`SET NOT NULL` use the proof:

```sql
BEGIN;
SET LOCAL lock_timeout = '2s';
ALTER TABLE customer ADD CONSTRAINT first_name_present CHECK (first_name IS NOT NULL) NOT VALID;
SELECT mode FROM pg_locks WHERE relation = 'customer'::regclass AND pid = pg_backend_pid() AND mode <> 'AccessShareLock';
COMMIT;

BEGIN;
ALTER TABLE customer VALIDATE CONSTRAINT first_name_present;
SELECT mode FROM pg_locks WHERE relation = 'customer'::regclass AND pid = pg_backend_pid() AND mode <> 'AccessShareLock';
COMMIT;

SET client_min_messages = debug1;
ALTER TABLE customer ALTER COLUMN first_name SET NOT NULL;
RESET client_min_messages;
ALTER TABLE customer DROP CONSTRAINT first_name_present;
```

```text
        mode
---------------------
 AccessExclusiveLock
(1 row)

           mode
--------------------------
 ShareUpdateExclusiveLock
(1 row)

DEBUG:  existing constraints on column "customer.first_name" are sufficient to prove that it does not contain nulls
```

The `DEBUG` line is PostgreSQL skipping the scan because the validated constraint already
proves the point (PostgreSQL 12 and later). `last_name` stays nullable, because Meera exists.

**Step 6, contract.** When no running code touches `full_name`, and the reconcile has been
clean for as long as your rollback window, remove the trigger and the column:

```sql
SELECT pg_relation_filenode('customer') AS filenode_before \gset
BEGIN;
SET LOCAL lock_timeout = '2s';
DROP TRIGGER customer_split_name ON customer;
ALTER TABLE customer DROP COLUMN full_name;
SELECT mode FROM pg_locks WHERE relation = 'customer'::regclass AND pid = pg_backend_pid() AND mode <> 'AccessShareLock';
COMMIT;
DROP FUNCTION customer_split_name();

SELECT pg_relation_filenode('customer') = :filenode_before AS same_file,
       pg_size_pretty(pg_relation_size('customer')) AS heap;
```

```text
        mode
---------------------
 AccessExclusiveLock
(1 row)

 same_file | heap
-----------+-------
 t         | 54 MB
(1 row)
```

`DROP COLUMN` is a catalog change: the file is untouched and the space is **not** returned
until the table is rewritten (`VACUUM FULL` or `pg_repack`, Chapter 37). Contract is the
safest step and the one people forget; a table carrying three generations of dropped columns
is the residue of refactorings that stopped after step 5.

## Summary

- **EAV** gave up types and constraints: the same question cost 8,012 buffers against 467, a
  price of `'abc'` and an attribute `colur` were accepted, and a text comparison returned
  10,921 rows where the answer was 5,193. Acceptable only for user-defined attributes with a
  measured ceiling, universal ones kept as columns.
- A **god table** does not waste space (the bitmap made the row 40 bytes wider); it has no
  rules, and accepted a company with a birthday and a `kind` of `'shop'`. Subtype tables with
  a composite key refused both.
- A **polymorphic foreign key** accepted an orphan and a misspelt type; an exclusive arc
  (a real foreign key per parent plus `num_nonnulls(...) = 1`) refused them.
- **JSONB as avoidance** and **premature sharding** are decisions: if you can list the keys
  they are columns, and the large orders and lines tables fit in under 750 MB.
- Refactor with **expand, migrate, contract**, every intermediate state valid for old and new
  code, `lock_timeout` on every step. **Dual write before backfill**: skipping it left 1,000
  rows unbackfilled and 500 stale with no error. Backfill in committed batches, reconcile
  before switching, add `NOT NULL` through `NOT VALID` then `VALIDATE`, and remember
  `DROP COLUMN` reclaims nothing.

**Exercises:** Practice Sessions 24.1–24.2 accompany this chapter and are in the workbook at
the back of the book.

**Next:** Part V closes here. Part VI opens with Chapter 25, *Window Functions*, the first of
the query-language chapters that assume the schema underneath them is sound.
