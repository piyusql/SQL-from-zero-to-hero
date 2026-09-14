# Chapter 9 — Joins

Part II interrogated one table at a time. Almost nothing you are paid to answer lives in
one table, so Part III puts them back together — and this is where the most money is lost.

Not because joins are hard to write; the syntax takes an afternoon. They are dangerous
because of a sentence almost every tutorial gets wrong: *a join combines two tables*. It
does not. **A join produces every pair of rows that satisfies a condition.** If the right
side matches a left row twice, that left row comes back twice, and every aggregate
downstream is wrong by a factor nobody can name.

Chapter 8 opened with `sum(total_amount)` over `orders` — 3,678,982.61. By the middle of
this chapter the same money reads 11,138,789.39, from a query three words longer that
passes review. The join types are the easy part.

---

## 9.1 A join is a filtered product

Start with the operation everything else is built from. `CROSS JOIN` pairs every left row
with every right row and applies no condition at all.

```sql
SELECT count(*) AS cross_rows FROM customers, products;
```

```text
 cross_rows
------------
     200000
(1 row)

```

A thousand customers, two hundred products, two hundred thousand rows. The comma is the
older spelling of `CROSS JOIN`.

Every other join is that product with a condition attached. `INNER JOIN ... ON` keeps the
pairs where the condition holds; `LEFT JOIN` also keeps left rows that found no partner.
PostgreSQL does not literally build 200,000 rows and discard most — Chapter 34 covers the
hash and merge algorithms it uses instead — but the **result** is defined that way, and
when you are working out why a query returned 6,250 rows instead of 2,500, the product is
the model that predicts it.

A deliberate `CROSS JOIN` is rare but not exotic, and Chapter 8 left its use case
unsolved: `GROUP BY` emits one row per group *present in the input*, so a category that
sold nothing in September produces no September row, and nobody reads a row that is not
there. Manufacture the axis instead — cross-join `(SELECT DISTINCT category FROM
products)` with a `generate_series` of months, `LEFT JOIN` the aggregated facts onto that
grid, and wrap the measure in `coalesce(..., 0)`. Five categories and two months is ten
rows whatever the data does; the grouped query alone returns eight and lets you believe
the grid is complete. Practice Session 12.3 builds the date-axis version.

> **Trap —** an accidental `CROSS JOIN` is a `JOIN` whose `ON` clause you forgot, or a
> comma list with the predicate left out of `WHERE`. It does not error. On the small
> `retail` set `FROM orders o, customers c` is 2,500,000 rows and comes back in a second;
> on the large one it is 600 billion and takes the machine with it.

## 9.2 `INNER JOIN`, and what it quietly removes

The join you write nine times in ten follows a foreign key.

```sql
SELECT o.id, o.placed_at::date AS placed, o.total_amount, c.name, c.city
FROM   orders o
JOIN   customers c ON c.id = o.customer_id
ORDER  BY o.id
LIMIT  5;
```

```text
 id |   placed   | total_amount |      name      |    city
----+------------+--------------+----------------+-------------
  1 | 2026-06-04 |       622.51 | Anita Sheikh   | Mysuru
  2 | 2026-06-11 |      1973.12 | Lakshmi Gupta  | Kochi
  3 | 2024-03-28 |      2673.55 | Divya Desai    | Ahmedabad
  4 | 2024-05-27 |      2442.23 | Rajesh Sheikh  | Bhubaneswar
  5 | 2024-05-22 |       714.38 | Karthik Shetty | Mumbai
(5 rows)

```

`JOIN` alone means `INNER JOIN`; the word `INNER` is noise and I do not write it. Alias
every table and qualify every column — not for brevity, but because
`SELECT id FROM orders JOIN customers ON customers.id = orders.customer_id` fails with
`column reference "id" is ambiguous`, and the day it stops failing is the day someone
drops a column and your query silently starts reading the other table's.

Now the part that gets skipped. **An inner join is also a filter.** A row with no partner
is gone, and no count says so unless you ask.

```sql
SELECT count(*) AS joined_rows, count(DISTINCT c.id) AS customers_represented
FROM   orders o JOIN customers c ON c.id = o.customer_id;
```

```text
 joined_rows | customers_represented
-------------+-----------------------
        2500 |                   803
(1 row)

```

