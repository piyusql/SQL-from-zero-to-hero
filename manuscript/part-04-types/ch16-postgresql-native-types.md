# Chapter 16 — PostgreSQL-Native Types

Chapters 13 and 14 covered the types every SQL dialect has. This chapter covers the ones
that make PostgreSQL worth choosing, and it is the one most likely to make you overreach.
Arrays, ranges, enums, composites and domains each remove a table, a join or a trigger
from some design — and each has a problem it makes worse, usually invisible until the
second year, when someone asks for a report the model cannot express.

Every section gives the same four things: what the type is, what it costs on disk, which
operators can use an index, and where I would reach for it. All of it was run on
PostgreSQL 15.10. Create a scratch database to follow along, and set
`\pset null '(null)'` if your `.psqlrc` does not already.

```bash
createdb ch16_scratch
psql -d ch16_scratch
```

Two tables are generated once and reused; the rest is created inline.

```sql
CREATE TABLE catalog_item (id int PRIMARY KEY, tags text[] NOT NULL);
INSERT INTO catalog_item
SELECT i,
       ARRAY(SELECT p.tag
             FROM unnest(ARRAY['apparel','handloom','cotton','grocery','beverage',
                               'south-indian','home','festive','brass','kitchen',
                               'steel','ayurveda','organic','gifting','clearance',
                               'imported']) WITH ORDINALITY AS p(tag, n)
             WHERE (('x' || substr(md5(i || ':' || p.n), 1, 8))::bit(32)::int % 16) = 0)
FROM generate_series(1, 200000) AS i;

CREATE TABLE access_log (id      int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                         src     inet NOT NULL,
                         seen_at timestamptz NOT NULL);
INSERT INTO access_log (src, seen_at)
SELECT ('10.' || (i % 40) || '.' || ((i / 40) % 256) || '.' || (i % 254 + 1))::inet,
       TIMESTAMPTZ '2026-01-01 00:00:00+05:30' + (i % 100000) * INTERVAL '1 minute'
FROM generate_series(1, 300000) AS i;

VACUUM ANALYZE;
```

---

## 16.1 Arrays

Every PostgreSQL type has an array type, declared by appending `[]`.

```sql
CREATE TABLE product_tags (
    id    int  PRIMARY KEY,
    name  text NOT NULL,
    tags  text[] NOT NULL DEFAULT '{}'
);

INSERT INTO product_tags (id, name, tags) VALUES
 (1, 'Handloom Cotton Saree', '{apparel,handloom,cotton}'),
 (2, 'Filter Coffee Powder',  ARRAY['grocery','beverage','south-indian']),
 (3, 'Brass Diya Set',        ARRAY['home','festive','brass']),
 (4, 'Steel Tiffin Carrier',  ARRAY['kitchen','steel']),
 (5, 'Unlabelled Sample Box', '{}');
```

Both literal forms work. Prefer `ARRAY[...]` over `'{a,b,c}'`: it type-checks its elements
and spares you the quoting rules.

**Arrays are 1-based**, subscripting out of range returns NULL rather than raising, and
slices use `lower:upper`.

```sql
SELECT id,
       tags[1]              AS first_tag,
       tags[2:3]            AS slice,
       tags[9]              AS ninth,
       array_length(tags,1) AS length,
       cardinality(tags)    AS cardinality
FROM   product_tags
ORDER  BY id;
```

```text
 id | first_tag |          slice          | ninth  | length | cardinality 
----+-----------+-------------------------+--------+--------+-------------
  1 | apparel   | {handloom,cotton}       | (null) |      3 |           3
  2 | grocery   | {beverage,south-indian} | (null) |      3 |           3
  3 | home      | {festive,brass}         | (null) |      3 |           3
  4 | kitchen   | {steel}                 | (null) |      2 |           2
  5 | (null)    | {}                      | (null) | (null) |           0
(5 rows)
```

> **Trap —** look at row 5. An empty array has no first dimension, so `array_length`
> returns NULL for it while `cardinality` returns 0, which means
> `WHERE array_length(tags,1) = 0` matches nothing, ever — three-valued logic from
> Chapter 7, arriving through a function you did not suspect. Use `cardinality(tags) = 0`
> or `tags = '{}'`. A slice, note, never goes out of range: `tags[2:3]` on the empty array
> is `{}`, not NULL.

