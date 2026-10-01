# Chapter 20 — Keys and Identity Strategy at Scale

Chapter 13 settled the *type* of a surrogate key (`bigint`) and Chapter 16 introduced `uuid`.
Neither answered the question a design review asks: **what should the primary key of this
table be?** That is four decisions at once: what identifies a row to the business, how the
number is generated, what it does to the index it lives in, and who gets to see it. Each fails
only after go-live, when the fix is a migration on a billion-row table. This chapter takes them
in order and measures the one people argue about without measuring: random versus
time-ordered UUIDs, at five million rows. Everything writes, so it runs in a scratch database:

```bash
createdb ch20_keys
psql -P null='(null)' -d ch20_keys
```

---

## 20.1 Natural key or surrogate key

A **natural key** is a value the business already has: an email address, a PAN, a mobile
number, a SKU. A **surrogate key** is one the database invents. "Identifies the row today" and
"identifies the row forever" are different claims, and only the second is a key.

Build the retail customers with email as the primary key, and orders that reference it:

```bash
psql -P null='(null)' -d retail -Atq \
  -c "\copy (SELECT id, name, email, city FROM customers ORDER BY id) TO '/tmp/ch20_customers.csv' CSV" \
  -c "\copy (SELECT id, customer_id, total_amount FROM orders ORDER BY id) TO '/tmp/ch20_orders.csv' CSV"
```

```sql
CREATE TABLE cust_nat (email text PRIMARY KEY, name text NOT NULL, city text);
CREATE TABLE ord_nat  (id int PRIMARY KEY,
                       customer_email text NOT NULL REFERENCES cust_nat ON UPDATE CASCADE,
                       total numeric(12,2));
CREATE TABLE cust_stage (id int, name text, email text, city text);
CREATE TABLE ord_stage  (id int, customer_id int, total numeric(12,2));
\copy cust_stage FROM '/tmp/ch20_customers.csv' CSV
\copy ord_stage FROM '/tmp/ch20_orders.csv' CSV
INSERT INTO cust_nat SELECT email, name, city FROM cust_stage;
INSERT INTO ord_nat SELECT o.id, c.email, o.total
FROM ord_stage o JOIN cust_stage c ON c.id = o.customer_id;
```

Three failures, all from real systems. First, **uniqueness is only as good as the string
comparison.** A primary key on `text` is case-sensitive:

```sql
INSERT INTO cust_nat VALUES ('Priya.Menon@vyapar.example', 'Priya Menon', 'Kochi'),
                            ('priya.menon@vyapar.example', 'Priya Menon', 'Kochi');
SELECT email FROM cust_nat WHERE lower(email) = 'priya.menon@vyapar.example';
```

```text
           email            
----------------------------
 Priya.Menon@vyapar.example
 priya.menon@vyapar.example
(2 rows)
```

One person, two customers, and the constraint is satisfied. Second, **keys get changed.**
People change email addresses, and a natural key turns that into a write to every child row.
Customer 426 has the most orders in this data:

```sql
BEGIN;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
UPDATE cust_nat SET email = 'rohit.k@vyapar.example' WHERE email = 'customer426@vyapar.example';
ROLLBACK;
```

```text
                                QUERY PLAN
--------------------------------------------------------------------------
 Update on cust_nat (actual rows=0 loops=1)
   ->  Index Scan using cust_nat_pkey on cust_nat (actual rows=1 loops=1)
         Index Cond: (email = 'customer426@vyapar.example'::text)
 Trigger for constraint ord_nat_customer_email_fkey on cust_nat: calls=1
 Trigger for constraint ord_nat_customer_email_fkey on ord_nat: calls=10
(5 rows)
```

`calls=10` on the child side: the cascade rewrote ten `orders` rows, and every index on them.
With ten orders it is invisible. With fifty million it is a table-sized `UPDATE` triggered by
someone editing their profile. Third, **the reference is wide**, and it is repeated in every
child row and every child index:

```sql
SELECT avg(pg_column_size(customer_email))::numeric(4,1) AS email_fk_bytes,
       pg_column_size(1::bigint) AS bigint_fk_bytes
FROM ord_nat;
```

```text
 email_fk_bytes | bigint_fk_bytes
----------------+-----------------
           26.9 |               8
(1 row)
```

