# Chapter 17 — JSONB in Depth

`jsonb` is the best-engineered type PostgreSQL has added since arrays, and the one I have
seen cause the most damage. Both are true for the same reason: it lets you store a shape
you have not agreed on yet.

Chapter 16's arrays, ranges and domains extend the relational model without leaving it.
`jsonb` is different in kind: inside that column the planner has no statistics, the type
system has no opinion, and a misspelled key is not an error.

Set `\pset null '(null)'` before you start, as Chapter 2 asked.

---

## 17.1 `json` and `jsonb` are not two spellings of one type

`json` stores the document **as text**, validating that it parses and then keeping the
bytes. `jsonb` parses it once on input and stores a decomposed binary tree. Everything else
follows from that.

```sql
SELECT '{"b": 1,   "a": 2, "a": 3}'::json  AS as_json,
       '{"b": 1,   "a": 2, "a": 3}'::jsonb AS as_jsonb;
```

```text
          as_json           |     as_jsonb     
----------------------------+------------------
 {"b": 1,   "a": 2, "a": 3} | {"a": 3, "b": 1}
(1 row)
```

`jsonb` discarded the whitespace, reordered the keys, and silently dropped the first `a` —
last duplicate wins. `json` preserved all three.

The binary form is not smaller:

```sql
SELECT pg_column_size('{"b": 1,   "a": 2, "a": 3}'::json)  AS json_bytes,
       pg_column_size('{"b": 1,   "a": 2, "a": 3}'::jsonb) AS jsonb_bytes;
```

```text
 json_bytes | jsonb_bytes 
------------+-------------
         30 |          44
(1 row)
```

`jsonb` pays for random access with a per-key offset table, and here that overhead exceeds
what deduplication saved. Expect it to cost more on disk for small documents. What you buy
is that reading a key is a lookup rather than a parse — `json` re-parses the whole document
on every `->>`, every row, every time.

<!-- BENCHMARK-TODO: ch17_scratch. `ALTER TABLE orders ADD COLUMN attrs_j json; UPDATE orders SET attrs_j = attrs::text::json;` then compare `SELECT count(*) FROM orders WHERE attrs ->> 'channel' = 'app'` with the same over `attrs_j ->> 'channel'`. Ratio = jsonb lookup vs json re-parse. -->

The decisive difference is not size. It is that `jsonb` has an equality operator and `json`
does not:

```sql
SELECT DISTINCT '{"a":1}'::json FROM generate_series(1,2);
```

```text
ERROR:  could not identify an equality operator for type json
LINE 1: SELECT DISTINCT '{"a":1}'::json FROM generate_series(1,2);
                        ^
```

No equality means no `DISTINCT`, no `GROUP BY`, no `UNION`, no unique constraint and no
index of any kind — an opaque blob you can only read whole.

> **In production —** use `jsonb`. Reach for `json` only when you must reproduce the exact
> bytes that arrived: signature verification, or an audit table recording precisely what a
> partner sent. Those are archival columns you never query into.

## 17.2 The dataset, and the operators

The `telemetry` dataset has a `jsonb` payload, but it holds device readings; we want an
application's own data. So: `orders (id, customer_id, placed_at, status, total_amount,
attrs jsonb)`, deliberately familiar from `retail`, with the flexible bits pushed into
`attrs`. That decision is what section 17.6 puts on trial.

The script that builds it and generates 200,000 rows is in the workbook, under Practice
Session 17.3. Every value derives from `md5()` of the row number rather than `random()`, so
the numbers printed here are the numbers you will get. Amounts are INR; 380 orders are
corporate and carry an extra `po_number` key. (One exception: above 30,000 rows `ANALYZE`
samples, so row *estimates* below will differ from yours in the last digits — counts, sizes
and plan shapes will not. Chapter 35.) One document, so you can see the shape:

```sql
SELECT jsonb_pretty(attrs) FROM orders WHERE id = 486;
```

```text
         jsonb_pretty         