### The operators that matter

Three carry almost all real array work: `@>` (contains all of), `<@` (is contained by) and
`&&` (overlaps at least one element). `tags && ARRAY['festive','cotton']` is "tagged either
festive or cotton"; `tags @> ARRAY['festive','cotton']` is "tagged both". `unnest` goes the
other way, expanding an array into rows so you can group on it; it is a set-returning
function and belongs in `FROM`, not the select list.

### Indexing, and the one-character mistake

Only those operators can use a GIN index. On `catalog_item`, containment is a `Seq Scan`
until you build one:

```sql
CREATE INDEX catalog_item_tags_gin ON catalog_item USING gin (tags);
```

```sql
EXPLAIN (COSTS OFF)
SELECT id FROM catalog_item WHERE tags @> ARRAY['handloom','cotton'];
```

```text
                        QUERY PLAN                         
-----------------------------------------------------------
 Bitmap Heap Scan on catalog_item
   Recheck Cond: (tags @> '{handloom,cotton}'::text[])
   ->  Bitmap Index Scan on catalog_item_tags_gin
         Index Cond: (tags @> '{handloom,cotton}'::text[])
(4 rows)
```

That index is cheap — 488 kB against a 13 MB heap — because it stores each distinct tag
once with a compressed posting list of row pointers. Now the mistake. The natural way to
write "has this tag" is `= ANY`, which returns the same 12,489 rows as
`tags @> ARRAY['handloom']`, with the index sitting right there:

```sql
EXPLAIN (COSTS OFF)
SELECT id FROM catalog_item WHERE 'handloom' = ANY (tags);
```

```text
                QUERY PLAN                 
-------------------------------------------
 Seq Scan on catalog_item
   Filter: ('handloom'::text = ANY (tags))
(2 rows)
```

`= ANY` is a scalar comparison against every element, not an array operator, so GIN cannot
serve it. Same answer, no index, forever. **Write containment as `@>` even for a single
element.** Chapter 33 covers GIN mechanics; Chapter 34, reading plans.

### When an array is the right model

An array is a column holding several values; a junction table is a relation. The deciding
question is not "how many values" but **what else you will need to say about an element**
— and an array cannot say anything, because it has no foreign key:

```sql
CREATE TABLE tag (name text PRIMARY KEY);
CREATE TABLE product_tag_fk (id int PRIMARY KEY, tags text[] REFERENCES tag(name));
```

```text
CREATE TABLE
ERROR:  foreign key constraint "product_tag_fk_tags_fkey" cannot be implemented
DETAIL:  Key columns "tags" and "name" are of incompatible types: text[] and text.
```

so this goes in:

```sql
INSERT INTO product_tags (id, name, tags)
VALUES (6, 'Jute Shopping Bag', ARRAY['handlooom','eco']);
```

```text
INSERT 0 1
```

A typo became a tag. Nothing will tell you, and the `handloom` count is wrong from now on.

**Use an array when the elements are opaque to the database, unconstrained, few, and
always read with their row** — import warnings, the columns of a CSV header, feature flags
you own end to end. **Use a junction table the moment an element needs an attribute, a
lifecycle, a rename, or a guarantee that it exists.** Tags are almost always the second
kind: within a year somebody wants a display label, a retirement flag and a global rename.
Practice Session 16.1 builds both models over the same 200,000 items.

## 16.2 Ranges and multiranges

A range is one value holding a lower bound, an upper bound and whether each is inclusive;
`int4range`, `numrange`, `tsrange`, `tstzrange` and `daterange` all ship built in.
The thing to internalise first: for discrete element types — integers and dates —
PostgreSQL **canonicalises every range to `[)`**, whatever you wrote.

```sql
SELECT daterange('2026-04-01','2026-06-30','[]')        AS as_stored,
       lower(daterange('2026-04-01','2026-06-30','[]')) AS lower,
       upper(daterange('2026-04-01','2026-06-30','[]')) AS upper;
```

```text
        as_stored        |   lower    |   upper    
-------------------------+------------+------------
 [2026-04-01,2026-07-01) | 2026-04-01 | 2026-07-01
(1 row)
```