Every identifier that "cannot change" fails this way. A mobile number is recycled by the
operator and reassigned to a stranger. A PAN does not exist for a minor or a customer who has
not supplied one, so a `PRIMARY KEY` on it refuses the row or takes placeholders that collide.
Names, as Chapter 18 showed, are not identifiers at all.

**What I would do:** every table gets a surrogate primary key, and the natural key stays as a
`UNIQUE` constraint (on `lower(email)` or `citext`, Chapter 16, if case should not matter).
Two exceptions: a small immutable code table (`country_code`, `currency`) can key on the code,
and a child table's key is often *correctly composite*, `order_items` by `(order_id, line_no)` or
a junction table by its two foreign keys. Composite keys are fine while every part is a stable
reference to a parent, and painful the moment another table must reference *them*: the wide key
is copied there too.

---

## 20.2 `IDENTITY`, not `SERIAL`

`serial` is a macro from before the standard had an answer: it creates a sequence, sets a
`nextval()` default and marks the sequence as owned by the column. `GENERATED ... AS IDENTITY`
(PostgreSQL 10) is the standard's answer, and better in ways that matter.

```sql
CREATE TABLE t_serial (id serial PRIMARY KEY, v text);
CREATE TABLE t_ident  (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, v text);

SELECT c.relname AS tbl, nullif(a.attidentity, '') AS identity,
       pg_get_expr(d.adbin, d.adrelid) AS default_expr,
       (SELECT deptype FROM pg_depend WHERE refobjid = c.oid AND refobjsubid = a.attnum
          AND objid IN (SELECT oid FROM pg_class WHERE relkind = 'S')) AS sequence_dependency
FROM pg_class c JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'id'
LEFT JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
WHERE c.relname IN ('t_serial', 't_ident') ORDER BY 1 DESC;
```

```text
   tbl    | identity |             default_expr             | sequence_dependency
----------+----------+--------------------------------------+---------------------
 t_serial | (null)   | nextval('t_serial_id_seq'::regclass) | a
 t_ident  | a        | (null)                               | i
(2 rows)
```

Three differences follow, and I have been bitten by each.

**`serial` is `integer`.** `bigserial` exists, but the default spelling gives you the
Chapter 13 outage. Identity lets you write the type you meant.

**`serial` lets anyone bypass it.** The default is an ordinary expression; any `INSERT` that
supplies an `id` wins, and the sequence does not notice. A migration that loads ids 1–3 by
hand leaves the sequence at 1, and the next application insert collides:

```sql
INSERT INTO t_serial (id, v) VALUES (1,'a'), (2,'b'), (3,'c');
INSERT INTO t_serial (v) VALUES ('d');
```

```text
ERROR:  duplicate key value violates unique constraint "t_serial_pkey"
DETAIL:  Key (id)=(1) already exists.
```

`GENERATED ALWAYS` refuses the explicit value and tells you the escape hatch:

```sql
INSERT INTO t_ident (id, v) VALUES (99, 'explicit');
INSERT INTO t_ident (id, v) OVERRIDING SYSTEM VALUE VALUES (99, 'explicit');
```

```text
ERROR:  cannot insert a non-DEFAULT value into column "id"
DETAIL:  Column "id" is an identity column defined as GENERATED ALWAYS.
HINT:  Use OVERRIDING SYSTEM VALUE to override.
INSERT 0 1
```

`BY DEFAULT` accepts explicit values like `serial` and has the same collision risk; use it
only while migrating legacy ids, then switch to `ALWAYS`. `OVERRIDING SYSTEM VALUE` is loud in
code review, which is the point. After an override the counter does not move by itself:
`ALTER TABLE ... ALTER COLUMN id RESTART WITH n` does it.

**Permissions.** A role that inserts into a `serial` table also needs `USAGE` on the
sequence. With identity it does not:

```sql
CREATE ROLE ch20_app LOGIN;
GRANT INSERT ON t_serial, t_ident TO ch20_app;
SET ROLE ch20_app;
INSERT INTO t_ident (v) VALUES ('via identity');
INSERT INTO t_serial (v) VALUES ('via serial');
RESET ROLE;
DROP OWNED BY ch20_app;
DROP ROLE ch20_app;
```

```text
SET
INSERT 0 1
ERROR:  permission denied for sequence t_serial_id_seq
RESET
```

The `serial` failure arrives in production, on the first insert by a new application role,
because the developer's superuser account never hit it.

