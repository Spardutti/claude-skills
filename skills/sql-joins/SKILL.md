---
name: sql-joins
category: Database
description: "MUST USE when writing SQL joins, defining table relationships, or using subqueries. Enforces correct JOIN types, prevents silent LEFT-to-INNER conversion, fan-out traps, NOT IN NULL bugs, and FK design mistakes."
---

# SQL Joins, Relationships & Subqueries

## LEFT JOIN Silently Becomes INNER JOIN

The most common and hardest-to-detect JOIN bug. Filtering on the right table in WHERE eliminates NULL rows.

```sql
-- BAD: WHERE on right table kills the LEFT JOIN
SELECT c.name, o.total
FROM customers c
LEFT JOIN orders o ON c.id = o.customer_id
WHERE o.status = 'shipped';
-- Customers with NO orders disappear (o.status is NULL for them)

-- GOOD: put the filter in the ON clause
SELECT c.name, o.total
FROM customers c
LEFT JOIN orders o ON c.id = o.customer_id AND o.status = 'shipped';
-- Customers with no shipped orders still appear (with NULLs)
```

**Rule:** ON controls _how tables relate_. WHERE controls _what rows survive_. For INNER JOINs the distinction doesn't matter. For OUTER JOINs it is critical.

## INNER JOIN After OUTER JOIN Nullifies It

```sql
-- BAD: INNER JOIN on table c kills rows preserved by LEFT JOIN
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

## The Fan-Out Trap (Inflated Aggregates)

Joining two "many" tables on a shared key creates a Cartesian product per group.

```sql
-- BAD: 3 orders x 2 refunds = 6 rows per customer, SUM is wrong
SELECT c.id, SUM(o.amount) AS total, SUM(r.refund) AS refunds
FROM customers c
JOIN orders o ON c.id = o.customer_id
JOIN refunds r ON c.id = r.customer_id
GROUP BY c.id;

-- GOOD: pre-aggregate before joining
SELECT c.id, o.total, r.refunds
FROM customers c
LEFT JOIN (
  SELECT customer_id, SUM(amount) AS total FROM orders GROUP BY customer_id
) o ON c.id = o.customer_id
LEFT JOIN (
  SELECT customer_id, SUM(refund) AS refunds FROM refunds GROUP BY customer_id
) r ON c.id = r.customer_id;
```

## Implicit Joins — Accident-Prone Syntax

```sql
-- BAD: comma join — missing WHERE = accidental Cartesian product
SELECT o.id, p.name
FROM orders o, products p;
-- 1,000 orders x 5,000 products = 5,000,000 rows

-- GOOD: explicit JOIN syntax makes the condition mandatory
SELECT o.id, p.name
FROM orders o
INNER JOIN products p ON o.product_id = p.id;
```

## COUNT With OUTER JOINs

```sql
-- BAD: COUNT(*) counts NULL rows — customers with no orders show 1
SELECT c.name, COUNT(*) AS order_count
FROM customers c
LEFT JOIN orders o ON c.id = o.customer_id
GROUP BY c.name;

-- GOOD: COUNT a column from the right table
SELECT c.name, COUNT(o.id) AS order_count
FROM customers c
LEFT JOIN orders o ON c.id = o.customer_id
GROUP BY c.name;
-- Customers with no orders correctly show 0
```

## DISTINCT Masking a Bad JOIN

```sql
-- BAD: JOIN creates duplicates, DISTINCT hides the problem
SELECT DISTINCT u.id, u.name
FROM users u
JOIN orders o ON o.user_id = u.id
WHERE o.created_at > '2025-01-01';
-- Sorts/hashes millions of rows to dedup

-- GOOD: EXISTS — one row per user, no dedup needed
SELECT u.id, u.name
FROM users u
WHERE EXISTS (
  SELECT 1 FROM orders o
  WHERE o.user_id = u.id AND o.created_at > '2025-01-01'
);
```

## EXISTS vs IN vs JOIN

```sql
-- IN: builds full subquery result set first
SELECT name FROM customers
WHERE id IN (SELECT customer_id FROM orders WHERE total > 100);

-- EXISTS: stops at first match per row (short-circuits)
SELECT name FROM customers c
WHERE EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.id AND o.total > 100);

-- JOIN: use when you need columns from both tables
SELECT c.name, o.total
FROM customers c
JOIN orders o ON c.id = o.customer_id
WHERE o.total > 100;
```

**Performance:** EXISTS beats IN when the subquery is large (short-circuits). IN beats EXISTS for small static lists. Modern optimizers often rewrite IN as a semi-join internally.

## The NOT IN NULL Trap

One of SQL's most dangerous anti-patterns — if ANY value in the subquery is NULL, NO rows are returned.

```sql
-- BAD: if closed_departments has a single NULL, this returns EMPTY
SELECT name FROM employees
WHERE department_id NOT IN (SELECT department_id FROM closed_departments);

-- GOOD: NOT EXISTS handles NULLs correctly
SELECT name FROM employees e
WHERE NOT EXISTS (
  SELECT 1 FROM closed_departments cd WHERE cd.department_id = e.department_id
);
```

**Why:** `5 NOT IN (1, 2, NULL)` → `5!=1 AND 5!=2 AND 5!=NULL` → `TRUE AND TRUE AND UNKNOWN` → `UNKNOWN` → row excluded.

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

## Foreign Key on the Wrong Side

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

## Missing Junction Table

```sql
-- BAD: multi-value column for many-to-many
CREATE TABLE students (
    id INT PRIMARY KEY,
    course_ids VARCHAR(255)  -- '1,3,7' — no FK, no index, no JOIN
);

-- GOOD: proper junction table
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

CASCADE chains can propagate across multiple tables, deleting thousands of rows from a single DELETE. Use RESTRICT by default, CASCADE only on true ownership (order → order_items).

## FULL OUTER JOIN Misuse

```sql
-- BAD: FULL OUTER JOIN when you want all customers with optional orders
SELECT c.name, o.total
FROM customers c
FULL OUTER JOIN orders o ON c.id = o.customer_id;
-- Also returns orphan orders with no customer — probably not what you want

-- GOOD: LEFT JOIN when you want all of one side, optionally the other
SELECT c.name, o.total
FROM customers c
LEFT JOIN orders o ON c.id = o.customer_id;
```

FULL OUTER JOIN is legitimate for reconciliation queries (comparing two data sources). Rarely needed elsewhere.

## Rules

1. **Never filter on the outer table's right side in WHERE** — use ON for LEFT JOIN conditions
2. **LEFT JOIN all the way through** when preserving unmatched rows across multiple joins
3. **Pre-aggregate before joining** two "many" tables to prevent fan-out
4. **Always use explicit JOIN syntax** — never comma joins
5. **COUNT(column) not COUNT(*)** with OUTER JOINs
6. **Prefer EXISTS over DISTINCT** to check membership without duplicates
7. **Never use NOT IN with nullable subqueries** — use NOT EXISTS instead
8. **Replace correlated subqueries** with JOINs on derived tables when possible
9. **FK goes on the "many" side** of a relationship
10. **Use junction tables** for many-to-many — never comma-separated IDs
11. **Default to ON DELETE RESTRICT** — use CASCADE only for owned child rows
12. **FULL OUTER JOIN is for reconciliation only** — use LEFT JOIN for "all of one side"
13. **Index foreign key columns** — see `sql-indexing` skill for details
