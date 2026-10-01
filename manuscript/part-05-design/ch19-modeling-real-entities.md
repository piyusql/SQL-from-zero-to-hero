# Chapter 19 — Modeling Real Entities

Chapter 18 answered *which table does this column live in*. This chapter answers the
question before it: *which things get a table at all, and how do they point at each other?*
Most schema damage is done here, not in normalization. A table drawn around the wrong
boundary is normalized perfectly and still cannot represent a partial shipment.

The running domain is order fulfilment for a Pune distributor: customers who move house,
orders that ship in pieces, returns against what was actually shipped. Everything writes,
so everything runs in scratch databases. The order data is 40 real orders from `retail`;
the shipping side is invented and deterministic.

```bash
createdb ch19_fulfil
psql -d retail -Atq -c "\copy (SELECT o.id, o.customer_id, o.placed_at, o.status, c.name, c.email FROM orders o JOIN customers c ON c.id = o.customer_id WHERE o.id <= 40 ORDER BY o.id) TO '/tmp/ch19_orders.csv' CSV" -c "\copy (SELECT order_id, product_id, quantity, unit_price FROM order_items WHERE order_id <= 40 ORDER BY id) TO '/tmp/ch19_lines.csv' CSV" -c "\copy (SELECT id, sku, name FROM products ORDER BY id) TO '/tmp/ch19_products.csv' CSV"
psql -d ch19_fulfil
```

---

## 19.1 Draw boundaries around domains, not screens

The checkout screen shows a customer, a delivery address, some items, a total and a
delivery estimate, so the first draft of the schema is one `checkout` table with all of
those columns. It works for a month. Then the mobile app gets a different screen, the
warehouse team wants to see shipments, and support wants the address the parcel *actually
went to* after the customer moved. Screens change every quarter. The things the business
is made of do not.

A thing earns its own table when it passes three tests:

- **Identity.** Someone can point at one and say "that one": order 6, shipment 34.
- **Lifecycle.** It is created by a different actor, at a different time, from its
  neighbours. The customer creates the order; a warehouse creates the shipment days later.
- **Cardinality.** Its count relative to its neighbour is not fixed at one. An order has
  one shipment only until the first backorder.

`retail.orders` has a `shipped_at` column, which quietly asserts that an order ships exactly
once. That is a fine shape for a teaching dataset and the wrong one for fulfilment. Apply
the tests and the domain falls into these tables:

```text
customers ──< customer_addresses
    └──< orders >── ship-to address (one specific row)
           ├──< order_lines >── products
           └──< shipments ──< shipment_lines >── fulfils one order line
                    └──< returns ──< return_lines >── returns part of one shipment line
```

## 19.2 One-to-many: the foreign key goes on the many side

The rule is mechanical: the child row carries the parent's key. The work is three
decisions per foreign key, each with a wrong default:

1. **Mandatory or optional?** `NOT NULL` if a child cannot exist without the parent.
   Nullable foreign keys are for genuinely optional relationships and cost you the trap
   below.
2. **What does deleting the parent do?** This is Chapter 15's `ON DELETE`, applied with a
   test: `CASCADE` only where the child is *part of* the parent and dies with it (an order
   line without its order is meaningless). Everything that carries business history is
   `RESTRICT`: customer to orders, order to shipments. `SET NULL` suits an optional
   reference you can afford to lose, such as `customers.referred_by`.
3. **Must the child agree with a sibling reference?** The most under-used decision, and
   the one that catches the worst data.

The third one. An order points at a customer and at a ship-to address. A single-column
foreign key to the address checks that the address exists, not that it belongs to *this*
customer. The fix is a composite key on the parent and a composite foreign key on the
child; the "redundant" `customer_id` is the price. Here is the whole fulfilment schema:

```sql
\pset null '(null)'
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE customers (customer_id int PRIMARY KEY, name text NOT NULL, email text NOT NULL UNIQUE);
CREATE TABLE products  (product_id  int PRIMARY KEY, sku  text NOT NULL UNIQUE, name text NOT NULL);

CREATE TABLE customer_addresses (
    address_id   int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id  int  NOT NULL REFERENCES customers,
    line1        text NOT NULL,
    city         text NOT NULL,
    pincode      text NOT NULL CHECK (pincode ~ '^[1-9][0-9]{5}$'),
    valid_during daterange NOT NULL,
    UNIQUE (customer_id, address_id),
    EXCLUDE USING gist (customer_id WITH =, valid_during WITH &&));

CREATE TABLE orders (
    order_id        int PRIMARY KEY,
    customer_id     int NOT NULL REFERENCES customers,
    ship_address_id int NOT NULL,
    placed_at       timestamptz NOT NULL,
    cancelled_at    timestamptz,
    FOREIGN KEY (customer_id, ship_address_id)
        REFERENCES customer_addresses (customer_id, address_id));

CREATE TABLE order_lines (
    order_id   int NOT NULL REFERENCES orders ON DELETE CASCADE,
    line_no    int NOT NULL,
    product_id int NOT NULL REFERENCES products,
    quantity   int NOT NULL CHECK (quantity > 0),
    unit_price numeric(10,2) NOT NULL CHECK (unit_price >= 0),
    PRIMARY KEY (order_id, line_no));

CREATE TABLE shipments (
    shipment_id  int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id     int  NOT NULL REFERENCES orders,
    warehouse    text NOT NULL,
    carrier      text NOT NULL,
    shipped_at   timestamptz NOT NULL,
    delivered_at timestamptz,
    CHECK (delivered_at >= shipped_at),
    UNIQUE (shipment_id, order_id));

CREATE TABLE shipment_lines (
    shipment_id int NOT NULL,
    order_id    int NOT NULL,
    line_no     int NOT NULL,
    quantity    int NOT NULL CHECK (quantity > 0),
    PRIMARY KEY (shipment_id, line_no),
    FOREIGN KEY (shipment_id, order_id) REFERENCES shipments (shipment_id, order_id),
    FOREIGN KEY (order_id, line_no)     REFERENCES order_lines (order_id, line_no));

CREATE TABLE returns (
    return_id   int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    shipment_id int NOT NULL REFERENCES shipments,
    opened_at   timestamptz NOT NULL,
    UNIQUE (return_id, shipment_id));

CREATE TABLE return_lines (
    return_id   int  NOT NULL,
    shipment_id int  NOT NULL,
    line_no     int  NOT NULL,
    quantity    int  NOT NULL CHECK (quantity > 0),
    reason      text NOT NULL CHECK (reason IN ('damaged','wrong_item','not_needed','late')),
    PRIMARY KEY (return_id, line_no),
    FOREIGN KEY (return_id, shipment_id) REFERENCES returns (return_id, shipment_id),
    FOREIGN KEY (shipment_id, line_no)   REFERENCES shipment_lines (shipment_id, line_no));
```