> **Trap —** `CREATE TABLE ... (LIKE t INCLUDING ALL)` copies a `serial` column's *default*, so
> the copy draws from the original's sequence: a "staging copy" that quietly consumes
> production ids. An identity column is copied with its own new sequence. Migrating an existing
> `serial` column to identity is Practice Session 20.2.

---

## 20.3 Gaps are normal; gapless is a design

Sequences are not transactional. `nextval()` hands out a number and never takes it back,
whatever happens to the transaction that asked. Three ways to lose a value, in one table:

```sql
CREATE TABLE inv (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ref text UNIQUE);
INSERT INTO inv (ref) VALUES ('a'), ('b');
BEGIN; INSERT INTO inv (ref) VALUES ('c'); ROLLBACK;
INSERT INTO inv (ref) VALUES ('b') ON CONFLICT DO NOTHING;
INSERT INTO inv (ref) VALUES ('d');
SELECT * FROM inv ORDER BY id;
```

```text
 id | ref
----+-----
  1 | a
  2 | b
  5 | d
(3 rows)
```

The rollback consumed 3; the `ON CONFLICT DO NOTHING` that inserted nothing consumed 4. A
crash, a failed `COPY` and a cancelled statement do the same. The second source of disorder
is the sequence `CACHE` setting: a session reserves a block of values and hands them out
locally. Two sessions on a sequence with `CACHE 10`:

```bash
psql -P null='(null)' -d ch20_keys -Atq -c "CREATE SEQUENCE s_cache CACHE 10"
(psql -d ch20_keys -Atq -c "SELECT 'session A', nextval('s_cache')" \
      -c "SELECT pg_sleep(3)" -c "SELECT 'session A', nextval('s_cache')" | grep --line-buffered .) &
sleep 1.5
psql -d ch20_keys -Atq -c "SELECT 'session B', nextval('s_cache')"
wait
```

```text
session A|1
session B|11
session A|2
```

Session B got 11 while session A's second value, 2, arrived after it. Identity columns default
to `CACHE 1`, so this bites only tuned sequences, but the lesson generalises: **an id is unique
and, within a session, increasing. It is not gapless and not commit-ordered.** Never use one to detect "new rows since I last looked"; a row with
a lower id can commit later than one with a higher id, and the poller skips it.

Some numbers must be gapless. GST invoice rules in India require a consecutive serial number
per series, and an auditor will ask about a hole. The answer is not a sequence. It is a
counter row, incremented in the *same transaction* as the document, so a rollback returns
the number:

```sql
CREATE TABLE invoice_counter (fy text PRIMARY KEY, last_no int NOT NULL);
INSERT INTO invoice_counter VALUES ('2026-27', 0);
CREATE TABLE gst_invoice (fy text, no int, customer text NOT NULL, PRIMARY KEY (fy, no));
BEGIN;
UPDATE invoice_counter SET last_no = last_no + 1 WHERE fy = '2026-27' RETURNING last_no;
INSERT INTO gst_invoice SELECT fy, last_no, 'Meera Banerjee' FROM invoice_counter WHERE fy = '2026-27';
ROLLBACK;
BEGIN;
UPDATE invoice_counter SET last_no = last_no + 1 WHERE fy = '2026-27' RETURNING last_no;
INSERT INTO gst_invoice SELECT fy, last_no, 'Meera Banerjee' FROM invoice_counter WHERE fy = '2026-27';
COMMIT;
SELECT * FROM gst_invoice;
```

```text
BEGIN
 last_no
---------
       1
(1 row)

UPDATE 1
INSERT 0 1
ROLLBACK
BEGIN
 last_no
---------
       1
(1 row)

UPDATE 1
INSERT 0 1
COMMIT
   fy    | no |    customer
---------+----+----------------
 2026-27 |  1 | Meera Banerjee
(1 row)
```

Both transactions were issued number 1, and only the committed one kept it. The price is that the counter row stays locked until commit, so **every writer in that series
queues behind the one in front** (Chapter 32, *Locking, Deadlocks, and Concurrency Patterns*).
Use this only for numbers a regulator reads, issue them at the last moment (a pending invoice
has no number until it is finalised), and keep an internal `IDENTITY` key on the same table
for everything else.

---

## 20.4 The ceiling, and watching it

Chapter 13 covered why `integer` keys are an outage waiting to happen. The failure itself:

```sql
CREATE TABLE narrow (id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY, v int);
ALTER TABLE narrow ALTER COLUMN id RESTART WITH 2147483645;
INSERT INTO narrow (v) VALUES (1), (2), (3);
INSERT INTO narrow (v) VALUES (4);
```

```text
INSERT 0 3
ERROR:  nextval: reached maximum value of sequence "narrow_id_seq" (2147483647)
```

Three inserts succeeded and the fourth is your incident. Widening the column later means a
table rewrite or the multi-step online swap of Chapter 52, *Schema Migrations on Live Systems*,
done under pressure. The cheap defence is a monitor:

```sql
SELECT sequencename, data_type, last_value, max_value,
       round(100.0 * last_value / max_value, 2) AS pct_used
FROM pg_sequences WHERE sequencename LIKE 'narrow%';
```

```text
 sequencename  | data_type | last_value | max_value  | pct_used
---------------+-----------+------------+------------+----------
 narrow_id_seq | integer   | 2147483647 | 2147483647 |   100.00
(1 row)
```

Alert at 50%: at that point the fix is a planned migration, not an incident. Remember that
failed inserts burn values too, so the sequence can be far ahead of `count(*)`.

---

## 20.5 UUIDs: what randomness costs the index

The case for UUID keys is real: ids minted in the application without a round trip, merging
data from several systems, ids you can hand to a client without exposing a counter (20.6). The
case against is a property of the B-tree, not the type.

A `bigint` identity always inserts at the *right edge* of the primary-key index: the right-hand
leaf is hot and cached, and when it fills, PostgreSQL splits it asymmetrically and leaves the
old page 90% full. A random UUIDv4 inserts at a random position, so each insert lands on a
random leaf that must be in memory, or read in, to take the key; leaves split in the middle and
stay about 70% full; and after each checkpoint, the first touch of a page writes a full 8 kB
image to the WAL.

**UUIDv7** (RFC 9562) keeps the 128 bits but puts a millisecond timestamp in the first 48,
so new ids sort after old ones and inserts return to the right edge.

> **Version note —** PostgreSQL 15 has no `uuidv7()`. It arrived in PostgreSQL 18. The
> function below is pure SQL and works on 15 and later; on 18 or newer, drop it and use the
> built-in. The rest of this chapter does not change.

Layout: 48 bits of Unix milliseconds, the 4-bit version `7`, 12 bits, the 2-bit variant `10`,
and 62 random bits. The specification leaves the 12 bits open, and my first attempt filled them
with random bits. The alternative that keeps ids ordered *within* a millisecond, when one backend
generates hundreds in it, is the sub-millisecond fraction of the clock. I built both:

```sql
CREATE EXTENSION pgstattuple;

CREATE FUNCTION uuidv7_naive() RETURNS uuid
LANGUAGE sql VOLATILE PARALLEL SAFE AS $$
  SELECT encode(
           substring(int8send((extract(epoch FROM clock_timestamp()) * 1000)::bigint) FROM 3)
        || int2send((x'7000'::int | (random() * 4095)::int)::int2)
        || substring(uuid_send(gen_random_uuid()) FROM 9 FOR 8), 'hex')::uuid
$$;

CREATE FUNCTION uuidv7() RETURNS uuid
LANGUAGE sql VOLATILE PARALLEL SAFE AS $$
  SELECT encode(
           substring(int8send(us / 1000) FROM 3)                                 -- 48-bit unix ms
        || int2send((x'7000'::int | ((us % 1000) * 4096 / 1000)::int)::int2)    -- version 7 + sub-ms fraction
        || substring(uuid_send(gen_random_uuid()) FROM 9 FOR 8), 'hex')::uuid   -- variant + random
  FROM (SELECT (extract(epoch FROM clock_timestamp()) * 1000000)::bigint AS us) t
$$;
```

The random tail borrows its bytes from `gen_random_uuid()`, whose variant bits are already
`10`. Verify before trusting: version nibble, variant nibble, embedded time, and whether
ids come out in generation order:

```sql
CREATE TABLE probe (fn text, n int, id uuid);
INSERT INTO probe SELECT 'naive',  i, uuidv7_naive() FROM generate_series(1, 200000) i;
INSERT INTO probe SELECT 'uuidv7', i, uuidv7()       FROM generate_series(1, 200000) i;

SELECT fn, count(*) AS ids, count(DISTINCT id) AS distinct_ids,
       count(*) FILTER (WHERE substr(id::text, 15, 1) = '7') AS version_7,
       count(*) FILTER (WHERE substr(id::text, 20, 1) IN ('8','9','a','b')) AS rfc_variant,
       count(*) FILTER (WHERE id < prev) AS out_of_order
FROM (SELECT fn, id, lag(id) OVER (PARTITION BY fn ORDER BY n) AS prev FROM probe) s
GROUP BY fn ORDER BY fn;
```

