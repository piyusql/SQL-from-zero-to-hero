# Chapter 18 — Normalization and Deliberate Denormalization

Part IV ended on a rule of thumb: if you can write down the list of keys, they are columns.
This chapter is about the next question, which is *which table does each column live in*.
Get it wrong and every later chapter gets harder: the index you cannot justify, the report
that disagrees with the other report, the `UPDATE` that has to touch twenty-six rows to
change one fact.

Normalization has a reputation for being a diagram-drawing ritual with names like Boyce–Codd
that nobody remembers. Strip the ritual away and it is one idea: **a fact should be stored
in exactly one place.** Every normal form is a more precise way of saying which facts you
are storing twice. The reason to learn the precise version is that you will inherit tables
where nobody wrote the rule down, and you need a way to *find* it.

This chapter works one schema from spreadsheet to third normal form, then Boyce–Codd, and
then makes the honest counter-case on the largest dataset in the book: there are read
paths where storing a fact twice is the right call, and the price is specific and
measurable. Everything below is DDL and writes, so it runs in scratch databases:

```bash
createdb ch18_scratch
psql -d ch18_scratch
```

---

## 18.1 The flat import

A distributor in Pune sends a weekly export, one row per order line, everything in one
sheet. To make it reproducible, build it from the `retail` data. The warehouse columns are
invented for this chapter: each order ships from one of four warehouses, chosen by order
number.

```bash
psql -d retail -Atq -c "\copy (
SELECT 'ORD-'||lpad(o.id::text,5,'0'), o.placed_at::date, c.name, c.email, c.city, o.status,
       (ARRAY['WH-PUN','WH-BLR','WH-DEL','WH-HYD'])[o.id%4+1],
       (ARRAY['Pune','Bengaluru','Delhi','Hyderabad'])[o.id%4+1],
       p.sku, p.name, p.category, oi.unit_price, oi.quantity
FROM orders o JOIN customers c ON c.id = o.customer_id
JOIN order_items oi ON oi.order_id = o.id JOIN products p ON p.id = oi.product_id
ORDER BY oi.id) TO '/tmp/flat.csv' CSV"
```

```sql
\pset null '(null)'
CREATE TABLE flat_import (
    order_no text, order_date date, customer_name text, customer_email text,
    customer_city text, status text, warehouse text, warehouse_city text,
    sku text, product_name text, category text, unit_price numeric(10,2), quantity int);
\copy flat_import FROM '/tmp/flat.csv' CSV

SELECT count(*) AS lines, count(DISTINCT order_no) AS orders,
       count(DISTINCT customer_email) AS customers, count(DISTINCT sku) AS skus
FROM   flat_import;
```

```text
 lines | orders | customers | skus 
-------+--------+-----------+------
  6250 |   2500 |       803 |  200
(1 row)
```

6,250 rows carrying 2,500 orders, 803 customers and 200 products. Each customer's email
and city, on average, appears about eight times. That is the smell. What we need is a way
to say precisely what is repeated.

## 18.2 Functional dependencies are the whole subject

A **functional dependency** `A → B` says: whenever two rows agree on `A`, they agree on
`B`. Knowing the customer's email tells you the customer's name; knowing the SKU tells you
the product name. Every normal form is a statement about which dependencies a table is
allowed to contain, so the working skill is *finding* them.

You do not find them by staring at column names. You find them by asking the data, with a
query that returns the groups that *break* a candidate dependency:

```sql
SELECT 'email -> name' AS candidate, count(*) AS violations
FROM (SELECT customer_email FROM flat_import GROUP BY 1
      HAVING count(DISTINCT customer_name) > 1) s
UNION ALL SELECT 'email -> city', count(*)
FROM (SELECT customer_email FROM flat_import GROUP BY 1
      HAVING count(DISTINCT customer_city) > 1) s
UNION ALL SELECT 'sku -> product_name', count(*)
FROM (SELECT sku FROM flat_import GROUP BY 1
      HAVING count(DISTINCT product_name) > 1) s
UNION ALL SELECT 'sku -> unit_price', count(*)
FROM (SELECT sku FROM flat_import GROUP BY 1
      HAVING count(DISTINCT unit_price) > 1) s
UNION ALL SELECT 'order_no -> customer_email', count(*)
FROM (SELECT order_no FROM flat_import GROUP BY 1
      HAVING count(DISTINCT customer_email) > 1) s
UNION ALL SELECT 'warehouse -> warehouse_city', count(*)
FROM (SELECT warehouse FROM flat_import GROUP BY 1
      HAVING count(DISTINCT warehouse_city) > 1) s
UNION ALL SELECT 'customer_name -> email', count(*)
FROM (SELECT customer_name FROM flat_import GROUP BY 1
      HAVING count(DISTINCT customer_email) > 1) s;
```