------------------------------
 {                           +
     "promo": [              +
         "DIWALI"            +
     ],                      +
     "channel": "store",     +
     "payment": {            +
         "bank": "ICICI",    +
         "method": "wallet"  +
     },                      +
     "delivery": {           +
         "city": "Delhi",    +
         "slot": "evening"   +
     },                      +
     "gift_wrap": false,     +
     "po_number": "PO-700486"+
 }
(1 row)
```

### Extraction

```sql
SELECT attrs -> 'payment'        AS "-> payment",
       attrs ->> 'channel'       AS "->> channel",
       attrs #> '{payment,bank}' AS "#> bank",
       attrs #>> '{promo,0}'     AS "#>> promo[0]",
       attrs -> 'refund'         AS "-> missing"
FROM orders WHERE id = 486;
```

```text
              -> payment               | ->> channel | #> bank | #>> promo[0] | -> missing 
---------------------------------------+-------------+---------+--------------+------------
 {"bank": "ICICI", "method": "wallet"} | store       | "ICICI" | DIWALI       | (null)
(1 row)
```

**Single arrow returns `jsonb`; double arrow returns `text`.** The output shows it: `#> bank`
prints `"ICICI"` with quotes because it is still a JSON string, while `->> channel` prints
bare `store`. `#>` and `#>>` take a path array instead of one key, and an integer in that
path indexes into an array.

Chain with `->` and finish with `->>`: `attrs -> 'payment' ->> 'bank'` works,
`attrs ->> 'payment' -> 'bank'` does not. A missing key yields SQL NULL rather than an error
— convenient, and section 17.6 is about what that convenience costs.

> **Trap —** `->>` returns `text`, so comparing it to a number compares strings.
>
> ```sql
> SELECT '{"n": 9}'::jsonb ->> 'n' > '10'     AS as_text,
>       ('{"n": 9}'::jsonb ->> 'n')::int > 10 AS as_int;
> ```
>
> ```text
>  as_text | as_int 
> ---------+--------
>  t       | f
> (1 row)
> ```
>
> Nine is greater than ten as text and is not as an integer. This silently corrupts any
> threshold filter over a numeric JSON value and is invisible in review. Cast on extraction,
> every time.

### Containment

`@>` asks whether the left document contains the right one, at any depth. It is the
workhorse, because it is what GIN indexes best.

```sql
SELECT '{"a": 1, "b": 2}'::jsonb        @> '{"a": 1}'::jsonb        AS object_subset,
       '{"p": {"q": 1, "r": 2}}'::jsonb @> '{"p": {"q": 1}}'::jsonb AS nested_object,
       '{"t": ["x","y","z"]}'::jsonb    @> '{"t": ["z"]}'::jsonb    AS array_subset,
       '[1, 2, 3]'::jsonb               @> '2'::jsonb               AS scalar_in_array,
       '[[1, 2]]'::jsonb                @> '[1]'::jsonb             AS does_not_nest;
```

```text
 object_subset | nested_object | array_subset | scalar_in_array | does_not_nest 
---------------+---------------+--------------+-----------------+---------------
 t             | t             | t            | t               | f
(1 row)
```

The first four are intuitive: an object contains any subset of its pairs, nesting is
followed, an array contains any subset of its elements, and a top-level array contains a
bare scalar. The last is the exception to memorise — containment does **not** match into a
nested array, so you would need `'[[1]]'`.

### Key existence

```sql
SELECT count(*) FILTER (WHERE attrs ? 'po_number')                     AS has_po,
       count(*) FILTER (WHERE attrs ?| ARRAY['po_number','gift_wrap']) AS has_either,
       count(*) FILTER (WHERE attrs ?& ARRAY['po_number','gift_wrap']) AS has_both,
       count(*) FILTER (WHERE attrs -> 'promo' ? 'DIWALI')             AS diwali
FROM orders;
```

```text
 has_po | has_either | has_both | diwali 
--------+------------+----------+--------
    380 |     200000 |      380 |  24862
(1 row)
```

`?` tests for a **key** at the top level of an object — or, applied to an array, for a
string element, which is the last column. `?|` and `?&` are any-of and all-of. All three
matter in section 17.4: they are what one of the two GIN operator classes cannot serve.

### Modification

