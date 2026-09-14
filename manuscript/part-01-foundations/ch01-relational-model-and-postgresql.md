# Chapter 1 — The Relational Model and Why PostgreSQL

There is a particular moment, usually two or three years into a system's life, when
somebody opens the database and discovers that the schema no longer describes the
business. Columns named `flag_2`. A table called `user_data_new`. A `status` column
holding eleven values, four of which nobody can define. Somewhere in the application
there is a comment that says *do not change this, it breaks reporting*, and nobody knows
why.

That system was not built by fools. It was built by people who knew SQL syntax perfectly
well and never learned the model underneath it. Syntax you can look up. The model is what
tells you, on a Tuesday afternoon with a deadline, whether the column you are about to
add belongs on this table or a different one.

So we start there, and we will not be long about it.

---

## 1.1 What a database is actually for

Any program that outlives a single run needs to put its data somewhere. A file will do
this. Files are fast, simple, and free.

Files stop working the moment you need any of the following:

**Two things happening at once.** Two users edit the same record. With a file, one
silently overwrites the other, and you find out weeks later from a customer.

**Partial failure.** You are moving money between two accounts. The debit succeeds, the
process is killed, and the credit never happens. The money is gone. There is no sequence
of file operations that makes this impossible.

**Asking questions you did not plan for.** Your file format was designed to look up a
customer by ID. Someone now wants every customer in Karnataka who ordered twice last
quarter. With a file, that is a new program. Every question is a new program, forever.

**Rules that must always hold.** An order must belong to a customer who exists. A
quantity may not be negative. In a file, these are conventions enforced by whichever
code paths remembered to check.

A database management system exists to solve exactly those four problems: concurrency,
atomicity, ad-hoc querying, and integrity. Everything else it does — indexes, replication,
query planning — is in service of doing those four things at acceptable speed.

Keep that list in mind, because it is also a checklist for when you *do not* need a
database. Configuration that one process reads at startup does not need one. A cache you
can rebuild does not need one. Reaching for Postgres by reflex is its own kind of mistake.

## 1.2 The relational model

In 1970 Edgar Codd, then at IBM, published *A Relational Model of Data for Large Shared
Data Banks*. Databases at the time were navigational: to find a record you followed
pointers from one record to another, and the path you followed was baked into your
program. Move the data and every program broke.

Codd's proposal was to stop describing *where data is* and start describing *what is
true*. It rests on a small number of ideas.

A **relation** is a set of facts of the same shape. In practice, a table.

A **tuple** is one fact. In practice, a row.

An **attribute** is one named, typed component of that fact. In practice, a column.

A table of customers is therefore a set of statements: *there is a customer with ID 1042,
named Anita Rao, in Bengaluru.* Every row asserts one such statement. The table is the
complete set of them.

Two consequences follow, and both matter more than they first appear.

**A relation is a set, so order is not information.** Rows have no inherent position.
If you want results in an order, you must say so with `ORDER BY`, every single time.
A query that comes back sorted without one is an accident of how the rows happened to be
read today, and it will change the day someone adds an index.

> **Trap —** this is the single most common source of "it worked yesterday" bugs in
> application code. If your test asserts on the first row of an unordered query, your
> test is lying to you. It will pass for a year and fail in production.

**The logical structure is separate from the physical storage.** You describe the shape
of the data. The database decides how to store it, which indexes to consult, and in what
order to do the work. Codd called this *physical data independence*, and it is the reason
you can add an index to a live system and make every existing query faster without
changing a line of application code.

That second consequence is the foundation of everything in Part VIII of this book. When
we spend an entire chapter on `EXPLAIN`, we are examining the decisions the database made
on your behalf under exactly this separation.

### Relationships are facts too

There is no special mechanism in the relational model for "this order belongs to this
customer". There is just another attribute. The `orders` table has a `customer_id`
column, whose value matches an `id` in `customers`. That is the whole idea. We declare it
to the database as a **foreign key** so that it stays true, but the relationship itself
is nothing but a value appearing in two places.

This is why the relational model scales conceptually. There is exactly one structure —
the relation — and everything is expressed in it. Compare that to a document store, where
"belongs to" might be nesting, or a reference, or duplication, depending on who wrote that
part of the schema.

## 1.3 Declarative thinking

Here is the mental shift that separates people who fight SQL from people who use it.

In most programming, you write *how*. Loop over this collection, test each element,
accumulate a result. You control the order of operations, and if the program is slow, it
is slow because of choices you made.

