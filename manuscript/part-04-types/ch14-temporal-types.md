# Chapter 14 — Temporal Types

Finance closes the books for July and reports 88 orders. The operations dashboard, reading
the same table on the same server, reports 90. Nobody has changed the data and both numbers
are correct: one of them decided July began at midnight UTC and the other at midnight in
Mumbai, and those disagree by five and a half hours at each end of the month.

Temporal types are not hard because calendars are complicated. They are hard because a
`timestamptz` column looks like it carries a time zone, and it does not. Once you
internalise what is actually stored — one number, no zone, ever — the rest is arithmetic.

Chapter 13 gave you the rule for numbers: pick the type that cannot silently lose
information. The answer here is shorter. **Default to `timestamptz`.** The rest of the
chapter is why, and what the exceptions cost.

---

## 14.1 The types, and what they weigh

Five temporal types worth knowing, and one worth avoiding.

```sql
SELECT pg_column_size(DATE        '2026-04-14')                 AS date_b,
       pg_column_size(TIME        '09:30:00')                   AS time_b,
       pg_column_size(TIMESTAMP   '2026-04-14 09:30:00')        AS timestamp_b,
       pg_column_size(TIMESTAMPTZ '2026-04-14 09:30:00+05:30')  AS timestamptz_b,
       pg_column_size(INTERVAL    '1 day')                      AS interval_b;
```

```text
 date_b | time_b | timestamp_b | timestamptz_b | interval_b 
--------+--------+-------------+---------------+------------
      4 |      8 |           8 |             8 |         16
(1 row)
```

Stop on the middle two columns. `timestamp` is eight bytes and `timestamptz` is eight bytes.
There is no room for a zone, and it is not hiding in a side table. **PostgreSQL does not
store a time zone in a `timestamptz` column.** The `tz` means "zone-*aware* on the way in
and on the way out", not "remembers a zone".

What is in those eight bytes is a signed count of microseconds from midnight UTC on
1 January 2000 — an *instant*, the thing two people on opposite sides of the world can agree
happened at the same moment.

| Type | Bytes | What it means |
|---|---|---|
| `date` | 4 | A calendar day. No time, no zone. |
| `time` | 8 | A wall-clock time of day. No date, no zone. |
| `timestamp` | 8 | A date and a wall-clock time. **No zone, and none inferred.** |
| `timestamptz` | 8 | An instant. Parsed and rendered through a zone. |
| `interval` | 16 | A duration, held as months + days + microseconds. |

The one to avoid is `timetz` — a time of day with a fixed UTC offset and no date. Without a
date there is no way to know whether daylight saving applied, so its offset is
unverifiable. The documentation says it exists only for standards compliance. Believe it.

## 14.2 One instant, written three ways

Here is the proof that no zone survives the write. Three rows, three textual forms, one
moment.

```sql
SET TIME ZONE 'Asia/Kolkata';

CREATE TABLE tz_demo (label text, ts timestamptz);
INSERT INTO tz_demo VALUES
  ('written with +05:30', '2026-04-14 09:30:00+05:30'),
  ('written as UTC',      '2026-04-14 04:00:00+00'),
  ('written in New York', '2026-04-14 00:00:00 America/New_York');

SELECT label, ts FROM tz_demo ORDER BY label;
```

```text
        label        |            ts             
---------------------+---------------------------
 written as UTC      | 2026-04-14 09:30:00+05:30
 written in New York | 2026-04-14 09:30:00+05:30
 written with +05:30 | 2026-04-14 09:30:00+05:30
(3 rows)
```

Three writes, one stored value. The offset in the literal was used to compute the instant
and then discarded — it is *input*, like the `0x` in a hex number.

Now reconnect from a machine in another zone. Nothing about the table changes.

```sql
SET TIME ZONE 'America/New_York';

SELECT label, ts FROM tz_demo ORDER BY label;
```

```text
        label        |           ts           
---------------------+------------------------
 written as UTC      | 2026-04-14 00:00:00-04
 written in New York | 2026-04-14 00:00:00-04
 written with +05:30 | 2026-04-14 00:00:00-04
(3 rows)
```