```text
          candidate          | violations 
-----------------------------+------------
 email -> name               |          0
 email -> city               |          0
 sku -> product_name         |          0
 sku -> unit_price           |        200
 order_no -> customer_email  |          0
 warehouse -> warehouse_city |          0
 customer_name -> email      |        238
(7 rows)
```

Zero violations means the dependency holds *in this data*. That is evidence, not proof —
only the business can say whether it holds forever — but it is very good evidence, and it
is the only kind you can get from a spreadsheet nobody documented. Two rows are worth
stopping on.

**`sku -> unit_price` fails for all 200 SKUs.** That is not redundancy. The price on an
order line is the price *at the time of sale*; it belongs to the line, not the product.
Normalizing it into a `products.price` column would rewrite history the first time a price
changed. A repeated value is only redundancy if it is the *same fact*.

**`customer_name -> email` fails 238 times.** Two customers called Anita Sheikh are two
people. Names are not identifiers — never let one become a key, and never join on one.

> **Trap —** `count(DISTINCT x)` ignores NULLs. If a customer appeared once with a city and
> once with a NULL city, `email -> city` would report zero violations while the data
> disagrees with itself. Here 99 of the customers have a NULL city, and the probe cannot
> see a conflict against those. When it matters, compare with `IS DISTINCT FROM` or add
> `count(*) FILTER (WHERE customer_city IS NULL)` to the probe.

## 18.3 1NF to 3NF, in the order the data forces you

**First normal form** says every column holds one atomic value and rows are distinct. The
import survives that only because it is one row per *line*. Half of all real imports arrive
the other way — one row per order with the items packed into a string:

```sql
CREATE TEMP TABLE packed (order_no text, items text);
INSERT INTO packed VALUES ('ORD-90001','SKU-00034:2;SKU-00165:3'), ('ORD-90002','SKU-00080:5');

SELECT order_no, split_part(item,':',1) AS sku, split_part(item,':',2)::int AS quantity
FROM   packed, LATERAL string_to_table(items, ';') AS item
ORDER  BY 1,2;
```

```text
 order_no  |    sku    | quantity 
-----------+-----------+----------
 ORD-90001 | SKU-00034 |        2
 ORD-90001 | SKU-00165 |        3
 ORD-90002 | SKU-00080 |        5
(3 rows)
```

`string_to_table` is PostgreSQL 14+. Unpacking is mechanical; the reason to do it is that
nothing can index, constrain, join or count what is inside a delimited string. Chapter 17
made the same argument for JSONB.

**Second normal form** is about keys, so we need one. The obvious candidate is
`(order_no, sku)`, and the data refuses it:

```sql
SELECT count(*) - count(DISTINCT (order_no, sku)) AS duplicate_keys FROM flat_import;
```

```text
 duplicate_keys 
----------------
             25
(1 row)
```

Twenty-five orders contain the same product on two lines. The natural key does not exist;
the lines need a number of their own. The export has a stable row order, so number them:

```sql
ALTER TABLE flat_import ADD COLUMN line_no int;
UPDATE flat_import f SET line_no = n.rn
FROM  (SELECT ctid AS c, row_number() OVER (PARTITION BY order_no ORDER BY ctid) AS rn
       FROM flat_import) n
WHERE  f.ctid = n.c;

SELECT count(*) - count(DISTINCT (order_no, line_no)) AS duplicate_keys FROM flat_import;
```

```text
 duplicate_keys 
----------------
              0
(1 row)
```

(Ordering by `ctid` is tolerable exactly once, on a table nobody is writing to. A key you
mint from physical position is not a key you can regenerate — in production, get the line
number from the source system.)

With key `(order_no, line_no)`, **2NF** says no column may depend on only *part* of the key.
`order_date`, `status`, the customer columns and the warehouse all depend on `order_no`
alone — half the key. They repeat once per line, and they belong on an order.

**Third normal form** says no column may depend on the key *through another non-key column*.
`customer_name` depends on `order_no` only via `customer_email`; `warehouse_city` only via
`warehouse`; `product_name` and `category` only via `sku`. Each is a transitive dependency,
and each gets a table whose key is the middle column.