In SQL you write *what*. You describe the set of rows you want to exist in the answer. You
do not say how to find them.

Consider: *for each customer in Bengaluru, how many orders did they place in 2026?*

```sql
SELECT   c.name,
         count(o.id) AS order_count
FROM     customers c
JOIN     orders o ON o.customer_id = c.id
WHERE    c.city = 'Bengaluru'
AND      o.placed_at >= '2026-01-01'
GROUP BY c.name;
```

Nothing in that statement says which table to read first. Nothing says whether to use an
index. Nothing says how to perform the join. Those decisions belong to the **query
planner**, which will consider the available indexes, its statistics about how many
customers are in Bengaluru, how much memory it has, and then choose.

And it will choose *differently on different days*. With a thousand customers it may read
the whole table. With ten million and a good index it will not. The query you wrote does
not change; the plan does.

This is a bargain, and it is worth being clear about both sides of it.

What you gain: you write far less code, the database adapts to changing data volumes
without you rewriting anything, and you can add an index later to speed up a query written
years ago.

What you give up: direct control. When the planner chooses badly — and it will, because
it is reasoning from statistics that are estimates — you cannot simply tell it what to do.
PostgreSQL deliberately has no query hints. You influence the planner by giving it better
information: accurate statistics, useful indexes, queries whose shape it can reason about.

Learning to do that well is most of what Part VIII teaches. But it starts here, with
accepting that your job is to describe the answer precisely and then to understand the
machine that decides how to compute it.

> **In production —** the most common cause of a query that was fast for two years and is
> suddenly slow is not a code change. It is a data change that made a previously good plan
> a bad one. Chapter 35 is about why that happens.

## 1.4 SQL, the standard, and the dialects

SQL was built at IBM in the 1970s to implement Codd's model, and was first standardised in
1986. The standard has been revised many times since — SQL:1999 added recursion,
SQL:2003 added window functions, SQL:2016 added JSON, and so on.

No database implements the standard completely. Every database adds things the standard
does not cover. The result is that "SQL" is a family of closely related languages rather
than one language, and code that runs on MySQL may not run on PostgreSQL.

PostgreSQL sits at the compliant end of that spectrum — it tracks the standard closely,
and where it extends it, it tends to do so in ways later standards adopt. This has a
practical benefit worth naming: what you learn here transfers. The window functions in
Chapter 25 work nearly identically in SQL Server and Oracle. The `EXPLAIN` output in
Chapter 34 does not transfer at all.

Appendix F covers what carries across and what quietly does not. If you are arriving from
another database, read it early — the differences that hurt are not the ones that throw
syntax errors, they are the ones that run fine and mean something else.

## 1.5 Why PostgreSQL

Postgres began in 1986 at Berkeley as Michael Stonebraker's successor to Ingres — hence
*post-Ingres*. It did not originally speak SQL; that arrived in 1995, and the project was
renamed PostgreSQL in 1996 when it moved to the open internet and the community took over.

It has been developed that way ever since, and the governance is worth understanding
because it explains the software's character. There is no company that owns PostgreSQL.
There is no open-core edition with the good features held back, and no licensing event
waiting to happen to you in five years. The license is permissive — you may do essentially
anything with it. Development is by a distributed group of contributors, many employed by
competing companies, none of whom can unilaterally decide anything.

The effect of that on the codebase is conservatism. Features arrive slowly and correct
rather than quickly and provisional. Data loss bugs are treated as emergencies. Backward
compatibility is taken seriously to a degree that occasionally frustrates people who want
a new behaviour. When you are responsible for something that must not lose data, this is
the temperament you want.

Beyond governance, four things make it the default recommendation.

**Correctness under concurrency.** PostgreSQL uses multi-version concurrency control.
Readers never block writers and writers never block readers, because a reader sees a
consistent snapshot of the database as of the moment its statement or transaction began.
This is the foundation of its concurrency behaviour and the source of several of its
operational quirks — dead tuples, vacuum, bloat. We give it a full chapter, Chapter 30,
and we put it *before* the performance chapters because those quirks are the subject of a
large fraction of real incidents.

**Extensibility as an architectural principle.** Most databases are closed systems.
PostgreSQL was designed from the start to let you add types, operators, functions, index
methods and entire procedural languages, and the extension mechanism is a first-class
part of the system rather than a plugin afterthought. This is why one engine credibly
handles relational data, JSON documents, full-text search, geospatial data with PostGIS,
and vector similarity with `pgvector`. Chapter 49 covers the extensions worth knowing.
The practical consequence is that many teams who would otherwise be running four
datastores are running one.