The `+05:30` you saw a moment ago was never in the row. It came from the session's `TimeZone`
setting, applied at render time — correctly, because 09:30 in Mumbai and 00:00 in New York
are the same instant.

> **In production —** the server this book is verified on has `TimeZone = GMT`, a Docker
> default and probably not yours. Check with `SHOW timezone;` before trusting a
> `timestamptz` you read off a screen. Every block below that depends on the session zone
> sets it explicitly first, so your results match whatever your server was built with.

Two consequences. **Ordering, comparison and subtraction on `timestamptz` are
zone-independent** — they operate on instants. And **display, `::date`, `date_trunc` and
`EXTRACT` are zone-dependent**, because all four ask a calendar question, and calendars are
local.

## 14.3 What `timestamp` loses, and how quietly

Run the identical inserts into a column declared `timestamp`.

```sql
SET TIME ZONE 'Asia/Kolkata';

CREATE TABLE naive_demo (label text, ts timestamp);
INSERT INTO naive_demo VALUES
  ('written with +05:30', '2026-04-14 09:30:00+05:30'),
  ('written as UTC',      '2026-04-14 04:00:00+00'),
  ('written in New York', '2026-04-14 00:00:00 America/New_York');

SELECT label, ts FROM naive_demo ORDER BY label;
```

```text
        label        |         ts          
---------------------+---------------------
 written as UTC      | 2026-04-14 04:00:00
 written in New York | 2026-04-14 00:00:00
 written with +05:30 | 2026-04-14 09:30:00
(3 rows)
```

Same three instants. Three stored values, spread across nine and a half hours. No error, no
warning, no `NOTICE`. `timestamp` parsed the date and time out of each literal and **threw
the offset away** — it did not convert, it truncated. Sort these rows and the order has
nothing to do with when anything happened. This is the bug behind almost every "our
timestamps are off by five and a half hours" incident I have been called into, and it never
announces itself at write time. It announces itself when another office runs the report.

Worse, comparing the two types is legal:

```sql
SET TIME ZONE 'Asia/Kolkata';
SELECT TIMESTAMP '2026-04-14 09:30:00' = TIMESTAMPTZ '2026-04-14 09:30:00+05:30' AS eq_ist,
       TIMESTAMP '2026-04-14 09:30:00' = TIMESTAMPTZ '2026-04-14 09:30:00+00'    AS eq_utc;
```

```text
 eq_ist | eq_utc 
--------+--------
 t      | f
(1 row)
```

```sql
SET TIME ZONE 'UTC';
SELECT TIMESTAMP '2026-04-14 09:30:00' = TIMESTAMPTZ '2026-04-14 09:30:00+05:30' AS eq_ist,
       TIMESTAMP '2026-04-14 09:30:00' = TIMESTAMPTZ '2026-04-14 09:30:00+00'    AS eq_utc;
```

```text
 eq_ist | eq_utc 
--------+--------
 f      | t
(1 row)
```

Both answers flipped. The `timestamp` side was promoted to `timestamptz` using the session
zone, so a `WHERE` clause mixing the two types returns different rows to different
connections — which is why a nightly job on a cron box with a different `TZ` environment
variable disagrees with your application server.

> **Trap —** a `timestamp` column is not "UTC by convention". It is a string of digits with
> a convention written down somewhere else, usually in a wiki page three years out of date.
> The database cannot enforce it and will not warn you when a new service breaks it.

**So: `timestamptz` for anything that records when something happened** — orders, logins,
sensor readings, audit rows, `created_at`, `updated_at`, all of it.

`timestamp` is right in one situation: when the *wall clock is the fact* and the instant is
not yet determined — a shift starting at 09:00 local in every depot you operate, a reminder
at 07:30 that must stay at 07:30 across a DST change. Store the local time with the zone
name in a separate `text` column, and resolve them when you schedule. For a plain calendar
day — a birthday, `customers.signup_date` — use `date`.

## 14.4 `AT TIME ZONE`, in both directions

One operator that does two opposite things depending on what you give it. Watching the
return type is what fixes the confusion.

Applied to a `timestamptz`, it answers *what did the clock on the wall say there?* and hands
back a zone-less `timestamp`:

```sql
SELECT TIMESTAMPTZ '2026-04-14 09:30:00+05:30' AT TIME ZONE 'America/New_York' AS wall_clock,
       pg_typeof(TIMESTAMPTZ '2026-04-14 09:30:00+05:30'
                 AT TIME ZONE 'America/New_York') AS type;
```

```text
     wall_clock      |            type             
---------------------+-----------------------------
 2026-04-14 00:00:00 | timestamp without time zone
(1 row)
```

Applied to a `timestamp`, it answers *this clock reading was in that zone — which instant is
it?* and hands back a `timestamptz`:

```sql
SELECT TIMESTAMP '2026-04-14 09:30:00' AT TIME ZONE 'Asia/Kolkata' AS instant,
       pg_typeof(TIMESTAMP '2026-04-14 09:30:00'
                 AT TIME ZONE 'Asia/Kolkata') AS type;
```

```text
          instant          |           type           
---------------------------+--------------------------
 2026-04-14 09:30:00+05:30 | timestamp with time zone
(1 row)
```

`timestamptz AT TIME ZONE z` strips zone-awareness; `timestamp AT TIME ZONE z` adds it. The
operator is its own inverse, which is why applying it twice re-reads an instant as if it
had been recorded elsewhere.

Name zones by **IANA name**, never by abbreviation. Postgres validates names:

```sql
SELECT now() AT TIME ZONE 'Asia/Bengaluru';
```

```text
ERROR:  time zone "Asia/Bengaluru" not recognized
```

It also accepts abbreviations, and that is where it stops protecting you. `IST` is the
obvious abbreviation for India Standard Time. In PostgreSQL's table it is not:

```sql
SELECT abbrev, utc_offset, is_dst FROM pg_timezone_abbrevs WHERE abbrev = 'IST';
```

```text
 abbrev | utc_offset | is_dst 
--------+------------+--------
 IST    | 02:00:00   | f
(1 row)
```

`IST` resolves to **Israel Standard Time, UTC+02:00**, and is Irish Standard Time elsewhere
in the world. Use it and every Indian timestamp you parse is three and a half hours wrong:

```sql
SELECT TIMESTAMPTZ '2026-04-14 09:30:00 IST'          AT TIME ZONE 'UTC' AS via_abbrev,
       TIMESTAMPTZ '2026-04-14 09:30:00 Asia/Kolkata' AT TIME ZONE 'UTC' AS via_name;
```

```text
     via_abbrev      |      via_name       
---------------------+---------------------
 2026-04-14 07:30:00 | 2026-04-14 04:00:00
(1 row)
```

No error. Three and a half hours of drift, in the direction nobody checks. Abbreviations are
ambiguous by construction and fixed-offset by definition, so they cannot express DST either.
Use full names always; `SELECT * FROM pg_timezone_names` is the list your server accepts.

## 14.5 `now()` is transaction time

```sql
BEGIN;
CREATE TEMP TABLE t0 AS SELECT now() AS n, clock_timestamp() AS c;
SELECT count(pg_sleep(1)) AS slept;
SELECT (SELECT n FROM t0) = now()             AS now_unchanged,
       (SELECT c FROM t0) = clock_timestamp() AS clock_unchanged;
COMMIT;
```

```text
 now_unchanged | clock_unchanged 
---------------+-----------------
 t             | f
(1 row)
```

`now()` — and its spelling `CURRENT_TIMESTAMP` — returns the instant the **transaction**
started and does not move. `statement_timestamp()` advances per statement.
`clock_timestamp()` reads the actual clock on every call and is the only `VOLATILE` one.

Transaction time is usually what you want: every row a batch job inserts gets one consistent
`created_at`. It is wrong when you are measuring elapsed time inside a transaction, where
`now() - now()` is always zero. `CURRENT_DATE` and `LOCALTIMESTAMP` derive from the same
instant and resolve in the session zone — `CURRENT_DATE` differs between a Mumbai session
and a New York session for five and a half hours out of every twenty-four.

## 14.6 DST arithmetic

India is a comfortable place to reason about time and a bad place to learn DST from.
`Asia/Kolkata` is UTC+05:30 all year — the IANA database your server ships records no
daylight saving there since 1945 — so nothing below would show up if we stayed home. The half-hour offset is its own corrective —
code that assumes offsets are whole hours breaks on India before anywhere else — but to see
a clock jump we must borrow a zone that jumps. `America/New_York` springs forward on
8 March 2026 and falls back on 1 November 2026.

