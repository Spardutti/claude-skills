# Joins, Relationships & Subqueries

## Contents

- INNER JOIN after OUTER JOIN nullifies it
- COUNT(*) with OUTER JOINs
- Implicit comma joins
- DISTINCT masking bad joins
- EXISTS vs IN vs JOIN
- Correlated subqueries
- Foreign key placement
- Junction tables for many-to-many
- CASCADE pitfalls
- FULL OUTER JOIN misuse

## INNER JOIN After OUTER JOIN Nullifies It

```sql
-- BAD: INNER JOIN on c kills rows preserved by LEFT JOIN
SELECT a.name, b.order_id, c.item_name
FROM customers a
LEFT JOIN orders b ON a.id = b.customer_id
INNER JOIN order_items c ON b.id = c.order_id;
-- Customers without orders vanish because b.id is NULL

-- GOOD: LEFT JOIN all the way through
SELECT a.name, b.order_id, c.item_name
FROM customers a
LEFT JOIN orders b ON a.id = b.customer_id
LEFT JOIN order_items c ON b.id = c.order_id;
```

### COUNT(*) With OUTER JOINs

```sql
-- BAD: COUNT(*) counts NULL rows — customers with no orders show 1
SELECT c.name, COUNT(*) AS order_count
FROM customers c LEFT JOIN orders o ON c.id = o.customer_id
GROUP BY c.name;

-- GOOD: COUNT a column from the right table
SELECT c.name, COUNT(o.id) AS order_count
FROM customers c LEFT JOIN orders o ON c.id = o.customer_id
GROUP BY c.name;
```

## Implicit Comma Joins

```sql
-- BAD: missing WHERE = accidental Cartesian product
SELECT o.id, p.name FROM orders o, products p;
-- 1,000 × 5,000 = 5,000,000 rows

-- GOOD: explicit JOIN makes the condition mandatory
SELECT o.id, p.name FROM orders o INNER JOIN products p ON o.product_id = p.id;
```

## DISTINCT Masking a Bad JOIN

```sql
-- BAD: JOIN creates duplicates, DISTINCT hides the problem
SELECT DISTINCT u.id, u.name
FROM users u JOIN orders o ON o.user_id = u.id
WHERE o.created_at > '2025-01-01';

-- GOOD: EXISTS — one row per user, no dedup needed
SELECT u.id, u.name FROM users u
WHERE EXISTS (
  SELECT 1 FROM orders o WHERE o.user_id = u.id AND o.created_at > '2025-01-01'
);
```

## EXISTS vs IN vs JOIN

```sql
-- IN: builds full subquery result set first
SELECT name FROM customers WHERE id IN (SELECT customer_id FROM orders WHERE total > 100);

-- EXISTS: stops at first match per row (short-circuits)
SELECT name FROM customers c
WHERE EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.id AND o.total > 100);

-- JOIN: use when you need columns from both tables
SELECT c.name, o.total FROM customers c JOIN orders o ON c.id = o.customer_id
WHERE o.total > 100;
```

EXISTS beats IN when the subquery is large. IN beats EXISTS for small static lists. Modern optimizers often rewrite IN as a semi-join internally.

## Correlated Subqueries — Hidden Cost

```sql
-- BAD: subquery re-executes for every row
SELECT e.name, e.salary,
  (SELECT AVG(salary) FROM employees e2 WHERE e2.dept_id = e.dept_id) AS dept_avg
FROM employees e;

-- GOOD: JOIN with derived table (single scan)
SELECT e.name, e.salary, d.dept_avg
FROM employees e
JOIN (
  SELECT dept_id, AVG(salary) AS dept_avg FROM employees GROUP BY dept_id
) d ON e.dept_id = d.dept_id;
```

## Foreign Key Placement

```sql
-- BAD: FK on the "one" side — comma-separated IDs
CREATE TABLE departments (
    id INT PRIMARY KEY,
    employee_ids TEXT  -- '1,3,7' — cannot index, join, or enforce
);

-- GOOD: FK on the "many" side
CREATE TABLE employees (
    id INT PRIMARY KEY,
    department_id INT REFERENCES departments(id)
);
```

## Junction Tables for Many-to-Many

```sql
-- BAD: multi-value column
CREATE TABLE students (
    id INT PRIMARY KEY,
    course_ids VARCHAR(255)
);

-- GOOD: junction table
CREATE TABLE student_courses (
    student_id INT REFERENCES students(id),
    course_id INT REFERENCES courses(id),
    PRIMARY KEY (student_id, course_id)
);
```

## CASCADE Pitfalls

```sql
-- DANGEROUS: deleting a department silently deletes all employees
CREATE TABLE employees (
    id INT PRIMARY KEY,
    department_id INT REFERENCES departments(id) ON DELETE CASCADE
);

-- SAFER: prevent accidental mass deletion
CREATE TABLE employees (
    id INT PRIMARY KEY,
    department_id INT REFERENCES departments(id) ON DELETE RESTRICT
);
```

CASCADE chains can propagate across multiple tables. Use RESTRICT by default, CASCADE only on true ownership (order → order_items).

## FULL OUTER JOIN Misuse

```sql
-- BAD: returns orphan orders with no customer too — probably not what you want
SELECT c.name, o.total FROM customers c
FULL OUTER JOIN orders o ON c.id = o.customer_id;

-- GOOD: LEFT JOIN when you want all of one side, optionally the other
SELECT c.name, o.total FROM customers c
LEFT JOIN orders o ON c.id = o.customer_id;
```

FULL OUTER JOIN is legitimate for reconciliation (comparing two data sources). Rarely needed elsewhere.

## Rules

1. Filter outer-join right side in `ON`, not `WHERE` (covered in SKILL.md gotcha #1).
2. LEFT JOIN all the way through when preserving unmatched rows across multiple joins.
3. Pre-aggregate before joining two "many" tables (covered in SKILL.md gotcha #9).
4. Always use explicit `JOIN` syntax — never comma joins.
5. `COUNT(column)` not `COUNT(*)` with OUTER JOINs.
6. Prefer `EXISTS` over `DISTINCT` to check membership without duplicates.
7. Never use `NOT IN` with nullable subqueries — use `NOT EXISTS` (covered in SKILL.md gotcha #3).
8. Replace correlated subqueries with JOINs on derived tables when possible.
9. FK goes on the "many" side of a relationship.
10. Use junction tables for many-to-many — never comma-separated IDs.
11. Default to `ON DELETE RESTRICT`; use `CASCADE` only for owned child rows.
12. `FULL OUTER JOIN` is for reconciliation only — use `LEFT JOIN` for "all of one side."
13. Index foreign key columns — without an index on the FK, JOINs require sequential scans and parent DELETE/UPDATE locks the child table.