You asked for "up to and including 30 June" and got "up to but excluding 1 July", the same
set of dates. Continuous types have no canonical form — `numrange(1,2,'[]')` stays `[1,2]`,
unequal to `[1,2)` — so with timestamps the bound you write is the bound you get, and
`'[]'` on two consecutive periods makes them overlap at the shared instant. Write half-open
periods and that class of off-by-one-second bug disappears.

The operators mirror the array ones: `@>` contains, `&&` overlaps, `-|-` adjacent. The two
non-obvious results are both consequences of the half-open bound:

```sql
SELECT daterange('2026-01-01','2026-04-01') @> DATE '2026-04-01' AS contains_apr_01,
       daterange('2026-01-01','2026-04-01') -|- daterange('2026-04-01','2026-07-01') AS adjacent;
```

```text
 contains_apr_01 | adjacent 
-----------------+----------
 f               | t
(1 row)
```

NULL as a bound means unbounded, so an open-ended period is `daterange('2026-01-01', NULL)`
and needs no sentinel like `9999-12-31`.

### Why this beats two columns

A `valid_from`/`valid_to` pair holds the same information and cannot be constrained. With
a range the constraint is free, using exclusion constraints from Chapter 15:

```sql
CREATE EXTENSION btree_gist;

CREATE TABLE tier_grant (
    id          int  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id int  NOT NULL,
    tier        text NOT NULL,
    valid       daterange NOT NULL,
    EXCLUDE USING gist (customer_id WITH =, valid WITH &&)
);

INSERT INTO tier_grant (customer_id, tier, valid) VALUES
 (7, 'bronze', daterange('2024-01-01','2025-01-01')),
 (7, 'silver', daterange('2025-01-01','2026-01-01')),
 (7, 'gold',   daterange('2026-01-01', NULL)),
 (9, 'bronze', daterange('2024-01-01','2024-07-01')),
 (9, 'silver', daterange('2025-03-01','2025-09-01')),
 (9, 'gold',   daterange('2025-09-01','2026-02-01'));
```

```sql
INSERT INTO tier_grant (customer_id, tier, valid)
VALUES (7, 'platinum', daterange('2025-06-01','2025-09-01'));
```

```text
ERROR:  conflicting key value violates exclusion constraint "tier_grant_customer_id_valid_excl"
DETAIL:  Key (customer_id, valid)=(7, [2025-06-01,2025-09-01)) conflicts with existing key (customer_id, valid)=(7, [2025-01-01,2026-01-01)).
```

Two customers may hold a tier on the same day; one customer may not hold two. That rule
is the database's job now, not a comment in a service class. The GiST index the constraint
creates is not overhead either — it answers point-in-time lookups directly, as Practice
Session 16.2 shows on 200,000 rows. `btree_gist` is a contrib extension, shipped but not
installed by default, and it is what lets a plain-equality column sit in a GiST exclusion
constraint beside the range (Chapter 49).

### Multiranges

> **Version note —** multirange types (`datemultirange`, `tstzmultirange`, …) and the
> `range_agg` aggregate require **PostgreSQL 14**. Verified working on 15.10. On 13 and
> earlier you need a gaps-and-islands window query instead.

A multirange is an ordered set of non-overlapping ranges. It closes the gap that made
ranges frustrating before 14: the union of two disjoint ranges is not itself a range.

```sql
SELECT customer_id, range_agg(valid) AS covered
FROM   tier_grant
GROUP  BY customer_id
ORDER  BY customer_id;
```

```text
 customer_id |                      covered                      
-------------+---------------------------------------------------
           7 | {[2024-01-01,)}
           9 | {[2024-01-01,2024-07-01),[2025-03-01,2026-02-01)}
(2 rows)
```

Customer 7's three consecutive tiers merged into one open-ended interval. Customer 9 has
a hole; subtract the coverage from the window you care about and it is named:

```sql
SELECT customer_id,
       datemultirange(daterange('2024-01-01','2026-02-01')) - range_agg(valid) AS gaps
FROM   tier_grant
GROUP  BY customer_id
ORDER  BY customer_id;
```

```text
 customer_id |           gaps            
-------------+---------------------------
           7 | {}
           9 | {[2024-07-01,2025-03-01)}
(2 rows)
```