First, the fact that makes `interval` arithmetic non-obvious. An `interval` is not a number
of seconds; it is three independent fields — months, days, microseconds — and comparing two
intervals normalises them at 24 hours to the day:

```sql
SELECT INTERVAL '1 day'   = INTERVAL '24 hours' AS day_eq_24h,
       INTERVAL '1 month' = INTERVAL '30 days'  AS month_eq_30d;
```

```text
 day_eq_24h | month_eq_30d 
------------+--------------
 t          | t
(1 row)
```

Equal. Now add each of them to an instant that straddles the spring-forward boundary:

```sql
SET TIME ZONE 'America/New_York';
SELECT TIMESTAMPTZ '2026-03-07 12:00:00' + INTERVAL '1 day'    AS plus_1_day,
       TIMESTAMPTZ '2026-03-07 12:00:00' + INTERVAL '24 hours' AS plus_24_hours;
```

```text
       plus_1_day       |     plus_24_hours      
------------------------+------------------------
 2026-03-08 12:00:00-04 | 2026-03-08 13:00:00-04
(1 row)
```

Two intervals that compare as equal produce answers an hour apart. **The `days` field means
"the same wall-clock time tomorrow"; the microseconds field means "this many elapsed
seconds".** On a 23-hour day those are different questions, and PostgreSQL answers each
correctly. Pick deliberately: a subscription renewing "at the same clock time each day"
wants `1 day`; an SLA allowing "24 hours to respond" wants `24 hours`.

Subtraction goes the other way and always yields elapsed time:

```sql
SELECT TIMESTAMPTZ '2026-03-08 12:00:00' - TIMESTAMPTZ '2026-03-07 12:00:00' AS difference,
       age(TIMESTAMPTZ '2026-03-08 12:00:00', TIMESTAMPTZ '2026-03-07 12:00:00') AS age;
```

```text
 difference |  age  
------------+-------
 23:00:00   | 1 day
(1 row)
```

`-` reports the time that actually passed. `age()` reports how the calendar describes it.
Both are true. A report computing "average time to ship" with `-` and rendering it as days
is off by an hour twice a year for every order that crossed a transition.

### The two broken hours

A local wall-clock time is not guaranteed to exist, nor to be unique.

```sql
SELECT TIMESTAMP '2026-03-08 02:30:00' AT TIME ZONE 'America/New_York' AS spring_gap,
       TIMESTAMP '2026-11-01 01:30:00' AT TIME ZONE 'America/New_York' AS autumn_fold;
```

```text
       spring_gap       |      autumn_fold       
------------------------+------------------------
 2026-03-08 03:30:00-04 | 2026-11-01 01:30:00-05
(1 row)
```

02:30 on 8 March never happened in New York — the clocks went from 02:00 to 03:00 — and
PostgreSQL silently shifted it to 03:30. 01:30 on 1 November happened **twice**, and
PostgreSQL picked the second, post-transition `-05` reading. Neither raises an error, and
both are reachable by any user picking a local time in a form.

The fold is lossy in the other direction too:

```sql
SELECT TIMESTAMPTZ '2026-11-01 01:30:00-04' AT TIME ZONE 'America/New_York' AS from_edt,
       TIMESTAMPTZ '2026-11-01 01:30:00-05' AT TIME ZONE 'America/New_York' AS from_est;
```

```text
      from_edt       |      from_est       
---------------------+---------------------
 2026-11-01 01:30:00 | 2026-11-01 01:30:00
(1 row)
```

Two distinct instants, an hour apart, collapse to one `timestamp`. **Converting a
`timestamptz` to a local `timestamp` is not reversible.** Do it for display and grouping;
never store the result and expect the instant back.

The same asymmetry shows up whenever you generate a schedule:

```sql
SELECT (SELECT count(*) FROM generate_series(TIMESTAMPTZ '2026-03-08 00:00:00',
          TIMESTAMPTZ '2026-03-08 23:59:59', INTERVAL '1 hour')) AS mar_08_slots,
       (SELECT count(*) FROM generate_series(TIMESTAMPTZ '2026-11-01 00:00:00',
          TIMESTAMPTZ '2026-11-01 23:59:59', INTERVAL '1 hour')) AS nov_01_slots;
```

```text
 mar_08_slots | nov_01_slots 
--------------+--------------
           23 |           25
(1 row)
```

Twenty-three hourly slots one day, twenty-five the other. Any capacity model, billing
window or appointment grid hard-coding 24 is wrong twice a year, and November is the
expensive direction — it double-books.

## 14.7 Bucketing

`date_trunc` rounds an instant down to the start of a calendar period. Because "the start of
the day" is a local question, it **resolves the boundary in the session's `TimeZone`**.
Chapter 8 flagged this and deferred it here.

Three days of `telemetry`, bucketed by day, session in UTC:

```sql
SET TIME ZONE 'UTC';
SELECT date_trunc('day', recorded_at)::date AS day, count(*) AS events
FROM   device_events
WHERE  recorded_at >= TIMESTAMPTZ '2026-06-01 00:00:00+00'
  AND  recorded_at <  TIMESTAMPTZ '2026-06-04 00:00:00+00'
GROUP  BY day ORDER BY day;
```

```text
    day     | events 
------------+--------
 2026-06-01 |    191
 2026-06-02 |    192
 2026-06-03 |    192
(3 rows)
```

The same query, same rows, session moved to Mumbai:

```sql
SET TIME ZONE 'Asia/Kolkata';
SELECT date_trunc('day', recorded_at)::date AS day, count(*) AS events
FROM   device_events
WHERE  recorded_at >= TIMESTAMPTZ '2026-06-01 00:00:00+00'
  AND  recorded_at <  TIMESTAMPTZ '2026-06-04 00:00:00+00'
GROUP  BY day ORDER BY day;
```

```text
    day     | events 
------------+--------
 2026-06-01 |    147
 2026-06-02 |    192
 2026-06-03 |    192
 2026-06-04 |     44
(4 rows)
```

575 events either way. Three buckets became four, and the first day lost 44 events to a day
that did not previously exist. Nobody wrote a bug: one connection had a different `TimeZone`
than the other, and `TimeZone` can be set per role, per database, per session, or by the
`PGTZ` environment variable of whatever host ran the job.

**Pin the zone in the query.** Convert first, then truncate:

```sql
SET TIME ZONE 'UTC';
SELECT (recorded_at AT TIME ZONE 'Asia/Kolkata')::date AS ist_day, count(*) AS events
FROM   device_events
WHERE  recorded_at >= TIMESTAMPTZ '2026-06-01 00:00:00+00'
  AND  recorded_at <  TIMESTAMPTZ '2026-06-04 00:00:00+00'
GROUP  BY ist_day ORDER BY ist_day;
```

```text
  ist_day   | events 
------------+--------
 2026-06-01 |    147
 2026-06-02 |    192
 2026-06-03 |    192
 2026-06-04 |     44
(4 rows)
```

Mumbai days, from a UTC session. The answer no longer depends on who is connected.

A three-argument `date_trunc(field, source, zone)` looks like it does the same job, and it
does — but it returns a `timestamptz` at the bucket's starting *instant*, so a `::date`
afterwards resolves in the session zone all over again and undoes the work:

```sql
SELECT date_trunc('day', recorded_at, 'Asia/Kolkata')::date AS ist_day, count(*) AS events
FROM   device_events
WHERE  recorded_at >= TIMESTAMPTZ '2026-06-01 00:00:00+00'
  AND  recorded_at <  TIMESTAMPTZ '2026-06-04 00:00:00+00'
GROUP  BY ist_day ORDER BY ist_day;
```

```text
  ist_day   | events 
------------+--------
 2026-05-31 |    147
 2026-06-01 |    192
 2026-06-02 |    192
 2026-06-03 |     44
(4 rows)
```

Right group sizes, labels shifted back a day, because midnight in Mumbai is 18:30 the
previous afternoon in UTC. The three-argument form is correct while you keep the
`timestamptz` and a trap the moment you cast. `(x AT TIME ZONE 'zone')::date` has no such
edge.