```text
   fn   |  ids   | distinct_ids | version_7 | rfc_variant | out_of_order
--------+--------+--------------+-----------+-------------+--------------
 naive  | 200000 |       200000 |    200000 |      200000 |        99893
 uuidv7 | 200000 |       200000 |    200000 |      200000 |            0
(2 rows)
```

Both are valid version-7 UUIDs. The naive one is out of order about half the time, because
two ids from the same millisecond compare by their random bits. The clock-fraction version
is in order in this run. It is not a guarantee: two calls in the same microsecond tie and
fall back to random order, and a clock stepped backwards by NTP produces smaller ids after
larger ones. The built-in in 18 guarantees monotonic order inside a backend; mine does not.

Now the experiment. Four tables, identical except for the key, each loaded with five million
rows by the same `INSERT ... SELECT`, with a `CHECKPOINT` before each load so every variant
starts from the same WAL state:

```sql
CREATE TABLE ev_bigint (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                        account_id int NOT NULL, amount_paise int NOT NULL);
CREATE TABLE ev_v4 (id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
                    account_id int NOT NULL, amount_paise int NOT NULL);
CREATE TABLE ev_v7_naive (id uuid DEFAULT uuidv7_naive() PRIMARY KEY,
                          account_id int NOT NULL, amount_paise int NOT NULL);
CREATE TABLE ev_v7 (id uuid DEFAULT uuidv7() PRIMARY KEY,
                    account_id int NOT NULL, amount_paise int NOT NULL);
```

`EXPLAIN (ANALYZE, WAL)` reports the write-ahead log for *this statement in this session*, which is what
we want: `pg_wal_lsn_diff` between two points would also count every other client of the
server.

```bash
for t in ev_bigint ev_v4 ev_v7_naive ev_v7; do
  psql -P null='(null)' -d ch20_keys -Atq -c "CHECKPOINT" -c "EXPLAIN (ANALYZE, WAL, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
    INSERT INTO $t (account_id, amount_paise) SELECT i % 100000, i % 9973 FROM generate_series(1, 5000000) i" \
  | sed '/Planning:/,$d' | grep -E 'Insert on|^ +WAL|^  Buffers'
done
psql -P null='(null)' -d ch20_keys -Atq -c "ANALYZE ev_bigint" -c "ANALYZE ev_v4" -c "ANALYZE ev_v7_naive" -c "ANALYZE ev_v7"
```

```text
Insert on ev_bigint (actual rows=0 loops=1)
  Buffers: shared hit=15283038 read=9 dirtied=40761 written=48569, temp read=8545 written=8545
  WAL: records=10165228 fpi=26 bytes=700578657
        WAL: records=151519 bytes=15000381
Insert on ev_v4 (actual rows=0 loops=1)
  Buffers: shared hit=19580129 read=470475 dirtied=607580 written=515465, temp read=8545 written=8545
  WAL: records=10024919 fpi=165869 bytes=1791776847
Insert on ev_v7_naive (actual rows=0 loops=1)
  Buffers: shared hit=17239910 read=14 dirtied=56015 written=66048, temp read=8545 written=8545
  WAL: records=10024159 fpi=19 bytes=819917577
Insert on ev_v7 (actual rows=0 loops=1)
  Buffers: shared hit=10335869 read=16 dirtied=51165 written=60139, temp read=8545 written=8545
  WAL: records=10019293 fpi=56 bytes=772136352
```

The `WAL:` line indented under the scan is the identity itself: the bigint insert spends 15 MB
of WAL on sequence records (one per 32 values) that the UUID variants never write, and still
writes the least, about 700 MB against 772 for v7 and 1.79 GB for v4. **The v4 total is the
least stable number in this chapter.** Full-page images are written on the first touch of a
page after each checkpoint, so the count depends on how many checkpoints the load straddles; across
my runs v4's load WAL ranged from 1.28 to 4.17 GB while bigint stayed within 0.1% of 700 MB. Trust
the direction, and the steady-state test below. v4's `read=470475` is its index outgrowing this
container's 128 MB `shared_buffers` and being fetched back from the OS. Sizes and shape (the
UUID rows depend on random arrival order, so a rerun lands within about 1% of these figures, not on them):

