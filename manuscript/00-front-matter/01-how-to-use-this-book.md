# How to Use This Book

## What you need before Chapter 1

- **macOS or Linux.** Every command in this book was run on one or the other. If you are
  on Windows, install WSL2 with Ubuntu and follow the Linux instructions throughout; we
  will not mention Windows again.
- **PostgreSQL 15 or newer.** Chapter 2 walks you through installing it. Do not skip
  ahead and try to follow along on PostgreSQL 12 — several things in this book do not
  exist there, and a few behave differently in ways that will confuse you.
- **A terminal, and `psql`.** Graphical clients are fine and we mention good ones, but
  every example is shown in `psql` because it is the one tool guaranteed to be on every
  machine you will ever have to fix.

Check what you have:

```bash
psql --version
```

```text
psql (PostgreSQL) 15.10
```

Anything numbered 15 or higher is fine. If that command fails, go to Chapter 2.

## Practice Sessions

The hands-on work lives in a **workbook at the back of the book**, not inside the
chapters. Each chapter ends with a pointer to its sessions; the sessions themselves are
collected together so you can work through them with the chapter open beside you, or come
back to them later without hunting through prose.

Sessions are numbered **`p.q`** — chapter, then session. Practice Session 9.3 is the
third session in Chapter 9. The `q` restarts at 1 in every chapter, so the pair always
tells you where a session belongs.

Every session is laid out the same way:

> **Goal** — what you will have achieved.
> **Setup** — SQL or shell commands to run first.
> **Task** — what to do.
> **Solution** — the answer, and why it is the answer.

Do the task before reading the solution. The solutions explain reasoning that only makes
sense once you have tried it and hit the thing it is warning you about.

Sessions never require knowledge from a later chapter. They frequently build on earlier
ones.

## The sample datasets

Three datasets run through the whole book, so that by Chapter 30 you already know the
schema and can concentrate on the technique:

| Dataset     | Tables                                              | Where it is used                  |
|-------------|-----------------------------------------------------|-----------------------------------|
| `retail`    | `products`, `customers`, `orders`, `order_items`    | joins, aggregation, schema design |
| `telemetry` | `devices`, `device_events`                          | indexing, partitioning, `EXPLAIN` |
| `hr`        | `departments`, `employees`, `salary_history`        | recursion, window functions       |

The data is Indian throughout — customers in Mumbai, Bengaluru and Kochi, an `orders`
table denominated in rupees, an `hr` hierarchy seven levels deep.

Each comes in two sizes. The **small** variant (around ten thousand rows) is for learning
syntax — queries return instantly and you can read the whole result. The **large** variant
(ten million rows and up) is for the performance chapters, where the entire point is that
the small one is too small to teach you anything.

Loading instructions are in Chapter 2, Practice Session 2.3.

> **A word on the large datasets —** all three together take roughly two minutes to
> generate and occupy about 3.5 GB (`telemetry` alone is 2.4 GB of the total). Generate
> them when you reach Part VIII; you do not need them before that, and the small variants
> load in about a second.

## Conventions on the page

SQL keywords are uppercase, identifiers are lowercase `snake_case`:

```sql
SELECT customer_id, count(*) AS order_count
FROM   orders
WHERE  placed_at >= '2026-01-01'
GROUP  BY customer_id;
```

Output is shown exactly as `psql` prints it:

```text
 customer_id | order_count
-------------+-------------
        1042 |          17
        1088 |           9
(2 rows)
```

Shell commands are prefixed with nothing; you are expected to know you are in a terminal:

```bash
createdb retail
```

Three kinds of callout interrupt the text, and all three are worth stopping for:

> **Version note —** behaviour that differs between PostgreSQL releases. Ignore these if
> you are on a recent version and everything works.

> **Trap —** something that looks correct, runs without error, and produces wrong results
> or terrible performance. These are the most valuable paragraphs in the book.

> **In production —** the difference between what works on your laptop and what works on
> a system with real data and real concurrency. Skip these while learning; come back to
> them before you ship.

## Reading paths

**You are new to SQL.** Chapters 1 through 17 in order, then stop and build something
real. Come back for Part V when you have felt the pain of a schema you regret.

**You know SQL from another database.** Start at Chapter 7 for NULL semantics, then
Part IV for the types that are genuinely Postgres-specific, then go straight to Part V.
Appendix F lists what transfers from MySQL, SQL Server and Oracle and what silently does
not.

**You write application queries and something is slow.** Chapter 34 is the one you want
— the deep dive on `EXPLAIN`. Read Chapter 30 on MVCC first even though you will be
tempted not to; half of what Chapter 34 shows you is MVCC consequences, and the chapter
will not land without it. Then Chapters 33, 35, 36 and 39.

**You are designing a new system.** Part V, all of it, before you write a single
`CREATE TABLE`. Then Chapter 38 on partitioning and Chapter 52 on migrations, so that the
decisions you make now stay changeable later.

**You just got handed the database.** Part VII, then Part X, then Chapter 39. Then set up
the monitoring in Chapter 48 before you need it.

**You are on an incident right now.** Chapter 39. Appendix E has the diagnostic queries
in copy-paste form. Come back and read the rest afterwards.

## If something does not work

Every SQL statement in this book was executed against a real PostgreSQL instance before
publication. If a command fails for you, check your version first — it is the cause more
often than anything else.