Three things to read off it. `order_lines` cascades from `orders` because a line is *part
of* an order; nothing else cascades. `shipment_lines` carries `order_id` redundantly so
that one foreign key ties the line to its shipment's order and the other ties it to an
order line of that *same* order: a shipment can only ship what its own order contains.
And `return_lines` references `shipment_lines`, not `order_lines`: you can only return
what was actually shipped, and from which parcel.

Now load it. The seed reads two staging tables, dropped at the end of 19.5; the first address of every customer
is valid from 2023, and even-numbered customers moved on 1 January 2025.

```sql
CREATE TABLE stg_orders (order_id int, customer_id int, placed_at timestamptz, status text, name text, email text);
CREATE TABLE stg_lines  (order_id int, product_id int, quantity int, unit_price numeric(10,2));
\copy stg_orders FROM '/tmp/ch19_orders.csv' CSV
\copy stg_lines  FROM '/tmp/ch19_lines.csv' CSV
\copy products   FROM '/tmp/ch19_products.csv' CSV

INSERT INTO customers SELECT DISTINCT customer_id, name, email FROM stg_orders;

INSERT INTO customer_addresses (customer_id, line1, city, pincode, valid_during)
SELECT customer_id, 'Flat ' || (customer_id % 40 + 1) || ', Gandhi Road',
       (ARRAY['Pune','Bengaluru','Delhi','Hyderabad'])[customer_id % 4 + 1],
       (ARRAY['411001','560001','110001','500001'])[customer_id % 4 + 1],
       CASE WHEN customer_id % 2 = 0 THEN daterange('2023-01-01','2025-01-01')
            ELSE daterange('2023-01-01', NULL) END
FROM (SELECT DISTINCT customer_id FROM stg_orders) c ORDER BY customer_id;
INSERT INTO customer_addresses (customer_id, line1, city, pincode, valid_during)
SELECT customer_id, 'Plot ' || (customer_id % 90 + 10) || ', Nehru Nagar',
       (ARRAY['Kochi','Chennai','Jaipur','Indore'])[customer_id % 4 + 1],
       (ARRAY['682001','600001','302001','452001'])[customer_id % 4 + 1],
       daterange('2025-01-01', NULL)
FROM (SELECT DISTINCT customer_id FROM stg_orders) c WHERE customer_id % 2 = 0 ORDER BY customer_id;

INSERT INTO orders (order_id, customer_id, ship_address_id, placed_at, cancelled_at)
SELECT o.order_id, o.customer_id, a.address_id, o.placed_at,
       CASE WHEN o.status = 'cancelled' THEN o.placed_at + interval '1 day' END
FROM   stg_orders o
JOIN   customer_addresses a ON a.customer_id = o.customer_id AND a.valid_during @> o.placed_at::date;

INSERT INTO order_lines
SELECT order_id, row_number() OVER (PARTITION BY order_id ORDER BY ctid), product_id, quantity, unit_price
FROM   stg_lines;

SELECT (SELECT count(*) FROM orders) AS orders, (SELECT count(*) FROM order_lines) AS lines,
       (SELECT count(*) FROM customer_addresses) AS addresses;
```

```text
 orders | lines | addresses
--------+-------+-----------
     40 |    94 |        57
(1 row)
```

(Numbering lines by `ctid` is acceptable once, on a staging table nobody else writes to;
Chapter 18 made the same caveat.) Fifty-seven addresses for forty customers: the
even-numbered customers each have two. Every order was matched to the address in force
on the day it was placed. Now watch the composite key work. Take an address belonging to
one customer and offer it to another customer's order:

```sql
INSERT INTO orders (order_id, customer_id, ship_address_id, placed_at)
SELECT 9001, 69, address_id, timestamptz '2026-09-30 10:00+05:30' FROM customer_addresses WHERE customer_id = 118 LIMIT 1;
```

```text
ERROR:  insert or update on table "orders" violates foreign key constraint "orders_customer_id_ship_address_id_fkey"
DETAIL:  Key (customer_id, ship_address_id)=(69, 5) is not present in table "customer_addresses".
```

A single-column foreign key would have accepted that: address 5 exists. The database now
guarantees no order ever ships to somebody else's address, whichever application wrote it.

> **Trap —** a nullable foreign key silently switches itself off. With the default
> `MATCH SIMPLE`, a composite foreign key is checked only if *every* column is non-null.
> If `customer_id` were nullable, a row with `customer_id = NULL` and any `ship_address_id`
> at all would pass.

Prove it on throwaway tables, then close the hole the way you would in production, with
`NOT NULL` (as above) or `MATCH FULL`:

```sql
CREATE TABLE t_simple (customer_id int, ship_address_id int,
    FOREIGN KEY (customer_id, ship_address_id) REFERENCES customer_addresses (customer_id, address_id));
INSERT INTO t_simple VALUES (NULL, 999999);

CREATE TABLE t_full (customer_id int, ship_address_id int,
    FOREIGN KEY (customer_id, ship_address_id) REFERENCES customer_addresses (customer_id, address_id) MATCH FULL);
INSERT INTO t_full VALUES (NULL, 999999);
DROP TABLE t_simple, t_full;
```

```text
CREATE TABLE
INSERT 0 1
CREATE TABLE
ERROR:  insert or update on table "t_full" violates foreign key constraint "t_full_customer_id_ship_address_id_fkey"
DETAIL:  MATCH FULL does not allow mixing of null and nonnull key values.
DROP TABLE
```

Address 999999 does not exist and the first insert was accepted. `MATCH FULL` refuses a
half-null key. My default: every foreign key that is not *genuinely* optional is
`NOT NULL`, and composite ones get `NOT NULL` on every column.

## 19.3 Many-to-many: a table with its own attributes

A many-to-many relationship is a third table holding pairs, and the table is rarely only a
pair. Its columns describe the *relationship*: the quantity on an order line, the position
of a product in a collection, the date it was added. That is why "junction table" undersells
it.

The key question is whether the pair itself is unique. Not always, and `retail` has the
evidence: an order line links an order to a product, so `(order_id, product_id)` looks like
the natural key.

```bash
psql -d retail -c "SELECT count(*) AS orders_with_a_repeated_product FROM (SELECT order_id FROM order_items GROUP BY order_id, product_id HAVING count(*) > 1) s"
```

```text
 orders_with_a_repeated_product
--------------------------------
                             25
(1 row)
```

Twenty-five orders carry the same product on two lines, which real order systems produce all
the time (a promotional line plus a manual one, two gift messages). A primary key on the pair would reject
legitimate data. That is why `order_lines` uses `(order_id, line_no)`. The rule I use:

- **Composite primary key on the two foreign keys** when the pair is unique by definition
  (a product is in a collection or it is not).
- **A line number or surrogate** when the pair can legitimately repeat, or when other
  tables must reference the row and a two-column reference is awkward.

Leave the key off entirely and you get the accidental duplicate: a double-clicked "add to
collection" button writes the pair twice, and every join that touches it double-counts.

```sql
CREATE TABLE collections (collection_id int PRIMARY KEY, title text NOT NULL);
INSERT INTO collections SELECT i, 'Festive edit ' || i FROM generate_series(1, 300) i;

CREATE TEMP TABLE naive_membership (collection_id int, product_id int);
INSERT INTO naive_membership VALUES (7, 42), (7, 42), (7, 43);
SELECT p.sku, count(*) AS rows_seen
FROM naive_membership m JOIN products p USING (product_id)
WHERE m.collection_id = 7 GROUP BY 1 ORDER BY 1;
```

```text
    sku    | rows_seen
-----------+-----------
 SKU-00042 |         2
 SKU-00043 |         1
(2 rows)
```

SKU-00042 is in the collection once and shows up twice. The real table, with the key and
the relationship's own columns:

```sql
CREATE TABLE collection_products (
    collection_id int  NOT NULL REFERENCES collections,
    product_id    int  NOT NULL REFERENCES products,
    position      int  NOT NULL CHECK (position > 0),
    added_on      date NOT NULL DEFAULT current_date,
    PRIMARY KEY (collection_id, product_id));
INSERT INTO collection_products (collection_id, product_id, position)
SELECT c.collection_id, p.product_id,
       row_number() OVER (PARTITION BY c.collection_id ORDER BY p.product_id)
FROM collections c CROSS JOIN products p WHERE (c.collection_id * p.product_id * 7919) % 4 = 0;

INSERT INTO collection_products (collection_id, product_id, position) VALUES (4, 8, 1);
```

```text
CREATE TABLE
INSERT 0 30000
ERROR:  duplicate key value violates unique constraint "collection_products_pkey"
DETAIL:  Key (collection_id, product_id)=(4, 8) already exists.
```

The primary key's index leads with `collection_id`, so it serves "products in collection
4" and cannot serve "collections containing product 42". Foreign key columns get no index
automatically, and the pair's second column is the one people forget. Here are 30,000
memberships, before and after the reverse index:

```sql
SET max_parallel_workers_per_gather = 0;
SELECT count(*) FROM collection_products WHERE product_id = 42;   -- warm the cache
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT collection_id FROM collection_products WHERE product_id = 42;
```

```text
 count
-------
   150
(1 row)

                        QUERY PLAN
-----------------------------------------------------------
 Seq Scan on collection_products (actual rows=150 loops=1)
   Filter: (product_id = 42)
   Rows Removed by Filter: 29850
   Buffers: shared hit=163
(4 rows)
```

```sql
CREATE INDEX collection_products_product_idx ON collection_products (product_id, collection_id);
VACUUM ANALYZE collection_products;
SELECT count(*) FROM collection_products WHERE product_id = 42;   -- warm the cache
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT collection_id FROM collection_products WHERE product_id = 42;
```

```text
 count
-------
   150
(1 row)

                                               QUERY PLAN
--------------------------------------------------------------------------------------------------------
 Index Only Scan using collection_products_product_idx on collection_products (actual rows=150 loops=1)
   Index Cond: (product_id = 42)
   Heap Fetches: 0
   Buffers: shared hit=4
(4 rows)
```

Both are warm runs: a sequential scan touching 163 buffers, then an index-only scan
touching 4, for the same 150 rows. The index is the second half of
the junction table's design, not an optimization to add later. Chapter 33, *Indexing*,
covers the choices.

## 19.4 One-to-one: usually one table, sometimes two

If two things always exist together and are read together, they are one table. Split only
for a reason you can name: different privileges (KYC data most staff must not read),
a sparse group of columns present for a small fraction of rows, or different write rates.
The mechanism is a primary key that is also the foreign key, which makes "at most one"
structural:

```sql
CREATE TABLE customer_kyc (
    customer_id int PRIMARY KEY REFERENCES customers,
    pan_last4   text NOT NULL CHECK (pan_last4 ~ '^[0-9A-Z]{4}$'),
    verified_on date NOT NULL);
INSERT INTO customer_kyc VALUES (69, '4F2K', '2025-03-01');
INSERT INTO customer_kyc VALUES (69, '9Z9Z', '2025-04-01');
```

```text
CREATE TABLE
INSERT 0 1
ERROR:  duplicate key value violates unique constraint "customer_kyc_pkey"
DETAIL:  Key (customer_id)=(69) already exists.
```

The other direction, "every customer *must* have a KYC row", cannot be declared with a
foreign key, because each table would need a row in the other before either exists.
Chapter 15's deferrable constraints can close the circle at commit; in practice most teams
accept that the child is optional and let the application check.

## 19.5 Order fulfilment, end to end

Data first: every order that left the warehouse gets a shipment; on every third order line
1 ships half and the balance is owed; customers send back one unit from each `returned`
order. `shipment_lines` has one rule no constraint can
express, that the shipped total for a line may not exceed the ordered quantity, so it gets
a trigger (Chapter 43 covers the mechanics). The trigger locks the order line first, so
two warehouse clerks cannot each ship the last unit.

```sql
CREATE FUNCTION check_not_overshipped() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE ordered int; already int;
BEGIN
    SELECT quantity INTO ordered FROM order_lines
    WHERE  order_id = NEW.order_id AND line_no = NEW.line_no FOR UPDATE;
    SELECT coalesce(sum(quantity), 0) INTO already FROM shipment_lines
    WHERE  order_id = NEW.order_id AND line_no = NEW.line_no AND shipment_id <> NEW.shipment_id;
    IF already + NEW.quantity > ordered THEN
        RAISE EXCEPTION 'order % line %: ordered %, already shipped %, cannot ship % more',
              NEW.order_id, NEW.line_no, ordered, already, NEW.quantity
              USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER shipment_lines_cap BEFORE INSERT OR UPDATE OF quantity, order_id, line_no
ON shipment_lines FOR EACH ROW EXECUTE FUNCTION check_not_overshipped();

INSERT INTO shipments (order_id, warehouse, carrier, shipped_at, delivered_at)
SELECT o.order_id, (ARRAY['WH-PUN','WH-BLR','WH-DEL','WH-HYD'])[o.order_id % 4 + 1],
       (ARRAY['BlueDart','Delhivery','Ecom Express'])[o.order_id % 3 + 1],
       o.placed_at + interval '1 day',
       CASE WHEN s.status IN ('delivered','returned') THEN o.placed_at + interval '4 days' END
FROM   orders o JOIN stg_orders s USING (order_id)
WHERE  s.status IN ('shipped','delivered','returned') ORDER BY o.order_id;

INSERT INTO shipment_lines (shipment_id, order_id, line_no, quantity)
SELECT sh.shipment_id, l.order_id, l.line_no,
       CASE WHEN l.order_id % 3 = 0 AND l.line_no = 1 THEN (l.quantity + 1) / 2 ELSE l.quantity END
FROM   shipments sh JOIN order_lines l USING (order_id) ORDER BY 1, 3;


INSERT INTO returns (shipment_id, opened_at)
SELECT sh.shipment_id, sh.delivered_at + interval '2 days'
FROM   shipments sh JOIN stg_orders s USING (order_id) WHERE s.status = 'returned' ORDER BY 1;
INSERT INTO return_lines SELECT return_id, shipment_id, 1, 1, 'damaged' FROM returns ORDER BY 1;
DROP TABLE stg_orders, stg_lines;
```

The point of the model is what it can now answer. "Where is order 27?" is a question about
three tables. Aggregate each child *before* joining it, or the fan-out from Chapter 9
multiplies the numbers:

```sql
CREATE VIEW order_line_progress AS
SELECT l.order_id, l.line_no, l.quantity AS ordered,
       coalesce(s.shipped, 0) AS shipped, coalesce(r.returned, 0) AS returned
FROM   order_lines l
LEFT   JOIN (SELECT order_id, line_no, sum(quantity) AS shipped
             FROM shipment_lines GROUP BY 1, 2) s USING (order_id, line_no)
LEFT   JOIN (SELECT sl.order_id, sl.line_no, sum(rl.quantity) AS returned
             FROM return_lines rl JOIN shipment_lines sl USING (shipment_id, line_no)
             GROUP BY 1, 2) r USING (order_id, line_no);

SELECT order_id, count(*) AS lines, sum(ordered) AS ordered, sum(shipped) AS shipped,
       sum(returned) AS returned, sum(ordered - shipped) AS outstanding
FROM   order_line_progress GROUP BY order_id
HAVING sum(shipped) > 0 AND sum(ordered - shipped) > 0 ORDER BY order_id;
```

```text
 order_id | lines | ordered | shipped | returned | outstanding
----------+-------+---------+---------+----------+-------------
        6 |     3 |       7 |       6 |        0 |           1
       12 |     4 |      11 |      10 |        0 |           1
       18 |     4 |      14 |      12 |        0 |           2
       24 |     1 |       3 |       2 |        0 |           1
       27 |     3 |       6 |       5 |        0 |           1
       33 |     2 |       8 |       6 |        0 |           2
       39 |     1 |       4 |       2 |        0 |           2
(7 rows)
```

Seven orders are partly shipped and still owe stock. Now the constraints, against real bad
data. Open a shipment for order 27, which is short on line 1, and try to over-ship it,
then try to put a line from a different order into it:

```sql
INSERT INTO shipments (order_id, warehouse, carrier, shipped_at)
VALUES (27, 'WH-DEL', 'Delhivery', timestamptz '2026-09-30 10:00+05:30') RETURNING shipment_id AS new_ship \gset
SELECT quantity AS ordered,
       (SELECT sum(quantity) FROM shipment_lines WHERE order_id = 27 AND line_no = 1) AS shipped
FROM order_lines WHERE order_id = 27 AND line_no = 1;

INSERT INTO shipment_lines VALUES (:new_ship, 27, 1, 2);
INSERT INTO shipment_lines VALUES (:new_ship, 3, 1, 1);
INSERT INTO shipment_lines VALUES (:new_ship, 27, 1, 1);

SELECT sh.shipment_id, sh.warehouse, sh.shipped_at::date AS shipped, sl.quantity
FROM   shipments sh JOIN shipment_lines sl USING (shipment_id)
WHERE  sh.order_id = 27 AND sl.line_no = 1 ORDER BY 1;
```

```text
INSERT 0 1
 ordered | shipped
---------+---------
       3 |       2
(1 row)

ERROR:  order 27 line 1: ordered 3, already shipped 2, cannot ship 2 more
CONTEXT:  PL/pgSQL function check_not_overshipped() line 9 at RAISE
ERROR:  insert or update on table "shipment_lines" violates foreign key constraint "shipment_lines_shipment_id_order_id_fkey"
DETAIL:  Key (shipment_id, order_id)=(34, 3) is not present in table "shipments".
INSERT 0 1
 shipment_id | warehouse |  shipped   | quantity
-------------+-----------+------------+----------
          23 | WH-HYD    | 2025-04-22 |        2
          34 | WH-DEL    | 2026-09-30 |        1
(2 rows)
```

Three outcomes, three different mechanisms. The first insert is stopped by the trigger,
the only rule here that needed code. The second slips past the trigger (order 3 has
stock) and is caught by the composite foreign key, because the new shipment belongs to
order 27, not order 3. The third, the last unit, is accepted, and the listing shows line 1 of order 27 leaving
in two parcels. Neither error needed the application to be careful.

Deletes show the `ON DELETE` choices. Order 1 has shipments; order 3 has none, but has
lines:

```sql
BEGIN;
DELETE FROM orders WHERE order_id = 1;
ROLLBACK;
BEGIN;
SELECT count(*) AS lines_before FROM order_lines WHERE order_id = 3;
DELETE FROM orders WHERE order_id = 3;
SELECT count(*) AS lines_after FROM order_lines WHERE order_id = 3;
ROLLBACK;
```

```text
BEGIN
ERROR:  update or delete on table "orders" violates foreign key constraint "shipments_order_id_fkey" on table "shipments"
DETAIL:  Key (order_id)=(1) is still referenced from table "shipments".
ROLLBACK
BEGIN
 lines_before
--------------
            2
(1 row)

DELETE 1
 lines_after
-------------
           0
(1 row)

ROLLBACK
```

Order 1 is protected by `RESTRICT` on `shipments`; order 3's lines went with it by
`CASCADE`. I would still not allow `DELETE` on `orders` in production, and use
`cancelled_at`: the cascade exists so that deleting an order cannot leave orphan lines, not
because deletion is a workflow (Chapter 22, *The Table Design Checklist*).

> **In production —** a rule enforced by a trigger rather than a constraint deserves a
> monitor, because a bulk load or a disabled trigger can get around it and nothing else will
> notice. For this one the query is short and should always return zero:

```sql
SELECT count(*) AS lines_over_shipped_or_over_returned
FROM   order_line_progress WHERE shipped > ordered OR returned > shipped;
```

```text
 lines_over_shipped_or_over_returned
-------------------------------------
                                   0
(1 row)
```

**Addresses over time.** Never `UPDATE` an address that an order references: every
historical order would now claim it shipped to the new house. An address is a row that is
*retired*, and the exclusion constraint from Chapter 15 keeps one delivery address in
force per customer. Ananya Nair (customer 69) moves on 1 June 2026:

```sql
INSERT INTO customer_addresses (customer_id, line1, city, pincode, valid_during)
VALUES (69, 'Plot 14, Lake View', 'Kochi', '682001', daterange('2026-06-01', NULL));

BEGIN;
UPDATE customer_addresses SET valid_during = daterange(lower(valid_during), '2026-06-01')
WHERE  customer_id = 69 AND upper_inf(valid_during);
INSERT INTO customer_addresses (customer_id, line1, city, pincode, valid_during)
VALUES (69, 'Plot 14, Lake View', 'Kochi', '682001', daterange('2026-06-01', NULL));
COMMIT;

SELECT o.order_id, o.placed_at::date AS placed, a.city AS shipped_to, cur.city AS lives_in_now
FROM   orders o
JOIN   customer_addresses a   ON a.address_id = o.ship_address_id
JOIN   customer_addresses cur ON cur.customer_id = o.customer_id AND cur.valid_during @> current_date
WHERE  o.customer_id = 69;
```

```text
ERROR:  conflicting key value violates exclusion constraint "customer_addresses_customer_id_valid_during_excl"
DETAIL:  Key (customer_id, valid_during)=(69, [2026-06-01,)) conflicts with existing key (customer_id, valid_during)=(69, [2023-01-01,)).
BEGIN
UPDATE 1
INSERT 0 1
COMMIT
 order_id |   placed   | shipped_to | lives_in_now
----------+------------+------------+--------------
        6 | 2025-10-05 | Bengaluru  | Kochi
(1 row)
```

The first insert is refused because the old address is still open-ended; the transaction
closes it and opens the new one atomically, and order 6 still says where it actually went.
If your customers keep several concurrent addresses, an address book, drop the exclusion
constraint and add a label; that is a domain decision, not a technicality.

## 19.6 Hierarchies

A hierarchy is a one-to-many relationship that points at its own table, and the interesting
question is which representation you pay for. Four are worth knowing:

- **Adjacency list**: `manager_id` on the row. One column, a real foreign key, one-row moves.
  Asking about depth needs recursion (Chapter 12).