Four more, which you will meet in `UPDATE`: `||` merges two documents, `-` removes a
top-level key, `#-` removes a path, and `jsonb_set(doc, path, value)` replaces one value in
place. `||` merges at the **top level only** — concatenating `{"payment": {"bank": "SBI"}}`
replaces the whole `payment` object. Use `jsonb_set` for one key inside it.

> **In production —** all four return a *new document*, so changing one boolean in a 40 kB
> document costs the same write as replacing all 40 kB — the whole row, the TOASTed chunks,
> plus a dead tuple. That is MVCC (Chapter 30), but JSONB is where it hurts, because it
> encourages wide rows updated in pieces.

## 17.3 Path queries

SQL/JSON path is a small query language of its own, and what you want once a condition
stops being "this key equals this value".

```sql
SELECT jsonb_path_query(attrs, '$.promo[*]')             AS each_promo,
       jsonb_path_query_first(attrs, '$.payment.method') AS method,
       jsonb_path_query_array(attrs, '$.delivery.*')     AS delivery_values
FROM orders WHERE id = 486;
```

```text
 each_promo |  method  |   delivery_values    
------------+----------+----------------------
 "DIWALI"   | "wallet" | ["Delhi", "evening"]
(1 row)
```

`$` is the document, `.key` steps into an object, `[*]` iterates an array and `.*` iterates
an object's values. `jsonb_path_query` is set-returning — one row per match, so it
multiplies rows as a join does; `_first` and `_array` collapse that back to one value.

Two operators put a path into a `WHERE` clause: `@?` asks *does this path match anything*,
and `@@` evaluates the path as a **predicate**.

```sql
SELECT count(*) FILTER (WHERE attrs @? '$.po_number')                                       AS corporate,
       count(*) FILTER (WHERE attrs @@ '$.payment.bank == "Kotak"')                         AS kotak,
       count(*) FILTER (WHERE attrs @? '$.promo[*] ? (@ == "DIWALI")')                      AS diwali,
       count(*) FILTER (WHERE attrs @@ '$.delivery.city == "Kochi" && $.gift_wrap == true') AS kochi_gift
FROM orders;
```

```text
 corporate | kotak | diwali | kochi_gift 
-----------+-------+--------+------------
       380 | 40092 |  24862 |       1672
(1 row)
```

The third column shows a **filter expression**: read `$.promo[*] ? (@ == "DIWALI")` as
*every element of `promo`, keeping those equal to `"DIWALI"`*, where `@` is the item being
tested. Do not confuse that `?` with the `?` key-existence operator — different languages,
same character, and it catches everyone once.

The fourth column is the reason to learn this at all: `&&` across two independent keys in
one predicate. Containment cannot express that, because `@>` has no notion of *and* between
unrelated subtrees.

### Lax and strict

A path is evaluated in **lax** mode unless you say otherwise, and lax mode silently
flattens: an array accessor applied to a scalar treats the scalar as a one-element array, so
`jsonb_path_query_array('{"a": 1}', 'lax $.a[*]')` returns `[1]`. Ask for the same thing in
strict mode and the shape error surfaces:

```sql
SELECT jsonb_path_query_array('{"a": 1}', 'strict $.a[*]') AS strict_result;
```

```text
ERROR:  jsonpath wildcard array accessor can only be applied to an array
```

Lax is right for querying data whose shape varies; `strict` is right when you are
*validating* and a wrong shape is a bug you want to hear about.

> **Version note —** `jsonb_path_query`, `@?` and `@@` arrived in PostgreSQL **12** and work
> on the book's minimum of 15. The SQL/JSON *standard* syntax — `JSON_TABLE`, `JSON_VALUE`,
> `JSON_QUERY`, `JSON_EXISTS` — is **PostgreSQL 17** and does not exist here:
>
> ```text
> ERROR:  function json_value(jsonb, unknown) does not exist
> LINE 1: SELECT JSON_VALUE(attrs, '$.channel') FROM orders WHERE id =...
>                ^
> HINT:  No function matches the given name and argument types. You might need to add explicit type casts.
> ```
>
> The functions above do everything `JSON_VALUE` and `JSON_QUERY` do. `JSON_TABLE` has no
> pre-17 equivalent; expand arrays with `jsonb_array_elements` in a `LATERAL` join instead
> (Chapter 9).