2,500 rows in and 2,500 out, because `orders.customer_id` is `NOT NULL` and carries a
foreign key, so every order has exactly one customer — a *guarantee from the schema*, not
an observation about today's data, and the only reason this join is safe. But 803, not
1,000. Build a customer report this way and 197 customers disappear: the ones who never
ordered, frequently the segment the report was commissioned to find.

## 9.3 Cardinality, and the three-million-rupee mistake

The whole chapter in one pair of queries. `orders` has 2,500 rows.

```sql
SELECT count(*) AS joined_rows
FROM   orders o JOIN order_items oi ON oi.order_id = o.id;
```

```text
 joined_rows
-------------
        6250
(1 row)

```

The join did not filter. It **multiplied**. Every order is paired with each of its line
items, and 6,250 is exactly the row count of `order_items`, because each line item has
precisely one parent order. Look at one order:

```sql
SELECT o.id, o.total_amount, oi.product_id, oi.quantity
FROM   orders o
JOIN   order_items oi ON oi.order_id = o.id
WHERE  o.id = 4
ORDER  BY oi.id;
```

```text
 id | total_amount | product_id | quantity
----+--------------+------------+----------
  4 |      2442.23 |        108 |        3
  4 |      2442.23 |        150 |        1
  4 |      2442.23 |        100 |        4
  4 |      2442.23 |         12 |        4
(4 rows)

```

Order 4 has four lines, so `total_amount` — an *order-level* fact — appears four times.
Nothing is duplicated in the data. The query asked for one row per line item, and 2442.23
is the honest answer to "what is this line's order total" four times over. Now sum it.

```sql
SELECT sum(total_amount) AS revenue FROM orders;

SELECT sum(o.total_amount) AS revenue
FROM   orders o JOIN order_items oi ON oi.order_id = o.id;
```

```text
  revenue
------------
 3678982.61
(1 row)

   revenue
-------------
 11138789.39
(1 row)

```

Three times the company's revenue, from a join to a table whose columns the query never
displays. No error, no warning, and a number of exactly the right shape to survive a
review, a dashboard and a board meeting — I have watched it survive all three.

**The rule, worth memorising in this form:** the output cardinality of a join is, for each
left row, the number of right rows that match it, summed over the left side. If that
number is always one, the join is safe and behaves like the "combining" people imagine. If
it is ever more than one, every left-side column is *replicated* and every aggregate over
one is inflated. Chain two such joins and the factors multiply, which is how a three-table
report reaches fifteen times the truth.

### The inflation factor is not the average fan-out

The obvious repair — divide by 2.5, the average lines per order — is wrong, and this is
the part that catches experienced people.

```sql
SELECT n_items, count(*) AS orders, round(avg(total_amount), 2) AS avg_order
FROM   (SELECT o.id, o.total_amount, count(*) AS n_items
        FROM   orders o JOIN order_items oi ON oi.order_id = o.id
        GROUP  BY o.id, o.total_amount) t
GROUP  BY n_items
ORDER  BY n_items;
```

```text
 n_items | orders | avg_order
---------+--------+-----------
       1 |    644 |    569.28
       2 |    611 |   1158.12
       3 |    596 |   1781.99
       4 |    649 |   2377.02
(4 rows)

```

Rows inflated by 6250 / 2500 = **2.50**. Money inflated by 11138789.39 / 3678982.61 =
**3.03**. The two differ because big orders have more lines, so the duplication is
*correlated with the measure* — each order is counted once per line, which weights large
orders more heavily. You cannot recover the true figure by arithmetic. Fix the query.

> **In production —** make the diagnostic reflexive. Run `count(*)` before you add a join
> and again after. If the number moved, know which direction and why: up means fan-out and
> your aggregates are suspect; down means an inner join dropped rows and your population
> is smaller than you think. Anything else — `DISTINCT` to tidy the row count,
> `sum(DISTINCT x)` to tidy the total — is a bandage over an undiagnosed injury. Practice
> Session 6.3 measured what `DISTINCT` costs; Practice Session 9.4 takes this query apart
> and repairs it two ways.

The correct answers are one-liners once you know the grain. Order-level revenue comes
from `orders` alone; line-level revenue from `order_items` alone:

```sql
SELECT sum(oi.quantity * oi.unit_price) AS revenue FROM order_items oi;
```

```text
  revenue
------------
 3678982.61
(1 row)

```

To the paisa. **Decide what one row of your result means before you write `FROM`.** Almost
every fan-out bug is a query whose author never settled that and let the join decide.

## 9.4 Outer joins

An outer join keeps rows that found no partner, filling the missing side with NULLs. Set
`\pset null '(null)'` — Chapter 2 asked you to, and here it is the difference between
reading output and guessing at it.

```sql
SELECT c.id, c.name, o.id AS order_id, o.status, o.total_amount
FROM   customers c
LEFT   JOIN orders o ON o.customer_id = c.id
WHERE  c.id BETWEEN 16 AND 19
ORDER  BY c.id, o.id;
```

```text
 id |      name       | order_id |  status   | total_amount
----+-----------------+----------+-----------+--------------
 16 | Karthik Sheikh  |     1575 | shipped   |      1789.74
 16 | Karthik Sheikh  |     2088 | shipped   |       467.52
 16 | Karthik Sheikh  |     2214 | paid      |      1034.50
 16 | Karthik Sheikh  |     2341 | delivered |       402.06
 17 | Aditya Banerjee |   (null) | (null)    |       (null)
 18 | Anita Singh     |   (null) | (null)    |       (null)
 19 | Ananya Rao      |     1850 | pending   |       148.80
(7 rows)

```

Customers 17 and 18 survive with no orders, NULL-extended across every `orders` column.
Unfiltered, the join returns 2,697 rows: 2,500 matched plus 197 unmatched. And a
`LEFT JOIN` fans out exactly like an inner one — customer 16 is still four rows.

Two consequences, both graded in Practice Session 9.2. The **anti-join**: add
`WHERE o.id IS NULL` and you keep only the NULL-extended rows — the customers who never
ordered. And `count(*)` is now a lie, because a NULL-extended row is still a row, so a
customer with no orders scores 1. Use `count(o.id)`. Chapter 8's rule, cashing in.

### The predicate that silently deletes your outer join

The most common outer-join bug there is, and invisible in code review.

```sql
SELECT count(*) AS rows FROM customers c
LEFT   JOIN orders o ON o.customer_id = c.id
WHERE  o.status = 'delivered';

SELECT count(*) AS rows FROM customers c
LEFT   JOIN orders o ON o.customer_id = c.id
AND    o.status = 'delivered';
```

```text
 rows
------
  963
(1 row)

 rows
------
 1393
(1 row)

```

`ON` decides **which rows pair up**. `WHERE` filters **the result of the join**, after
NULL-extension. A NULL-extended row has `o.status` NULL, `NULL = 'delivered'` is unknown,
and Chapter 7's rule discards it — so the first query is an inner join wearing the word
`LEFT`. The second keeps all 1,000 customers: 963 matched rows plus 430 customers with no
delivered order.

**On an outer join, conditions on the optional side belong in `ON`.** Conditions on the
preserved side mean the same thing in either place — which is why people learn the wrong
habit and get bitten later.

### `RIGHT JOIN`

`RIGHT JOIN` preserves the *right* table. It is standard, and I have not written one
deliberately in years.

```sql
SELECT count(*) FROM orders o RIGHT JOIN customers c ON o.customer_id = c.id;  -- 2697
SELECT count(*) FROM customers c LEFT JOIN orders o ON o.customer_id = c.id;   -- 2697
```

Identical results, and the `LEFT` version reads in the direction the eye moves: the
preserved table is already on the page. A `RIGHT JOIN` makes you hold the whole `FROM`
clause in your head to know which side is optional, and in a five-table query mixing both
directions nobody does. Write `LEFT` and reorder the tables.

### `FULL OUTER JOIN`

`FULL JOIN` preserves both sides. Its one common use is reconciling two sets where either
may hold something the other does not — which products sold in January but not February,
and the reverse:

```sql
WITH jan AS (SELECT oi.product_id, sum(oi.quantity) AS units
             FROM   orders o JOIN order_items oi ON oi.order_id = o.id
             WHERE  o.placed_at >= DATE '2026-01-01' AND o.placed_at < DATE '2026-02-01'
             GROUP  BY 1),
     feb AS (SELECT oi.product_id, sum(oi.quantity) AS units
             FROM   orders o JOIN order_items oi ON oi.order_id = o.id
             WHERE  o.placed_at >= DATE '2026-02-01' AND o.placed_at < DATE '2026-03-01'
             GROUP  BY 1)
SELECT coalesce(jan.product_id, feb.product_id) AS product_id,
       jan.units AS jan_units, feb.units AS feb_units
FROM   jan FULL JOIN feb ON feb.product_id = jan.product_id
WHERE  jan.product_id IS NULL OR feb.product_id IS NULL
ORDER  BY product_id LIMIT 6;
```

```text
 product_id | jan_units | feb_units
------------+-----------+-----------
          3 |         7 |    (null)
          7 |        10 |    (null)
          9 |         2 |    (null)
         10 |    (null) |         3
         11 |    (null) |         3
         12 |        15 |    (null)
(6 rows)

```

Forty-nine products sold in January and not February, thirty-eight the reverse, eighty-
seven in both. The `coalesce` is not decoration: on a full join *either* side's key can be
NULL, so `SELECT jan.product_id` alone blanks out half the report.

## 9.5 `ON`, `USING`, and why `NATURAL` is a trap

**`ON`** takes any boolean expression — usually an equality on a foreign key, but a range,
an inequality or several conditions all work. It is the only form that always works and
the one to default to.

**`USING (col)`** is shorthand for an equality on identically-named columns, and it
**merges** them into one output column, so `SELECT *` returns a single `dept_id` rather
than two. A real convenience, and unavailable in `retail`, which names the child column
`customer_id` and the parent `id`. `USING` rewards a naming convention you either have or
do not.

**`NATURAL JOIN`** takes no condition at all: it joins on *every* column the two tables
share by name. The condition is therefore written nowhere in your query, and is computed
from the current schema, silently. Both halves of that sentence are the problem.

`retail` shows the first immediately. `customers` and `orders` share exactly one column
name — `id`, each table's own primary key:

```sql
SELECT count(*) FROM customers NATURAL JOIN orders;
SELECT id, name, status, total_amount FROM customers NATURAL JOIN orders ORDER BY id LIMIT 4;
```

```text
 count
-------
  1000
(1 row)

 id |      name       |  status   | total_amount
----+-----------------+-----------+--------------
  1 | Imran Reddy     | returned  |       622.51
  2 | Rohit Kumar     | delivered |      1973.12
  3 | Sneha Sheikh    | paid      |      2673.55
  4 | Sneha Mukherjee | delivered |      2442.23
(4 rows)

```

It joined `customers.id = orders.id`, which is meaningless, and returned a thousand rows
of confident nonsense. Order 1 belongs to customer 610; this attributes it to customer 1.
No error, and the shape looks right.

The second problem is worse because it arrives later. In a scratch database, build a
schema where `NATURAL` does the right thing — two tables sharing only `dept_id`:

```sql
CREATE TABLE departments (dept_id int PRIMARY KEY, dept_name text);
CREATE TABLE employees (emp_id int PRIMARY KEY, emp_name text, dept_id int);
INSERT INTO departments VALUES (1, 'Platform'), (2, 'Finance');
INSERT INTO employees VALUES (1, 'Harpreet Singh', 1), (2, 'Meera Banerjee', 2),
                             (3, 'Arjun Iyer', 1);

SELECT * FROM employees NATURAL JOIN departments ORDER BY emp_id;
```

```text
 dept_id | emp_id |    emp_name    | dept_name
---------+--------+----------------+-----------
       1 |      1 | Harpreet Singh | Platform
       2 |      2 | Meera Banerjee | Finance
       1 |      3 | Arjun Iyer     | Platform
(3 rows)

```

Correct. Now a migration adds an audit column to every table — an ordinary Tuesday:

```sql
ALTER TABLE employees   ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE departments ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();

SELECT * FROM employees NATURAL JOIN departments ORDER BY emp_id;
```

```text
 dept_id | updated_at | emp_id | emp_name | dept_name
---------+------------+--------+----------+-----------
(0 rows)

```

The condition became `dept_id AND updated_at` and the report returned nothing. The
`USING (dept_id)` version still returns three rows, because it says what it joins on.