- **Materialized path**: the ancestor chain as text, `/1/4/15/`. Subtree is a prefix match.
- **Closure table**: one row per ancestor-descendant pair, including each node with itself.
- **Nested sets** number the nodes so a subtree is an interval. Reads are fast and every
  insert renumbers everything to its right, which is why I have never shipped it.

PostgreSQL's `ltree` type is a typed materialized path; it appears in Chapter 49,
*Extensions Worth Knowing*. I will use `hr`'s org chart (2,774 employees, seven levels)
for correctness and maintenance, and a generated tree for cost, because 2,774 rows fit in 62
pages and every plan on them is a sequential scan.

```bash
psql -d hr -Atq -c "\copy (SELECT emp_id, full_name, manager_id, job_title, salary FROM employees ORDER BY emp_id) TO '/tmp/ch19_emp.csv' CSV"
createdb ch19_tree
psql -d ch19_tree
```

```sql
\pset null '(null)'
CREATE TABLE emp (emp_id int PRIMARY KEY, full_name text NOT NULL,
                  manager_id int REFERENCES emp, job_title text NOT NULL, salary numeric(10,2) NOT NULL);
\copy emp FROM '/tmp/ch19_emp.csv' CSV

ALTER TABLE emp ADD COLUMN path text;
WITH RECURSIVE t AS (
  SELECT emp_id, '/' || emp_id || '/' AS path FROM emp WHERE manager_id IS NULL
  UNION ALL SELECT e.emp_id, t.path || e.emp_id || '/' FROM emp e JOIN t ON e.manager_id = t.emp_id)
UPDATE emp SET path = t.path FROM t WHERE emp.emp_id = t.emp_id;

CREATE TABLE emp_closure (
  ancestor int NOT NULL REFERENCES emp, descendant int NOT NULL REFERENCES emp,
  depth int NOT NULL CHECK (depth >= 0), PRIMARY KEY (ancestor, descendant));
INSERT INTO emp_closure
WITH RECURSIVE t AS (
  SELECT emp_id AS ancestor, emp_id AS descendant, 0 AS depth FROM emp
  UNION ALL SELECT t.ancestor, e.emp_id, t.depth + 1 FROM t JOIN emp e ON e.manager_id = t.descendant)
SELECT * FROM t;
CREATE INDEX emp_closure_desc_idx ON emp_closure (descendant, ancestor);

SELECT emp_id, full_name, path FROM emp WHERE emp_id IN (1, 15, 2774);
```

```text
 emp_id |    full_name     |           path
--------+------------------+--------------------------
      1 | Ananya Reddy     | /1/
     15 | Farhan Mukherjee | /1/4/15/
   2774 | Vikram Desai     | /1/2/23/44/95/1123/2774/
(3 rows)
```

The closure table holds 17,445 rows for 2,774 employees, about six per person: one for
every ancestor plus the row that says each node is its own depth-0 descendant. That self
row is not decoration; it makes the next section work.

**Maintenance is where the representations differ.** Hire someone under Lakshmi Kulkarni
(employee 22), then move the vice president Farhan Mukherjee (employee 15, 309 people below)
from under employee 4 to under employee 5, and look at the command tags:

```sql
BEGIN;
INSERT INTO emp (emp_id, full_name, manager_id, job_title, salary, path)
SELECT 3000, 'Nandini Pillai', 22, 'Analyst', 41000, path || '3000/' FROM emp WHERE emp_id = 22;
INSERT INTO emp_closure
SELECT ancestor, 3000, depth + 1 FROM emp_closure WHERE descendant = 22
UNION ALL SELECT 3000, 3000, 0;
COMMIT;

BEGIN;
UPDATE emp SET manager_id = 5 WHERE emp_id = 15;
UPDATE emp SET path = '/1/5/15/' || substr(path, length('/1/4/15/') + 1) WHERE path LIKE '/1/4/15/%';
DELETE FROM emp_closure
WHERE  descendant IN (SELECT descendant FROM emp_closure WHERE ancestor = 15)
AND    ancestor NOT IN (SELECT descendant FROM emp_closure WHERE ancestor = 15);
INSERT INTO emp_closure
SELECT a.ancestor, d.descendant, a.depth + 1 + d.depth
FROM   emp_closure a CROSS JOIN emp_closure d
WHERE  a.descendant = 5 AND d.ancestor = 15;
COMMIT;
```

```text
BEGIN
INSERT 0 1
INSERT 0 4
COMMIT
BEGIN
UPDATE 1
UPDATE 309
DELETE 618
INSERT 0 618
COMMIT
```

A hire is one row in the adjacency list and four in the closure table (three ancestors
plus the self row). The move is `UPDATE 1` in the adjacency list, 309 rows for the path
(`UPDATE 309`), and 618 deleted plus 618 inserted for the closure table: two ancestors
dropped and two gained, times 309. Nothing here is timed; row counts are the cost. The
closure table can drift from `manager_id`, so prove it did not, by rebuilding it with
recursion and subtracting in both directions. The path gets the same check against its
parent:

```sql
WITH RECURSIVE t AS (
  SELECT emp_id AS ancestor, emp_id AS descendant, 0 AS depth FROM emp
  UNION ALL SELECT t.ancestor, e.emp_id, t.depth + 1 FROM t JOIN emp e ON e.manager_id = t.descendant),
r AS (SELECT * FROM t)
SELECT (SELECT count(*) FROM (TABLE r EXCEPT SELECT * FROM emp_closure) a) AS missing,
       (SELECT count(*) FROM (SELECT * FROM emp_closure EXCEPT TABLE r) b) AS stale,
       (SELECT count(*) FROM emp e JOIN emp m ON m.emp_id = e.manager_id
        WHERE e.path <> m.path || e.emp_id || '/') AS bad_paths;
```

