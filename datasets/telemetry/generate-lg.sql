-- telemetry — large generator (~10,000,000 rows)
--
-- Generated with generate_series inside the server. Nothing is read from disk, so
-- there is no multi-gigabyte data file in the repository.
--
-- Unlike seed-sm.sql this uses random(), not md5(): at ten million rows the hashing
-- dominates the runtime and nobody is going to read the values by eye anyway.
--
-- Still no indexes beyond the primary key and no partitions. Chapter 33 builds the
-- indexes, Chapter 38 builds the partitions, and both chapters want a "before"
-- measurement that is honestly slow.

\set ON_ERROR_STOP on
\timing on

-- Per-batch progress is emitted with RAISE NOTICE. If the server has
-- client_min_messages turned up, you would otherwise watch a blank screen for
-- several minutes and assume it had hung.
SET client_min_messages = notice;

\echo ''
\echo '>> telemetry (lg): 5,000 devices and 10,000,000 events.'
\echo '>> Expect a few minutes and a few GB of disk. Progress is reported per batch.'
\echo ''

TRUNCATE device_events, devices RESTART IDENTITY CASCADE;

-- ---------------------------------------------------------------- devices (5,000)
INSERT INTO devices (device_id, serial, model, firmware, site, region, installed_at, decommissioned_at)
SELECT i,
       'SN-' || upper(substr(md5('sn' || i), 1, 10)),
       (ARRAY['tata-sense-v2','tata-sense-v3','bharat-therm-100','bharat-therm-200','sahyadri-air-x'])[1 + floor(random() * 5)::integer],
       (ARRAY['1.8.2','2.0.0','2.1.4','2.1.4','2.2.0-rc1'])[1 + floor(random() * 5)::integer],
       'site-' || lpad((1 + floor(random() * 120)::integer)::text, 3, '0'),
       (ARRAY['maharashtra','karnataka','tamil-nadu','delhi-ncr','gujarat'])[1 + floor(random() * 5)::integer],
       timestamptz '2022-03-01 00:00:00+00' + (floor(random() * 900)::integer) * interval '1 day',
       CASE WHEN random() < 0.08
            THEN timestamptz '2025-01-01 00:00:00+00' + (floor(random() * 400)::integer) * interval '1 day'
            ELSE NULL END
FROM generate_series(1, 5000) AS i;

ANALYZE devices;

-- ---------------------------------------------------------------- device_events (10,000,000)
-- Batched through a procedure so each chunk commits: you get progress output, and a
-- ten-million-row load does not sit in one enormous transaction.
CREATE PROCEDURE _gen_events(p_total bigint, p_batch bigint)
LANGUAGE plpgsql AS $$
DECLARE
    lo bigint := 1;
    hi bigint;
BEGIN
    WHILE lo <= p_total LOOP
        hi := least(lo + p_batch - 1, p_total);

        -- The OFFSET 0 below is an optimisation fence and it is load-bearing.
        -- Without it the planner pulls the subquery up, and a volatile function in
        -- a FROM item that does not reference the outer row is evaluated ONCE for
        -- the whole scan instead of once per row — you would get a million events
        -- per batch all carrying the same metric_name. It also guarantees the
        -- metric index `k` is the same value in all three places it is used.
        INSERT INTO device_events (device_id, recorded_at, metric_name, metric_value, payload, severity)
        SELECT g.device_id,
               g.recorded_at,
               (ARRAY['temp_c','humidity_pct','battery_v','rssi_dbm','pressure_hpa'])[g.k],
               round(( (ARRAY[-10, 5, 2.9, -95, 960]::numeric[])[g.k]
                       + g.vf * ( (ARRAY[45, 99, 4.3, -35, 1050]::numeric[])[g.k]
                                - (ARRAY[-10, 5, 2.9, -95, 960]::numeric[])[g.k] ) ), 3),
               g.payload,
               g.severity
        FROM (
            SELECT
                -- SKEW, on purpose. Cubing a uniform 0..1 value crowds events onto
                -- the low device ids: a few very chatty devices, a long quiet tail.
                -- This is what makes the Chapter 35 statistics work and the
                -- Chapter 34 misestimate hunt produce a real misestimate.
                1 + floor(power(random(), 3) * 5000)::integer AS device_id,
                -- 18 months of history, evenly spread: a clean monthly partition key.
                timestamptz '2025-04-01 00:00:00+00'
                    + (random() * 547) * interval '1 day'     AS recorded_at,
                1 + floor(random() * 5)::integer              AS k,
                random()::numeric                             AS vf,
                jsonb_build_object(
                    'fw',   (ARRAY['1.8.2','2.0.0','2.1.4','2.2.0-rc1'])[1 + floor(random() * 4)::integer],
                    'batt', 60 + floor(random() * 41)::integer,
                    'rssi', -95 + floor(random() * 55)::integer,
                    'tags', (ARRAY['["ok"]','["ok","calibrated"]',
                                   '["retry"]','["ok","indoor","calibrated"]']::jsonb[])[1 + floor(random() * 4)::integer],
                    'net',  jsonb_build_object('ssid', 'site-' || (1 + floor(random() * 6)::integer),
                                               'roam', random() < 0.15)
                )                                             AS payload,
                CASE WHEN random() < 0.10
                     THEN (ARRAY['warn','warn','error','critical'])[1 + floor(random() * 4)::integer]
                     ELSE NULL END                            AS severity
            FROM generate_series(lo, hi) AS i
            OFFSET 0
        ) AS g;

        COMMIT;
        RAISE NOTICE 'device_events: % / % rows', hi, p_total;
        lo := lo + p_batch;
    END LOOP;
END $$;

CALL _gen_events(10000000, 1000000);

DROP PROCEDURE _gen_events(bigint, bigint);

\echo '>> collecting planner statistics'
ANALYZE;

SELECT pg_size_pretty(pg_database_size(current_database())) AS telemetry_lg_on_disk;