A coverage-gap report in one aggregate. The equivalent window query is twenty lines and
gets the boundary conditions wrong the first three times.

## 16.3 `ENUM`, and the `ALTER` you will regret

An enum is a named type with a fixed, **ordered** list of labels.

```sql
CREATE TYPE order_status AS ENUM
    ('pending','paid','shipped','delivered','returned','cancelled');

CREATE TABLE ord (id     int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                  status order_status NOT NULL);

INSERT INTO ord (status) VALUES ('delivered'),('pending'),('cancelled'),('shipped');
```

Two genuine advantages over `text`. Sorting follows declaration order, not the alphabet —
usually what you want for a lifecycle column:

```sql
SELECT id, status FROM ord ORDER BY status;
```

```text
 id |  status   
----+-----------
  2 | pending
  4 | shipped
  1 | delivered
  3 | cancelled
(4 rows)
```

And the value costs four bytes regardless of label length:

```sql
SELECT pg_column_size('delivered'::order_status) AS enum_bytes,
       pg_column_size('delivered'::text)         AS text_bytes;
```

```text
 enum_bytes | text_bytes 
------------+------------
          4 |         13
(1 row)
```

Typos are rejected at parse time, with the offending value named:

```sql
INSERT INTO ord (status) VALUES ('refunded');
```

```text
ERROR:  invalid input value for enum order_status: "refunded"
LINE 1: INSERT INTO ord (status) VALUES ('refunded');
                                         ^
```

Now the part to test rather than recall: it changed in PostgreSQL 12, and most of what is
written online predates that. On 15.10, `ALTER TYPE ... ADD VALUE` **does** run inside a
transaction block — and the new label still cannot be used in that same transaction:

```sql
BEGIN;
ALTER TYPE order_status ADD VALUE 'refunded' AFTER 'returned';
INSERT INTO ord (status) VALUES ('refunded');
COMMIT;
```

```text
BEGIN
ALTER TYPE
ERROR:  unsafe use of new value "refunded" of enum type order_status
LINE 1: INSERT INTO ord (status) VALUES ('refunded');
                                         ^
HINT:  New enum values must be committed before they can be used.
ROLLBACK
```

Read the last line. The statement failed, the transaction aborted, and the `ADD VALUE`
rolled back with it: not a half-applied type, nothing at all. Migration tools wrap a
migration in a transaction by default, so **adding an enum value and backfilling it must
be two deployments**. I tested the escape hatches: neither creating the type in the same
transaction nor a savepoint helps. Only a commit does.

There is also no way to remove a label — not restricted, not privileged, simply absent
from the grammar:

```sql
ALTER TYPE order_status DROP VALUE 'refunded';
```

```text
ERROR:  syntax error at or near "VALUE"
LINE 1: ALTER TYPE order_status DROP VALUE 'refunded';
                                     ^
```

Retiring a value means creating a new type, rewriting every column that uses the old one
with `ALTER TABLE ... ALTER COLUMN ... TYPE`, then dropping the original — a full table
rewrite under `ACCESS EXCLUSIVE` each time (Chapter 52). `RENAME VALUE` is the only cheap
edit you get.

> **In production —** the table has an enum column and the deploy adds a state. That is
> the whole story, and a two-release dance every time. I use enums for closed sets that
> belong to the data model rather than the business — `debit`/`credit`, `ipv4`/`ipv6`. For
> anything a product manager can rename, the four bytes are not worth it.

The three-way choice between a lookup table, an `ENUM` and `text` + `CHECK` is a schema
decision, not a type decision, and Chapter 21, *Structuring a New Enterprise Database*,
settles it with the migration and multi-tenancy constraints in view. What this chapter
owes you is the cost sheet above.

## 16.4 `uuid`

`uuid` stores a 128-bit value in 16 bytes, which is the whole reason to use the type
rather than `text`:

```sql
SELECT pg_column_size('0b7ef9d4-3c6a-4d67-9d2e-1f5a8c0e77b3'::uuid) AS uuid_bytes,
       pg_column_size('0b7ef9d4-3c6a-4d67-9d2e-1f5a8c0e77b3'::text) AS text_bytes,
       pg_column_size('0b7ef9d43c6a4d679d2e1f5a8c0e77b3'::text)     AS packed_hex_bytes;
```