```sql
CREATE TABLE customers  (customer_id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                         email text NOT NULL UNIQUE, name text NOT NULL, city text);
CREATE TABLE warehouses (warehouse_code text PRIMARY KEY, city text NOT NULL);
CREATE TABLE products   (sku text PRIMARY KEY, name text NOT NULL, category text NOT NULL);
CREATE TABLE orders     (order_no text PRIMARY KEY, order_date date NOT NULL, status text NOT NULL,
                         customer_id   int  NOT NULL REFERENCES customers,
                         warehouse_code text NOT NULL REFERENCES warehouses);
CREATE TABLE order_lines (order_no text NOT NULL REFERENCES orders, line_no int NOT NULL,
                          sku text NOT NULL REFERENCES products,
                          quantity int NOT NULL CHECK (quantity > 0),
                          unit_price numeric(10,2) NOT NULL,
                          PRIMARY KEY (order_no, line_no));
```

Notice `customer_id` is a surrogate and `email` stays `UNIQUE`. The email is the business
identifier, but people change it; foreign keys should not have to follow. Chapter 20 takes
key strategy seriously. Load it:

```sql
INSERT INTO customers (email, name, city)
  SELECT DISTINCT customer_email, customer_name, customer_city FROM flat_import ORDER BY 1;
INSERT INTO warehouses SELECT DISTINCT warehouse, warehouse_city FROM flat_import;
INSERT INTO products   SELECT DISTINCT sku, product_name, category FROM flat_import;
INSERT INTO orders
  SELECT DISTINCT f.order_no, f.order_date, f.status, c.customer_id, f.warehouse
  FROM flat_import f JOIN customers c ON c.email = f.customer_email;
INSERT INTO order_lines SELECT order_no, line_no, sku, quantity, unit_price FROM flat_import;
```

A decomposition is only correct if it is **lossless**: joining the pieces must give back
exactly the original rows, no more and no fewer. Do not eyeball it; subtract in both
directions. `EXCEPT` treats NULLs as equal, which is what we want here.

```sql
WITH rebuilt AS (
  SELECT o.order_no, o.order_date, c.name AS customer_name, c.email AS customer_email,
         c.city AS customer_city, o.status, w.warehouse_code AS warehouse,
         w.city AS warehouse_city, p.sku, p.name AS product_name, p.category,
         l.unit_price, l.quantity, l.line_no
  FROM   order_lines l JOIN orders o USING (order_no) JOIN customers c USING (customer_id)
         JOIN warehouses w USING (warehouse_code) JOIN products p USING (sku))
SELECT (SELECT count(*) FROM (SELECT * FROM flat_import EXCEPT SELECT * FROM rebuilt) a) AS missing,
       (SELECT count(*) FROM (SELECT * FROM rebuilt EXCEPT SELECT * FROM flat_import) b) AS invented;
```

```text
 missing | invented 
---------+----------
       0 |        0
(1 row)
```

Same information, one home per fact:

```sql
SELECT pg_size_pretty(pg_table_size('flat_import')) AS flat,
       pg_size_pretty(pg_table_size('customers') + pg_table_size('warehouses')
                    + pg_table_size('products')  + pg_table_size('orders')
                    + pg_table_size('order_lines')) AS normalized_tables;
```

```text
  flat   | normalized_tables 
---------+-------------------
 2080 kB | 824 kB
(1 row)
```

Table storage only; the normalized side also carries primary-key and unique indexes, the
flat side carries none. Size is the least important benefit. The important one is next.

## 18.4 What you bought: three anomalies, one of them measurable

A table that stores a fact twice invites three failures.

**The update anomaly.** One customer's most-repeated email appears on 26 rows:

```sql
SELECT customer_email, count(*) AS rows_to_touch
FROM flat_import GROUP BY 1 ORDER BY 2 DESC, 1 LIMIT 3;
```

```text
       customer_email       | rows_to_touch 
----------------------------+---------------
 customer426@vyapar.example |            26
 customer530@vyapar.example |            26
 customer102@vyapar.example |            23
(3 rows)
```

The customer moves to Kochi. Someone writes the `UPDATE` with a filter that is almost right —
inside a transaction, so we can look and then walk away:

```sql
BEGIN;
UPDATE flat_import SET customer_city = 'Kochi'
WHERE  customer_email = 'customer426@vyapar.example' AND order_no < 'ORD-01500';

SELECT customer_city, count(*) FROM flat_import
WHERE  customer_email = 'customer426@vyapar.example' GROUP BY 1 ORDER BY 1;
ROLLBACK;
```

```text
BEGIN
UPDATE 19
 customer_city | count 
---------------+-------
 Kochi         |    19
 Nagpur        |     7
(2 rows)
```

