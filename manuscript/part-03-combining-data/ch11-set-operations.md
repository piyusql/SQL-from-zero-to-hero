# Chapter 11 — Set Operations

Joins widen a row and subqueries decide whether to keep one. Set operations do neither.
They take two result sets that already have the same shape and stack, intersect or
subtract them — combining *vertically* where a join combines horizontally.

This is a short chapter because the syntax is an hour's work. The interesting part is
everything around it: a default that costs you a sort you never asked for, `ORDER BY` and
`LIMIT` that do not attach where people assume, chaining rules that quietly change the
answer, and a NULL rule that flatly contradicts the one Chapter 7, *Filtering, Operators,
and Three-Valued Logic*, spent a chapter teaching.

---

## 11.1 The four operators

Every set operation takes the form *query* **operator** *query*. `UNION` stacks,
`INTERSECT` keeps rows in both, `EXCEPT` keeps rows in the left that are not in the right.
Each has a plain form that removes duplicates and an `ALL` form that does not.

Stacking first. Two slices of `orders`, tagged so you can tell them apart in the output:

```sql
SELECT 'open'   AS bucket, id, total_amount FROM orders WHERE status IN ('pending','paid')
UNION ALL
SELECT 'closed' AS bucket, id, total_amount FROM orders WHERE status IN ('delivered','returned')
ORDER  BY bucket, id
LIMIT  6;
```

```text
 bucket | id | total_amount
--------+----+--------------
 closed |  1 |       622.51
 closed |  2 |      1973.12
 closed |  4 |      2442.23
 closed |  5 |       714.38
 closed |  7 |      1623.73
 closed |  9 |      1113.94
(6 rows)

```

`INTERSECT` and `EXCEPT` are where the operators earn their place. Take the discount codes
appearing on high-value cancelled orders and on high-value delivered ones. From now on the
outputs contain NULLs, so set `\pset null '(null)'` as Chapter 2 instructed — a blank cell
and a genuine empty string are indistinguishable otherwise.

```sql
SELECT discount_code FROM orders WHERE status = 'cancelled' AND total_amount > 4000
INTERSECT
SELECT discount_code FROM orders WHERE status = 'delivered' AND total_amount > 4000;
```

```text
 discount_code
---------------
 (null)
(1 row)

```

```sql
SELECT discount_code FROM orders WHERE status = 'delivered' AND total_amount > 4000
EXCEPT
SELECT discount_code FROM orders WHERE status = 'cancelled' AND total_amount > 4000
ORDER  BY 1;
```

```text
 discount_code
---------------
 DIWALI25
 FREESHIP
(2 rows)

```

Hold on to that first result. We come back to it in section 11.4, because it should not be
possible.

### What `ALL` changes

Without `ALL`, all three operators collapse duplicates — including duplicates that were
already present inside a single branch, before anything was combined. With `ALL`, they
count. `EXCEPT ALL` subtracts *occurrences*: a row appearing three times on the left and
once on the right survives twice. `INTERSECT ALL` keeps the smaller of the two
multiplicities.

```sql
SELECT code FROM (VALUES ('DIWALI25'),('DIWALI25'),('DIWALI25'),('VIP15')) AS a(code)
EXCEPT ALL
SELECT code FROM (VALUES ('DIWALI25'),('VIP15'),('VIP15')) AS b(code);
```

```text
   code
----------
 DIWALI25
 DIWALI25
(2 rows)

```

Three `DIWALI25` minus one leaves two; one `VIP15` minus two leaves none rather than minus
one. Plain `EXCEPT` on the same input returns zero rows, because as *sets* the left side
is `{DIWALI25, VIP15}` and so is the right. `INTERSECT ALL` returns `DIWALI25` once and
`VIP15` once — `min(3,1)` and `min(1,2)`.

The `ALL` variants are rare in application code and invaluable in reconciliation, where
"this row appears twice on one side and once on the other" is exactly the duplicate-key
bug you are hunting.

## 11.2 The compatibility rules

Two rules, both enforced at parse time, plus a third that is not enforced at all.

**Same number of columns.**

