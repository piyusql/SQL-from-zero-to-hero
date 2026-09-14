# Preface

## Why this book has the title it does

Technical books are not usually named after feelings. The shelf this one will sit on is
full of *Mastering*, *Definitive*, *In Action*, *The Complete Guide To* — titles that
promise coverage, which is a reasonable thing to promise and a dull thing to say.

We called this one *SQL from My Heart* because that is honestly how the three of us came
to it. Between us we have spent the better part of two decades with PostgreSQL: designing
schemas that outlived the companies that commissioned them, being paged at two in the
morning because a query plan flipped, and slowly accumulating the kind of knowledge that
does not fit in documentation because it is not really about syntax at all. It is about
judgement. Which of the six ways to do this thing will still be a good idea in three
years, at a hundred times the data volume, when the person maintaining it has never met
you.

That kind of knowledge is usually transmitted by apprenticeship — by sitting near someone
who has already made the mistake. Most people never get that. This book is our attempt to
write it down.

The elephant on the cover is a painting. It was made for us, by hand, by someone who has
never written a line of SQL and who put up with a great deal of talk about query planners
during the months this book was written. PostgreSQL's mascot is an elephant called
Slonik, and it felt right that ours should be one somebody painted rather than one
somebody licensed.

## Who this book is for

Two people, and they are rarely the same person.

**The application engineer** writes the queries. You own whether the feature is fast,
whether the schema will still make sense next year, and whether the page loads. You
probably cannot SSH into the database host, and may not want to. Your path is Parts I
through IX, then Part XI. Part VIII, on performance engineering, is written for you
specifically — it assumes you can read a query plan and change a query, but not that you
can restart the server.

**The platform owner** runs the cluster. Backups, replication, failover, capacity,
configuration, the pager. Parts VII through XII are yours. You may already know
Parts I through VI; skim them for the Postgres-specific behaviour and move on.

We have deliberately kept these apart. Books that mix "here is how to write a good join"
with "here is how to configure WAL archiving" serve neither reader well, and most people
genuinely only need one of the two. Part X, on administration, is self-contained. If you
never open it, the rest of the book still works.

If you are new to databases entirely, start at Chapter 1 and go in order. The book is
built so that each part earns the next.

## What this book assumes

That you are comfortable in a terminal. That you can install software on your own machine.
That you have seen a programming language, any programming language, well enough to
recognise a loop.

It does not assume you have used a database before.

## What this book is not

It is not a reference manual. The PostgreSQL documentation is genuinely excellent — better
than the documentation for almost any other piece of infrastructure software — and we are
not going to reproduce it badly. When you need to know every option of `CREATE INDEX`, go
there. When you need to know which index to create and why, come here.

It is not neutral. Where twenty years of experience has produced an opinion, you get the
opinion, and you get the reasoning so you can disagree with it on purpose. Where something
is genuinely a trade-off, we say so and show you both sides. What we have tried never to
do is present a real decision as though it were obvious.

And it is not a book about PostgreSQL's internals for their own sake. We go into MVCC in
some depth, but only because you cannot reason about bloat, vacuum lag, or lock waits
without it — and those three things cause a startling proportion of all production
database incidents. Everything we teach, we teach because it eventually shows up on a
pager.

## A note on scale

A lot of database advice is written as though every table were small. It is easy to write
a chapter on indexing that never mentions what happens when the index no longer fits in
memory, or a chapter on migrations that never mentions the lock you are about to take on a
table with two hundred million rows in it.

We have tried to write the other kind of book. Where a technique stops working at scale,
we say where it stops. Where a decision only matters at scale, we flag it early enough
that you can make it before it is expensive to change. The subtitle says *to terabyte
scale* and we meant it literally.

## Acknowledgements

To everyone who has ever handed us a slow query and a production incident at the same
time: you taught us more than any documentation did.

And to the painter of the elephant. This book is for you.

---

*Andy W. Pearson* is the shared name of three engineers who have built, broken and
repaired PostgreSQL systems across finance, logistics and infrastructure. They write
together because no one of them has seen all of it.