Nothing in the database objects. Nineteen rows say Kochi, seven say Nagpur, and every
report that groups by city now splits one customer in two. Rerun the dependency probe from
18.2 and `email -> city` reports the damage — but only if somebody thinks to run it. In the
normalized schema the same change is `UPDATE customers SET city = 'Kochi' WHERE email = …`,
`UPDATE 1`, and there is no second copy to disagree with.

**The insert anomaly.** You cannot record a new product, or a new warehouse, until an order
mentions it, because the only table that can hold them is the order line. **The delete
anomaly** is the mirror: cancel the only order that ever included a SKU and the SKU's name
vanishes with it. These need no measurement; they are structural.

The pattern behind all three is the same and worth memorising: **normalization does not make
queries faster. It makes it impossible for the data to disagree with itself**, using the
constraints you learned in Chapter 15. The cost is joins.

## 18.5 Boyce–Codd: when the dependency's left side is not a key

3NF has a gap that BCNF closes. **BCNF** says: for every dependency `A → B`, `A` must be a
key (or a superkey) of its table. Almost every 3NF schema satisfies it. The exceptions look
like this — a coaching institute where a student takes each subject with one teacher, and
each teacher teaches only one subject:

```sql
CREATE TABLE batch_enrol (
    student text, subject text, teacher text,
    PRIMARY KEY (student, subject));
INSERT INTO batch_enrol VALUES
 ('Aarav Nair','Physics','Dr. Menon'),   ('Aarav Nair','Maths','Dr. Iyer'),
 ('Ishita Rao','Physics','Dr. Menon'),   ('Kabir Sheikh','Physics','Dr. Menon'),
 ('Kabir Sheikh','Chemistry','Dr. Banerjee');

SELECT teacher, count(DISTINCT subject) AS subjects FROM batch_enrol GROUP BY 1 ORDER BY 1;
```

```text
   teacher    | subjects 
--------------+----------
 Dr. Banerjee |        1
 Dr. Iyer     |        1
 Dr. Menon    |        1
(3 rows)
```

Every teacher teaches one subject: `teacher → subject`. But `teacher` is not a key here, so
this violates BCNF, though every column is part of *some* candidate key and so 3NF is
satisfied. The symptom is the same as before — Dr. Menon's subject is stored on three rows,
and if Dr. Menon switched to Chemistry you would have to find them all. Decompose on the offending
dependency:

```sql
CREATE TABLE teacher_subject (teacher text PRIMARY KEY, subject text NOT NULL);
INSERT INTO teacher_subject SELECT DISTINCT teacher, subject FROM batch_enrol;
CREATE TABLE student_teacher (student text, teacher text REFERENCES teacher_subject,
                              PRIMARY KEY (student, teacher));
INSERT INTO student_teacher SELECT DISTINCT student, teacher FROM batch_enrol;
```

Now the part textbooks under-sell. BCNF decomposition can **lose a dependency**. The
original table also enforced `(student, subject) → teacher`: one teacher per student per
subject. Watch what the split lets through once a second Physics teacher exists:

```sql
INSERT INTO teacher_subject VALUES ('Dr. Rao','Physics');
INSERT INTO student_teacher VALUES ('Aarav Nair','Dr. Rao');

SELECT st.student, ts.subject, count(*) AS teachers
FROM   student_teacher st JOIN teacher_subject ts USING (teacher)
GROUP  BY 1,2 HAVING count(*) > 1;
```

```text
  student   | subject | teachers 
------------+---------+----------
 Aarav Nair | Physics |        2
(1 row)
```

Aarav now has two Physics teachers, and the database accepted it. The original table
refused the same fact:

```sql
INSERT INTO batch_enrol VALUES ('Aarav Nair','Physics','Dr. Rao');
```

```text
ERROR:  duplicate key value violates unique constraint "batch_enrol_pkey"
DETAIL:  Key (student, subject)=(Aarav Nair, Physics) already exists.
```

No declarative constraint can express "one teacher per student per subject" across the two
new tables; it would take a trigger. This is the honest position: **3NF is the practical
target, and you go to BCNF when the redundancy is hurting more than the lost constraint.**
Both answers are defensible. What is not defensible is not knowing which one you picked.

## 18.6 Deliberate denormalization, priced

Everything so far argued for one copy of each fact. Now the counter-case, on `retail_lg` —
the 2,000,000-order dataset from Practice Session 8.2 (see the workbook if you have not
built it). Work on a copy, since we will alter `orders`:

```bash
createdb -T retail_lg ch18_lg
psql -d ch18_lg
```

