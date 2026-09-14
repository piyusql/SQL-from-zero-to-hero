# Preface

## Who Andy W. Pearson is

There is no Andy W. Pearson. The name is three people, and it is assembled the way
everything else in this book is — out of parts that each had to earn their place.

**Andy** is Anand K Gupta.
**W** is Tarun Kumar, though nobody who knows him calls him that. He is *Dablu*, the name
his maa gave him.
**Pearson** is Piyus Kumar.

We met at college. In 2006, in our third year, we discovered databases at roughly the same
time and in roughly the same way — by being handed something that was slow and being
unable to explain why. We spent that year arguing about indexes with more confidence than
any of us had earned, and somewhere in the middle of it we said we would write a book
about this one day.

Students say that kind of thing. It is usually the last anyone hears of it.

This is twenty years later. In between, the three of us went in different directions and
kept ending up in the same conversation. We have worked on Microsoft SQL Server, on
Oracle, on MySQL, and eventually on PostgreSQL — sometimes by choice, often because it
was what the company already had. That route matters to what is in this book. When you
have watched four systems solve the same problem four different ways, you stop believing
that the way your current database does it is the only way, or the obvious one, and you
start being able to say *why* it made that choice.

We landed on PostgreSQL and stayed, and the thing that kept surprising us was scale. Not
that it is fast — plenty of things are fast on a laptop. It is that the behaviour stays
*explainable* as the data grows. The query planner tells you what it decided and roughly
why. The statistics that produced the decision are readable. When something degrades at
ten million rows that was fine at ten thousand, there is almost always a number you can
go and look at that explains it. That is rarer than it sounds, and most of this book is
us trying to hand over how to go and look.

So: three authors, one name, a promise made in a classroom in 2006, and two decades of
being wrong about databases in public until we were occasionally right.

## Why the book has the title it does

*Zero to hero* is a large promise, and the shelf this book will sit on is full of titles
that make it without meaning it. So it is worth being precise about both ends before you
spend your time on us.

**Zero means zero.** Chapter 1 does not assume you have used a database. It assumes you
are comfortable in a terminal and have seen a loop in some programming language, and it
starts from why a database exists at all. If you already write SQL every day, the reading
paths in the next section will tell you where to jump in.

**Hero is the harder half**, and it is not what the phrase usually implies. It does not
mean you will have memorised more syntax than your colleagues. Syntax you can look up, and
the PostgreSQL documentation is better at it than we are. It means **judgement**: knowing
which of the six ways to do this thing will still be a good idea in three years, at a
hundred times the data volume, when the person maintaining it has never met you. Knowing
which query plan should worry you. Knowing what the `ALTER TABLE` you are about to run
will do to a table with two hundred million rows in it.

That knowledge is normally transmitted by apprenticeship: by sitting near someone who has
already made the mistake. Most people never get that. This book is our attempt to write it
down.

The distance between the two ends of the title is the whole point, and we have tried hard
not to skip the middle. Every technique arrives with the scale at which it stops working.

The elephant on the cover is a painting by **Neha Shree** — Piyus's wife — made by hand,
in oils, by someone who has never written a line of SQL and who put up with a great deal
of talk about query planners during the months this book was written. PostgreSQL's mascot
is an elephant called Slonik, and it felt right that ours should be one somebody painted
rather than one somebody licensed. Every copy of this book carries her work on the front,
which is a better outcome than any stock image we could have bought.

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

Every SQL statement in this book was run before it was printed. The numbers are
measurements, not estimates.

## Acknowledgements

To everyone who has ever handed us a slow query and a production incident at the same
time: you taught us more than any documentation did.

To the maa who named Dablu, and to everyone else who put up with three friends who never
quite stopped talking about databases.

And to **Neha Shree**, who painted the elephant. You gave this book its face. Thank you.