### Every customer in their own day

The zone is an ordinary expression, so it can come from a row. `retail` customers are
registered across five zones; here is how much the UTC calendar disagrees with theirs.

```sql
WITH zone_of (country, tz) AS (
  VALUES ('IN','Asia/Kolkata'),     ('SG','Asia/Singapore'),
         ('AE','Asia/Dubai'),       ('US','America/New_York'),
         ('AU','Australia/Sydney')
)
SELECT z.country,
       count(*)                                        AS orders,
       count(*) FILTER (
         WHERE (o.placed_at AT TIME ZONE z.tz)::date
            <> (o.placed_at AT TIME ZONE 'UTC')::date) AS moved_day
FROM   orders o
JOIN   customers c ON c.id = o.customer_id
JOIN   zone_of  z ON z.country = c.country
GROUP  BY z.country
ORDER  BY moved_day DESC;
```

```text
 country | orders | moved_day 
---------+--------+-----------
 IN      |   1568 |       358
 AU      |    103 |        50
 AE      |    248 |        41
 US      |    227 |        35
 SG      |    108 |        35
(5 rows)
```

23% of Indian orders and half of Australian ones fall on a different calendar day depending
on which of two perfectly reasonable definitions you use. At month boundaries that leakage
moves revenue between periods:

```sql
SET TIME ZONE 'UTC';
SELECT date_trunc('month', placed_at)::date AS month, count(*) AS orders
FROM   orders WHERE placed_at >= TIMESTAMPTZ '2026-05-01 00:00:00+00'
GROUP  BY month ORDER BY month;
```

```text
   month    | orders 
------------+--------
 2026-05-01 |     84
 2026-06-01 |     79
 2026-07-01 |     88
 2026-08-01 |     80
 2026-09-01 |      3
(5 rows)
```

```sql
SELECT date_trunc('month', placed_at AT TIME ZONE 'Asia/Kolkata')::date AS month,
       count(*) AS orders
FROM   orders WHERE placed_at >= TIMESTAMPTZ '2026-05-01 00:00:00+00'
GROUP  BY month ORDER BY month;
```

```text
   month    | orders 
------------+--------
 2026-05-01 |     83
 2026-06-01 |     78
 2026-07-01 |     90
 2026-08-01 |     80
 2026-09-01 |      3
(5 rows)
```

88 orders in July, or 90 — the two numbers this chapter opened with. Both correct; neither
correct *by default*. Somebody has to decide, write the zone into the query, and put it on
the report, and that decision belongs in the schema review rather than in whichever BI tool
renders it last.

`date_trunc` only knows calendar units. For five-minute or six-hour rollups, reach for
`date_bin(INTERVAL '6 hours', recorded_at, origin)`, which slices the timeline into
fixed widths from an origin you supply. It counts elapsed time and knows nothing about DST,
so in a zone that shifts its buckets drift an hour off the wall clock — right for rate
calculations, wrong for "the 09:00 to 15:00 shift". Practice Session 14.2 uses it.

### Filter on the column, bucket on the expression

This is why `(placed_at AT TIME ZONE ...)::date` belongs in `GROUP BY` and never in `WHERE`.
A 500,000-row table with a plain B-tree index on a `timestamptz` column, asked for one day
two ways:

```sql
EXPLAIN SELECT count(*) FROM events
WHERE occurred_at >= TIMESTAMPTZ '2026-06-01 00:00:00+05:30'
  AND occurred_at <  TIMESTAMPTZ '2026-06-02 00:00:00+05:30';
```

```text
 Aggregate  (cost=48.67..48.68 rows=1 width=8)
   ->  Index Only Scan using events_occurred_at_idx on events  (cost=0.42..45.08 rows=1433 width=0)
         Index Cond: ((occurred_at >= '2026-06-01 00:00:00+05:30'::timestamp with time zone) AND (occurred_at < '2026-06-02 00:00:00+05:30'::timestamp with time zone))
(3 rows)
```

```sql
EXPLAIN SELECT count(*) FROM events WHERE occurred_at::date = DATE '2026-06-01';
```