## 17.4 Indexing: GIN, and which operator class

A B-tree on a whole `jsonb` column is almost useless — it serves only equality and ordering
of entire documents. You want GIN, which indexes the *contents*.

```sql
CREATE INDEX orders_attrs_gin ON orders USING gin (attrs);
SELECT pg_size_pretty(pg_relation_size('orders'))           AS table_size,
       pg_size_pretty(pg_relation_size('orders_attrs_gin')) AS jsonb_ops;
```

```text
 table_size | jsonb_ops 
------------+-----------
 49 MB      | 4000 kB
(1 row)
```

It serves containment and key existence. Take the second, since it matters shortly:

```sql
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM orders WHERE attrs ? 'po_number';
```

```text
                                 QUERY PLAN                                  
-----------------------------------------------------------------------------
 Aggregate (actual rows=1 loops=1)
   ->  Bitmap Heap Scan on orders (actual rows=380 loops=1)
         Recheck Cond: (attrs ? 'po_number'::text)
         Heap Blocks: exact=372
         ->  Bitmap Index Scan on orders_attrs_gin (actual rows=380 loops=1)
               Index Cond: (attrs ? 'po_number'::text)
(6 rows)
```

The index scan returns exactly the 380 matching rows, so the recheck discards nothing.

### `jsonb_path_ops`

The default operator class, `jsonb_ops`, indexes **every key and every value separately**.
`jsonb_path_ops` indexes a *hash of the whole path down to each value*: fewer entries, each
more selective. Add it alongside and compare.

```sql
CREATE INDEX orders_attrs_pathops ON orders USING gin (attrs jsonb_path_ops);
SELECT pg_size_pretty(pg_relation_size('orders_attrs_gin'))     AS jsonb_ops,
       pg_size_pretty(pg_relation_size('orders_attrs_pathops')) AS jsonb_path_ops;
```

```text
 jsonb_ops | jsonb_path_ops 
-----------+----------------
 4000 kB   | 1976 kB
(1 row)
```

**Half the size, deterministically** — and the same ratio holds on the `telemetry`
dataset's `payload` column, which is a different shape entirely.

The cost is coverage. Drop the default index and ask again for key existence — disabling
sequential scans first, so that what you see is *capability* rather than *cost*.

```sql
DROP INDEX orders_attrs_gin;
SET enable_seqscan = off;

EXPLAIN (COSTS OFF) SELECT count(*) FROM orders WHERE attrs ? 'po_number';
```

```text
                 QUERY PLAN                  
---------------------------------------------
 Aggregate
   ->  Seq Scan on orders
         Filter: (attrs ? 'po_number'::text)
(3 rows)
```

A sequential scan *with sequential scans disabled* is PostgreSQL saying there is no
alternative: `jsonb_path_ops` stores no bare keys, so it cannot answer "does this key
exist". Ask the same question as a path and the same index serves it —
`WHERE attrs @? '$.po_number'` plans as a `Bitmap Index Scan on orders_attrs_pathops`.
That is the escape hatch: rewrite `attrs ? 'k'` as `attrs @? '$.k'`.

| Operator | `jsonb_ops` | `jsonb_path_ops` |
|---|---|---|
| `@>` containment | yes | yes |
| `@?` path exists | yes | yes |
| `@@` path predicate | yes | yes |
| `?` `?\|` `?&` key existence | yes | **no** |
| Index size, this table | 4000 kB | 1976 kB |

**Default to `jsonb_path_ops`.** Containment is the predicate you will actually write.
Choose `jsonb_ops` only when you need the `?` family against a query you cannot rewrite.

<!-- BENCHMARK-TODO: ch17_scratch, one index present at a time. Compare `SELECT count(*) FROM orders WHERE attrs @> '{"delivery": {"city": "Kochi"}, "channel": "partner"}'` under orders_attrs_gin vs orders_attrs_pathops (4118 rows either way). Ratio for the lookup-speed claim. -->

