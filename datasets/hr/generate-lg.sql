-- hr — large generator (~3,500,000 rows)
--
-- An 8-level, 1,000,000-person reporting tree plus salary history. Built with
-- generate_series; nothing large lives in the repository.
--
-- The extra level over the small variant is deliberate: Chapter 12's recursive CTE
-- is cheap on 2,774 rows and expensive on a million, and seeing that difference is
-- the point of running the large variant at all.

\set ON_ERROR_STOP on
\timing on

-- Per-level progress is emitted with RAISE NOTICE; make sure it is visible.
SET client_min_messages = notice;

\echo ''
\echo '>> hr (lg): 1,000 departments, 1,000,000 employees over 8 levels, ~2,500,000 salary rows.'
\echo ''

TRUNCATE salary_history, employees, departments RESTART IDENTITY CASCADE;

-- ---------------------------------------------------------------- departments (1,000)
\echo '>> departments'
INSERT INTO departments (dept_id, name, location, cost_center, parent_dept_id, annual_budget)
SELECT i,
       CASE WHEN i <= 8
            THEN (ARRAY['Engineering','Sales','Finance','Operations',
                        'People','Marketing','Legal','Support'])[i]
            ELSE (ARRAY['Engineering','Sales','Finance','Operations',
                        'People','Marketing','Legal','Support'])[1 + ((i - 9) % 8)]
                 || ' — Unit ' || ((i - 9) / 8 + 1)
       END,
       (ARRAY['Bengaluru','Mumbai','Hyderabad','Pune','Gurugram'])[1 + floor(random() * 5)::integer],
       'IN-CC-' || lpad((1000 + i * 7)::text, 6, '0'),
       CASE WHEN i <= 8 THEN NULL ELSE 1 + ((i - 9) % 8) END,
       CASE WHEN random() < 0.11 THEN NULL
            ELSE round((250000 + random() * 4750000)::numeric, 2) END
FROM generate_series(1, 1000) AS i;

ANALYZE departments;

-- ---------------------------------------------------------------- employees (1,000,000)
\echo '>> employees (8 levels)'
DO $$
DECLARE
    sizes  integer[] := ARRAY[1, 10, 80, 600, 4500, 34000, 260000, 700809];  -- = 1,000,000
    titles text[]    := ARRAY['Chief Executive Officer','Executive Vice President','Senior Vice President',
                              'Vice President','Director','Senior Manager','Team Lead','Individual Contributor'];
    lvl integer;
    lo integer; hi integer;
    prev_lo integer := 0; prev_hi integer := 0;
    next_id integer := 1;
BEGIN
    FOR lvl IN 1 .. array_length(sizes, 1) LOOP
        lo := next_id;
        hi := next_id + sizes[lvl] - 1;

        -- OFFSET 0 is an optimisation fence: it keeps each random() evaluated once
        -- per row, and lets `status` be referenced again to derive terminated_on
        -- without re-rolling the dice. Without it you get terminated_on set on
        -- people whose status is 'active', which is exactly the kind of
        -- contradiction Chapter 15 tells the reader to design out.
        INSERT INTO employees (emp_id, full_name, email, dept_id, manager_id,
                               job_title, hire_date, salary, status, terminated_on)
        SELECT g.i,
               g.full_name,
               'emp' || g.i || '@sampark.example',
               g.dept_id,
               g.manager_id,
               titles[lvl],
               g.hire_date,
               g.salary,
               g.status,
               CASE WHEN g.status = 'terminated' THEN g.term_date ELSE NULL END
        FROM (
            SELECT i,
                   (ARRAY['Rajesh','Anita','Priya','Arjun','Fatima','Harpreet','Meera','Vikram','Lakshmi','Imran',
                          'Sneha','Karthik','Divya','Rohit','Ananya','Suresh','Kavita','Aditya','Nisha','Farhan'])[1 + floor(random() * 20)::integer]
                     || ' ' ||
                   (ARRAY['Kumar','Rao','Menon','Iyer','Sheikh','Singh','Banerjee','Patel','Reddy','Chatterjee',
                          'Nair','Desai','Gupta','Pillai','Joshi','Mukherjee','Shetty','Bhat','Kulkarni','Verma'])[1 + floor(random() * 20)::integer]
                                                                     AS full_name,
                   1 + floor(random() * 1000)::integer               AS dept_id,
                   CASE WHEN lvl = 1 THEN NULL
                        ELSE prev_lo + floor(random() * (prev_hi - prev_lo + 1))::integer
                   END                                               AS manager_id,
                   date '2009-01-01' + floor(random() * 6100)::integer AS hire_date,
                   round((380000.0 / power(1.40, lvl - 1) * (0.82 + random() * 0.45))::numeric, 2) AS salary,
                   CASE WHEN random() < 0.04 THEN 'terminated'
                        WHEN random() < 0.04 THEN 'on_leave'
                        ELSE 'active' END                            AS status,
                   date '2023-01-01' + floor(random() * 950)::integer AS term_date
            FROM generate_series(lo, hi) AS i
            OFFSET 0
        ) AS g;

        RAISE NOTICE 'employees: level % of % done (% rows)', lvl, array_length(sizes, 1), sizes[lvl];

        prev_lo := lo;
        prev_hi := hi;
        next_id := hi + 1;
    END LOOP;
END $$;

ANALYZE employees;

-- ---------------------------------------------------------------- salary_history (~2,500,000)
-- 1 to 4 rows per employee, averaging 2.5. The row count comes from a fenced
-- subquery; a bare random() in the generate_series argument is evaluated once for
-- the whole scan and every employee ends up with exactly the same number of rows.
\echo '>> salary_history'
INSERT INTO salary_history (emp_id, effective_date, salary, reason)
SELECT g.emp_id,
       g.hire_date + ((g.n - 1) * g.gap_days)::integer,
       round((g.salary * g.factor)::numeric, 2),
       CASE WHEN g.n = 1 THEN 'hire' ELSE g.reason END
FROM (
    SELECT e.emp_id,
           e.hire_date,
           e.salary,
           ln                                       AS n,
           180 + floor(random() * 400)::integer     AS gap_days,
           0.70 + random() * 0.30                   AS factor,
           (ARRAY['merit','merit','promotion','market_adjustment'])[1 + floor(random() * 4)::integer] AS reason
    FROM (SELECT emp_id, hire_date, salary,
                 1 + floor(random() * 4)::integer AS rows_for_emp
          FROM employees
          OFFSET 0) AS e
    CROSS JOIN LATERAL generate_series(1, e.rows_for_emp) AS ln
    OFFSET 0
) AS g;

ALTER TABLE departments ALTER COLUMN dept_id RESTART WITH 1001;
ALTER TABLE employees   ALTER COLUMN emp_id  RESTART WITH 1000001;

\echo '>> collecting planner statistics'
ANALYZE;

SELECT pg_size_pretty(pg_database_size(current_database())) AS hr_lg_on_disk;