> **Trap —** `NATURAL JOIN` makes your query's correctness depend on every future
> `ALTER TABLE` anyone runs on either table, and fails silently in both directions: a new
> shared column and rows vanish, a renamed column and the condition quietly weakens. Never
> ship it.

## 9.6 Self-joins

Joining a table to itself needs nothing but two aliases. `hr.employees` points at itself
through `manager_id`:

```sql
SELECT e.emp_id, e.full_name AS employee, e.job_title, m.full_name AS manager
FROM   employees e
LEFT   JOIN employees m ON m.emp_id = e.manager_id
ORDER  BY e.emp_id
LIMIT  6;
```

```text
 emp_id |     employee      |        job_title        |   manager
--------+-------------------+-------------------------+--------------
      1 | Ananya Reddy      | Chief Executive Officer | (null)
      2 | Sneha Reddy       | Senior Vice President   | Ananya Reddy
      3 | Nisha Kulkarni    | Senior Vice President   | Ananya Reddy
      4 | Fatima Chatterjee | Senior Vice President   | Ananya Reddy
      5 | Lakshmi Gupta     | Senior Vice President   | Ananya Reddy
      6 | Vikram Singh      | Senior Vice President   | Ananya Reddy
(6 rows)

```

`LEFT` is load-bearing. `manager_id` is NULL for exactly one row, so the inner version
returns 2,773 of 2,774 employees and the missing one is the chief executive — an
off-by-one that survives every test written by someone who checked the count looked
plausible.

Each self-join climbs exactly one level: two give you the skip-level manager, six the
whole chain here, and no fixed *n* answers "everyone under Ananya Reddy". Arbitrary depth
needs `WITH RECURSIVE`, Chapter 12. Practice Session 9.3 walks all seven levels by hand
first, so the recursive version later reads as a simplification rather than magic.

## 9.7 `LATERAL`

Every join so far combined two independent row sources. `LATERAL` lets the right-hand
subquery see the current left row, turning a `FROM` item into something evaluated *per
row*. Without it the reference is rejected:

```sql
SELECT c.name, r.id
FROM   customers c,
       (SELECT o.id FROM orders o WHERE o.customer_id = c.id LIMIT 2) r;
```

```text
ERROR:  invalid reference to FROM-clause entry for table "c"
LINE 4: ... (SELECT o.id FROM orders o WHERE o.customer_id = c.id LIMIT...
                                                             ^
HINT:  There is an entry for table "c", but it cannot be referenced from this part of the query.
```

Add the keyword and the same subquery is legal. This is the clean answer to **top N per
group** — a question ordinary joins cannot express, because `LIMIT` applies to the whole
result, not per group. Two most recent orders per customer in Mysuru:

```sql
SELECT c.name, r.id AS order_id, r.placed_at::date AS placed, r.total_amount
FROM   customers c
CROSS  JOIN LATERAL (SELECT o.id, o.placed_at, o.total_amount
                     FROM   orders o
                     WHERE  o.customer_id = c.id
                     ORDER  BY o.placed_at DESC
                     LIMIT  2) r
WHERE  c.city = 'Mysuru'
ORDER  BY c.id, r.placed_at DESC
LIMIT  8;
```

```text
       name        | order_id |   placed   | total_amount
-------------------+----------+------------+--------------
 Rohit Kumar       |     1396 | 2026-06-07 |       348.72
 Rohit Kumar       |      289 | 2026-05-10 |      1061.90
 Ananya Banerjee   |     1045 | 2025-09-23 |      1086.70
 Ananya Banerjee   |     1307 | 2025-04-22 |      2189.97
 Farhan Chatterjee |     2310 | 2025-05-29 |       403.54
 Ananya Nair       |        6 | 2025-10-05 |      2059.48
 Vikram Rao        |     1184 | 2025-07-29 |      1912.19
 Vikram Rao        |     1944 | 2024-03-04 |       964.90
(8 rows)

```

Farhan Chatterjee and Ananya Nair contribute one row each, having only one order. The
fan-out is **bounded by you** — at most two per customer, by construction — which makes
`LATERAL` the safe way to attach children to a parent.