`retail_lg` arrives with no indexes beyond the primary keys, and its `orders` heap carries
dead space from the load. Repack the table so the size numbers mean something, then add
the indexes any sensible application would already have. **Both the normalized and the
denormalized variants below use them**; the comparison is only fair if neither is starved.

```sql
VACUUM FULL orders;
CREATE INDEX orders_customer_placed ON orders (customer_id, placed_at DESC);
CREATE INDEX orders_placed          ON orders (placed_at);
CREATE INDEX order_items_order      ON order_items (order_id);
VACUUM (ANALYZE) orders;
ANALYZE order_items;

SELECT pg_size_pretty(pg_relation_size('orders')) AS orders_heap,
       pg_size_pretty(pg_indexes_size('orders'))  AS orders_indexes;
```

```text
 orders_heap | orders_indexes 
-------------+----------------
 136 MB      | 146 MB
(1 row)
```

Two read paths that both want *how many items are in each order*, which is a fact derivable
from `order_items` and therefore a candidate for redundancy.

**Path 1: a customer's order history page** — the twenty most recent orders with item
counts. The measurement is `BUFFERS`, not the clock: buffer counts are the same on every run,
where timings on a shared machine are not. Run each `EXPLAIN` in this section twice and
read the second, so the first pays for the cold cache:

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT o.id, o.placed_at, o.status, o.total_amount, count(oi.id) AS items
FROM   orders o LEFT JOIN order_items oi ON oi.order_id = o.id
WHERE  o.customer_id = 1234
GROUP  BY o.id
ORDER  BY o.placed_at DESC
LIMIT  20;
```

```text
                                                 QUERY PLAN                                                 
------------------------------------------------------------------------------------------------------------
 Limit (actual rows=6 loops=1)
   Buffers: shared hit=33
   ->  Sort (actual rows=6 loops=1)
         Sort Key: o.placed_at DESC
         Sort Method: quicksort  Memory: 25kB
         Buffers: shared hit=33
         ->  GroupAggregate (actual rows=6 loops=1)
               Group Key: o.id
               Buffers: shared hit=33
               ->  Sort (actual rows=14 loops=1)
                     Sort Key: o.id
                     Sort Method: quicksort  Memory: 26kB
                     Buffers: shared hit=33
                     ->  Nested Loop Left Join (actual rows=14 loops=1)
                           Buffers: shared hit=33
                           ->  Index Scan using orders_customer_placed on orders o (actual rows=6 loops=1)
                                 Index Cond: (customer_id = 1234)
                                 Buffers: shared hit=9
                           ->  Index Scan using order_items_order on order_items oi (actual rows=2 loops=6)
                                 Index Cond: (order_id = o.id)
                                 Buffers: shared hit=24
 Planning:
   Buffers: shared hit=16
(23 rows)
```

33 buffers for six orders: nine for the orders, twenty-four for the items. Small and
already fast. Hold that thought.

**Path 2: an operations dashboard** — the distribution of items per order for August 2026,
about 64,000 orders:

```sql
SET max_parallel_workers_per_gather = 0;   -- one process, so buffer totals are comparable
SET enable_nestloop = off;                 -- give the normalized side its best plan (see below)
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT items, count(*) AS orders
FROM  (SELECT o.id, count(oi.id) AS items
       FROM   orders o LEFT JOIN order_items oi ON oi.order_id = o.id
       WHERE  o.placed_at >= '2026-08-01' AND o.placed_at < '2026-09-01'
       GROUP  BY o.id) s
GROUP  BY items ORDER BY items;
```

```text
                                                                                         QUERY PLAN
--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
 Sort (actual rows=4 loops=1)
   Sort Key: (count(oi.id))
   Sort Method: quicksort  Memory: 25kB
   Buffers: shared hit=867 read=48186, temp read=16 written=39
   ->  HashAggregate (actual rows=4 loops=1)
         Group Key: count(oi.id)
         Batches: 1  Memory Usage: 40kB
         Buffers: shared hit=864 read=48186, temp read=16 written=39
         ->  HashAggregate (actual rows=63892 loops=1)
               Group Key: o.id
               Batches: 5  Memory Usage: 8241kB  Disk Usage: 224kB
               Buffers: shared hit=864 read=48186, temp read=16 written=39
               ->  Hash Right Join (actual rows=159644 loops=1)
                     Hash Cond: (oi.order_id = o.id)
                     Buffers: shared hit=864 read=48186
                     ->  Seq Scan on order_items oi (actual rows=5004129 loops=1)
                           Buffers: shared read=31874
                     ->  Hash (actual rows=63892 loops=1)
                           Buckets: 65536  Batches: 1  Memory Usage: 2759kB
                           Buffers: shared hit=864 read=16312
                           ->  Bitmap Heap Scan on orders o (actual rows=63892 loops=1)
                                 Recheck Cond: ((placed_at >= '2026-08-01 00:00:00+00'::timestamp with time zone) AND (placed_at < '2026-09-01 00:00:00+00'::timestamp with time zone))
                                 Heap Blocks: exact=16999
                                 Buffers: shared hit=864 read=16312
                                 ->  Bitmap Index Scan on orders_placed (actual rows=63892 loops=1)
                                       Index Cond: ((placed_at >= '2026-08-01 00:00:00+00'::timestamp with time zone) AND (placed_at < '2026-09-01 00:00:00+00'::timestamp with time zone))
                                       Buffers: shared hit=1 read=176
 Planning:
   Buffers: shared hit=18 read=2
