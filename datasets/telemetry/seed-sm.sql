-- telemetry — small seed (~10k rows total)
--
-- Deterministic: values derive from md5() of the row number, not random().

\set ON_ERROR_STOP on

BEGIN;

TRUNCATE device_events, devices RESTART IDENTITY CASCADE;

CREATE FUNCTION _h(seed text) RETURNS integer LANGUAGE sql IMMUTABLE AS
$$ SELECT ('x' || substr(md5(seed), 1, 7))::bit(28)::integer $$;

-- ---------------------------------------------------------------- devices (200)
INSERT INTO devices (device_id, serial, model, firmware, site, region, installed_at, decommissioned_at)
SELECT i,
       'SN-' || upper(substr(md5('sn' || i), 1, 10)),
       (ARRAY['tata-sense-v2','tata-sense-v3','bharat-therm-100','bharat-therm-200','sahyadri-air-x'])[1 + (_h('mo' || i) % 5)],
       (ARRAY['1.8.2','2.0.0','2.1.4','2.1.4','2.2.0-rc1'])[1 + (_h('fw' || i) % 5)],
       (ARRAY['plant-pune','plant-chennai','plant-sanand','depot-nashik','depot-hosur',
              'lab-bengaluru','lab-hyderabad','roof-mumbai'])[1 + (_h('si' || i) % 8)],
       (ARRAY['maharashtra','karnataka','tamil-nadu','delhi-ncr','gujarat'])[1 + (_h('re' || i) % 5)],
       timestamptz '2022-03-01 00:00:00+00' + (_h('ia' || i) % 900) * interval '1 day',
       CASE WHEN _h('dc' || i) % 12 = 0
            THEN timestamptz '2025-01-01 00:00:00+00' + (_h('dd' || i) % 400) * interval '1 day'
            ELSE NULL END
FROM generate_series(1, 200) AS i;

-- ---------------------------------------------------------------- device_events (9800)
-- device_id is deliberately SKEWED, not uniform. Cubing a 0..1 value concentrates
-- traffic on the low device ids: a handful of very chatty devices and a long tail of
-- quiet ones. That skew is the whole point of Practice Session 35.1 (inspect pg_stats
-- on a skewed column) and of the misestimate hunt in 34.4. Do not "fix" it.
INSERT INTO device_events (device_id, recorded_at, metric_name, metric_value, payload, severity)
SELECT 1 + floor(power((_h('dv' || i) % 1000000) / 1000000.0, 3) * 200)::integer,
       timestamptz '2026-06-01 00:00:00+00' + (i % 9000) * interval '15 minutes'
                                            + (_h('jt' || i) % 900) * interval '1 second',
       m.metric_name,
       round((m.lo + (_h('mv' || i) % 10000) / 10000.0 * (m.hi - m.lo))::numeric, 3),
       jsonb_build_object(
           'fw',    (ARRAY['1.8.2','2.0.0','2.1.4','2.2.0-rc1'])[1 + (_h('pf' || i) % 4)],
           'batt',  60 + (_h('pb' || i) % 41),
           'rssi',  -95 + (_h('pr' || i) % 55),
           'tags',  (ARRAY['["ok"]', '["ok","calibrated"]',
                           '["retry"]', '["ok","indoor","calibrated"]']::jsonb[])[1 + (_h('pt' || i) % 4)],
           'net',   jsonb_build_object('ssid', 'site-' || (1 + _h('pn' || i) % 6),
                                       'roam', (_h('pm' || i) % 7 = 0))
       ),
       -- ~90% NULL. Sparse, low-cardinality and nullable: a good partial-index target
       -- for Practice Session 33.3.
       CASE _h('sv' || i) % 10 WHEN 0 THEN (ARRAY['warn','warn','error','critical'])[1 + (_h('sv2' || i) % 4)]
                               ELSE NULL END
FROM generate_series(1, 9800) AS i
CROSS JOIN LATERAL (
    SELECT * FROM (VALUES ('temp_c', -10, 45), ('humidity_pct', 5, 99),
                          ('battery_v', 2.9, 4.3), ('rssi_dbm', -95, -35),
                          ('pressure_hpa', 960, 1050)) AS v(metric_name, lo, hi)
    OFFSET (_h('mn' || i) % 5) LIMIT 1
) AS m;

DROP FUNCTION _h(text);

COMMIT;

ANALYZE;