> **Trap —** "the index was used" is not "the index helped". GIN indexes *equality* of
> extracted entries, so a jsonpath predicate that is not an equality test degrades to a full
> index scan plus a recheck of every row:
>
> ```sql
> EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
> SELECT count(*) FROM orders WHERE attrs @@ '$.po_number starts with "PO-7004"';
> ```
>
> ```text
>                                        QUERY PLAN                                       
> ----------------------------------------------------------------------------------------
>  Aggregate (actual rows=1 loops=1)
>    ->  Bitmap Heap Scan on orders (actual rows=1 loops=1)
>          Recheck Cond: (attrs @@ '($."po_number" starts with "PO-7004")'::jsonpath)
>          Rows Removed by Index Recheck: 199999
>          Heap Blocks: exact=6248
>          ->  Bitmap Index Scan on orders_attrs_pathops (actual rows=200000 loops=1)
>                Index Cond: (attrs @@ '($."po_number" starts with "PO-7004")'::jsonpath)
> (7 rows)
> ```
>
> The index scan returned all 200,000 rows and the recheck threw away 199,999 — worse than a
> sequential scan. `Rows Removed by Index Recheck` is the line that tells you. Chapter 34
> reads these properly.

### The expression index, and the statistics it brings

For a single scalar key you query with `=`, `<` or `ORDER BY`, a B-tree on the extraction
expression beats GIN. First, the planner without one:

```sql
EXPLAIN SELECT * FROM orders WHERE attrs ->> 'channel' = 'app';
```

```text
                                 QUERY PLAN                                 
----------------------------------------------------------------------------
 Gather  (cost=1000.00..8598.00 rows=1000 width=216)
   Workers Planned: 2
   ->  Parallel Seq Scan on orders  (cost=0.00..7498.00 rows=417 width=216)
         Filter: ((attrs ->> 'channel'::text) = 'app'::text)
(4 rows)
```

`rows=1000` is not an estimate. It is PostgreSQL's hardcoded 0.5% guess for a predicate it
cannot reason about. The true count is 50,234. Now add the index:

```sql
CREATE INDEX orders_channel ON orders ((attrs ->> 'channel'));
ANALYZE orders;
EXPLAIN SELECT * FROM orders WHERE attrs ->> 'channel' = 'app';
```

```text
                                    QUERY PLAN                                     
-----------------------------------------------------------------------------------
 Bitmap Heap Scan on orders  (cost=559.59..7557.18 rows=49973 width=216)
   Recheck Cond: ((attrs ->> 'channel'::text) = 'app'::text)
   ->  Bitmap Index Scan on orders_channel  (cost=0.00..547.09 rows=49973 width=0)
         Index Cond: ((attrs ->> 'channel'::text) = 'app'::text)
(4 rows)
```

49,973 estimated against 50,234 actual. The index did more than provide an access path:
`ANALYZE` now gathers statistics on the indexed *expression* and files them under the
index's name, which is where to look for them —
`SELECT most_common_vals FROM pg_stats WHERE tablename = 'orders_channel'`.

> **In production —** this is the most under-used JSONB technique I know. An expression
> index on a hot key fixes the row estimate for *every* query using that expression,
> including ones that never touch the index. If you will not carry the index,
> `CREATE STATISTICS` on the expression buys the estimate without the access path.

## 17.5 Building API output

JSONB's least controversial use, and it needs no JSONB column at all: assembling a nested
document from properly normalized tables, in one round trip, beats three queries and an
object mapper. Back to `retail`:

```sql
SELECT jsonb_pretty(jsonb_build_object(
         'order_id',  o.id,
         'placed_at', o.placed_at,
         'status',    o.status,
         'customer',  jsonb_build_object('name', c.name, 'city', c.city, 'tier', c.loyalty_tier),
         'items',     (SELECT jsonb_agg(jsonb_build_object('sku', p.sku, 'qty', oi.quantity, 'price', oi.unit_price)
                                        ORDER BY p.sku)
                       FROM order_items oi JOIN products p ON p.id = oi.product_id
                       WHERE oi.order_id = o.id),
         'total',     o.total_amount)) AS document
FROM orders o JOIN customers c ON c.id = o.customer_id
WHERE o.id = 13;
```