```text
 uuid_bytes | text_bytes | packed_hex_bytes 
------------+------------+------------------
         16 |         40 |               36
(1 row)
```

Two and a half times the storage for the `text` version, on every row and every index
entry. The type also normalises input — braces, case and missing hyphens are all accepted
and stored identically — and rejects anything malformed, here one character short:

```sql
SELECT '0b7ef9d4-3c6a-4d67-9d2e-1f5a8c0e77b'::uuid;
```

```text
ERROR:  invalid input syntax for type uuid: "0b7ef9d4-3c6a-4d67-9d2e-1f5a8c0e77b"
LINE 1: SELECT '0b7ef9d4-3c6a-4d67-9d2e-1f5a8c0e77b'::uuid;
               ^
```

`gen_random_uuid()` is built in since PostgreSQL 13; you no longer need `pgcrypto` or
`uuid-ossp` to produce a v4 UUID.

Whether a UUID should be your *primary key* is a much larger question — random v4 values
scatter inserts across the whole B-tree, costing write locality and index density. That
argument, with measurements and the UUIDv7 answer, is Chapter 20. Use `uuid` here for what
it is: the right column type for a value that is already a UUID.

## 16.5 `inet` and `cidr`

`inet` holds an IPv4 or IPv6 host address with an optional netmask; `cidr` holds a network
and refuses anything with bits set below the mask.

```sql
SELECT a AS stored, host(a) AS host, masklen(a) AS masklen,
       network(a) AS network, family(a) AS family, pg_column_size(a) AS bytes
FROM   (VALUES ('10.14.3.27/24'::inet),
               ('203.0.113.9'::inet),
               ('2405:200:801::42/64'::inet)) AS v(a);
```

```text
       stored        |       host       | masklen |      network      | family | bytes 
---------------------+------------------+---------+-------------------+--------+-------
 10.14.3.27/24       | 10.14.3.27       |      24 | 10.14.3.0/24      |      4 |    10
 203.0.113.9         | 203.0.113.9      |      32 | 203.0.113.9/32    |      4 |    10
 2405:200:801::42/64 | 2405:200:801::42 |      64 | 2405:200:801::/64 |      6 |    22
(3 rows)
```

Ten bytes for IPv4, twenty-two for IPv6, against fifteen-plus for the text form — and
unlike text, the value is validated:

```sql
SELECT '10.14.3.27/24'::cidr;
```

```text
ERROR:  invalid cidr value: "10.14.3.27/24"
LINE 1: SELECT '10.14.3.27/24'::cidr;
               ^
DETAIL:  Value has bits set to right of mask.
```

The reason to care is ordering and containment. Text sorts addresses lexicographically,
which is wrong in a way that looks right:

```sql
WITH v(s) AS (VALUES ('10.14.3.9'),('10.14.3.27'),('10.14.3.100'))
SELECT (SELECT string_agg(s, ' < ' ORDER BY s)       FROM v) AS ordered_as_text,
       (SELECT string_agg(s, ' < ' ORDER BY s::inet) FROM v) AS ordered_as_inet;
```

```text
           ordered_as_text            |           ordered_as_inet            
--------------------------------------+--------------------------------------
 10.14.3.100 < 10.14.3.27 < 10.14.3.9 | 10.14.3.9 < 10.14.3.27 < 10.14.3.100
(1 row)
```

And `<<=` ("is contained within or equals") answers subnet questions that text can only
approximate with `LIKE '10.14.%'`, wrong for any mask that is not a multiple of eight. A
GiST index with the `inet_ops` operator class serves it:

```sql
CREATE INDEX access_log_src_gist ON access_log USING gist (src inet_ops);
```

```sql
EXPLAIN (COSTS OFF)
SELECT count(*) FROM access_log WHERE src <<= '10.7.0.0/16'::inet;
```

```text
                          QUERY PLAN                           
---------------------------------------------------------------
 Aggregate
   ->  Index Only Scan using access_log_src_gist on access_log
         Index Cond: (src <<= '10.7.0.0/16'::inet)
(3 rows)
```

The count never touches the heap — which depends on a current visibility map, and is why
the setup ran `VACUUM ANALYZE`. Freshly loaded and only `ANALYZE`d, the same query gets a
`Bitmap Heap Scan` (Chapter 33).