`CROSS JOIN LATERAL` drops left rows whose subquery returned nothing, exactly as an inner
join would. To keep them, write `LEFT JOIN LATERAL (...) r ON true`: the `ON true` is
required syntax rather than a placeholder, and it restores the NULL-extension of section
9.4.

Most people meet this problem and reach instead for a correlated subquery in the select
list — one per output column, each re-scanning the child table. Chapter 10 covers that
form. `LATERAL` gets every column from one evaluation.

## 9.8 The order you write is not the order it runs

Write a four-table query customers → orders → order_items → products, filtered on
`p.category = 'lighting'` and `c.city = 'Mysuru'`, and run `EXPLAIN (COSTS OFF)` over it.
On this data PostgreSQL 15.10 starts with a `Hash Join` between `order_items` and
`products` — the pair you wrote *last* — then joins that to a separate
`customers`/`orders` hash.

Inner joins are associative and commutative, so the planner enumerates orderings, costs
them and picks one; the order you typed is not among its inputs. Rearranging `FROM` to
"help" achieves nothing.

Two caveats. Outer joins are *not* freely reorderable, so a `LEFT JOIN` mid-chain
constrains the planner in ways an inner join does not. And the enumeration is bounded:
past `join_collapse_limit` tables — 8 by default — PostgreSQL stops searching
exhaustively, at which point written order does begin to matter. Reading those plans is
Chapter 34, *Deep Dive: EXPLAIN*.

## 9.9 What is not in this chapter

`EXISTS`, `IN`, `NOT EXISTS` and correlated subqueries express *semi-joins* and
*anti-joins* — "does a matching row exist" without producing one — and are the right tool
for several problems this chapter solved clumsily: Chapter 10. `UNION`, `INTERSECT` and
`EXCEPT` stack results vertically rather than widening them, and `EXCEPT` often beats
section 9.4's `FULL JOIN` for reconciliation: Chapter 11. Recursive hierarchy walking is
Chapter 12; `row_number() OVER (PARTITION BY ...)`, the other answer to top-N per group,
is Chapter 25. Nested loop, hash and merge joins: Chapter 34.

---

## Summary

- A join is a **filtered Cartesian product**, not a merge. Model it that way and row
  counts stop surprising you. `CROSS JOIN` is the unfiltered case, and manufactures a
  complete reporting grid that `GROUP BY` alone cannot.
- **Cardinality is the whole game.** Output rows = for each left row, the number of
  matching right rows. One-to-many replicates left-side columns and every aggregate over
  them inflates silently: `sum(total_amount)` over `orders` is 3,678,982.61; joined to
  `order_items` it is 11,138,789.39.
- The inflation factor is **not** the average fan-out — 3.03 against 2.50 rows — because
  duplication correlates with order size. You cannot divide your way out.
- Run `count(*)` before and after adding a join. Up means fan-out; down means an inner
  join dropped rows — `customers` joined to `orders` loses the 197 who never ordered.
  Decide what one result row means before writing `FROM`.
- On an outer join, conditions on the **optional** side go in `ON`. In `WHERE` they
  discard NULL-extended rows and turn it back into an inner join, with nothing to warn
  you. Count with `count(col)`, not `count(*)`.
- `RIGHT JOIN` is a `LEFT JOIN` written backwards; swap the tables. `FULL JOIN` earns its
  place in reconciliation, where you must `coalesce` the key.
- `ON` always; `USING` when the names line up. **Never `NATURAL`** — its condition comes
  from the live schema, so an audit column added to two tables turns three rows into zero,
  and a shared `id` column joins two primary keys to each other.
- Self-joins need two aliases and `LEFT`, so the root row survives. Each climbs one level;
  unbounded depth is Chapter 12.
- `LATERAL` lets the right side see the current left row — the direct answer to top-N per
  group, with a fan-out you bound.
- The planner reorders inner joins freely and ignores the order you typed, up to
  `join_collapse_limit`. Chapter 34.

**Exercises:** Practice Sessions 9.1–9.4 accompany this chapter and are in the workbook
at the back of the book.

**Next:** Chapter 10 asks the question a join answers badly — *does a matching row exist?*
It covers scalar, derived and correlated subqueries, `EXISTS` against `IN`, and the
`NOT IN` trap that returns zero rows when one NULL is present.
