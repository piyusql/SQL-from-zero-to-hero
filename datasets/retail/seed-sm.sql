-- retail — small seed (~10k rows total)
--
-- Everything here is DETERMINISTIC. Values come from md5() of the row number, not
-- random(), so every reader gets byte-identical data and the query output printed in
-- the book matches what they see. Do not replace _h() with random().

\set ON_ERROR_STOP on

BEGIN;

TRUNCATE order_items, orders, customers, products RESTART IDENTITY CASCADE;

-- Deterministic hash helper, 0 .. 268435455. Dropped at the end of this file.
CREATE FUNCTION _h(seed text) RETURNS integer LANGUAGE sql IMMUTABLE AS
$$ SELECT ('x' || substr(md5(seed), 1, 7))::bit(28)::integer $$;

-- ---------------------------------------------------------------- products (200)
INSERT INTO products (id, sku, name, category, price, in_stock, created_at)
SELECT i,
       'SKU-' || lpad(i::text, 5, '0'),
       (ARRAY['Ganga','Konark','Mysuru','Jaipur','Nilgiri',
              'Chola','Deccan','Kaveri','Aravalli','Sundar'])[1 + (i % 10)]
         || ' ' ||
       (ARRAY['Diya','Charpai','Almirah','Thali','Jharokha',
              'Dhurrie','Surahi','Mudha','Parat','Chowki'])[1 + ((i / 10) % 10)],
       (ARRAY['furniture','lighting','kitchen','decor','storage'])[1 + (i % 5)],
       round((4.50 + (_h('p' || i) % 39000) / 100.0)::numeric, 2),
       (i % 17) <> 0,
       timestamptz '2023-01-01 00:00:00+00' + (_h('pc' || i) % 700) * interval '1 day'
FROM generate_series(1, 200) AS i;

-- ---------------------------------------------------------------- customers (1000)
-- Country mix is weighted: 'IN' takes 12 of the 20 slots (~60%), with the rest drawn
-- from India's main trade and diaspora partners. Chapter 1's worked example filters
-- on a single country, so the dominant value has to return an interesting number of
-- rows and the minorities have to be non-trivial.
INSERT INTO customers (id, name, email, country, city, signup_date, loyalty_tier, referred_by)
SELECT i,
       (ARRAY['Rajesh','Anita','Priya','Arjun','Fatima','Harpreet','Meera','Vikram','Lakshmi','Imran',
              'Sneha','Karthik','Divya','Rohit','Ananya','Suresh','Kavita','Aditya','Nisha','Farhan'])[1 + (_h('fn' || i) % 20)]
         || ' ' ||
       (ARRAY['Kumar','Rao','Menon','Iyer','Sheikh','Singh','Banerjee','Patel','Reddy','Chatterjee',
              'Nair','Desai','Gupta','Pillai','Joshi','Mukherjee','Shetty','Bhat','Kulkarni','Verma'])[1 + (_h('ln' || i) % 20)],
       'customer' || i || '@vyapar.example',
       (ARRAY['IN','IN','IN','IN','IN','IN','IN','IN','IN','IN',
              'IN','IN','US','US','AE','AE','SG','GB','AU','MY'])[1 + (_h('co' || i) % 20)],
       -- ~12% have no city on file: fuel for COALESCE / IS DISTINCT FROM in Chapter 7
       CASE WHEN _h('ci' || i) % 8 = 0 THEN NULL
            ELSE (ARRAY['Mumbai','Delhi','Bengaluru','Hyderabad','Chennai','Kolkata','Pune','Ahmedabad',
                        'Jaipur','Kochi','Lucknow','Chandigarh','Indore','Coimbatore','Surat','Nagpur',
                        'Bhubaneswar','Visakhapatnam','Guwahati','Mysuru'])[1 + (_h('ci2' || i) % 20)] END,
       date '2021-06-01' + (_h('sd' || i) % 1700),
       CASE _h('lt' || i) % 5 WHEN 0 THEN 'gold' WHEN 1 THEN 'silver'
                              WHEN 2 THEN 'bronze' ELSE NULL END,   -- ~40% NULL
       -- ~30% were referred by an existing, lower-numbered customer. The other ~70%
       -- are NULL, which is precisely what breaks a naive
       --   WHERE id NOT IN (SELECT referred_by FROM customers)
       -- in Practice Session 7.1 and 10.2.
       CASE WHEN i > 40 AND _h('rb' || i) % 10 < 3
            THEN 1 + (_h('rb2' || i) % (i - 1))
            ELSE NULL END
FROM generate_series(1, 1000) AS i;

-- ---------------------------------------------------------------- orders (2500)
-- Orders are only ever placed by customers 1..850, so at least 150 customers have
-- zero orders and Practice Session 9.2 (LEFT JOIN) has something to find.
INSERT INTO orders (id, customer_id, placed_at, shipped_at, status, discount_code, total_amount)
SELECT i,
       1 + (_h('oc' || i) % 850),
       ts,
       CASE WHEN st IN ('shipped','delivered','returned')
            THEN ts + ((1 + _h('sh' || i) % 96) * interval '1 hour')
            ELSE NULL END,                                  -- NULL for pending/paid/cancelled
       st,
       CASE WHEN _h('dc' || i) % 6 = 0
            THEN (ARRAY['WELCOME10','DIWALI25','FREESHIP','VIP15'])[1 + (_h('dc2' || i) % 4)]
            ELSE NULL END,                                  -- ~83% NULL
       0                                                    -- filled in below from order_items
FROM generate_series(1, 2500) AS i,
     LATERAL (SELECT timestamptz '2024-01-01 00:00:00+00'
                     + (_h('od' || i) % 975) * interval '1 day'
                     + (_h('oh' || i) % 86400) * interval '1 second') AS d(ts),
     LATERAL (SELECT (ARRAY['delivered','delivered','delivered','shipped','shipped',
                            'paid','pending','cancelled','returned','delivered'])[1 + (_h('os' || i) % 10)]) AS s(st);

-- ---------------------------------------------------------------- order_items (~6250)
-- 1 to 4 lines per order. The multi-line majority is what makes the Chapter 9.4
-- fan-out exercise ("my SUM tripled when I added a join") reproducible.
INSERT INTO order_items (order_id, product_id, quantity, unit_price)
SELECT o.id,
       p.id,
       1 + (_h('iq' || o.id || '-' || ln) % 5),
       round(p.price * (0.85 + (_h('ip' || o.id || '-' || ln) % 31) / 100.0), 2)
FROM orders o
CROSS JOIN LATERAL generate_series(1, 1 + (_h('in' || o.id) % 4)) AS ln
JOIN products p ON p.id = 1 + (_h('ix' || o.id || '-' || ln) % 200);

-- Keep the denormalised total honest, so 9.4 has a correct answer to compare against.
UPDATE orders o
SET    total_amount = t.amt
FROM  (SELECT order_id, sum(quantity * unit_price) AS amt
       FROM order_items GROUP BY order_id) t
WHERE t.order_id = o.id;

-- Identity columns were fed explicit values above; move the sequences past them or
-- the reader's first INSERT in Chapter 5 fails on a duplicate key.
ALTER TABLE products  ALTER COLUMN id RESTART WITH 201;
ALTER TABLE customers ALTER COLUMN id RESTART WITH 1001;
ALTER TABLE orders    ALTER COLUMN id RESTART WITH 2501;

DROP FUNCTION _h(text);

COMMIT;

-- Planner statistics, not tuning. Without these every plan in Chapters 34 and 35 is
-- nonsense for reasons that have nothing to do with what those chapters teach.
ANALYZE;