```sql
SELECT v.variant, (SELECT count(*) FROM ev_bigint) AS rows_each,
       pg_size_pretty(pg_relation_size(v.tbl::regclass)) AS heap,
       pg_size_pretty(pg_relation_size((v.tbl || '_pkey')::regclass)) AS pkey,
       s.leaf_pages, round(s.avg_leaf_density::numeric, 1) AS leaf_density, s.leaf_fragmentation
FROM (VALUES ('bigint', 'ev_bigint'), ('uuidv4', 'ev_v4'),
             ('uuidv7 naive', 'ev_v7_naive'), ('uuidv7', 'ev_v7')) v(variant, tbl),
     LATERAL pgstatindex((v.tbl || '_pkey')::regclass) s;
```

```text
   variant    | rows_each |  heap  |  pkey  | leaf_pages | leaf_density | leaf_fragmentation
--------------+-----------+--------+--------+------------+--------------+--------------------
 bigint       |   5000000 | 211 MB | 107 MB |      13662 |         90.1 |                  0
 uuidv4       |   5000000 | 249 MB | 195 MB |      24813 |         69.6 |              49.76
 uuidv7 naive |   5000000 | 249 MB | 189 MB |      24042 |         71.8 |              33.95
 uuidv7       |   5000000 | 249 MB | 151 MB |      19200 |         89.8 |               0.84
(4 rows)
```