```sql
SELECT id, status FROM orders UNION ALL SELECT id FROM orders;
```

```text
ERROR:  each UNION query must have the same number of columns
LINE 1: SELECT id, status FROM orders UNION ALL SELECT id FROM order...
                                                       ^
```

**Compatible types, column by column.** Compatible is looser than identical: PostgreSQL
resolves a common type the same way it does for `CASE`, so `integer` and `numeric` unify
to `numeric`, and a bare string literal takes the type of whatever it is stacked against.
What it will not do is invent a conversion between unrelated types.

```sql
SELECT id FROM orders UNION ALL SELECT name FROM customers;
```

```text
ERROR:  UNION types integer and text cannot be matched
LINE 1: SELECT id FROM orders UNION ALL SELECT name FROM customers;
                                               ^
```

**Columns match by position, never by name** — and this is the one that ships. Column
names come from the first branch; every later branch contributes values only, and its own
labels are discarded without comment.

```sql
SELECT city AS a, country AS b FROM customers WHERE id = 1
UNION ALL
SELECT country, city FROM customers WHERE id = 1;
```

```text
   a   |   b
-------+-------
 Kochi | AE
 AE    | Kochi
(2 rows)

```

> **Trap —** both columns are `text`, so nothing errors and the branches are transposed in
> silence. This is how a nightly load ends up with country codes in the city column. Write
> the select lists of a wide `UNION` one column per line and vertically aligned, so a diff
> shows the mismatch, and never rely on `SELECT *` matching across two tables.

## 11.3 `UNION ALL` is the default you should reach for

`UNION` is not "`UNION ALL` plus tidiness". It is `UNION ALL` followed by a full
deduplication of the combined result, which means sorting or hashing every row that came
out of both branches. You pay for that whether or not there were any duplicates to find,
and most of the time there were not — the branches are disjoint by construction, because
you wrote the predicates that made them disjoint.

Here it is on the large `retail` variant: two million orders, the `delivered` slice
stacked on the `shipped` slice. A given order has one status, so the two sets cannot
overlap.

```sql
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT id, customer_id, total_amount FROM orders WHERE status = 'delivered'
UNION ALL
SELECT id, customer_id, total_amount FROM orders WHERE status = 'shipped';
```

```text
 Append (actual rows=1199578 loops=1)
   ->  Seq Scan on orders (actual rows=799986 loops=1)
         Filter: (status = 'delivered'::text)
         Rows Removed by Filter: 1200014
   ->  Seq Scan on orders orders_1 (actual rows=399592 loops=1)
         Filter: (status = 'shipped'::text)
         Rows Removed by Filter: 1600408
 Planning Time: 0.141 ms
 Execution Time: 232.644 ms
```

Change one word:

```sql
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT id, customer_id, total_amount FROM orders WHERE status = 'delivered'
UNION
SELECT id, customer_id, total_amount FROM orders WHERE status = 'shipped';
```

```text
 Unique (actual rows=1199578 loops=1)
   ->  Sort (actual rows=1199578 loops=1)
         Sort Key: orders.id, orders.customer_id, orders.total_amount
         Sort Method: external merge  Disk: 29352kB
         ->  Append (actual rows=1199578 loops=1)
               ->  Seq Scan on orders (actual rows=799986 loops=1)
                     Filter: (status = 'delivered'::text)
                     Rows Removed by Filter: 1200014
               ->  Seq Scan on orders orders_1 (actual rows=399592 loops=1)
                     Filter: (status = 'shipped'::text)
                     Rows Removed by Filter: 1600408
 Planning Time: 0.144 ms
 Execution Time: 457.429 ms
```

Approximately 210 ms against approximately 440 ms across repeated runs on the machine this
book was written on — a little over twice the work, in that order on every run. Absolute
numbers will differ on your hardware; the ratio is the point.

