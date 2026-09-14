-- hr — small seed (~10k rows total)
--
-- Deterministic: values derive from md5() of the row number, not random().

\set ON_ERROR_STOP on

BEGIN;

TRUNCATE salary_history, employees, departments RESTART IDENTITY CASCADE;

CREATE FUNCTION _h(seed text) RETURNS integer LANGUAGE sql IMMUTABLE AS
$$ SELECT ('x' || substr(md5(seed), 1, 7))::bit(28)::integer $$;

-- ---------------------------------------------------------------- departments (40)
-- 8 top-level divisions, 32 departments hanging off them.
INSERT INTO departments (dept_id, name, location, cost_center, parent_dept_id, annual_budget)
SELECT i,
       CASE WHEN i <= 8
            THEN (ARRAY['Engineering','Sales','Finance','Operations',
                        'People','Marketing','Legal','Support'])[i]
            ELSE (ARRAY['Engineering','Sales','Finance','Operations',
                        'People','Marketing','Legal','Support'])[1 + ((i - 9) % 8)]
                 || ' — ' ||
                 (ARRAY['North','South','East','West'])[1 + ((i - 9) / 8)]
       END,
       (ARRAY['Bengaluru','Mumbai','Hyderabad','Pune','Gurugram'])[1 + (_h('dl' || i) % 5)],
       'IN-CC-' || lpad((1000 + i * 7)::text, 5, '0'),
       CASE WHEN i <= 8 THEN NULL ELSE 1 + ((i - 9) % 8) END,
       CASE WHEN _h('db' || i) % 9 = 0 THEN NULL          -- nullable on purpose
            ELSE round((250000 + (_h('db2' || i) % 4750000))::numeric, 2) END
FROM generate_series(1, 40) AS i;

-- ---------------------------------------------------------------- employees (2774)
-- A 7-level reporting tree. Each level's managers are drawn from the level above by
-- hash, so branching factors vary widely: some managers have one report, some have
-- fifteen. Uniform branching would make Chapter 12's recursion exercises boring and
-- Chapter 25's "rank within manager" windows degenerate.
DO $$
DECLARE
    sizes  integer[] := ARRAY[1, 5, 18, 70, 280, 1100, 1300];  -- 7 levels, 2774 people
    titles text[]    := ARRAY['Chief Executive Officer','Senior Vice President','Vice President',
                              'Director','Senior Manager','Team Lead','Individual Contributor'];
    lvl integer;
    lo integer; hi integer;
    prev_lo integer := 0; prev_hi integer := 0;
    next_id integer := 1;
BEGIN
    FOR lvl IN 1 .. array_length(sizes, 1) LOOP
        lo := next_id;
        hi := next_id + sizes[lvl] - 1;

        INSERT INTO employees (emp_id, full_name, email, dept_id, manager_id,
                               job_title, hire_date, salary, status, terminated_on)
        SELECT i,
               (ARRAY['Rajesh','Anita','Priya','Arjun','Fatima','Harpreet','Meera','Vikram','Lakshmi','Imran',
                      'Sneha','Karthik','Divya','Rohit','Ananya','Suresh','Kavita','Aditya','Nisha','Farhan'])[1 + (_h('en' || i) % 20)]
                 || ' ' ||
               (ARRAY['Kumar','Rao','Menon','Iyer','Sheikh','Singh','Banerjee','Patel','Reddy','Chatterjee',
                      'Nair','Desai','Gupta','Pillai','Joshi','Mukherjee','Shetty','Bhat','Kulkarni','Verma'])[1 + (_h('es' || i) % 20)],
               'emp' || i || '@sampark.example',
               1 + (_h('ed' || i) % 40),
               CASE WHEN lvl = 1 THEN NULL
                    ELSE prev_lo + (_h('em' || i) % (prev_hi - prev_lo + 1)) END,
               titles[lvl],
               date '2009-01-01' + (_h('eh' || i) % 6100),
               -- Pay falls as you go down the tree, with spread inside each level.
               round((320000.0 / power(1.42, lvl - 1) * (0.82 + (_h('ep' || i) % 45) / 100.0))::numeric, 2),
               CASE _h('et' || i) % 25 WHEN 0 THEN 'terminated'
                                       WHEN 1 THEN 'on_leave'
                                       ELSE 'active' END,
               CASE WHEN _h('et' || i) % 25 = 0
                    THEN date '2023-01-01' + (_h('ex' || i) % 950) ELSE NULL END
        FROM generate_series(lo, hi) AS i;

        prev_lo := lo;
        prev_hi := hi;
        next_id := hi + 1;
    END LOOP;
END $$;

-- ---------------------------------------------------------------- salary_history (~6900)
-- 1 to 4 rows per employee, always starting with the hire. Gives LAG/LEAD in
-- Practice Session 25.3 something real to compute period-over-period against.
INSERT INTO salary_history (emp_id, effective_date, salary, reason)
SELECT e.emp_id,
       e.hire_date + ((n - 1) * (180 + (_h('sd' || e.emp_id || '-' || n) % 400)))::integer,
       round(e.salary / power(1.055, (1 + (_h('sn' || e.emp_id) % 4)) - n)::numeric, 2),
       CASE WHEN n = 1 THEN 'hire'
            ELSE (ARRAY['merit','merit','promotion','market_adjustment'])[1 + (_h('sr' || e.emp_id || '-' || n) % 4)] END
FROM employees e
CROSS JOIN LATERAL generate_series(1, 1 + (_h('sn' || e.emp_id) % 4)) AS n;

ALTER TABLE departments ALTER COLUMN dept_id RESTART WITH 41;
ALTER TABLE employees   ALTER COLUMN emp_id  RESTART WITH 2775;

DROP FUNCTION _h(text);

COMMIT;

ANALYZE;