```text
                   document                   
----------------------------------------------
 {                                           +
     "items": [                              +
         {                                   +
             "qty": 2,                       +
             "sku": "SKU-00073",             +
             "price": 193.98                 +
         }                                   +
     ],                                      +
     "total": 387.96,                        +
     "status": "delivered",                  +
     "customer": {                           +
         "city": "Guwahati",                 +
         "name": "Harpreet Desai",           +
         "tier": "silver"                    +
     },                                      +
     "order_id": 13,                         +
     "placed_at": "2025-02-07T18:26:20+00:00"+
 }
(1 row)
```

The line items come from a correlated subquery rather than a join, which keeps the
one-to-many nesting without fanning out the parent row — the bug Practice Session 9.4
diagnoses. `jsonb_agg` takes `ORDER BY` inside the call, so the array has a defined order.
Three things to know before shipping this:

- **`jsonb_agg` over zero rows returns SQL NULL, not `[]`.** An order with no line items
  emits `"items": null`. Write `coalesce(jsonb_agg(...), '[]'::jsonb)`.
- **SQL NULL inside `jsonb_build_object` becomes JSON `null`**, not an absent key. If the
  client distinguishes them, use `jsonb_strip_nulls`.
- **`timestamptz` renders in the session's `TimeZone`.** The `+00:00` above is UTC; the same
  query in Mumbai emits `+05:30`. Pin `TimeZone` on the role serving your API or you will
  ship an inconsistent contract (Chapter 14).

Chapter 26, *Advanced Aggregation*, treats `jsonb_agg` and its relatives fully.

## 17.6 When JSONB is a table you refused to model

Everything so far was mechanics. This is the opinion.

The `attrs` column in this chapter has five keys, every row has the same five, and I can
list them. That is not semi-structured data — it is five columns in a trench coat, and the
database cannot see any of them.

**The planner is blind.** Section 17.4 showed one predicate estimated at 1,000 against
50,234 actual. Compound it:

```sql
EXPLAIN SELECT * FROM orders
WHERE attrs #>> '{payment,method}' = 'upi' AND attrs #>> '{delivery,city}' = 'Kochi';
```

```text
                                                              QUERY PLAN                                                              
--------------------------------------------------------------------------------------------------------------------------------------
 Gather  (cost=1000.00..8915.17 rows=5 width=216)
   Workers Planned: 2
   ->  Parallel Seq Scan on orders  (cost=0.00..7914.67 rows=2 width=216)
         Filter: (((attrs #>> '{payment,method}'::text[]) = 'upi'::text) AND ((attrs #>> '{delivery,city}'::text[]) = 'Kochi'::text))
(4 rows)
```

Five rows estimated; the real answer is 3,340. A 668-fold underestimate, because PostgreSQL
multiplied two 0.5% guesses together. On a standalone scan that costs nothing — but put the
query inside a join and the planner picks a nested loop sized for five rows and runs it
3,340 times.

Now model the column and ask the same kind of question:

```sql
ALTER TABLE orders ADD COLUMN payment_method text;
UPDATE orders SET payment_method = attrs #>> '{payment,method}';
VACUUM ANALYZE orders;

EXPLAIN SELECT * FROM orders WHERE payment_method = 'upi';
```

```text
                           QUERY PLAN                           
----------------------------------------------------------------
 Seq Scan on orders  (cost=0.00..15167.00 rows=40180 width=222)
   Filter: (payment_method = 'upi'::text)
(2 rows)
```

40,180 estimated, 39,851 actual — within 1%, with no index and no tuning, because a column
has an entry in `pg_stats` and an expression over a blob does not.

**Typos are not errors.** The other half of the cost, and the half that reaches users:

```sql
SELECT count(*) FROM orders WHERE attrs ->> 'chanel' = 'app';
```

```text
 count 
-------
     0
(1 row)
```

```sql
SELECT count(*) FROM orders WHERE chanel = 'app';
```