```text
 Finalize Aggregate  (cost=8118.55..8118.56 rows=1 width=8)
   ->  Gather  (cost=8118.44..8118.55 rows=1 width=8)
         Workers Planned: 1
         ->  Partial Aggregate  (cost=7118.44..7118.45 rows=1 width=8)
               ->  Parallel Seq Scan on events  (cost=0.00..7114.76 rows=1471 width=0)
                     Filter: ((occurred_at)::date = '2026-06-01'::date)
(6 rows)
```

An `Index Only Scan` against a `Parallel Seq Scan`, estimated cost 48.67 against 8118.55.
Run them: 0.389 ms against 15.687 ms in median, reading 8 buffers against 2,703.
Wrapping the indexed column in a cast hides it from the index — the planner cannot know
`::date` is monotonic — so it reads every row and casts each one. (Row estimates vary a few
percent between `ANALYZE` runs, which sample.) The `::date` version is zone-dependent too,
returning different rows to different sessions: wrong on two axes.

The fix is the **half-open range**: `>= start AND < next_start`, both bounds written as
`timestamptz`. Index-friendly, explicit about its zone, and unlike `BETWEEN` it cannot
double-count the boundary microsecond. Chapter 33 covers expression indexes for when you
genuinely must group and filter on the same derived value.


## 14.8 What is not in this chapter

`tstzrange` models a validity period as one value, with overlap operators and an exclusion
constraint that makes double-booking impossible: Chapter 16 and Practice Session 15.2.
Monthly partitions on a `timestamptz` column, pruning, and retention by dropping a partition
are Chapter 38. `generate_series` supplies the date axis a `GROUP BY` cannot invent for days
with no rows — Practice Session 12.3. `LAG`/`LEAD` over time buckets is Chapter 25.

---

## Summary

- **Default to `timestamptz`.** It and `timestamp` both occupy eight bytes, which is the
  proof that neither stores a zone: `timestamptz` holds an instant, in microseconds from
  2000-01-01 UTC. An offset in a literal is *input* — used to compute the instant, then
  discarded.
- Ordering, comparison and subtraction on `timestamptz` are zone-independent. Display,
  `::date`, `date_trunc` and `EXTRACT` re-apply the session's zone on the way out.
- **`timestamp` truncates the offset silently**, storing three different values for one
  instant with no error. Comparing it to `timestamptz` is legal and the result changes with
  the session zone, so one query returns different rows to different connections. Use it
  only where the wall clock is the fact, with the zone name stored beside it; use `date` for
  calendar days.
- `AT TIME ZONE` inverts itself: on a `timestamptz` it yields a `timestamp`, on a `timestamp`
  a `timestamptz`. Name zones by IANA name — `IST` in PostgreSQL's abbreviation table is
  **Israel Standard Time, UTC+02:00**, not India's, and using it moves every value three and
  a half hours with no error.
- `now()` is transaction time and does not advance; `clock_timestamp()` does.
- `INTERVAL '1 day'` and `INTERVAL '24 hours'` compare as equal and add differently across a
  DST boundary. `-` gives elapsed time (23:00:00), `age()` gives calendar time (1 day).
- Local times need not exist or be unique. PostgreSQL shifts a non-existent one forward and
  picks the post-transition reading for an ambiguous one, without complaint. Converting
  `timestamptz` → `timestamp` is not reversible.
- **`date_trunc` on a `timestamptz` resolves boundaries in the session's `TimeZone`.** Pin it
  with `(col AT TIME ZONE 'Asia/Kolkata')`. The three-argument `date_trunc` returns a
  `timestamptz`, so casting its result to `date` undoes the pinning.
- Filter on the raw column with a half-open range so an index can serve it; put the bucket
  expression in `GROUP BY`. `WHERE col::date = ...` forfeits the index *and* is
  zone-dependent.

**Exercises:** Practice Sessions 14.1–14.3 accompany this chapter and are in the workbook at
the back of the book.

**Next:** types stop bad values from being *representable*; constraints stop them from being
*stored*. Chapter 15, *Constraints and Referential Integrity*, covers `NOT NULL`, `UNIQUE`,
`CHECK`, primary and foreign keys, deliberate `ON DELETE` behaviour, deferrable and exclusion
constraints, and how to add a foreign key to a large table without holding a lock all day.