Read the plan rather than the clock, because the plan says why. `Append` is the whole of
the first query: read one branch, then the other, emit. The second grows a `Sort` and a
`Unique` on top, and the `Sort` reports `Sort Method: external merge  Disk: 29352kB` — 1.2
million rows did not fit in the default 4 MB `work_mem`, so the sort ran on disk. Read
`Disk:` as the *peak* tape size rather than the total: run the same plan with `BUFFERS`
and it reports `temp read=7333 written=7356`, which at 8 kB a block is roughly 57 MB
written and 57 MB read back across the merge passes. Practice Session 11.2 quotes those
counters in full.

Then the line that should settle it: **`actual rows=1199578` on both plans.** The dedup
removed zero rows, for 57 MB of temporary writes and half the runtime.

> **In production —** most people write `UNION` because `UNION ALL` looks like the special
> case. It is the other way round. Write `UNION ALL` unless you can say where the
> duplicates come from; if you can say it, remove them at the source, since a `DISTINCT`
> inside one branch deduplicates a smaller input than a `UNION` over the combined result.

Raising `work_mem` is not the fix. It removes the spill and, on this data, leaves the
query *slower* still — Practice Session 11.2 measures that, and Chapter 45, *Configuration
and Resource Tuning*, covers sizing the setting properly.

## 11.4 NULLs are equal here. They are equal nowhere in Chapter 7

Return to that `INTERSECT` from section 11.1, which returned one row containing `(null)`.
For a row to survive an `INTERSECT`, it must match a row on the other side. So two NULLs
matched.

Chapter 7 was emphatic that they cannot. Write the same question as a join and PostgreSQL
agrees with Chapter 7:

```sql
SELECT count(*) FROM
  (SELECT discount_code FROM orders WHERE status = 'cancelled' AND total_amount > 4000) a
JOIN
  (SELECT discount_code FROM orders WHERE status = 'delivered' AND total_amount > 4000) b
  ON a.discount_code = b.discount_code;
```

```text
 count
-------
     0
(1 row)

```

Same data, same intent, opposite answers: `NULL = NULL` is `unknown`, so the join keeps
nothing, while `INTERSECT` treats the two NULLs as the same row. The rule in its simplest
form:

```sql
SELECT NULL AS a UNION SELECT NULL;
```

```text
   a
--------
 (null)
(1 row)

```

One row, not two. Set operations do not compare with `=`. They use the *not distinct from*
relation — the same semantics as the `IS NOT DISTINCT FROM` operator — under which two
NULLs are the same value and a NULL differs from everything else. `DISTINCT`, `GROUP BY`
(Chapter 8, *Aggregation and Grouping*) and `PARTITION BY` use it too.

So SQL has two notions of sameness and gives you no syntactic warning about which one is
in force. **Equality is three-valued and lives in `WHERE`, `ON` and `CASE`. Grouping
equivalence is two-valued and lives in `DISTINCT`, `GROUP BY`, `PARTITION BY` and every
set operation.** That is an inconsistency in the language, not a subtlety you failed to
grasp, and naming it is the only defence; the rule cannot be derived from anything else
you know.

It is also the one place the inconsistency works in your favour. Comparing two sources
column by column with `=` mishandles every nullable column, and the usual fix is a chain
of `IS NOT DISTINCT FROM` in the join condition. `EXCEPT` has that behaviour built in —
which is section 11.6.

## 11.5 `ORDER BY`, `LIMIT`, and what binds to what

A trailing `ORDER BY` or `LIMIT` belongs to the **whole combined result**, never to the
branch it sits next to. That reads as obvious on the page and is misread constantly,
because the clause is physically adjacent to the last `SELECT`.

Suppose you want the two largest pending orders and the two largest paid ones:

```sql
SELECT id, total_amount FROM orders WHERE status = 'pending'
UNION ALL
SELECT id, total_amount FROM orders WHERE status = 'paid'
ORDER  BY total_amount DESC
LIMIT  4;
```

```text
  id  | total_amount
------+--------------
  712 |      5620.14
 1126 |      5447.92
  711 |      4825.24
 2141 |      4601.59
(4 rows)

```

Four rows, so it looks right. It is not: 1126, 711 and 2141 are `pending` and only 712 is
`paid`. This is the top four *overall*, and a branch with uniformly smaller values can
vanish from the output entirely without anything announcing it.