```text
ERROR:  column "chanel" does not exist
LINE 1: SELECT count(*) FROM orders WHERE chanel = 'app';
                                          ^
```

One misspelling returns zero rows and looks like a quiet week. The other cannot reach
production: it will not compile, and it will not survive a rename. That is what a schema
*is* — a set of claims the database enforces on your behalf.

The rest of the ledger, briefly. Inside a document there is no `NOT NULL`, no foreign key
and no declared type, so nothing stops `"batt": "78"` sitting beside `"batt": 78`. And
there is no `ALTER` for a key's type — no migration, only a backfill nobody schedules.

### So when is it right?

Four cases:

1. **Genuinely open-ended data.** Per-tenant custom fields, user-defined form responses,
   product attributes that differ by category. The keys are unknowable at design time
   because they are *your customers'* keys, not yours.
2. **Third-party payloads kept verbatim**, archived whole for audit and replay, with the
   fields you act on promoted to real columns.
3. **Sparse attributes with a long tail.** Two hundred possible keys, four on any row; the
   alternatives are two hundred mostly-NULL columns or EAV, and both are worse (Chapter 24).
4. **Output assembly.** Section 17.5 — no JSONB column involved.

What unites the first three: **the keys you query and constrain are columns, and JSONB holds
the remainder.** Not JSONB instead of a schema — JSONB *beside* one.

The test I apply in review is one question: *can you write down the list of keys?* If you
can, they are columns, and you are deferring a decision rather than avoiding one. It does
not go away; it gets made later, by more people, against production data, under a deadline.

---

## Summary

- **`json` stores text; `jsonb` stores a parsed tree.** `jsonb` reorders keys, drops
  duplicates and is often *larger* on disk. Use it anyway: `json` has no equality operator,
  so no `DISTINCT`, no `GROUP BY`, no index. Reserve `json` for bytes you must reproduce
  exactly.
- `->` and `#>` return `jsonb`; `->>` and `#>>` return `text`. Chain with `->`, finish with
  `->>`, and **cast on extraction** — `'9' > '10'` is true as text.
- `@>` follows nesting and matches array subsets, but does not match into a nested array.
  `?`/`?|`/`?&` test key existence, and on an array test string membership.
- SQL/JSON path (`jsonb_path_query`, `@?`, `@@`) is PostgreSQL 12+ and handles what
  containment cannot: filters, comparisons, conditions spanning unrelated keys. `lax` is the
  default. `JSON_TABLE` and its relatives are PostgreSQL 17 and unavailable on 15.
- **Default to `jsonb_path_ops`:** 1976 kB against 4000 kB for `jsonb_ops` on the same
  table. It serves `@>`, `@?` and `@@` but not `?`, `?|` or `?&` — rewrite `attrs ? 'k'` as
  `attrs @? '$.k'` and it can.
- GIN indexes equality only. A non-equality jsonpath predicate becomes a full index scan
  plus a recheck of every row; watch for `Rows Removed by Index Recheck`.
- For a single scalar key, a **B-tree expression index** beats GIN and gives `ANALYZE` real
  statistics for that expression — often worth more than the access path.
- Building documents with `jsonb_build_object`/`jsonb_agg` needs no JSONB column. Guard
  `jsonb_agg` with `coalesce(..., '[]')` and pin `TimeZone`.
- **The planner is blind inside a JSONB column.** Two extracted predicates estimated 5 rows
  against 3,340 actual; the same data as a column estimated 40,180 against 39,851. A
  misspelled key returns zero rows; a misspelled column raises an error.
- If you can write down the list of keys, they are columns. JSONB belongs *beside* a schema,
  holding what you have genuinely established you cannot model — not instead of one.

**Exercises:** Practice Sessions 17.1–17.3 accompany this chapter and are in the
workbook at the back of the book.

**Next:** Part V — this book's highest-leverage part — opens by taking section 17.6
seriously. Chapter 18, *Normalization and Deliberate Denormalization*, works 1NF through
BCNF on a real schema, then makes the honest counter-case: the answer to "should this be a
column" is not always yes.