```text
 missing | stale | bad_paths
---------+-------+-----------
       0 |     0 |         0
(1 row)
```

**Cycles.** An adjacency list happily accepts a loop. Make the CEO report to the newest
person in the chain and count who can still be reached from the root:

```sql
BEGIN;
UPDATE emp SET manager_id = 2774 WHERE emp_id = 1;
WITH RECURSIVE t AS (SELECT emp_id FROM emp WHERE manager_id IS NULL
  UNION ALL SELECT e.emp_id FROM emp e JOIN t ON e.manager_id = t.emp_id)
SELECT count(*) AS reachable_from_root FROM t;
ROLLBACK;
```

```text
BEGIN
UPDATE 1
 reachable_from_root
---------------------
                   0
(1 row)

ROLLBACK
```

`UPDATE 1`, no error, and the whole company vanished from every "start at the root"
query. Chapter 12's `CYCLE` clause detects a loop while walking; nothing stops you writing
one. The closure table stops it structurally. Run the same move through the closure
maintenance statement and the primary key refuses, because the cycle would need a
second `(2774, 2774)` row:

```sql
BEGIN;
UPDATE emp SET manager_id = 2774 WHERE emp_id = 1;
INSERT INTO emp_closure
SELECT a.ancestor, d.descendant, a.depth + 1 + d.depth
FROM   emp_closure a CROSS JOIN emp_closure d
WHERE  a.descendant = 2774 AND d.ancestor = 1;
ROLLBACK;
```

```text
BEGIN
UPDATE 1
ERROR:  duplicate key value violates unique constraint "emp_closure_pkey"
DETAIL:  Key (ancestor, descendant)=(2774, 2774) already exists.
ROLLBACK
```

**Cost, on a tree big enough to matter.** The generated tree has 500,000 nodes, five
children each, ten levels deep. It is not Indian data because it has no readable columns;
it exists to have volume. The closure table for it has 4.4 million rows. (Building it takes
a while and a few hundred megabytes.)

```sql
CREATE TABLE node (node_id int PRIMARY KEY, parent_id int REFERENCES node,
                   salary numeric(10,2) NOT NULL, path text NOT NULL);
INSERT INTO node
WITH RECURSIVE g AS (
  SELECT i AS node_id, CASE WHEN i = 1 THEN NULL ELSE (i - 2) / 5 + 1 END AS parent_id,
         20000 + (i::bigint * 7919) % 90000 AS salary
  FROM generate_series(1, 500000) i),
t AS (
  SELECT node_id, parent_id, salary, '/' || node_id || '/' AS path FROM g WHERE parent_id IS NULL
  UNION ALL SELECT g.node_id, g.parent_id, g.salary, t.path || g.node_id || '/'
  FROM g JOIN t ON g.parent_id = t.node_id)
SELECT * FROM t ORDER BY node_id;
CREATE INDEX node_path_idx ON node (path text_pattern_ops);

CREATE TABLE node_closure (ancestor int NOT NULL REFERENCES node, descendant int NOT NULL REFERENCES node,
                           depth int NOT NULL, PRIMARY KEY (ancestor, descendant));
INSERT INTO node_closure
WITH RECURSIVE t AS (
  SELECT node_id AS ancestor, node_id AS descendant, 0 AS depth FROM node
  UNION ALL SELECT t.ancestor, n.node_id, t.depth + 1 FROM t JOIN node n ON n.parent_id = t.descendant)
SELECT * FROM t;
CREATE INDEX node_closure_desc_idx ON node_closure (descendant, ancestor);
VACUUM ANALYZE node; VACUUM ANALYZE node_closure;

SELECT pg_size_pretty(pg_table_size('node') + pg_relation_size('node_pkey')) AS adjacency_and_path_col,
       pg_size_pretty(pg_relation_size('node_path_idx')) AS path_index,
       pg_size_pretty(pg_total_relation_size('node_closure')) AS closure_total;
```

```text
 adjacency_and_path_col | path_index | closure_total
------------------------+------------+---------------
 51 MB                  | 29 MB      | 392 MB
(1 row)
```

The closure table (with its two indexes) is roughly eight times the size of the table and
key it describes. Now three
questions a hierarchy is asked, measured in buffers (hit plus read) from `EXPLAIN
(ANALYZE, BUFFERS)`, run twice with the second, warm run reported. The helper below
does that, and I pinned `max_parallel_workers_per_gather = 0` so the plan shape cannot
change under you.

```sql
SET max_parallel_workers_per_gather = 0;
CREATE FUNCTION buffers_of(q text) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE j json;
BEGIN
    EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, FORMAT JSON) ' || q INTO j;   -- warm the cache
    EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, FORMAT JSON) ' || q INTO j;
    RETURN (j->0->'Plan'->>'Shared Hit Blocks')::bigint + (j->0->'Plan'->>'Shared Read Blocks')::bigint;
END $$;

CREATE TEMP TABLE probe (task text, form text, sql text);
INSERT INTO probe VALUES
('1 subtree payroll (625 rows)', 'adjacency',
 $$WITH RECURSIVE t AS (SELECT node_id, salary FROM node WHERE node_id = 800
    UNION ALL SELECT n.node_id, n.salary FROM node n JOIN t ON n.parent_id = t.node_id)
   SELECT count(*), sum(salary) FROM t$$),
('1 subtree payroll (625 rows)', 'path',
 $$SELECT count(*), sum(salary) FROM node WHERE path LIKE '/1/2/7/32/160/800/%'$$),
('1 subtree payroll (625 rows)', 'closure',
 $$SELECT count(*), sum(n.salary) FROM node_closure c JOIN node n ON n.node_id = c.descendant
   WHERE c.ancestor = 800$$),
('2 headcount, 625 managers', 'adjacency',
 $$WITH RECURSIVE t AS (SELECT node_id AS root, node_id FROM node WHERE node_id BETWEEN 157 AND 781
    UNION ALL SELECT t.root, n.node_id FROM node n JOIN t ON n.parent_id = t.node_id)
   SELECT count(*), sum(c) FROM (SELECT root, count(*) - 1 AS c FROM t GROUP BY root) s$$),
('2 headcount, 625 managers', 'closure',
 $$SELECT count(*), sum(c) FROM (SELECT ancestor, count(*) - 1 AS c FROM node_closure
   WHERE ancestor BETWEEN 157 AND 781 GROUP BY ancestor) s$$),
('3 ancestors of one leaf (10 rows)', 'adjacency',
 $$WITH RECURSIVE up AS (SELECT node_id, parent_id FROM node WHERE node_id = 500000
    UNION ALL SELECT n.node_id, n.parent_id FROM node n JOIN up ON n.node_id = up.parent_id)
   SELECT count(*) FROM up$$),
('3 ancestors of one leaf (10 rows)', 'path',
 $$SELECT count(*) FROM node WHERE node_id = ANY (string_to_array(trim('/' FROM
   (SELECT path FROM node WHERE node_id = 500000)), '/')::int[])$$),
('3 ancestors of one leaf (10 rows)', 'closure',
 $$SELECT count(*) FROM node_closure WHERE descendant = 500000$$);

SELECT task, form, buffers_of(sql) AS buffers FROM probe ORDER BY task, form;
```