Per-branch sorting and limiting needs parentheses, which make each branch a complete query
with its own `ORDER BY` and `LIMIT`:

```sql
(SELECT id, total_amount FROM orders WHERE status = 'pending' ORDER BY total_amount DESC LIMIT 2)
UNION ALL
(SELECT id, total_amount FROM orders WHERE status = 'paid'    ORDER BY total_amount DESC LIMIT 2);
```

```text
  id  | total_amount
------+--------------
 1126 |      5447.92
  711 |      4825.24
  712 |      5620.14
 1680 |      4346.98
(4 rows)

```

Different rows — 1680 in place of 2141 — and now correct. Note also that the result is not
in descending order overall: each branch was sorted, then the branches were concatenated.
A combined ordering needs a further `ORDER BY` outside the parentheses.

Two smaller rules follow from the same place. Writing a branch's `ORDER BY` *without*
parentheses is a syntax error rather than a silent reinterpretation, which is one mercy.
And the trailing `ORDER BY` sees only the *output* columns of the combined result, named
after the first branch — sort `SELECT id ... UNION ALL SELECT id ...` by `total_amount`
and you get `ERROR:  column "total_amount" does not exist`, even though the column exists
in the table, because by then there is one result set with one column in it. Add the
column to every branch, or sort by ordinal.

### Chaining: `INTERSECT` binds tighter

`UNION` and `EXCEPT` have equal precedence and associate left to right. `INTERSECT` binds
tighter than both, exactly as `*` binds tighter than `+`. Three sets of discount codes:

```sql
SELECT discount_code FROM orders WHERE status = 'cancelled' AND total_amount > 4000
UNION
SELECT discount_code FROM orders WHERE status = 'delivered' AND total_amount > 4000
INTERSECT
SELECT discount_code FROM orders WHERE status = 'shipped'   AND total_amount > 4000
ORDER  BY 1;
```

```text
 discount_code
---------------
 FREESHIP
 VIP15
 (null)
(3 rows)

```

Read left to right, that is "cancelled or delivered, then keep only what also shipped",
which would be two rows. The `INTERSECT` ran first, so what you actually got is
"cancelled, plus whatever delivered and shipped have in common". Parenthesise to get the
other reading:

```sql
(SELECT discount_code FROM orders WHERE status = 'cancelled' AND total_amount > 4000
 UNION
 SELECT discount_code FROM orders WHERE status = 'delivered' AND total_amount > 4000)
INTERSECT
SELECT discount_code FROM orders WHERE status = 'shipped'    AND total_amount > 4000
ORDER  BY 1;
```

```text
 discount_code
---------------
 FREESHIP
 (null)
(2 rows)

```

> **Trap —** three rows against two, no error, no warning. `EXCEPT` chained after `UNION`
> is worse, because there the trap is left-associativity: `A UNION B EXCEPT C` subtracts
> `C` from both, which is rarely what the author meant. Parenthesise every chain of three
> or more branches, even where the default grouping happens to be the one you want. You
> are writing for the person who adds a fourth branch.

## 11.6 `EXCEPT` as a reconciliation tool

This is the operator's best use. Two systems claim to hold the same facts and you want the
rows where they disagree, in both directions — one statement, any number of columns, NULL
handling already correct. `retail` keeps a denormalised `orders.total_amount` alongside
the `order_items` it should equal, so reconcile those:

```sql
SELECT o.id, o.total_amount FROM orders o
EXCEPT
SELECT oi.order_id, sum(oi.quantity * oi.unit_price) FROM order_items oi GROUP BY oi.order_id;
```

```text
 id | total_amount
----+--------------
(0 rows)

```

Zero rows means every `(id, total_amount)` pair in `orders` has a match in the computed
totals. It does **not** mean the two agree: `EXCEPT` is directional, and an order line
with no matching order would not appear. Run it the other way as well — also zero rows
here — and the pair of results is a proof of agreement rather than a hopeful sign.

Run both directions always, and label the sides so the output of the second is not
mistaken for the output of the first. Practice Session 11.1 builds that report and shows
what a column-by-column join gets wrong on a nullable column.

