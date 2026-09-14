-- retail — large generator (~7,300,000 rows)
--
-- Same shape as seed-sm.sql, three orders of magnitude bigger, built with
-- generate_series so nothing large is committed to the repository. Uses random()
-- rather than md5(): at this size the hashing would dominate, and the exact values
-- do not matter once the result set is too big to read.
--
-- The data properties the book depends on are preserved at this size:
--   * customers with no orders at all     (Chapter 9, LEFT JOIN)
--   * NULLs in referred_by                (Chapter 7, the NOT IN trap)
--   * multi-line orders                   (Chapter 9.4, fan-out inflating a SUM)
--   * 'IN' dominant, minorities non-trivial (Chapter 1)

\set ON_ERROR_STOP on
\timing on

\echo ''
\echo '>> retail (lg): 5,000 products, 300,000 customers, 2,000,000 orders, ~5,000,000 order items.'
\echo ''

TRUNCATE order_items, orders, customers, products RESTART IDENTITY CASCADE;

-- ---------------------------------------------------------------- products (5,000)
\echo '>> products'
INSERT INTO products (id, sku, name, category, price, in_stock, created_at)
SELECT i,
       'SKU-' || lpad(i::text, 5, '0'),
       (ARRAY['Ganga','Konark','Mysuru','Jaipur','Nilgiri',
              'Chola','Deccan','Kaveri','Aravalli','Sundar'])[1 + (i % 10)]
         || ' ' ||
       (ARRAY['Diya','Charpai','Almirah','Thali','Jharokha',
              'Dhurrie','Surahi','Mudha','Parat','Chowki'])[1 + ((i / 10) % 10)]
         || ' ' || i,
       (ARRAY['furniture','lighting','kitchen','decor','storage'])[1 + (i % 5)],
       round((4.50 + random() * 390)::numeric, 2),
       random() > 0.06,
       timestamptz '2023-01-01 00:00:00+00' + (floor(random() * 700)::integer) * interval '1 day'
FROM generate_series(1, 5000) AS i;

-- ---------------------------------------------------------------- customers (300,000)
\echo '>> customers'
INSERT INTO customers (id, name, email, country, city, signup_date, loyalty_tier, referred_by)
SELECT i,
       (ARRAY['Rajesh','Anita','Priya','Arjun','Fatima','Harpreet','Meera','Vikram','Lakshmi','Imran',
              'Sneha','Karthik','Divya','Rohit','Ananya','Suresh','Kavita','Aditya','Nisha','Farhan'])[1 + floor(random() * 20)::integer]
         || ' ' ||
       (ARRAY['Kumar','Rao','Menon','Iyer','Sheikh','Singh','Banerjee','Patel','Reddy','Chatterjee',
              'Nair','Desai','Gupta','Pillai','Joshi','Mukherjee','Shetty','Bhat','Kulkarni','Verma'])[1 + floor(random() * 20)::integer],
       'customer' || i || '@vyapar.example',
       (ARRAY['IN','IN','IN','IN','IN','IN','IN','IN','IN','IN',
              'IN','IN','US','US','AE','AE','SG','GB','AU','MY'])[1 + floor(random() * 20)::integer],
       CASE WHEN random() < 0.12 THEN NULL
            ELSE (ARRAY['Mumbai','Delhi','Bengaluru','Hyderabad','Chennai','Kolkata','Pune','Ahmedabad',
                        'Jaipur','Kochi','Lucknow','Chandigarh','Indore','Coimbatore','Surat','Nagpur',
                        'Bhubaneswar','Visakhapatnam','Guwahati','Mysuru'])[1 + floor(random() * 20)::integer] END,
       date '2021-06-01' + floor(random() * 1700)::integer,
       CASE WHEN random() < 0.40 THEN NULL
            ELSE (ARRAY['gold','silver','bronze'])[1 + floor(random() * 3)::integer] END,
       CASE WHEN i > 1000 AND random() < 0.30
            THEN 1 + floor(random() * (i - 1))::integer
            ELSE NULL END