(29 rows)
```

**49,053 buffers** (`hit` plus `read`; how they split depends on what was cached, the
total does not). The planner scans all 5,004,129 `order_items` rows to serve 64,000 orders.

The `SET enable_nestloop = off` deserves an explanation, because it flatters the
normalized side and I want you to know why. Left alone, this query's plan is unstable.
The planner's estimated cost for the hash join above and for a parallel nested loop that
probes `order_items_order` once per order differ by a few percent, and `ANALYZE` samples
rows at random, so which one wins changes from one `ANALYZE` to the next. On a fresh copy
of the database where it chose the nested loop, the same query read **273,338 buffers** —
five and a half times more. Estimated costs a few percent apart, actual work five times
apart: cost estimates rank plans, they do not measure them (Chapter 34). We compare
against the better plan so the denormalized column has to beat the best the join can do.
The parallelism setting stays on for the rest of the section; the nested-loop one is reset
in the next block, where the join disappears.

Now denormalize. Add the count to `orders`, backfill it, repack, and look at what it cost:

```sql
RESET enable_nestloop;
ALTER TABLE orders ADD COLUMN item_count int;
UPDATE orders o SET item_count = c.n
FROM  (SELECT order_id, count(*) AS n FROM order_items GROUP BY order_id) c
WHERE  c.order_id = o.id;
ALTER TABLE orders ALTER COLUMN item_count SET NOT NULL;
VACUUM FULL orders;
ANALYZE orders;

SELECT pg_size_pretty(pg_relation_size('orders')) AS orders_heap,
       pg_size_pretty(pg_indexes_size('orders'))  AS orders_indexes;
```

```text
 orders_heap | orders_indexes 
-------------+----------------
 143 MB      | 146 MB
(1 row)
```

Seven megabytes of heap and no index growth. Storage is not the bill. (The backfill itself
rewrote all two million rows; on a live table you would do it in batches, not one statement.)
Rerun both paths without the join:

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT id, placed_at, status, total_amount, item_count AS items
FROM   orders WHERE customer_id = 1234
ORDER  BY placed_at DESC LIMIT 20;
```

```text
                                      QUERY PLAN                                       
---------------------------------------------------------------------------------------
 Limit (actual rows=6 loops=1)
   Buffers: shared hit=9
   ->  Sort (actual rows=6 loops=1)
         Sort Key: placed_at DESC
         Sort Method: quicksort  Memory: 25kB
         Buffers: shared hit=9
         ->  Bitmap Heap Scan on orders (actual rows=6 loops=1)
               Recheck Cond: (customer_id = 1234)
               Heap Blocks: exact=6
               Buffers: shared hit=9
               ->  Bitmap Index Scan on orders_customer_placed (actual rows=6 loops=1)
                     Index Cond: (customer_id = 1234)
                     Buffers: shared hit=3
(13 rows)
```

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT item_count AS items, count(*) AS orders
FROM   orders
WHERE  placed_at >= '2026-08-01' AND placed_at < '2026-09-01'
GROUP  BY item_count ORDER BY item_count;
```

```text
                                                                                QUERY PLAN
--------------------------------------------------------------------------------------------------------------------------------------------------------------------------
 Sort (actual rows=4 loops=1)
   Sort Key: item_count
   Sort Method: quicksort  Memory: 25kB
   Buffers: shared hit=16137 read=1761 written=1
   ->  HashAggregate (actual rows=4 loops=1)
         Group Key: item_count
         Batches: 1  Memory Usage: 24kB
         Buffers: shared hit=16137 read=1761 written=1
         ->  Bitmap Heap Scan on orders (actual rows=63892 loops=1)
               Recheck Cond: ((placed_at >= '2026-08-01 00:00:00+00'::timestamp with time zone) AND (placed_at < '2026-09-01 00:00:00+00'::timestamp with time zone))
               Heap Blocks: exact=17721
               Buffers: shared hit=16137 read=1761 written=1
               ->  Bitmap Index Scan on orders_placed (actual rows=63892 loops=1)
                     Index Cond: ((placed_at >= '2026-08-01 00:00:00+00'::timestamp with time zone) AND (placed_at < '2026-09-01 00:00:00+00'::timestamp with time zone))
                     Buffers: shared hit=177
 Planning:
   Buffers: shared hit=4