**Data types that mean something.** Postgres has native types for ranges, arrays, network
addresses, UUIDs, intervals, and JSON with real indexing. This is not a convenience
feature. Every time you store a date as text or an IP address as `varchar`, you have moved
a correctness guarantee out of the database and into whichever application code remembers
to enforce it. Part IV is about taking those guarantees back.

**It is boring at scale.** Terabyte PostgreSQL installations are unremarkable. The tooling
for backup, replication, failover, monitoring and partitioning is mature and well
understood, and the failure modes are documented by twenty years of people hitting them
in public.

The mascot, incidentally, is an elephant named Slonik — *little elephant* in Russian. The
association goes back to a mailing list suggestion invoking Agatha Christie's *Elephants
Can Remember*. It is a better mascot than most, and for a database whose defining property
is not losing things, it is well chosen.

## 1.6 Where PostgreSQL is the wrong answer

A book that never says this is selling something.

**Very high connection counts without pooling.** PostgreSQL allocates a process per
connection. Processes are not cheap. A few hundred concurrent connections is comfortable;
several thousand direct connections will hurt, and the fix is a connection pooler rather
than a bigger machine. This catches out teams arriving from databases with a threaded
model, and it is common enough that we devote most of Chapter 50 to it.

**Write throughput beyond one machine.** PostgreSQL scales reads across replicas easily.
Writes go to one primary. There is no supported built-in multi-master. If your write
volume genuinely exceeds what one large machine can absorb, you are looking at sharding —
Citus, or doing it in the application — and both carry real complexity. Chapter 53 is
honest about where that line is, and it is much further out than most people assume.

**Large-scale analytical scanning.** Postgres stores data in rows. Scanning two billion
rows to average one column is work a columnar system does an order of magnitude better.
Postgres will do it; a warehouse built for it will do it faster and cheaper. The right
architecture is frequently Postgres for transactions with analytics offloaded, and
Chapter 53 covers that shape.

**Major version upgrades.** Moving between major versions is a deliberate operation
requiring planning and a maintenance window, or a logical-replication dance to avoid one.
It is entirely manageable and Chapter 47 shows how, but it is not automatic and it should
be in your roadmap rather than a surprise.

None of these are reasons to avoid PostgreSQL. They are reasons to know what you are
signing up for, which is a different thing, and the sort of thing that is much cheaper to
learn now than during an incident.

## 1.7 Versions, and why this book requires 15 or newer

PostgreSQL ships one major version a year, typically in autumn, and supports each for five
years. Minor releases arrive quarterly and contain only bug and security fixes — they are
always safe to apply and you should apply them.

This book requires **PostgreSQL 15 or newer**, and we will not be writing around older
releases. That choice buys clarity: we can use `MERGE`, modern `EXPLAIN` output, and
recent partitioning behaviour without qualifying every example. Where something changed
meaningfully in a later version, you will see a version note.

If you are running something older in production, the book still teaches you what you need
— but install a current version locally to work through it. Chapter 2 shows you how, and
running two versions side by side is genuinely easy.

> **Version note —** the biggest behavioural change readers arriving from older Postgres
> should know about is CTE inlining, which changed in version 12. Advice written before
> then treats `WITH` as an optimisation fence. It is no longer. See Chapter 12.

---

## Summary

- A database earns its complexity by solving four problems that files cannot: concurrency,
  atomicity, ad-hoc querying, and enforced integrity. If you need none of them, you may
  not need a database.
- The relational model represents everything — including relationships — as sets of typed
  facts. Rows have no order unless you ask for one.
- Separating logical structure from physical storage is what lets the database change how
  a query runs without you changing the query. It is the foundation of everything in
  Part VIII.
- SQL is declarative. You describe the answer; the planner chooses the method. You
  influence it with statistics and indexes, never with hints.
- PostgreSQL is community-owned, permissively licensed, conservative about correctness,
  and deliberately extensible. It is the sensible default for transactional systems.
- It is a poor fit for unpooled high connection counts, multi-machine write volume, and
  large-scale columnar analytics. Know this now rather than later.
- This book requires PostgreSQL 15 or newer.

**Exercises:** Practice Sessions 1.1–1.2 accompany this chapter and are in
the workbook at the back of the book.

**Next:** Chapter 2 installs PostgreSQL on macOS or Linux, gets you comfortable in
`psql`, and loads the three sample datasets you will use for the rest of the book.