## 11.7 When a set operator is a symptom

Set operations are easy to overuse, because stacking two queries is the first idea that
arrives and it always works. Two patterns are worth recognising as smells.

**Branches over the same table that differ only in a literal.** Section 11.1's
`open`/`closed` query reads the table twice to attach a label. `CASE` does it in one pass:

```sql
SELECT CASE WHEN status IN ('pending','paid') THEN 'open' ELSE 'closed' END AS bucket,
       count(*)
FROM   orders
WHERE  status IN ('pending','paid','delivered','returned')
GROUP  BY 1;
```

I expected to be able to quote a speedup here and cannot. On the large variant the two
forms run within noise of each other — both around 250 ms across repeated runs, with the
ordering inverting from run to run — because 15.10 plans the `UNION ALL` as a
`Parallel Append` and gives each branch its own worker, so the second scan is very nearly
free. Rewrite to `CASE` for the reasons that survive measurement: one scan instead of two
means half the buffer traffic under concurrency, and the `CASE` version stays one scan
when a fourth and fifth bucket arrive, while the `UNION ALL` version grows a branch and
another full scan each time.

**`INTERSECT` or `EXCEPT` where you wanted a semi-join or an anti-join.** These operators
compare whole rows, so they only answer "which complete rows are missing". The moment you
want *the customers who have no orders* with the customer's name and city in the output,
`EXCEPT` is the wrong shape: you would project both sides down to `id`, then join back to
recover the columns. `NOT EXISTS` (Chapter 10, *Subqueries and EXISTS*) says it directly
and keeps every column of the outer table.

Reach for a set operation when the two inputs genuinely have the same shape and different
origins. Reach for `JOIN`, `CASE` or `EXISTS` when they do not.

---

## Summary

- Set operations combine two result sets vertically. `UNION` stacks, `INTERSECT` keeps
  rows in both, `EXCEPT` keeps rows in the left and not the right. `ALL` on any of them
  switches from set semantics to multiset semantics, counting occurrences rather than
  collapsing them.
- Branches must have the same column count and pairwise-compatible types. They are matched
  **by position, not by name**, and the output takes the first branch's names — transposed
  branches of the same type fail silently.
- **`UNION ALL` is the default; `UNION` is the special case.** Measured on two million
  orders, the dedup roughly doubled runtime — about 440 ms against 210 ms — and spilled
  roughly 57 MB of temporary files to remove exactly zero duplicate rows. Write `UNION`
  only when you can say where the duplicates come from.
- **Set operations treat NULLs as equal**, using `IS NOT DISTINCT FROM` semantics rather
  than `=`. `SELECT NULL UNION SELECT NULL` returns one row, and an `INTERSECT` can return
  a NULL row where the equivalent join returns nothing. This contradicts Chapter 7 and
  matches Chapter 8's `GROUP BY`. It is a genuine inconsistency in SQL; learn it as a
  separate rule.
- A trailing `ORDER BY` or `LIMIT` applies to the **combined** result, not the last
  branch, and can only name output columns of the combined result. Per-branch sorting or
  limiting requires parentheses around each branch.
- `INTERSECT` binds tighter than `UNION` and `EXCEPT`, which are left-associative.
  Parenthesise any chain of three or more branches.
- `EXCEPT` in both directions is the cleanest row-level reconciliation in SQL, and its
  NULL handling is already right. Zero rows one way proves nothing; run both.
- A set operator over branches that differ only in a literal usually wants `CASE`; one
  used to find missing or matching rows usually wants `EXISTS` or `NOT EXISTS`.

**Exercises:** Practice Sessions 11.1–11.2 accompany this chapter and are in the
workbook at the back of the book.

**Next:** Chapter 12 gives these stacked and subtracted queries a name. `WITH` turns a set
operation into a readable pipeline, the PostgreSQL 12 inlining change means a CTE is no
longer an optimisation fence by default, and `WITH RECURSIVE` uses `UNION ALL` as the
engine that walks a hierarchy one level at a time — or `UNION`, at a price you can now put
a number on.