(17 rows)
```

The scoreboard, in buffers:

| Read path | Normalized | Denormalized | |
|---|---|---|---|
| Order history, one customer | 33 | 9 | 3.7× fewer |
| Dashboard, one month | 49,053 | 17,898 | 2.7× fewer |

Read that table skeptically, because I did. The dashboard's win is 2.7×, not the hundredfold
people expect, because the query still visits 17,759 heap pages: `placed_at` is uncorrelated
with physical row order in this dataset, so a month of orders is scattered across the whole
table. The column removed the join; it did not remove the scan. And Path 1 improved by a
ratio that looks large and means little — 33 buffers was already fast and nobody notices 24
of them. **A denormalization justified by the first row of that table is a mistake.** The
second row is at least arguable, and even there, a covering index (Chapter 33) may deliver
more than the column did for a fraction of the risk.

### The write side, which is the bill

A redundant column must be kept correct by something. The honest options are the
application (fails the first time a second writer appears, exactly as in Chapter 15), a
trigger, or a periodic reconcile job. A trigger:

```sql
CREATE FUNCTION bump_item_count() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    UPDATE orders SET item_count = item_count + 1 WHERE id = NEW.order_id;
  END IF;
  IF TG_OP IN ('DELETE', 'UPDATE') THEN
    UPDATE orders SET item_count = item_count - 1 WHERE id = OLD.order_id;
  END IF;
  RETURN NULL;
END $$;

CREATE TRIGGER order_items_count
AFTER INSERT OR DELETE OR UPDATE OF order_id ON order_items
FOR EACH ROW EXECUTE FUNCTION bump_item_count();
```

Every insert of an order line is now also an update of an order row. What does that cost?
Insert one line into each of 1,000 different orders and measure the WAL generated. The
first run has the trigger off, the second on; each starts right after a `CHECKPOINT`,
which is the realistic worst case, since the first change to any page after a checkpoint
logs the whole 8 kB page:

```sql
ALTER TABLE order_items DISABLE TRIGGER order_items_count;
CHECKPOINT;
SELECT pg_current_wal_insert_lsn() AS start_lsn \gset
INSERT INTO order_items (order_id, product_id, quantity, unit_price)
SELECT id, 10, 1, 99.00 FROM orders WHERE id % 2000 = 1;
SELECT round(pg_wal_lsn_diff(pg_current_wal_insert_lsn(), :'start_lsn') / 1000) AS wal_bytes_per_row;
```

```text
 wal_bytes_per_row 
-------------------
             15914
(1 row)
```

The bypass left those 1,000 counts stale, so repair them, re-enable the trigger and go
again on a different 1,000 orders. `pg_stat_reset()` zeroes this scratch database's
counters so we can read the update statistics afterwards:

```sql
UPDATE orders o SET item_count = c.n
FROM  (SELECT order_id, count(*) AS n FROM order_items GROUP BY order_id) c
WHERE  c.order_id = o.id AND o.item_count <> c.n;
ALTER TABLE order_items ENABLE TRIGGER order_items_count;
SELECT pg_stat_reset();
CHECKPOINT;
SELECT pg_current_wal_insert_lsn() AS start_lsn \gset
INSERT INTO order_items (order_id, product_id, quantity, unit_price)
SELECT id, 10, 1, 99.00 FROM orders WHERE id % 2000 = 3;
SELECT round(pg_wal_lsn_diff(pg_current_wal_insert_lsn(), :'start_lsn') / 1000) AS wal_bytes_per_row;
```

```text
 wal_bytes_per_row 
-------------------
             43835
(1 row)
```

```sql
SELECT pg_sleep(2);      -- statistics are flushed asynchronously
SELECT n_tup_upd, n_tup_hot_upd FROM pg_stat_user_tables WHERE relname = 'orders';
```

```text
 n_tup_upd | n_tup_hot_upd 
-----------+---------------
      1000 |            60