FROM generate_series(1, 300000) AS i;

ANALYZE customers;
ANALYZE products;

-- ---------------------------------------------------------------- orders (2,000,000)
-- Only customers 1..255,000 ever order, leaving ~45,000 with none.
-- NOTE ON `OFFSET 0`
-- Every random() below sits inside a subquery ending in OFFSET 0. That is an
-- optimisation fence, and it is load-bearing, not decoration.
--
-- Without it the planner pulls the subquery up into the outer query. A volatile
-- function in a FROM item that does not reference the outer row then gets evaluated
-- ONCE for the whole scan rather than once per row — and you silently get two
-- million orders that all share a single placed_at and a single status. The fence
-- keeps the evaluation per-row, and also guarantees that a value referenced twice
-- (placed_at, used again to derive shipped_at) is the same value both times.
\echo '>> orders'
INSERT INTO orders (id, customer_id, placed_at, shipped_at, status, discount_code, total_amount)
SELECT g.id,
       g.customer_id,
       g.placed_at,
       CASE WHEN g.status IN ('shipped','delivered','returned')
            THEN g.placed_at + g.ship_lag
            ELSE NULL END,
       g.status,
       g.discount_code,
       0
FROM (
    SELECT i AS id,
           1 + floor(random() * 255000)::integer AS customer_id,
           timestamptz '2024-01-01 00:00:00+00'
               + (random() * 975) * interval '1 day'                    AS placed_at,
           (1 + floor(random() * 96)::integer) * interval '1 hour'      AS ship_lag,
           (ARRAY['delivered','delivered','delivered','shipped','shipped',
                  'paid','pending','cancelled','returned','delivered'])[1 + floor(random() * 10)::integer] AS status,
           CASE WHEN random() < 0.17
                THEN (ARRAY['WELCOME10','DIWALI25','FREESHIP','VIP15'])[1 + floor(random() * 4)::integer]
                ELSE NULL END                                           AS discount_code
    FROM generate_series(1, 2000000) AS i
    OFFSET 0
) AS g;

-- ---------------------------------------------------------------- order_items (~5,000,000)
-- 1 to 4 lines per order, averaging 2.5. The line count comes from a fenced
-- subquery for the same reason as above: a bare random() in the generate_series
-- argument is evaluated once and every order ends up with an identical line count,
-- which would flatten the Chapter 9.4 fan-out exercise.
\echo '>> order_items'
INSERT INTO order_items (order_id, product_id, quantity, unit_price)
SELECT g.order_id,
       p.id,
       g.quantity,
       round((p.price * g.price_factor)::numeric, 2)
FROM (
    SELECT o.id                                     AS order_id,
           1 + floor(random() * 5000)::integer      AS product_id,
           1 + floor(random() * 5)::integer         AS quantity,
           0.85 + random() * 0.30                   AS price_factor
    FROM (SELECT id, 1 + floor(random() * 4)::integer AS lines
          FROM orders
          OFFSET 0) AS o
    CROSS JOIN LATERAL generate_series(1, o.lines) AS ln
    OFFSET 0
) AS g
JOIN products p ON p.id = g.product_id;

\echo '>> reconciling orders.total_amount with order_items'
UPDATE orders o
SET    total_amount = t.amt
FROM  (SELECT order_id, sum(quantity * unit_price) AS amt
       FROM order_items GROUP BY order_id) t
WHERE t.order_id = o.id;

ALTER TABLE products  ALTER COLUMN id RESTART WITH 5001;
ALTER TABLE customers ALTER COLUMN id RESTART WITH 300001;
ALTER TABLE orders    ALTER COLUMN id RESTART WITH 2000001;

-- That UPDATE rewrote every order row. Reclaim the dead tuples now rather than
-- shipping a dataset that is 40% bloat before the reader has done anything.
\echo '>> vacuum and analyze'
VACUUM (ANALYZE) orders;
ANALYZE;

SELECT pg_size_pretty(pg_database_size(current_database())) AS retail_lg_on_disk;