> **In production —** store client addresses as `inet`, not `text`. The first time an
> incident asks "which office subnet was this from", the column either answers in one
> predicate or forces a scan with string surgery. An IP address is also personal data under
> most privacy regimes; Chapter 51 covers masking.

## 16.6 Composite types

`CREATE TYPE ... AS` with a column list makes a composite type, usable as a column type.

```sql
CREATE TYPE postal_address AS (line1 text, city text, state text, pincode text);

CREATE TABLE cust_comp (id int PRIMARY KEY, name text NOT NULL, ship_to postal_address);

INSERT INTO cust_comp VALUES
 (1, 'Anita Rao',      ROW('14 Residency Road','Bengaluru','Karnataka','560025')),
 (2, 'Harpreet Singh', ROW('221 Sector 17','Chandigarh','Chandigarh','160017')),
 (3, 'Meera Banerjee', NULL),
 (4, 'Arjun Iyer',     ROW(NULL,NULL,NULL,NULL));
```

Fields are read with parenthesised dot notation — `(ship_to).city`, the parentheses
mandatory so the parser does not read `ship_to` as a table name. Tidy, until you meet a
constraint you cannot write:

```sql
CREATE TYPE bad_address AS (pincode text NOT NULL);
```

```text
ERROR:  syntax error at or near "NOT"
LINE 1: CREATE TYPE bad_address AS (pincode text NOT NULL);
                                                 ^
```

A composite type takes no `NOT NULL`, no `CHECK`, no `DEFAULT` and no `UNIQUE` on its
fields; every such rule has to move into a table-level `CHECK` reaching through the
composite, or into a trigger. And NULL behaves in a way that will cost you an afternoon:

```sql
SELECT id, ship_to,
       ship_to IS NULL               AS is_null,
       ship_to IS DISTINCT FROM NULL AS distinct_from_null
FROM   cust_comp WHERE id IN (3,4) ORDER BY id;
```

```text
 id | ship_to | is_null | distinct_from_null 
----+---------+---------+--------------------
  3 | (null)  | t       | f
  4 | (,,,)   | t       | t
(2 rows)
```

Row 3 has no address; row 4 has an address whose every field is NULL. `IS NULL` calls them
the same, because the standard defines it to recurse into the fields; only
`IS DISTINCT FROM NULL` tells them apart. `WHERE ship_to IS NOT NULL` silently drops row 4.

**Composite types earn their place as function return types and PL/pgSQL row variables,
giving a function a named, structured result** (Chapter 42). As a *column* type they are a
table you refused to write: no per-field constraint, no per-field index without an
expression index, no way to add a field without touching the type every dependent table
shares. Use four columns, or a child table.

## 16.7 `DOMAIN`

A domain is a base type plus constraints, named once and reused.

```sql
CREATE DOMAIN email_address AS text
    CONSTRAINT email_address_shape
    CHECK (VALUE ~ '^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$');

CREATE DOMAIN pincode AS text
    CONSTRAINT pincode_six_digits
    CHECK (VALUE ~ '^[1-8][0-9]{5}$');

CREATE TABLE person (id    int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                     name  text          NOT NULL,
                     email email_address NOT NULL,
                     pin   pincode);

INSERT INTO person (name, email, pin) VALUES
 ('Priya Menon', 'priya.menon@kochi-retail.example', '682001'),
 ('Arjun Iyer',  'Arjun.Iyer@Pune-Mail.Example',     '411001');
```

Name the constraint. The name is what appears when the rule fires, and it is the
difference between a rejection that explains itself and one that does not:

```sql
INSERT INTO person (name, email, pin)
VALUES ('Rajesh Kumar', 'rajesh.kumar@delhi-mail.example', '012345');
```

```text
ERROR:  value for domain pincode violates check constraint "pincode_six_digits"
```

A domain beats a column `CHECK` on three counts. It applies everywhere the type is used,
so `'not-an-address'::email_address` fails with no table involved. It is declared once for
twenty tables. And it names the concept: `email email_address` says what the column *is*,
`email text` only how it is stored.

It has one real hole:

```sql
CREATE DOMAIN strict_text AS text NOT NULL;
CREATE TABLE warehouse (id int PRIMARY KEY, label strict_text);
INSERT INTO warehouse VALUES (1, 'Bhiwandi');
```

```sql
SELECT r.id AS requested_id, w.label,
       w.label IS NULL    AS label_is_null,
       pg_typeof(w.label) AS declared_type
FROM   (VALUES (1),(2)) AS r(id)
LEFT   JOIN warehouse w ON w.id = r.id
ORDER  BY r.id;
```

```text
 requested_id |  label   | label_is_null | declared_type 
--------------+----------+---------------+---------------
            1 | Bhiwandi | f             | strict_text
            2 | (null)   | t             | strict_text
(2 rows)
```

`warehouse.label` is declared with a domain carrying `NOT NULL`, and the outer join
produced a NULL of that type anyway: the constraint governs values *stored in a column*,
not values in a result set. Client code treating a `NOT NULL` domain as a guarantee will
dereference that null. Put `NOT NULL` on the column, where the planner and your ORM both
understand it, and keep domains for value-shape rules.

### Changing a domain later

Adding a constraint validates every existing column of that type across the database, all
or nothing — and `person` already holds a mixed-case address:

```sql
ALTER DOMAIN email_address
  ADD CONSTRAINT email_address_lowercase CHECK (VALUE = lower(VALUE));
```

```text
ERROR:  column "email" of table "person" contains values that violate the new constraint
```

The `NOT VALID` / `VALIDATE` split from Chapter 15 applies: add the constraint unenforced
against history, clean the data, validate:

```sql
ALTER DOMAIN email_address
  ADD CONSTRAINT email_address_lowercase CHECK (VALUE = lower(VALUE)) NOT VALID;
```

New writes are checked from that moment; the back-scan happens when you say so. Practice
Session 16.3 walks the cycle, including what `VALIDATE` does if run too early.

One limit to state plainly: **a domain rejects a value, it cannot change it.** If you want
addresses lower-cased rather than refused, that is a `BEFORE` trigger or a generated
column, not a `CHECK`.

---

## Summary

- **Arrays** suit elements the database never needs to reason about. Index containment
  with GIN and write `@>`, not `= ANY` — same rows, only one uses the index. There is no
  foreign key on array elements, so a typo silently becomes a value. And `array_length` on
  an empty array is NULL where `cardinality` is 0; use `cardinality`.
- **Ranges** replace a `valid_from`/`valid_to` pair with a value the database can
  constrain. Discrete ranges canonicalise to `[)`; write half-open periods for continuous
  ones too. An exclusion constraint makes "no overlaps" a schema rule, and its GiST index
  serves point-in-time lookups too.
- **Multiranges and `range_agg` need PostgreSQL 14**, verified on 15.10. Subtracting
  `range_agg` from a window gives a coverage-gap report in one aggregate.
- **`ENUM`** costs four bytes and sorts by declaration order. On 15.10 `ADD VALUE` runs
  inside a transaction but the label is unusable until after commit, so adding a value and
  using it are two deployments — and there is no `DROP VALUE` at all. Reserve enums for
  sets the business cannot rename; Chapter 21 owns the lookup-vs-enum-vs-`CHECK` call.
- **`uuid`** is 16 bytes against 40 for the text form, and validates input. Whether to key
  on one is Chapter 20.
- **`inet`/`cidr`** sort and contain correctly where text does neither; GiST with
  `inet_ops` indexes subnet containment.
- **Composite types** take no constraints on their fields, and `IS NULL` cannot separate
  an absent value from one whose fields are all NULL. Good as function return types, poor
  as columns.
- **Domains** attach a named, reusable rule to a type, covering casts and function
  arguments as well as columns — but a `NOT NULL` domain still yields NULL through an outer
  join, and a domain rejects a value, never fixes it. Tighten one with `NOT VALID`, then
  `VALIDATE`.

**Exercises:** Practice Sessions 16.1–16.3 accompany this chapter and are in the
workbook at the back of the book.

**Next:** Chapter 17, *JSONB in Depth*, takes the last and most abused native type on its
own terms — `json` versus `jsonb`, the operators, path queries, the two GIN operator
classes and when each wins, and the question underneath all of it: whether the document
you are storing is a table you refused to model.