(1 row)
```

**2.8× the WAL per inserted line**, and the replication and backup traffic that goes with
it. The counters say why: of 1,000 trigger-driven updates to `orders`, only 60 were HOT
(heap-only) updates. Every other one wrote a new row version *and* a new
entry in each of the table's three indexes, because `VACUUM FULL` packed the pages full and
left no room for a new version beside the old. (Chapter 30 covers HOT and `fillfactor`. A
lower `fillfactor` on `orders` would change this number, and is the standard mitigation.)

Two more costs the numbers do not show. Every line insert now takes a row lock on its
parent order, so two sessions adding lines to the same order queue behind each other.
And the trigger is one code path among several. Anything that skips it — a bulk load, a
restore, `session_replication_role = replica` — breaks the invariant silently:

```sql
SELECT count(*) AS drifted
FROM   orders o
WHERE  o.item_count IS DISTINCT FROM
       (SELECT count(*) FROM order_items oi WHERE oi.order_id = o.id);
```

```text
 drifted 
---------
       0
(1 row)
```

```sql
BEGIN;
SET LOCAL session_replication_role = replica;      -- skips every trigger, FK checks included
INSERT INTO order_items (order_id, product_id, quantity, unit_price)
VALUES (653498, 10, 1, 99.00);
COMMIT;

SELECT o.id, o.item_count AS stored,
       (SELECT count(*) FROM order_items oi WHERE oi.order_id = o.id) AS actual
FROM   orders o WHERE o.id = 653498;
```

```text
   id   | stored | actual 
--------+--------+--------
 653498 |      3 |      4
(1 row)
```

No error, no warning, one wrong number on one dashboard forever, until someone runs the
reconcile query and repairs what it finds:

```sql
UPDATE orders o SET item_count = c.n
FROM  (SELECT order_id, count(*) AS n FROM order_items GROUP BY order_id) c
WHERE  c.order_id = o.id AND o.item_count <> c.n;
```

```text
UPDATE 1
```

### Rules for doing it on purpose

1. **Normalize first, denormalize one measured path.** Start from 3NF. Denormalize only
   after a real query on real volume shows the join is the cost — and record the
   `BUFFERS` before and after, as above.
2. **Price the write side before the read side.** The read gain is visible in one
   `EXPLAIN`. The WAL, the row lock and the index churn only show up when you measure
   inserts.
3. **Name the mechanism that keeps it correct** — trigger, reconcile job, or generated
   column — and write the drift query the day you add the column. A redundant column
   without a drift query is a bug with a delay on it.
4. **Prefer a derived object to a copied column.** A materialized view or a summary table
   refreshed on a schedule stores the redundancy outside the table people write to and
   can be rebuilt from source. That is Chapter 41.
5. **Never denormalize a fact that changes.** Copying `customer_city` onto every order is
   how the anomaly in 18.4 gets rebuilt by hand. Copying a fact that is frozen by
   definition — the price *at sale* — is not denormalization at all; it is the fact.

## Summary

- Normalization is one idea: **store each fact once.** Functional dependencies are how you
  find the facts you are storing twice; find them by grouping on the left side and looking
  for `HAVING count(DISTINCT right) > 1`. Zero violations is strong evidence, not proof, and
  `count(DISTINCT)` ignores NULLs.
- A repeated value is redundancy only if it is the same fact: `unit_price` on a line is the
  price *at sale* (`sku -> unit_price` failed for all 200 SKUs). Names are not identifiers
  (`customer_name -> email` failed 238 times). Key discovery is part of the work:
  `(order_no, sku)` had 25 duplicates.
- 2NF removes dependencies on part of a key, 3NF removes dependencies through a non-key
  column. Prove the split lossless with `EXCEPT` both ways.
- The payoff is **integrity, not speed**: a half-finished update left one customer in two
  cities (19 rows vs 7) with no error; normalized, it is `UPDATE 1`.
- BCNF closes a gap in 3NF and can lose a dependency (a student acquired two Physics
  teachers and nothing objected). Target 3NF; go further when the redundancy hurts more.
- Denormalization is priced both ways. Reads, in buffers: 33 → 9 (order history) and
  49,053 → 17,898 (dashboard, 2.7×). Writes: 15,914 → 43,835 WAL bytes per inserted
  line, 60 of 1,000 updates HOT, a parent-row lock, and an invariant that any path skipping
  the trigger silently breaks. Ship the drift query with the column.

**Exercises:** Practice Sessions 18.1–18.2 accompany this chapter and are in the
workbook at the back of the book.

**Next:** Chapter 19, *Modeling Real Entities*, applies this to the shapes that recur in
every schema — one-to-many, many-to-many, optional relationships and hierarchies — and
draws table boundaries around domains rather than screens.