Read down `leaf_density`. The bigint index is 90% full, as designed. UUIDv4 is at 70%, its
index 1.8 times the size of the bigint one, and about half its leaves are out of physical order
(`leaf_fragmentation`), which is what makes a range scan over it seek. The naive v7 also lands
near 70%, which is the proof that the version nibble is not the fix: **ordering is**. A page
splits in the middle whenever the new key is not the largest on the rightmost page. The
clock-fraction v7 recovers 90%. Absolute sizes belong to this box and this schema; the ratios
are the result. Even the good UUID pays for its width: the heap is 18% larger (a 16-byte key
changes the row's alignment padding) and the index 1.4 times the bigint one, purely from key size.

The load is a single large statement. The cost that never goes away is the *steady state*:
one small insert after a checkpoint, into indexes that are now full-sized. Ten thousand rows
each:

```bash
for t in ev_bigint ev_v4 ev_v7; do
  psql -P null='(null)' -d ch20_keys -Atq -c "CHECKPOINT" -c "EXPLAIN (ANALYZE, WAL, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
    INSERT INTO $t (account_id, amount_paise) SELECT i, i FROM generate_series(1, 10000) i" \
  | sed '/Planning:/,$d' | grep -E 'Insert on|^ +WAL|^  Buffers'
done
```

```text
Insert on ev_bigint (actual rows=0 loops=1)
  Buffers: shared hit=30301 read=12 dirtied=85 written=81
  WAL: records=20331 fpi=3 bytes=1407797
        WAL: records=304 bytes=30096
Insert on ev_v4 (actual rows=0 loops=1)
  Buffers: shared hit=31911 read=8376 dirtied=8463 written=127
  WAL: records=20064 fpi=8313 bytes=51022027
Insert on ev_v7 (actual rows=0 loops=1)
  Buffers: shared hit=20385 read=9 dirtied=104 written=101
  WAL: records=20038 fpi=3 bytes=1549473
```

`dirtied` counts pages made dirty by the statement, and it is the number to compare: the
bigint insert dirtied 85 pages, the v7 insert 104, and the v4 insert 8,463: nearly one page per
row inserted, each of which a checkpoint must write and whose first touch put a whole 8 kB image
in the WAL (`fpi=8313`, 51 MB, against 1.4 and 1.5 MB). That is the workload-level cost of random
ids, and no clock is needed to see it. (The v4 figures moved between 8.2 and 9.7 thousand pages
across my runs; the other two barely moved.)

One more property, and it is why v7 is worth having over v4 when you must use a UUID: the
key is a time index. After a `VACUUM` sets the visibility map, "the newest 50,000 rows"
is a range scan on the primary key alone:

```sql
VACUUM ev_bigint, ev_v7;
SELECT id AS boundary FROM ev_v7 ORDER BY id DESC OFFSET 49999 LIMIT 1 \gset
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM ev_v7 WHERE id >= :'boundary';
SELECT (max(id) - 49999) AS boundary FROM ev_bigint \gset
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM ev_bigint WHERE id >= :boundary;
```

```text
                                 QUERY PLAN
-----------------------------------------------------------------------------
 Aggregate (actual rows=1 loops=1)
   Buffers: shared hit=194 read=1
   ->  Index Only Scan using ev_v7_pkey on ev_v7 (actual rows=50000 loops=1)
         Index Cond: (id >= '01a0f27b-46bc-768b-8c64-6f9a409a5782'::uuid)
         Heap Fetches: 0
         Buffers: shared hit=194 read=1
 Planning:
   Buffers: shared hit=17
(8 rows)

                                     QUERY PLAN
-------------------------------------------------------------------------------------
 Aggregate (actual rows=1 loops=1)
   Buffers: shared hit=34 read=110
   ->  Index Only Scan using ev_bigint_pkey on ev_bigint (actual rows=50000 loops=1)
         Index Cond: (id >= 4960001)
         Heap Fetches: 0
         Buffers: shared hit=34 read=110
 Planning:
   Buffers: shared hit=12
(8 rows)
```

Both are index-only scans over 50,000 keys; the v7 one touches 195 buffers against
the bigint's 144, the key-width cost again. For v4 the query has no meaning: its order is random, so
"recent" needs a separate timestamp index.

> **In production —** my rule: **`bigint` identity by default.** Use UUID when ids must be
> minted outside the database (offline clients, multi-writer merges, ids embedded in URLs of
> systems you do not control), and then use **v7**, generated by `uuidv7()` on 18+ or a
> function like the one above on 15–17. Choose v4 only for a table small enough that the
> index fits in memory forever, or for an id whose entire job is to be unguessable, which is
> the next section. If you inherit a v4 primary key on a big table, the index is bloated by
> design: `REINDEX INDEX CONCURRENTLY` restores density (Practice Session 20.1), but the random
> arrival order that caused it is unchanged. Chapter 37 covers it.

> **Trap —** UUIDv7 leaks the creation time to the millisecond: the first 12 hex digits
> are the timestamp. That is harmless for an internal key and a disclosure for an id you show
> customers ("when did this account sign up?"). Time-ordered ids are for keys; opaque ids
> are for URLs.

---

## 20.6 Exposing internal ids

A sequential key in a URL or an API is three problems. The first is *access*: if
`/bills/4242` returns whatever row has that id, `/bills/4243` returns the neighbour's.
That is IDOR (insecure direct object reference), OWASP files it under
broken access control, and the cause is the handler, not the id:

```sql
CREATE TABLE bill (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id   uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    customer_id int NOT NULL,
    amount      numeric(12,2) NOT NULL,
    issued_at   timestamptz NOT NULL);
INSERT INTO bill (customer_id, amount, issued_at)
SELECT 1 + i % 1000, 100 + i % 5000, timestamptz '2026-08-01' + i * interval '48 seconds'
FROM generate_series(1, 100000) i;

PREPARE get_bill(bigint) AS SELECT id, customer_id, amount FROM bill WHERE id = $1;
EXECUTE get_bill(4242);
EXECUTE get_bill(4243);
```

```text
  id  | customer_id | amount
------+-------------+---------
 4242 |         243 | 4342.00
(1 row)

  id  | customer_id | amount
------+-------------+---------
 4243 |         244 | 4343.00
(1 row)
```

Customer 243 asked for bill 4242 and got it; guessing 4243 returned customer 244's. The
second problem is *volume*. An ordinary customer who sees ids on two bills issued a week
apart can compute your business:

```sql
SELECT max(id) FILTER (WHERE issued_at < '2026-08-15') AS id_on_14_aug,
       max(id) FILTER (WHERE issued_at < '2026-08-22') AS id_on_21_aug
FROM bill;
```

```text
 id_on_14_aug | id_on_21_aug
--------------+--------------
        25199 |        37799
(1 row)
```

That is 12,600 bills a week, read off two invoices. It is a known technique with a
wartime name (the German tank problem). Third, ids are *enumerable*: a scraper walks 1 to
`max(id)`.

The fix has two parts, and only the first is security. **Authorise on every access**: the
query carries the owner, so a wrong id returns nothing (Chapter 44 moves this into
row-level security so a forgotten `WHERE` cannot happen):

```sql
PREPARE get_bill_owned(bigint, int) AS
  SELECT id, amount FROM bill WHERE id = $1 AND customer_id = $2;
EXECUTE get_bill_owned(4243, 243);
EXECUTE get_bill_owned(4243, 244);
```

```text
 id | amount
----+--------
(0 rows)

  id  | amount
------+---------
 4243 | 4343.00
(1 row)
```

The second part is an **opaque public id** so that nothing leaks or enumerates: keep the
`bigint` as the internal key, and give the row a random `uuid` column that is the only
identifier the outside world sees. Joins and foreign keys stay 8-byte; the public id is looked up once, at the edge:

```sql
SELECT public_id FROM bill WHERE id = 4243 \gset
SELECT id, amount FROM bill WHERE public_id = :'public_id';
SELECT pg_size_pretty(pg_relation_size('bill_pkey')) AS pkey,
       pg_size_pretty(pg_relation_size('bill_public_id_key')) AS public_id_index;
```

```text
  id  | amount
------+---------
 4243 | 4343.00
(1 row)

  pkey   | public_id_index
---------+-----------------
 2208 kB | 4120 kB
(1 row)
```

The price is a second index nearly twice the size of the primary key (4,120 kB against 2,208 kB
here) that, being random, has 20.5's density problem. That is acceptable because it serves only
lookups at the edge; no join or foreign key uses it. An opaque id defends against enumeration
and leakage, *not* against access: a leaked URL works for whoever holds it, so the ownership
check stays. A reversible encoding of the internal id (Hashids and the like) is obfuscation,
not a secret; I would not build on it.

---

## 20.7 Other schemes, and keys that outlive one database

A **ULID** is UUIDv7's idea with 80 random bits, shown as 26 Crockford-base32 characters;
store it in a `uuid` column and encode at the edge. A **snowflake-style id** packs a timestamp, a
node number and a counter into 64 bits: time-ordered like v7 at the size of a `bigint`, at the
cost of a scheme that assigns node numbers without collision. Reach for it when ids must be
minted outside the database *and* the key must stay 8 bytes. I have not measured either; the
ordering conclusions above apply because both are time-prefixed.

Two forward pointers. In a **multi-tenant** schema, the tenant is part of every key's
meaning; `(tenant_id, id)` composite keys are how row-level isolation and partitioning stay
cheap, and the trade-offs are Chapter 21, *Structuring a New Enterprise Database*. In a
**sharded** system a per-database sequence collides across shards, so ids have to be
minted by a scheme that includes the shard (a snowflake variant or a UUID); Chapter 53,
*Scaling PostgreSQL*, covers when sharding is the answer at all. The decision you make here
is the one that is hardest to change there.

---

## Summary

- **Natural keys change, collide and go wide**: email as a primary key accepted two spellings of
  one customer, cascaded a profile edit into ten child rows and made the foreign key 26.9 bytes
  against 8. Surrogate primary key, natural key as `UNIQUE`.
- **`IDENTITY`, not `SERIAL`**: it is the type you wrote, `GENERATED ALWAYS` refuses explicit
  ids, and the inserting role needs no sequence grant. `serial` failed all three.
- **Ids are unique, not gapless and not commit-ordered.** A rollback and a no-op `ON CONFLICT`
  each burned a value. Numbers a regulator reads come from a counter row in the same
  transaction, and serialise writers. Watch `pg_sequences`.
- **Random UUIDs cost the index.** At five million rows the primary key was 90% dense for
  bigint, 70% for UUIDv4 and for a v7 that does not order within the millisecond, and 90% for a
  v7 with the clock fraction. Steady-state inserts dirtied 8,463 pages for v4 against 104 for v7.
  UUIDv7 needs a function on 15 to 17.
- **Never expose sequential ids without an ownership check**; give the outside world an opaque
  `public_id`, not the key.
- **Default:** `bigint GENERATED ALWAYS AS IDENTITY`; UUIDv7 when ids are minted outside the
  database; v4 for ids whose job is to be unguessable.

**Exercises:** Practice Sessions 20.1–20.2 accompany this chapter and are in the
workbook at the back of the book.

**Next:** Chapter 21, *Structuring a New Enterprise Database*, takes the tables and keys
designed so far and organizes them: schemas for `app`, `audit` and `staging`, OLTP versus
reporting separation, and the three multi-tenancy models with the ceilings each one hits.