```text
               task                |   form    | buffers
-----------------------------------+-----------+---------
 1 subtree payroll (625 rows)      | adjacency |   25509
 1 subtree payroll (625 rows)      | closure   |    2505
 1 subtree payroll (625 rows)      | path      |     236
 2 headcount, 625 managers         | adjacency |   30612
 2 headcount, 625 managers         | closure   |    1900
 3 ancestors of one leaf (10 rows) | adjacency |      40
 3 ancestors of one leaf (10 rows) | closure   |       4
 3 ancestors of one leaf (10 rows) | path      |      35
(8 rows)
```

Those adjacency numbers used *no index on `parent_id`*, which is how a foreign key arrives:
Postgres does not index the referencing column. Add it and rerun the adjacency rows:

```sql
CREATE INDEX node_parent_idx ON node (parent_id);
ANALYZE node;
SELECT task, form || ' + index on parent_id' AS form, buffers_of(sql) AS buffers
FROM   probe WHERE form = 'adjacency' ORDER BY task;
```

```text
               task                |              form              | buffers
-----------------------------------+--------------------------------+---------
 1 subtree payroll (625 rows)      | adjacency + index on parent_id |    2009
 2 headcount, 625 managers         | adjacency + index on parent_id |   18625
 3 ancestors of one leaf (10 rows) | adjacency + index on parent_id |      40
(3 rows)
```


Read the two tables honestly, because the answer is not "closure wins".

- **Adjacency without an index on `parent_id` is a trap.** The foreign key does not create
  one. Subtree payroll cost 25,509 buffers, five sequential scans of the table, one per
  level. With the index it cost 2,009.
- **For one subtree, the path won.** 236 buffers against 2,505 for the closure table. The
  closure table finds the 625 descendants in five buffers, then spends four per row
  probing `node` for the salary. The path index hands back the rows in one range scan.
- **The closure table wins when the answer does not need the base table**: headcount for
  625 managers took 1,900 buffers against 18,625 for indexed recursion (an index-only
  scan over `(ancestor, descendant)`), and it wins ancestors (4 against 35 and 40).
- The path's weakness is not in these numbers. It is text, so the database cannot check
  that it agrees with `manager_id` (the `bad_paths` query above is how you find out), and
  a prefix match must be a literal or a bound pattern: `LIKE (SELECT path ...) || '%'`
  cannot use the index.

What I would do: **adjacency list plus an index on the foreign key** for anything shaped
like an org chart or a category tree, walked with Chapter 12's recursion. Add a path when
subtree reads dominate and subtrees rarely move. Add a closure table when you aggregate
over subtrees or ask for ancestors constantly, when a cycle would be a real incident, and
when you can afford about eight times the storage and a move that rewrites 1,236 rows
to change one manager. If the tree is your product's central feature, look at `ltree`
first.

## Summary

- Draw tables around things with their own **identity, lifecycle and cardinality**, not
  around screens. `retail.orders.shipped_at` models exactly one shipment; fulfilment needs
  `shipments` and `shipment_lines`.
- One-to-many: the foreign key lives on the many side, and each one is three decisions,
  mandatory or not, what delete does (`CASCADE` only for parts, `RESTRICT` for history) and
  whether it must agree with a sibling. A composite foreign key stopped an order shipping to
  another customer's address.
- A nullable column in a composite `MATCH SIMPLE` foreign key disables the check
  (`(NULL, 999999)` was accepted); use `NOT NULL` or `MATCH FULL`.
- Many-to-many is a table with attributes. 25 `retail` orders repeat a product, so the pair
  is not a key there; where it is, a composite primary key prevents the double-count, and
  the reverse index is part of the design (163 buffers to 4).
- Rules a constraint cannot express (over-shipping) need a trigger that locks the parent
  row. Retire addresses instead of updating them, and let an exclusion constraint keep one
  in force.
- Hierarchies: an unindexed adjacency list cost 25,509 buffers for one subtree, 2,009
  indexed; path 236; closure 2,505. Closure won headcount (1,900 vs 18,625) and ancestors
  (4 vs 40), costs about eight times the storage, and its primary key rejects cycles that
  the adjacency list accepts silently.

**Exercises:** Practice Sessions 19.1–19.2 accompany this chapter and are in the
workbook at the back of the book.

**Next:** Chapter 20, *Keys and Identity Strategy at Scale*, takes on the question this
chapter kept deferring: which column identifies a row, whether it should be an `int`, a
`bigint` or a UUID, and what each choice does to index size and insert locality.
