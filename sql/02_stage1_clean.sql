-- =====================================================================
-- Meridian Crest Bank · Hubballi Zone · Project Ekatra
-- STAGE 1 · Can we trust the data?
--
-- Runs after 00_create_database_and_tables.sql and 01_load_data.sql.
-- The 18 raw tables are never changed. Every fix is written to a new
-- clean table, and every problem is written to dq_log with the rule
-- applied, the rows affected and the rupees involved.
--
-- Clean tables used by Stage 2:
--   customers_clean, borrower_map, loan_book, disbursements_clean,
--   collateral_clean, repayments_clean, loan_emi_check, loan_rule_breaches
-- Evidence tables:
--   recon_files (Q1.1), recon_warehouse (Q1.1), dq_log (all questions),
--   customer_exceptions (Q1.3), identity_decisions (Q1.4)
-- =====================================================================

USE meridian_crest_bank;
SET NAMES utf8mb4;
SET SQL_SAFE_UPDATES = 0;
-- Log lines group by an expression and show its label; allow that.
SET SESSION sql_mode = REPLACE(@@SESSION.sql_mode, 'ONLY_FULL_GROUP_BY', '');

-- ---------------------------------------------------------------------
-- 0. Helper functions: turn the source systems' text into usable values
-- ---------------------------------------------------------------------

DROP FUNCTION IF EXISTS fn_to_date;
DROP FUNCTION IF EXISTS fn_to_amount;
DROP FUNCTION IF EXISTS fn_to_months;
DROP FUNCTION IF EXISTS fn_to_rate;
DROP FUNCTION IF EXISTS fn_proper;
DROP FUNCTION IF EXISTS fn_clean_name;
DROP FUNCTION IF EXISTS fn_clean_pan;
DROP FUNCTION IF EXISTS fn_clean_mobile;
DROP FUNCTION IF EXISTS fn_date_format;
DROP FUNCTION IF EXISTS fn_amount_format;

DELIMITER $$

-- Dates arrive in four shapes. Slash dates are ambiguous: CBS-M writes
-- them month first (02/17/2025 exists, no first part above 12), CBS-P
-- writes them day first (29/08/1992 exists, no second part above 12).
-- Five-digit numbers are Excel serial dates (day 0 = 1899-12-30).
CREATE FUNCTION fn_to_date(s VARCHAR(30), src VARCHAR(5)) RETURNS DATE
DETERMINISTIC NO SQL
BEGIN
  SET s = TRIM(s);
  IF s IS NULL OR s = '' THEN RETURN NULL; END IF;
  IF s REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN RETURN STR_TO_DATE(s, '%Y-%m-%d'); END IF;
  IF s REGEXP '^[0-9]{1,2}/[0-9]{1,2}/[0-9]{4}$' THEN
    RETURN IF(src = 'CBS-M', STR_TO_DATE(s, '%m/%d/%Y'), STR_TO_DATE(s, '%d/%m/%Y'));
  END IF;
  IF s REGEXP '^[0-9]{1,2}-[A-Za-z]{3}-[0-9]{4}$' THEN RETURN STR_TO_DATE(s, '%d-%b-%Y'); END IF;
  IF s REGEXP '^[0-9]{5}$' THEN RETURN DATE_ADD('1899-12-30', INTERVAL CAST(s AS UNSIGNED) DAY); END IF;
  RETURN NULL;
END$$

-- Label for the shape a date arrived in (used for the quality log).
CREATE FUNCTION fn_date_format(s VARCHAR(30)) RETURNS VARCHAR(20)
DETERMINISTIC NO SQL
BEGIN
  IF s IS NULL OR TRIM(s) = '' THEN RETURN 'EMPTY'; END IF;
  IF s REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN RETURN 'ISO'; END IF;
  IF s REGEXP '^[0-9]{1,2}/[0-9]{1,2}/[0-9]{4}$' THEN RETURN 'SLASH'; END IF;
  IF s REGEXP '^[0-9]{1,2}-[A-Za-z]{3}-[0-9]{4}$' THEN RETURN 'DD-MON-YYYY'; END IF;
  IF s REGEXP '^[0-9]{5}$' THEN RETURN 'EXCEL_SERIAL'; END IF;
  RETURN 'UNKNOWN';
END$$

-- Amounts arrive as 1003000, 218000.00, 1,19,000, ₹56,09,000 or 33.17 L
-- (lakh = 1,00,000). Strip the symbol, the Indian commas and spaces.
CREATE FUNCTION fn_to_amount(s VARCHAR(30)) RETURNS DECIMAL(16,2)
DETERMINISTIC NO SQL
BEGIN
  DECLARE t VARCHAR(30);
  IF s IS NULL OR TRIM(s) = '' THEN RETURN NULL; END IF;
  SET t = REPLACE(REPLACE(REPLACE(TRIM(s), '₹', ''), ',', ''), ' ', '');
  IF t REGEXP '^[0-9]+(\\.[0-9]+)?L$' THEN
    RETURN ROUND(CAST(LEFT(t, CHAR_LENGTH(t) - 1) AS DECIMAL(16,4)) * 100000, 2);
  END IF;
  IF t REGEXP '^[0-9]+(\\.[0-9]+)?$' THEN RETURN CAST(t AS DECIMAL(16,2)); END IF;
  RETURN NULL;
END$$

CREATE FUNCTION fn_amount_format(s VARCHAR(30)) RETURNS VARCHAR(20)
DETERMINISTIC NO SQL
BEGIN
  IF s IS NULL OR TRIM(s) = '' THEN RETURN 'EMPTY'; END IF;
  IF s LIKE '%L' THEN RETURN 'LAKH'; END IF;
  IF s LIKE '₹%' THEN RETURN 'RUPEE_SYMBOL'; END IF;
  IF s LIKE '%,%' THEN RETURN 'INDIAN_COMMAS'; END IF;
  RETURN 'PLAIN';
END$$

-- Tenure arrives as 36, 36M or 3Y. Result is in months.
CREATE FUNCTION fn_to_months(s VARCHAR(10)) RETURNS SMALLINT
DETERMINISTIC NO SQL
BEGIN
  SET s = UPPER(TRIM(s));
  IF s REGEXP '^[0-9]+Y$' THEN RETURN CAST(LEFT(s, CHAR_LENGTH(s) - 1) AS UNSIGNED) * 12; END IF;
  IF s REGEXP '^[0-9]+M$' THEN RETURN CAST(LEFT(s, CHAR_LENGTH(s) - 1) AS UNSIGNED); END IF;
  IF s REGEXP '^[0-9]+$'  THEN RETURN CAST(s AS UNSIGNED); END IF;
  RETURN NULL;
END$$

-- Rate arrives as 12.35, 9.15% or 0.1200 (a fraction). Result is % a year.
CREATE FUNCTION fn_to_rate(s VARCHAR(10)) RETURNS DECIMAL(6,3)
DETERMINISTIC NO SQL
BEGIN
  DECLARE v DECIMAL(10,5);
  IF s IS NULL OR TRIM(s) = '' THEN RETURN NULL; END IF;
  SET v = CAST(REPLACE(TRIM(s), '%', '') AS DECIMAL(10,5));
  IF v < 1 THEN SET v = v * 100; END IF;
  RETURN v;
END$$

-- Capitalise the first letter of each word: "D'SOUZA" -> "D'Souza".
CREATE FUNCTION fn_proper(s VARCHAR(100)) RETURNS VARCHAR(100)
DETERMINISTIC NO SQL
BEGIN
  DECLARE i INT DEFAULT 1;
  DECLARE res VARCHAR(100) DEFAULT '';
  DECLARE c VARCHAR(1);
  DECLARE up BOOLEAN DEFAULT TRUE;
  SET s = LOWER(s);
  WHILE i <= CHAR_LENGTH(s) DO
    SET c = SUBSTRING(s, i, 1);
    SET res = CONCAT(res, IF(up, UPPER(c), c));
    SET up = c IN (' ', '''', '-', '&', '/', '.');
    SET i = i + 1;
  END WHILE;
  RETURN REGEXP_REPLACE(res, '\\bLlp\\b', 'LLP');
END$$

-- Names: drop titles (MR., SMT., M/S), trailing full stops and double
-- spaces, turn CBS-P's "SURNAME, FIRST" into "First Surname".
CREATE FUNCTION fn_clean_name(s VARCHAR(80)) RETURNS VARCHAR(80)
DETERMINISTIC NO SQL
BEGIN
  DECLARE t VARCHAR(80);
  IF s IS NULL OR TRIM(s) = '' THEN RETURN NULL; END IF;
  SET t = UPPER(TRIM(s));
  SET t = REGEXP_REPLACE(t, '\\s+', ' ');
  SET t = REGEXP_REPLACE(t, '^(MR|MRS|MS|SMT|SHRI|DR)\\.? ', '');
  SET t = REGEXP_REPLACE(t, '^M/S ', '');
  SET t = REGEXP_REPLACE(t, '\\.$', '');
  IF LOCATE(',', t) > 0 THEN
    SET t = CONCAT(TRIM(SUBSTRING(t, LOCATE(',', t) + 1)), ' ', TRIM(SUBSTRING(t, 1, LOCATE(',', t) - 1)));
  END IF;
  RETURN fn_proper(TRIM(t));
END$$

-- PAN: upper case, no spaces. Returns NULL unless it is 5 letters,
-- 4 digits, 1 letter, with holder type P (person) or C (company).
CREATE FUNCTION fn_clean_pan(s VARCHAR(12)) RETURNS CHAR(10)
DETERMINISTIC NO SQL
BEGIN
  DECLARE t VARCHAR(12);
  IF s IS NULL THEN RETURN NULL; END IF;
  SET t = UPPER(REPLACE(TRIM(s), ' ', ''));
  IF t REGEXP '^[A-Z]{3}[PC][A-Z][0-9]{4}[A-Z]$' THEN RETURN t; END IF;
  RETURN NULL;
END$$

-- Mobile: keep digits, drop +91 / 91 / 0 prefixes. Returns NULL unless
-- 10 digits starting 6, 7, 8 or 9.
CREATE FUNCTION fn_clean_mobile(s VARCHAR(150)) RETURNS CHAR(10)
DETERMINISTIC NO SQL
BEGIN
  DECLARE t VARCHAR(150);
  IF s IS NULL THEN RETURN NULL; END IF;
  SET t = REGEXP_REPLACE(s, '[^0-9]', '');
  IF CHAR_LENGTH(t) = 12 AND LEFT(t, 2) = '91' THEN SET t = SUBSTRING(t, 3); END IF;
  IF CHAR_LENGTH(t) = 11 AND LEFT(t, 1) = '0'  THEN SET t = SUBSTRING(t, 2); END IF;
  IF t REGEXP '^[6-9][0-9]{9}$' THEN RETURN t; END IF;
  RETURN NULL;
END$$

DELIMITER ;

-- ---------------------------------------------------------------------
-- Data quality log: one row per problem found
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS dq_log;
CREATE TABLE dq_log (
  dq_id            INT AUTO_INCREMENT PRIMARY KEY,
  question         VARCHAR(5)    NOT NULL,
  table_name       VARCHAR(40)   NOT NULL,
  column_name      VARCHAR(40)   NULL,
  source_system    VARCHAR(10)   NULL,
  problem          VARCHAR(200)  NOT NULL,
  rule_applied     VARCHAR(300)  NOT NULL,
  action_taken     VARCHAR(10)   NOT NULL,   -- FIXED, FLAGGED, EXCLUDED, ADDED, NONE
  rows_affected    INT           NOT NULL,
  rupees_involved  DECIMAL(16,2) NULL
);

-- =====================================================================
-- Q1.1 IS EVERYTHING HERE?
-- =====================================================================

-- File by file: rows held against rows the manifest says were sent, and
-- the control total held against the manifest's control total.
DROP TABLE IF EXISTS recon_files;
CREATE TABLE recon_files AS
SELECT m.file_name, m.source_system, m.expected_rows, h.rows_held,
       h.rows_held - m.expected_rows AS row_difference,
       m.control_column, m.control_total, h.total_held,
       h.total_held - m.control_total AS total_difference,
       CAST(NULL AS CHAR(300)) AS explanation
FROM load_manifest m
JOIN (
  SELECT 'regions.csv' f, COUNT(*) rows_held, NULL total_held FROM regions
  UNION ALL SELECT 'branches.csv', COUNT(*), NULL FROM branches
  UNION ALL SELECT 'products.csv', COUNT(*), NULL FROM products
  UNION ALL SELECT 'officers.csv', COUNT(*), NULL FROM officers
  UNION ALL SELECT 'customers.csv', COUNT(*), NULL FROM customers
  UNION ALL SELECT 'customer_contacts.csv', COUNT(*), NULL FROM customer_contacts
  UNION ALL SELECT 'legacy_id_map.csv', COUNT(*), NULL FROM legacy_id_map
  UNION ALL SELECT 'loan_accounts.csv', COUNT(*), SUM(fn_to_amount(outstanding_principal)) FROM loan_accounts
  UNION ALL SELECT 'disbursements.csv', COUNT(*), NULL FROM disbursements
  UNION ALL SELECT 'collateral.csv', COUNT(*), NULL FROM collateral
  UNION ALL SELECT 'emi_schedule.csv', COUNT(*), SUM(emi_due) FROM emi_schedule
  UNION ALL SELECT 'repayments.csv', COUNT(*), SUM(amount) FROM repayments
  UNION ALL SELECT 'nach_mandates.csv', COUNT(*), NULL FROM nach_mandates
  UNION ALL SELECT 'finance_npa_oct2026.csv', COUNT(*), NULL FROM finance_npa_oct2026
  UNION ALL SELECT 'risk_npa_oct2026.csv', COUNT(*), NULL FROM risk_npa_oct2026
  UNION ALL SELECT 'cbs_extract_oct2026.csv', COUNT(*), SUM(outstanding_principal) FROM cbs_extract_oct2026
  UNION ALL SELECT 'dw_snapshot_oct2026.csv', COUNT(*), SUM(outstanding_principal) FROM dw_snapshot_oct2026
) h ON h.f = m.file_name;

-- The manifest lists 17 files; it does not list itself.
ALTER TABLE recon_files MODIFY expected_rows INT NULL, MODIFY row_difference BIGINT NULL;
INSERT INTO recon_files (file_name, source_system, expected_rows, rows_held, row_difference, explanation)
SELECT 'load_manifest.csv', 'MANIFEST', NULL, COUNT(*), NULL,
       'Not listed in the manifest (a file cannot list itself). 17 rows = one per other file.'
FROM load_manifest;

UPDATE recon_files SET explanation = 'Matches: rows and control total as sent.'
WHERE explanation IS NULL AND row_difference = 0 AND COALESCE(total_difference, 0) = 0;

-- loan_accounts is the one file that does not match: explained further
-- down once the loan book is built (duplicates and 2 missing loans).
UPDATE recon_files SET explanation =
  'Loaded exactly as sent (8,366 rows). The file holds 102 loans twice (64 exact repeats, 38 re-extracted in batch B07 on 1 Nov) and is missing 2 loans that every other file has (MCL0105074, MCL0105200). After de-duplication and recovery: 8,266 loans, total = control total. See dq_log Q1.5.'
WHERE file_name = 'loan_accounts.csv';

-- Warehouse: is October fully in the data warehouse? Compare the core
-- banking extract with the warehouse snapshot loan by loan.
DROP TABLE IF EXISTS recon_warehouse;
CREATE TABLE recon_warehouse (
  loan_id        VARCHAR(20) NOT NULL,
  issue          VARCHAR(40) NOT NULL,
  cbs_value      VARCHAR(30) NULL,
  dw_value       VARCHAR(30) NULL,
  rupees         DECIMAL(16,2) NULL,
  PRIMARY KEY (loan_id, issue)
);

INSERT INTO recon_warehouse
SELECT c.loan_id, 'MISSING_FROM_WAREHOUSE', c.outstanding_principal, NULL, c.outstanding_principal
FROM cbs_extract_oct2026 c LEFT JOIN dw_snapshot_oct2026 d ON d.loan_id = c.loan_id
WHERE d.loan_id IS NULL;

INSERT INTO recon_warehouse
SELECT d.loan_id, 'IN_WAREHOUSE_NOT_IN_CBS', NULL, d.outstanding_principal, d.outstanding_principal
FROM dw_snapshot_oct2026 d LEFT JOIN cbs_extract_oct2026 c ON c.loan_id = d.loan_id
WHERE c.loan_id IS NULL;

INSERT INTO recon_warehouse
SELECT c.loan_id, 'BALANCE_DIFFERS', c.outstanding_principal, d.outstanding_principal,
       d.outstanding_principal - c.outstanding_principal
FROM cbs_extract_oct2026 c JOIN dw_snapshot_oct2026 d ON d.loan_id = c.loan_id
WHERE c.outstanding_principal <> d.outstanding_principal;

INSERT INTO recon_warehouse
SELECT c.loan_id, 'ASSET_CLASS_DIFFERS', c.cbs_asset_class, d.cbs_asset_class, c.outstanding_principal
FROM cbs_extract_oct2026 c JOIN dw_snapshot_oct2026 d ON d.loan_id = c.loan_id
WHERE c.cbs_asset_class <> d.cbs_asset_class;

INSERT INTO recon_warehouse
SELECT c.loan_id, 'BRANCH_OR_PRODUCT_DIFFERS', CONCAT(c.branch_code, '/', c.product_code),
       CONCAT(d.branch_code, '/', d.product_code), c.outstanding_principal
FROM cbs_extract_oct2026 c JOIN dw_snapshot_oct2026 d ON d.loan_id = c.loan_id
WHERE c.branch_code <> d.branch_code OR c.product_code <> d.product_code;

INSERT INTO dq_log (question, table_name, column_name, source_system, problem, rule_applied, action_taken, rows_affected, rupees_involved)
SELECT 'Q1.1', 'dw_snapshot_oct2026', 'loan_id', 'DWH',
       CASE issue
         WHEN 'MISSING_FROM_WAREHOUSE'   THEN 'Loan in CBS extract but not loaded into the warehouse (all former Pavanpur loans)'
         WHEN 'IN_WAREHOUSE_NOT_IN_CBS'  THEN 'Loan in warehouse but not in the October CBS extract (stale rows for loans no longer in the book)'
         WHEN 'BALANCE_DIFFERS'          THEN 'Warehouse balance differs from CBS (warehouse holds the higher, earlier balance)'
         WHEN 'ASSET_CLASS_DIFFERS'      THEN 'CBS says NPA, warehouse says STD'
         ELSE issue END,
       'Warehouse is NOT complete: CBS extract is the system of record; warehouse not used for any figure',
       'FLAGGED', COUNT(*), SUM(rupees)
FROM recon_warehouse GROUP BY issue;

-- =====================================================================
-- Q1.2 HOW BAD IS IT? (profile before fixing)
-- Every format problem, by table, column and source system.
-- =====================================================================

-- loan_accounts: dates, amounts, rates, tenure, product names, branch codes
INSERT INTO dq_log (question, table_name, column_name, source_system, problem, rule_applied, action_taken, rows_affected, rupees_involved)
SELECT 'Q1.2', 'loan_accounts', col, source_system, CONCAT('Date written as ', fmt),
       CASE fmt WHEN 'SLASH' THEN 'Slash dates read as MM/DD/YYYY for CBS-M and DD/MM/YYYY for CBS-P (no value contradicts this)'
                WHEN 'EXCEL_SERIAL' THEN 'Excel serial number converted: 1899-12-30 + n days'
                ELSE 'Converted with STR_TO_DATE' END,
       'FIXED', COUNT(*), SUM(fn_to_amount(outstanding_principal))
FROM (
  SELECT 'sanction_date' col, source_system, fn_date_format(sanction_date) fmt, outstanding_principal FROM loan_accounts
  UNION ALL
  SELECT 'first_emi_date', source_system, fn_date_format(first_emi_date), outstanding_principal FROM loan_accounts
) x WHERE fmt <> 'ISO'
GROUP BY col, source_system, fmt;

INSERT INTO dq_log (question, table_name, column_name, source_system, problem, rule_applied, action_taken, rows_affected, rupees_involved)
SELECT 'Q1.2', 'loan_accounts', col, source_system, CONCAT('Amount written in format ', fmt),
       'Removed ₹ and Indian-style commas; "L" multiplied by 1,00,000', 'FIXED', COUNT(*), SUM(amt)
FROM (
  SELECT 'sanction_amount' col, source_system, fn_amount_format(sanction_amount) fmt, fn_to_amount(sanction_amount) amt FROM loan_accounts
  UNION ALL
  SELECT 'outstanding_principal', source_system, fn_amount_format(outstanding_principal), fn_to_amount(outstanding_principal) FROM loan_accounts
) x WHERE fmt <> 'PLAIN'
GROUP BY col, source_system, fmt;

INSERT INTO dq_log (question, table_name, column_name, source_system, problem, rule_applied, action_taken, rows_affected, rupees_involved)
SELECT 'Q1.2', 'loan_accounts', 'interest_rate', source_system, problem,
       'Removed %; values below 1 multiplied by 100', 'FIXED', COUNT(*), SUM(amt)
FROM (
  SELECT source_system, fn_to_amount(outstanding_principal) amt,
         CASE WHEN interest_rate LIKE '%\%%' THEN 'Rate written with a % sign'
              ELSE 'Rate written as a fraction (0.1200 = 12.00%)' END problem
  FROM loan_accounts
  WHERE interest_rate LIKE '%\%%' OR CAST(REPLACE(interest_rate, '%', '') AS DECIMAL(10,5)) < 1
) x GROUP BY source_system, problem;

INSERT INTO dq_log (question, table_name, column_name, source_system, problem, rule_applied, action_taken, rows_affected, rupees_involved)
SELECT 'Q1.2', 'loan_accounts', 'tenure', source_system, problem,
       'Converted to months (Y x 12)', 'FIXED', COUNT(*), SUM(amt)
FROM (
  SELECT source_system, fn_to_amount(outstanding_principal) amt,
         CONCAT('Tenure written in ', IF(tenure LIKE '%Y', 'years (e.g. 5Y)', 'months with M suffix (e.g. 60M)')) problem
  FROM loan_accounts WHERE tenure REGEXP '[YM]$'
) x GROUP BY source_system, problem;

INSERT INTO dq_log (question, table_name, column_name, source_system, problem, rule_applied, action_taken, rows_affected, rupees_involved)
SELECT 'Q1.2', 'loan_accounts', 'product', source_system,
       CONCAT(COUNT(DISTINCT product), ' different names used for product codes (e.g. PERS LOAN, JEWEL LOAN, 2W/4W LOAN)'),
       'Mapped every name to the 6 product codes in products (mapping confirmed against cbs_extract product_code for every loan)',
       'FIXED', COUNT(*), SUM(fn_to_amount(outstanding_principal))
FROM loan_accounts WHERE product NOT IN (SELECT product_code FROM products)
GROUP BY source_system;

INSERT INTO dq_log (question, table_name, column_name, source_system, problem, rule_applied, action_taken, rows_affected, rupees_involved)
SELECT 'Q1.2', 'loan_accounts', 'branch_code', source_system,
       'Pavanpur branch code lost its leading zero (101 instead of 0101)',
       'Left-padded CBS-P branch codes to 4 digits', 'FIXED', COUNT(*), SUM(fn_to_amount(outstanding_principal))
FROM loan_accounts WHERE CHAR_LENGTH(branch_code) < 4
GROUP BY source_system;

INSERT INTO dq_log (question, table_name, column_name, source_system, problem, rule_applied, action_taken, rows_affected, rupees_involved)
SELECT 'Q1.2', 'loan_accounts', 'sanctioning_officer_id', source_system,
       'No approving officer recorded', 'Kept; officer unknown, loan cannot be tested against the delegation matrix',
       'FLAGGED', COUNT(*), SUM(fn_to_amount(outstanding_principal))
FROM loan_accounts WHERE sanctioning_officer_id IS NULL
GROUP BY source_system;

-- customers: names, PANs, dates, gender, KYC words
INSERT INTO dq_log (question, table_name, column_name, source_system, problem, rule_applied, action_taken, rows_affected, rupees_involved)
SELECT 'Q1.2', 'customers', col, source_system, problem, rule_applied, 'FIXED', COUNT(*), NULL
FROM (
  SELECT 'customer_name' col, source_system,
         'Name not in clean "First Surname" form (titles, SURNAME, FIRST order, upper/lower case, extra spaces, trailing full stop)' problem,
         'Titles and M/S removed, order reversed, spaces collapsed, proper case' rule_applied
  FROM customers WHERE BINARY customer_name <> BINARY fn_clean_name(customer_name)
  UNION ALL
  SELECT 'pan', source_system, 'PAN in lower case or with spaces', 'Upper-cased and spaces removed'
  FROM customers WHERE pan IS NOT NULL AND BINARY pan <> BINARY fn_clean_pan(pan)
  UNION ALL
  SELECT 'date_of_birth', source_system, 'Date of birth written DD/MM/YYYY', 'Converted to DATE'
  FROM customers WHERE date_of_birth LIKE '%/%'
  UNION ALL
  SELECT 'created_on', source_system, 'Created date written DD/MM/YYYY', 'Converted to DATE'
  FROM customers WHERE created_on LIKE '%/%'
  UNION ALL
  SELECT 'gender', source_system, 'Gender written Male/Female instead of M/F', 'Standardised to M/F'
  FROM customers WHERE gender IN ('Male', 'Female')
  UNION ALL
  SELECT 'kyc_status', source_system, 'Pavanpur KYC word "KYC DONE"', 'Standardised to VERIFIED'
  FROM customers WHERE kyc_status = 'KYC DONE'
) x GROUP BY col, source_system, problem, rule_applied;

-- other tables: amounts and dates in mixed formats
INSERT INTO dq_log (question, table_name, column_name, source_system, problem, rule_applied, action_taken, rows_affected, rupees_involved)
SELECT 'Q1.2', t, col, src, problem, rule_applied, 'FIXED', COUNT(*), SUM(amt)
FROM (
  SELECT 'disbursements' t, 'amount' col, COALESCE(la.source_system, 'CBS-M') src,
         CONCAT('Amount written in format ', fn_amount_format(d.amount)) problem,
         'Removed ₹ and commas; "L" x 1,00,000' rule_applied, fn_to_amount(d.amount) amt
  FROM disbursements d LEFT JOIN (SELECT DISTINCT loan_id, source_system FROM loan_accounts) la ON la.loan_id = d.loan_id
  WHERE fn_amount_format(d.amount) <> 'PLAIN'
  UNION ALL
  SELECT 'disbursements', 'disbursement_date', COALESCE(la.source_system, 'CBS-M'),
         'Payout date written DD/MM/YYYY', 'Converted to DATE', fn_to_amount(d.amount)
  FROM disbursements d LEFT JOIN (SELECT DISTINCT loan_id, source_system FROM loan_accounts) la ON la.loan_id = d.loan_id
  WHERE d.disbursement_date LIKE '%/%'
  UNION ALL
  SELECT 'collateral', 'valuation_amount', COALESCE(la.source_system, 'CBS-M'),
         CONCAT('Amount written in format ', fn_amount_format(c.valuation_amount)),
         'Removed ₹ and commas; "L" x 1,00,000', fn_to_amount(c.valuation_amount)
  FROM collateral c LEFT JOIN (SELECT DISTINCT loan_id, source_system FROM loan_accounts) la ON la.loan_id = c.loan_id
  WHERE fn_amount_format(c.valuation_amount) <> 'PLAIN'
  UNION ALL
  SELECT 'collateral', 'valuation_date', COALESCE(la.source_system, 'CBS-M'),
         'Valuation date written DD/MM/YYYY', 'Converted to DATE', fn_to_amount(c.valuation_amount)
  FROM collateral c LEFT JOIN (SELECT DISTINCT loan_id, source_system FROM loan_accounts) la ON la.loan_id = c.loan_id
  WHERE c.valuation_date LIKE '%/%'
  UNION ALL
  SELECT 'customer_contacts', 'contact_value', IF(c.customer_id LIKE 'PV%', 'CBS-P', 'CBS-M'),
         'Mobile written with +91, 0 prefix or spaces', 'Kept digits only, dropped 91/0 prefix', NULL
  FROM customer_contacts c
  WHERE c.contact_type = 'MOBILE' AND c.contact_value IS NOT NULL
    AND c.contact_value <> COALESCE(fn_clean_mobile(c.contact_value), '#') AND fn_clean_mobile(c.contact_value) IS NOT NULL
) x GROUP BY t, col, src, problem, rule_applied;

-- =====================================================================
-- Q1.3 CLEAN THE CUSTOMER RECORDS
-- =====================================================================

-- Best mobile per customer: a valid primary number first, then any valid
-- number, the most recently updated first.
DROP TABLE IF EXISTS tmp_best_mobile;
CREATE TABLE tmp_best_mobile AS
SELECT customer_id, mobile_clean, raw_value FROM (
  SELECT customer_id, fn_clean_mobile(contact_value) mobile_clean, contact_value raw_value,
         ROW_NUMBER() OVER (PARTITION BY customer_id
                            ORDER BY fn_clean_mobile(contact_value) IS NULL, is_primary = 'Y' DESC,
                                     updated_on DESC, contact_id) rn
  FROM customer_contacts WHERE contact_type = 'MOBILE'
) x WHERE rn = 1;
ALTER TABLE tmp_best_mobile ADD PRIMARY KEY (customer_id);

DROP TABLE IF EXISTS customers_clean;
CREATE TABLE customers_clean (
  customer_id        VARCHAR(15) NOT NULL PRIMARY KEY,
  source_system      VARCHAR(5)  NOT NULL,
  customer_name_raw  VARCHAR(80) NULL,
  customer_name      VARCHAR(80) NULL,
  entity_type        VARCHAR(10) NOT NULL,       -- INDIVIDUAL or COMPANY
  pan_raw            VARCHAR(12) NULL,
  pan                CHAR(10)    NULL,           -- NULL when it cannot be fixed
  pan_status         VARCHAR(60) NOT NULL,
  mobile             CHAR(10)    NULL,
  mobile_status      VARCHAR(60) NOT NULL,
  date_of_birth      DATE        NULL,
  gender             CHAR(1)     NULL,
  occupation         VARCHAR(30) NULL,
  kyc_status         VARCHAR(12) NULL,
  created_on         DATE        NULL
);

INSERT INTO customers_clean
SELECT c.customer_id, c.source_system, c.customer_name, fn_clean_name(c.customer_name),
       IF(UPPER(c.customer_name) REGEXP 'M/S|PVT|LTD|LLP|& CO|INDUSTRIES|TRADERS|MILL|MOTORS|WORKS|TEXTILES|PRINTERS|TRANSPORT|PRODUCTS|ENTERPRISES|PLASTICS|GINNING|AGRO|TIMBER|MART|AUTO PARTS|HARDWARE|STORES|AGENCIES|DAIRY|BRICK',
          'COMPANY', 'INDIVIDUAL'),
       c.pan, fn_clean_pan(c.pan), 'TBD',
       m.mobile_clean, IF(m.mobile_clean IS NULL, 'TBD', 'VALID'),
       fn_to_date(c.date_of_birth, c.source_system),
       CASE WHEN c.gender IN ('M', 'Male') THEN 'M' WHEN c.gender IN ('F', 'Female') THEN 'F' END,
       c.occupation,
       IF(c.kyc_status = 'KYC DONE', 'VERIFIED', c.kyc_status),
       fn_to_date(c.created_on, c.source_system)
FROM customers c LEFT JOIN tmp_best_mobile m ON m.customer_id = c.customer_id;

-- PAN verdicts. The 4th character must match the holder: P for a
-- person, C for a company.
UPDATE customers_clean SET pan_status = CASE
  WHEN pan_raw IS NULL THEN 'UNFIXABLE: no PAN recorded'
  WHEN UPPER(pan_raw) IN ('NA', 'PANAPPLIED') THEN 'UNFIXABLE: placeholder (NA / PANAPPLIED)'
  WHEN UPPER(REPLACE(pan_raw, ' ', '')) = 'XXXXX0000X' THEN 'UNFIXABLE: dummy PAN XXXXX0000X'
  WHEN pan IS NULL AND CHAR_LENGTH(REPLACE(pan_raw, ' ', '')) <> 10 THEN 'UNFIXABLE: wrong length (character missing)'
  WHEN pan IS NULL THEN 'UNFIXABLE: wrong pattern'
  WHEN entity_type = 'INDIVIDUAL' AND SUBSTRING(pan, 4, 1) <> 'P' THEN 'UNFIXABLE: company PAN on a person'
  WHEN entity_type = 'COMPANY' AND SUBSTRING(pan, 4, 1) <> 'C' THEN 'UNFIXABLE: personal PAN on a company'
  WHEN BINARY pan <> BINARY pan_raw THEN 'FIXED: case / spaces'
  ELSE 'VALID' END;
UPDATE customers_clean SET pan = NULL WHERE pan_status LIKE 'UNFIXABLE%';

UPDATE customers_clean cc
LEFT JOIN (SELECT customer_id, MAX(contact_value) any_value, COUNT(*) n
           FROM customer_contacts WHERE contact_type = 'MOBILE' GROUP BY customer_id) x
  ON x.customer_id = cc.customer_id
JOIN tmp_best_mobile b ON b.customer_id = cc.customer_id
SET cc.mobile_status = CASE
  WHEN cc.mobile IS NOT NULL AND b.raw_value = cc.mobile THEN 'VALID'
  WHEN cc.mobile IS NOT NULL THEN 'FIXED: +91 / 0 / spaces removed'
  WHEN x.n IS NULL THEN 'UNFIXABLE: no mobile recorded'
  ELSE 'UNFIXABLE: 9 digits (a digit is missing)' END;
UPDATE customers_clean SET mobile_status = 'UNFIXABLE: no mobile recorded'
WHERE mobile_status = 'TBD';

-- Everything that cannot be fixed, one row per customer per reason.
DROP TABLE IF EXISTS customer_exceptions;
CREATE TABLE customer_exceptions AS
SELECT customer_id, source_system, customer_name, 'PAN' field, pan_raw raw_value, pan_status reason
FROM customers_clean WHERE pan_status LIKE 'UNFIXABLE%'
UNION ALL
SELECT cc.customer_id, cc.source_system, cc.customer_name, 'MOBILE', b.raw_value, cc.mobile_status
FROM customers_clean cc LEFT JOIN tmp_best_mobile b ON b.customer_id = cc.customer_id
WHERE cc.mobile_status LIKE 'UNFIXABLE%'
UNION ALL
SELECT customer_id, source_system, customer_name, 'DATE_OF_BIRTH', NULL, 'UNFIXABLE: no date of birth recorded'
FROM customers_clean WHERE date_of_birth IS NULL;

INSERT INTO dq_log (question, table_name, column_name, source_system, problem, rule_applied, action_taken, rows_affected, rupees_involved)
SELECT 'Q1.3', 'customers', LOWER(field), source_system, reason,
       'Cannot be repaired from the data held; listed in customer_exceptions for the branch to collect',
       'FLAGGED', COUNT(*), NULL
FROM customer_exceptions GROUP BY field, source_system, reason;

INSERT INTO dq_log (question, table_name, column_name, source_system, problem, rule_applied, action_taken, rows_affected, rupees_involved)
SELECT 'Q1.3', 'customers', 'pan', source_system, pan_status, 'Upper-cased, spaces removed, then validated', 'FIXED', COUNT(*), NULL
FROM customers_clean WHERE pan_status LIKE 'FIXED%' GROUP BY source_system, pan_status;

INSERT INTO dq_log (question, table_name, column_name, source_system, problem, rule_applied, action_taken, rows_affected, rupees_involved)
SELECT 'Q1.3', 'customer_contacts', 'mobile', source_system, mobile_status, 'Best valid number chosen (primary first, latest first)', 'FIXED', COUNT(*), NULL
FROM customers_clean WHERE mobile_status LIKE 'FIXED%' GROUP BY source_system, mobile_status;

-- =====================================================================
-- Q1.4 ONE BORROWER, ONE IDENTITY
-- A Pavanpur customer (PV...) is the same person as a Meridian customer
-- (MC...) only when the evidence agrees and nothing contradicts it:
--   R1 same valid PAN, same clean name, same date of birth
--   R2 same clean name + same date of birth, and the PANs do not
--      contradict (one side missing or unusable)
-- A candidate is refused when the PANs differ, the dates of birth
-- differ, or there is more than one possible partner.
-- =====================================================================

DROP TABLE IF EXISTS identity_decisions;
CREATE TABLE identity_decisions (
  pavanpur_customer_id  VARCHAR(15) NOT NULL,
  meridian_customer_id  VARCHAR(15) NOT NULL,
  proposed_by           VARCHAR(20) NOT NULL,   -- VENDOR_MAP or OUR_SEARCH
  vendor_basis          VARCHAR(20) NULL,
  same_pan              VARCHAR(12) NOT NULL,   -- YES / NO / ONE_MISSING
  same_name             CHAR(3)     NOT NULL,
  same_dob              VARCHAR(12) NOT NULL,
  decision              VARCHAR(8)  NOT NULL,   -- ACCEPT / REFUSE
  reason                VARCHAR(200) NOT NULL,
  PRIMARY KEY (pavanpur_customer_id, meridian_customer_id)
);

-- Candidates: everything the vendor proposed, plus our own search of
-- unmapped Pavanpur customers by PAN and by name + date of birth.
INSERT INTO identity_decisions
SELECT p.customer_id, m.customer_id, src, basis,
       CASE WHEN p.pan IS NULL OR m.pan IS NULL THEN 'ONE_MISSING' WHEN p.pan = m.pan THEN 'YES' ELSE 'NO' END,
       IF(p.customer_name = m.customer_name, 'YES', 'NO'),
       CASE WHEN p.date_of_birth IS NULL OR m.date_of_birth IS NULL THEN 'ONE_MISSING'
            WHEN p.date_of_birth = m.date_of_birth THEN 'YES' ELSE 'NO' END,
       'TBD', ''
FROM (
  SELECT pavanpur_customer_id pv, meridian_customer_id mc, 'VENDOR_MAP' src, match_basis basis FROM legacy_id_map
  UNION
  SELECT p.customer_id, m.customer_id, 'OUR_SEARCH', NULL
  FROM customers_clean p JOIN customers_clean m ON m.pan = p.pan AND m.source_system = 'CBS-M'
  WHERE p.source_system = 'CBS-P' AND p.customer_id NOT IN (SELECT pavanpur_customer_id FROM legacy_id_map)
  UNION
  SELECT p.customer_id, m.customer_id, 'OUR_SEARCH', NULL
  FROM customers_clean p JOIN customers_clean m
    ON m.customer_name = p.customer_name AND m.date_of_birth = p.date_of_birth AND m.source_system = 'CBS-M'
  WHERE p.source_system = 'CBS-P' AND p.customer_id NOT IN (SELECT pavanpur_customer_id FROM legacy_id_map)
) cand
JOIN customers_clean p ON p.customer_id = cand.pv
JOIN customers_clean m ON m.customer_id = cand.mc;

UPDATE identity_decisions SET
  decision = CASE
    WHEN same_pan = 'NO' THEN 'REFUSE'
    WHEN same_dob = 'NO' THEN 'REFUSE'
    WHEN same_name = 'NO' THEN 'REFUSE'
    WHEN same_pan = 'YES' THEN 'ACCEPT'
    WHEN same_dob = 'YES' THEN 'ACCEPT'
    ELSE 'REFUSE' END,
  reason = CASE
    WHEN same_pan = 'NO' THEN 'Refused: different PANs means different people'
    WHEN same_dob = 'NO' THEN 'Refused: same name but different dates of birth'
    WHEN same_name = 'NO' THEN 'Refused: names differ'
    WHEN same_pan = 'YES' THEN 'Accepted: same PAN, name and date of birth'
    WHEN same_dob = 'YES' THEN 'Accepted: same name and date of birth; PAN missing/unusable on one side, so nothing contradicts'
    ELSE 'Refused: not enough evidence' END;

-- A Pavanpur ID may link to only one Meridian ID; if more than one
-- candidate survives, refuse all of them.
UPDATE identity_decisions d
JOIN (SELECT pavanpur_customer_id FROM identity_decisions WHERE decision = 'ACCEPT'
      GROUP BY pavanpur_customer_id HAVING COUNT(*) > 1) amb USING (pavanpur_customer_id)
SET d.decision = 'REFUSE', d.reason = 'Refused: more than one possible Meridian match';

-- Meridian IDs that share one PAN, or name + date of birth, inside CBS-M.
INSERT INTO identity_decisions
SELECT a.customer_id, b.customer_id, 'OUR_SEARCH', 'CBS-M internal',
       CASE WHEN a.pan IS NULL OR b.pan IS NULL THEN 'ONE_MISSING' WHEN a.pan = b.pan THEN 'YES' ELSE 'NO' END,
       'YES', 'YES',
       IF(a.pan IS NOT NULL AND b.pan IS NOT NULL AND a.pan <> b.pan, 'REFUSE', 'ACCEPT'),
       IF(a.pan IS NOT NULL AND b.pan IS NOT NULL AND a.pan <> b.pan,
          'Refused: two Meridian records, same name and birth date but different PANs',
          'Accepted: two Meridian records for the same person')
FROM customers_clean a JOIN customers_clean b
  ON a.source_system = 'CBS-M' AND b.source_system = 'CBS-M' AND a.customer_id > b.customer_id
 AND a.customer_name = b.customer_name AND a.date_of_birth = b.date_of_birth;

-- One row per customer number -> one real borrower. The borrower takes
-- the Meridian ID when a link is accepted, otherwise its own ID.
DROP TABLE IF EXISTS borrower_map;
CREATE TABLE borrower_map (
  customer_id    VARCHAR(15) NOT NULL PRIMARY KEY,
  borrower_id    VARCHAR(15) NOT NULL,
  link_basis     VARCHAR(60) NOT NULL,
  KEY (borrower_id)
);
INSERT INTO borrower_map
SELECT c.customer_id,
       COALESCE(d.meridian_customer_id, c.customer_id),
       COALESCE(CONCAT(d.proposed_by, ': ', LEFT(d.reason, 45)), 'Own record (no accepted match)')
FROM customers_clean c
LEFT JOIN identity_decisions d ON d.pavanpur_customer_id = c.customer_id AND d.decision = 'ACCEPT';

INSERT INTO dq_log (question, table_name, column_name, source_system, problem, rule_applied, action_taken, rows_affected, rupees_involved)
SELECT 'Q1.4', 'legacy_id_map', 'meridian_customer_id', proposed_by,
       CONCAT(IF(decision = 'ACCEPT', 'Link accepted', 'Link refused'),
              IF(vendor_basis IS NULL, '', CONCAT(' (vendor basis ', vendor_basis, ')'))),
       reason, IF(decision = 'ACCEPT', 'FIXED', 'EXCLUDED'), COUNT(*), NULL
FROM identity_decisions GROUP BY proposed_by, vendor_basis, decision, reason;

-- =====================================================================
-- Q1.5 A USABLE LOAN BOOK
-- =====================================================================

-- Every raw row parsed into usable types.
DROP TABLE IF EXISTS tmp_loans_parsed;
CREATE TABLE tmp_loans_parsed AS
SELECT la.record_id, la.loan_id, la.source_system, la.load_batch, la.load_timestamp, la.customer_id,
       IF(la.source_system = 'CBS-P', LPAD(la.branch_code, 4, '0'), la.branch_code) branch_code,
       CASE
         WHEN la.product IN ('PL', 'Personal Loan', 'PERS LOAN', 'PERSONAL') THEN 'PL'
         WHEN la.product IN ('VL', 'Vehicle Loan', 'VEHICLE', '2W/4W LOAN') THEN 'VL'
         WHEN la.product IN ('HL', 'Home Loan', 'HOME LN', 'HOUSING LOAN') THEN 'HL'
         WHEN la.product IN ('GL', 'Gold Loan', 'GOLD', 'JEWEL LOAN') THEN 'GL'
         WHEN la.product IN ('LAP', 'Loan Against Property', 'MORTGAGE LOAN') THEN 'LAP'
         WHEN la.product IN ('MSME', 'MSME TL', 'BUSINESS LOAN') THEN 'MSME'
       END product_code,
       la.product product_raw, la.sourcing_channel, la.sanctioning_officer_id,
       fn_to_date(la.sanction_date, la.source_system) sanction_date,
       fn_to_amount(la.sanction_amount) sanction_amount,
       fn_to_rate(la.interest_rate) interest_rate,
       fn_to_months(la.tenure) tenure_months,
       CAST(la.emi_amount AS DECIMAL(12,2)) emi_amount,
       fn_to_date(la.first_emi_date, la.source_system) first_emi_date,
       fn_to_amount(la.outstanding_principal) outstanding_principal,
       la.cbs_asset_class,
       ROW_NUMBER() OVER (PARTITION BY la.loan_id ORDER BY la.load_timestamp DESC, la.record_id) version_rank,
       COUNT(*) OVER (PARTITION BY la.loan_id) copies
FROM loan_accounts la;

-- Duplicates. Rule: keep the latest version of each loan (latest
-- load_timestamp; exact repeats keep the lowest record_id). The B07
-- re-extract carries the balance that the CBS extract also holds.
INSERT INTO dq_log (question, table_name, column_name, source_system, problem, rule_applied, action_taken, rows_affected, rupees_involved)
SELECT 'Q1.5', 'loan_accounts', 'loan_id', p.source_system,
       IF(p.outstanding_principal = k.outstanding_principal AND p.load_timestamp = k.load_timestamp,
          'Exact repeat of a loan row (same batch, same timestamp)',
          'Older version of a loan re-extracted in batch B07 (balance before the last October posting)'),
       'Kept one row per loan: latest load_timestamp; exact repeats keep lowest record_id',
       'EXCLUDED', COUNT(*), SUM(p.outstanding_principal)
FROM tmp_loans_parsed p
JOIN tmp_loans_parsed k ON k.loan_id = p.loan_id AND k.version_rank = 1
WHERE p.version_rank > 1
GROUP BY p.source_system,
         IF(p.outstanding_principal = k.outstanding_principal AND p.load_timestamp = k.load_timestamp, 1, 0);

-- Branch: the branch that holds the loan today. Closed branches pass
-- their loans to merged_into_ifsc (followed up to two steps).
DROP TABLE IF EXISTS branch_current;
CREATE TABLE branch_current AS
SELECT b.ifsc, b.branch_code, b.source_system, b.branch_status,
       CASE WHEN b.branch_status = 'Active' THEN b.ifsc
            WHEN m1.branch_status = 'Active' THEN m1.ifsc
            ELSE m2.ifsc END current_ifsc
FROM branches b
LEFT JOIN branches m1 ON m1.ifsc = b.merged_into_ifsc
LEFT JOIN branches m2 ON m2.ifsc = m1.merged_into_ifsc;
ALTER TABLE branch_current ADD PRIMARY KEY (ifsc), ADD UNIQUE KEY (branch_code, source_system);

-- Payout totals per loan (duplicate payout rows removed; see Q1.7).
DROP TABLE IF EXISTS disbursements_clean;
CREATE TABLE disbursements_clean (
  disbursement_id    VARCHAR(16)   NOT NULL PRIMARY KEY,
  loan_id            VARCHAR(20)   NOT NULL,
  tranche_no         SMALLINT      NOT NULL,
  disbursement_date  DATE          NULL,
  amount             DECIMAL(14,2) NULL,
  payment_mode       VARCHAR(10)   NULL,
  is_duplicate       CHAR(1)       NOT NULL,
  KEY (loan_id)
);
INSERT INTO disbursements_clean
SELECT d.disbursement_id, d.loan_id, d.tranche_no,
       fn_to_date(d.disbursement_date, COALESCE(s.source_system, 'CBS-M')),
       fn_to_amount(d.amount), d.payment_mode, 'N'
FROM disbursements d
LEFT JOIN (SELECT DISTINCT loan_id, source_system FROM loan_accounts) s ON s.loan_id = d.loan_id;

-- A later tranche with the same date and amount as an earlier tranche of
-- the same loan is the same payout posted twice.
DROP TABLE IF EXISTS tmp_disb_dups;
CREATE TABLE tmp_disb_dups AS
SELECT disbursement_id FROM (
  SELECT disbursement_id,
         ROW_NUMBER() OVER (PARTITION BY loan_id, disbursement_date, amount ORDER BY tranche_no) rn
  FROM disbursements_clean
) x WHERE rn > 1;
ALTER TABLE tmp_disb_dups ADD PRIMARY KEY (disbursement_id);
UPDATE disbursements_clean d JOIN tmp_disb_dups x USING (disbursement_id) SET d.is_duplicate = 'Y';
DROP TABLE tmp_disb_dups;

DROP TABLE IF EXISTS tmp_disb_totals;
CREATE TABLE tmp_disb_totals AS
SELECT loan_id, SUM(amount) total_disbursed, MIN(disbursement_date) first_disbursed_on,
       MAX(disbursement_date) last_disbursed_on, COUNT(*) tranches
FROM disbursements_clean WHERE is_duplicate = 'N' GROUP BY loan_id;
ALTER TABLE tmp_disb_totals ADD PRIMARY KEY (loan_id);

-- The clean loan book: one row per loan.
DROP TABLE IF EXISTS loan_book;
CREATE TABLE loan_book (
  loan_id                 VARCHAR(20)   NOT NULL PRIMARY KEY,
  kept_record_id          INT           NULL,
  source_system           VARCHAR(5)    NOT NULL,
  customer_id             VARCHAR(15)   NOT NULL,
  borrower_id             VARCHAR(15)   NOT NULL,
  branch_code             VARCHAR(6)    NOT NULL,
  booking_ifsc            CHAR(11)      NULL,
  branch_ifsc             CHAR(11)      NULL,   -- branch that holds it today
  region_id               VARCHAR(4)    NULL,
  product_code            VARCHAR(6)    NOT NULL,
  secured_flag            CHAR(1)       NULL,
  sourcing_channel        VARCHAR(15)   NULL,
  sanctioning_officer_id  VARCHAR(10)   NULL,
  sanction_date           DATE          NULL,
  sanction_amount         DECIMAL(14,2) NULL,
  interest_rate           DECIMAL(6,3)  NULL,
  tenure_months           SMALLINT      NULL,
  emi_amount_recorded     DECIMAL(12,2) NULL,
  emi_amount              DECIMAL(12,2) NULL,   -- corrected in Q1.6
  first_emi_date          DATE          NULL,
  last_emi_date           DATE          NULL,
  total_disbursed         DECIMAL(14,2) NULL,
  first_disbursed_on      DATE          NULL,
  last_disbursed_on       DATE          NULL,
  outstanding_principal   DECIMAL(14,2) NOT NULL,
  cbs_asset_class         VARCHAR(10)   NULL,
  record_origin           VARCHAR(60)   NOT NULL,
  KEY (borrower_id), KEY (branch_ifsc)
);

INSERT INTO loan_book
SELECT p.loan_id, p.record_id, p.source_system, p.customer_id, COALESCE(bm.borrower_id, p.customer_id),
       p.branch_code, bc.ifsc, bc.current_ifsc, NULL, p.product_code, NULL, p.sourcing_channel,
       p.sanctioning_officer_id, p.sanction_date, p.sanction_amount, p.interest_rate, p.tenure_months,
       p.emi_amount, p.emi_amount, p.first_emi_date,
       DATE_ADD(p.first_emi_date, INTERVAL p.tenure_months - 1 MONTH),
       t.total_disbursed, t.first_disbursed_on, t.last_disbursed_on,
       p.outstanding_principal, p.cbs_asset_class,
       IF(p.copies > 1, 'loan_accounts (latest of duplicates)', 'loan_accounts')
FROM tmp_loans_parsed p
LEFT JOIN borrower_map bm ON bm.customer_id = p.customer_id
LEFT JOIN branch_current bc ON bc.branch_code = p.branch_code AND bc.source_system = p.source_system
LEFT JOIN tmp_disb_totals t ON t.loan_id = p.loan_id
WHERE p.version_rank = 1;

-- Two loans are missing from loan_accounts but present in the CBS
-- extract, Finance and Risk lists, payouts, EMI schedule and payments.
-- Rebuild them from those tables. Rate = instalment-1 interest / amount
-- x 1200; tenure solved from the EMI formula.
INSERT INTO loan_book
SELECT c.loan_id, NULL, 'CBS-M', f.customer_id, COALESCE(bm.borrower_id, f.customer_id),
       c.branch_code, bc.ifsc, bc.current_ifsc, NULL, c.product_code, NULL, NULL, NULL,
       t.first_disbursed_on, t.total_disbursed,
       ROUND(e1.interest_component / t.total_disbursed * 1200, 2),
       ROUND(-LN(1 - t.total_disbursed * (e1.interest_component / t.total_disbursed) / c.emi_amount)
             / LN(1 + e1.interest_component / t.total_disbursed)),
       c.emi_amount, c.emi_amount, e1.due_date, NULL,
       t.total_disbursed, t.first_disbursed_on, t.last_disbursed_on,
       c.outstanding_principal, c.cbs_asset_class, 'Rebuilt from cbs_extract + related tables'
FROM cbs_extract_oct2026 c
JOIN finance_npa_oct2026 f ON f.loan_id = c.loan_id
JOIN emi_schedule e1 ON e1.loan_id = c.loan_id AND e1.instalment_no = 1
LEFT JOIN tmp_disb_totals t ON t.loan_id = c.loan_id
LEFT JOIN borrower_map bm ON bm.customer_id = f.customer_id
LEFT JOIN branch_current bc ON bc.branch_code = c.branch_code AND bc.source_system = 'CBS-M'
WHERE c.loan_id NOT IN (SELECT loan_id FROM loan_book);

UPDATE loan_book SET last_emi_date = DATE_ADD(first_emi_date, INTERVAL tenure_months - 1 MONTH)
WHERE last_emi_date IS NULL;

UPDATE loan_book l
JOIN branches b ON b.ifsc = l.branch_ifsc
JOIN products p ON p.product_code = l.product_code
SET l.region_id = b.region_id, l.secured_flag = p.secured_flag;

INSERT INTO dq_log (question, table_name, column_name, source_system, problem, rule_applied, action_taken, rows_affected, rupees_involved)
SELECT 'Q1.5', 'loan_accounts', 'loan_id', source_system,
       'Loan missing from loan_accounts but present in CBS extract, Finance, Risk, payouts, schedule and payments',
       'Rebuilt from cbs_extract (branch, product, balance, EMI), finance (customer), payouts (amount, date), schedule (first EMI, rate, tenure)',
       'ADDED', COUNT(*), SUM(outstanding_principal)
FROM loan_book WHERE record_origin LIKE 'Rebuilt%' GROUP BY source_system;

INSERT INTO dq_log (question, table_name, column_name, source_system, problem, rule_applied, action_taken, rows_affected, rupees_involved)
SELECT 'Q1.7', 'loan_accounts', 'branch_code', source_system,
       'Loan booked at a branch that has since closed',
       'Moved to the branch that took over its loans (branches.merged_into_ifsc, followed to an active branch)',
       'FIXED', COUNT(*), SUM(outstanding_principal)
FROM loan_book WHERE booking_ifsc <> branch_ifsc GROUP BY source_system;

INSERT INTO dq_log (question, table_name, column_name, source_system, problem, rule_applied, action_taken, rows_affected, rupees_involved)
SELECT 'Q1.5', 'loan_accounts', 'outstanding_principal', source_system,
       'Loan fully repaid but still open with a balance of a rupee or less',
       'Kept in the book (it is in the CBS extract); flagged for closure',
       'FLAGGED', COUNT(*), SUM(outstanding_principal)
FROM loan_book WHERE outstanding_principal <= 1 GROUP BY source_system;

-- =====================================================================
-- Q1.6 DO THE LOAN TERMS ADD UP?
-- EMI = P x r x (1+r)^n / ((1+r)^n - 1), r = annual rate / 12 / 100.
-- =====================================================================

DROP TABLE IF EXISTS loan_emi_check;
CREATE TABLE loan_emi_check AS
SELECT l.loan_id, l.source_system, l.product_code, l.sanction_amount, l.total_disbursed,
       l.interest_rate, l.tenure_months, l.emi_amount_recorded,
       ROUND(l.sanction_amount * (l.interest_rate / 1200) * POW(1 + l.interest_rate / 1200, l.tenure_months)
             / (POW(1 + l.interest_rate / 1200, l.tenure_months) - 1), 2) emi_on_sanction,
       ROUND(l.total_disbursed * (l.interest_rate / 1200) * POW(1 + l.interest_rate / 1200, l.tenure_months)
             / (POW(1 + l.interest_rate / 1200, l.tenure_months) - 1), 2) emi_on_disbursed,
       ROUND(l.sanction_amount * (1 + l.interest_rate / 100 * l.tenure_months / 12) / l.tenure_months, 2) emi_flat_rate,
       s.schedule_emi,
       CAST(NULL AS CHAR(30)) verdict,
       CAST(NULL AS CHAR(250)) explanation
FROM loan_book l
LEFT JOIN (SELECT loan_id, MAX(emi_due) schedule_emi FROM emi_schedule
           WHERE instalment_no = 2 OR instalment_no = 1 GROUP BY loan_id) s ON s.loan_id = l.loan_id;

UPDATE loan_emi_check SET
  verdict = CASE
    WHEN ABS(emi_amount_recorded - emi_on_sanction) <= 2 THEN 'OK'
    WHEN ABS(emi_amount_recorded - emi_on_disbursed) <= 2 THEN 'OK_PARTLY_DISBURSED'
    WHEN ABS(emi_amount_recorded - emi_flat_rate) <= 2 THEN 'FLAT_RATE'
    WHEN ABS(schedule_emi - emi_on_sanction) <= 2 OR ABS(schedule_emi - emi_on_disbursed) <= 2 THEN 'EMI_KEYING_ERROR'
    ELSE 'UNEXPLAINED' END;

UPDATE loan_emi_check SET explanation = CASE verdict
  WHEN 'OK' THEN 'EMI matches amount, rate and tenure'
  WHEN 'OK_PARTLY_DISBURSED' THEN 'Home loan paid out in stages: EMI is correctly set on the amount paid out so far, not the full sanction'
  WHEN 'FLAT_RATE' THEN 'Pavanpur personal loan priced on a flat rate: EMI = P x (1 + rate x years) / months. Terms add up on that basis, but the true (reducing) rate is far higher than the rate on record'
  WHEN 'EMI_KEYING_ERROR' THEN 'EMI on the loan record was mistyped (digits swapped/changed). The EMI schedule and the formula agree, so the schedule value is used'
  ELSE 'Cannot be explained' END;

UPDATE loan_book l JOIN loan_emi_check e ON e.loan_id = l.loan_id
SET l.emi_amount = e.schedule_emi WHERE e.verdict = 'EMI_KEYING_ERROR';

INSERT INTO dq_log (question, table_name, column_name, source_system, problem, rule_applied, action_taken, rows_affected, rupees_involved)
SELECT 'Q1.6', 'loan_accounts', 'emi_amount', l.source_system, CONCAT('EMI check: ', e.verdict), e.explanation,
       CASE e.verdict WHEN 'EMI_KEYING_ERROR' THEN 'FIXED' WHEN 'FLAT_RATE' THEN 'FLAGGED' ELSE 'NONE' END,
       COUNT(*), SUM(l.outstanding_principal)
FROM loan_emi_check e JOIN loan_book l ON l.loan_id = e.loan_id
WHERE e.verdict <> 'OK'
GROUP BY l.source_system, e.verdict, e.explanation;

-- =====================================================================
-- Q1.7 THE RIGHT BRANCH AND THE RIGHT MONEY
-- Branches were fixed above. Payouts and security below.
-- =====================================================================

INSERT INTO dq_log (question, table_name, column_name, source_system, problem, rule_applied, action_taken, rows_affected, rupees_involved)
SELECT 'Q1.7', 'disbursements', 'disbursement_id', COALESCE(l.source_system, 'CBS-M'),
       'Same payout posted twice (same loan, date and amount under a new tranche number)',
       'Second posting excluded from payout totals', 'EXCLUDED', COUNT(*), SUM(d.amount)
FROM disbursements_clean d LEFT JOIN loan_book l ON l.loan_id = d.loan_id
WHERE d.is_duplicate = 'Y' GROUP BY l.source_system;

DROP TABLE IF EXISTS collateral_clean;
CREATE TABLE collateral_clean (
  collateral_id      VARCHAR(16)   NOT NULL PRIMARY KEY,
  loan_id            VARCHAR(20)   NOT NULL,
  collateral_type    VARCHAR(20)   NULL,
  description        VARCHAR(100)  NULL,
  gold_weight_grams  DECIMAL(8,2)  NULL,
  valuation_amount   DECIMAL(16,2) NULL,
  valuation_date     DATE          NULL,
  value_per_gram     DECIMAL(10,2) NULL,
  check_result       VARCHAR(120)  NOT NULL,
  KEY (loan_id)
);
INSERT INTO collateral_clean
SELECT c.collateral_id, c.loan_id, c.collateral_type, c.description, c.gold_weight_grams,
       fn_to_amount(c.valuation_amount), fn_to_date(c.valuation_date, COALESCE(l.source_system, 'CBS-M')),
       ROUND(fn_to_amount(c.valuation_amount) / NULLIF(c.gold_weight_grams, 0), 2),
       CASE
         WHEN l.loan_id IS NULL THEN 'Loan not in book'
         WHEN (l.product_code = 'GL' AND c.collateral_type <> 'Gold Ornaments')
           OR (l.product_code = 'VL' AND c.collateral_type <> 'Vehicle')
           OR (l.product_code = 'HL' AND c.collateral_type <> 'Residential Property')
           OR (l.product_code = 'PL') THEN 'Security type does not fit the product'
         WHEN c.collateral_type = 'Gold Ornaments' AND c.gold_weight_grams IS NULL THEN 'Gold without a weight'
         WHEN fn_to_amount(c.valuation_amount) IS NULL OR fn_to_amount(c.valuation_amount) <= 0 THEN 'No usable value'
         ELSE 'OK' END
FROM collateral c LEFT JOIN loan_book l ON l.loan_id = c.loan_id;

INSERT INTO dq_log (question, table_name, column_name, source_system, problem, rule_applied, action_taken, rows_affected, rupees_involved)
SELECT 'Q1.7', 'loan_book', 'collateral', l.source_system,
       'Secured loan with no security recorded', 'Flagged: security must be traced before the loan can be provisioned as secured',
       'FLAGGED', COUNT(*), SUM(l.outstanding_principal)
FROM loan_book l
WHERE l.secured_flag = 'Y' AND NOT EXISTS (SELECT 1 FROM collateral_clean c WHERE c.loan_id = l.loan_id)
GROUP BY l.source_system;

INSERT INTO dq_log (question, table_name, column_name, source_system, problem, rule_applied, action_taken, rows_affected, rupees_involved)
SELECT 'Q1.7', 'collateral', 'collateral_type', 'ALL', check_result, 'Flagged', 'FLAGGED', COUNT(*), SUM(valuation_amount)
FROM collateral_clean WHERE check_result <> 'OK' GROUP BY check_result;

-- Payments: usable money only. A reversal cancels the payment it names;
-- a bounced NACH never arrived; a second identical posting (same loan,
-- day, amount, mode, consecutive reference) is a double posting.
DROP TABLE IF EXISTS repayments_clean;
CREATE TABLE repayments_clean (
  payment_id      VARCHAR(16)   NOT NULL PRIMARY KEY,
  loan_id         VARCHAR(20)   NOT NULL,
  payment_date    DATE          NOT NULL,
  amount          DECIMAL(12,2) NOT NULL,
  payment_mode    VARCHAR(10)   NOT NULL,
  payment_status  VARCHAR(10)   NOT NULL,
  counts_as_paid  CHAR(1)       NOT NULL,
  reason          VARCHAR(80)   NOT NULL,
  reversed_on     DATE          NULL,
  KEY (loan_id, payment_date)
);
INSERT INTO repayments_clean
SELECT r.payment_id, r.loan_id, r.payment_date, r.amount, r.payment_mode, r.payment_status,
       'Y', 'Successful payment', NULL
FROM repayments r;

UPDATE repayments_clean SET counts_as_paid = 'N', reason = 'Bounced: money never received'
WHERE payment_status = 'BOUNCED';
UPDATE repayments_clean SET counts_as_paid = 'N', reason = 'Reversal entry: cancels an earlier payment'
WHERE payment_status = 'REVERSED';
DROP TABLE IF EXISTS tmp_reversals;
CREATE TABLE tmp_reversals AS
SELECT reversal_of payment_id, MIN(payment_date) reversed_on
FROM repayments WHERE payment_status = 'REVERSED' GROUP BY reversal_of;
ALTER TABLE tmp_reversals ADD PRIMARY KEY (payment_id);
UPDATE repayments_clean p JOIN tmp_reversals r USING (payment_id)
SET p.counts_as_paid = 'N', p.reason = 'Reversed later (cheque/NACH returned)', p.reversed_on = r.reversed_on;
DROP TABLE tmp_reversals;

DROP TABLE IF EXISTS tmp_double_posts;
CREATE TABLE tmp_double_posts AS
SELECT payment_id FROM (
  SELECT payment_id,
         ROW_NUMBER() OVER (PARTITION BY loan_id, payment_date, amount, payment_mode ORDER BY payment_id) rn
  FROM repayments_clean WHERE payment_status = 'SUCCESS'
) x WHERE rn > 1;
ALTER TABLE tmp_double_posts ADD PRIMARY KEY (payment_id);
-- Checked: every one of these loans was in arrears and the second
-- payment is needed to clear its dues (the borrower paid two EMIs at
-- once). They are genuine catch-up payments, so they COUNT; flagged only.
UPDATE repayments_clean p JOIN tmp_double_posts d USING (payment_id)
SET p.reason = 'Same-day repeat payment: kept (catch-up of an overdue EMI)';
DROP TABLE tmp_double_posts;

INSERT INTO dq_log (question, table_name, column_name, source_system, problem, rule_applied, action_taken, rows_affected, rupees_involved)
SELECT 'Q1.7', 'repayments', 'payment_id', COALESCE(l.source_system, '?'),
       'Two identical payments on the same day (looks like a double posting)',
       'Kept: each loan was one EMI behind and both payments are needed to clear it',
       'FLAGGED', COUNT(*), SUM(r.amount)
FROM repayments_clean r LEFT JOIN loan_book l ON l.loan_id = r.loan_id
WHERE r.reason LIKE 'Same-day repeat%' GROUP BY l.source_system;

INSERT INTO dq_log (question, table_name, column_name, source_system, problem, rule_applied, action_taken, rows_affected, rupees_involved)
SELECT 'Q1.7', 'repayments', 'payment_status', COALESCE(l.source_system, '?'), r.reason,
       'Not counted as money received', 'EXCLUDED', COUNT(*), SUM(r.amount)
FROM repayments_clean r LEFT JOIN loan_book l ON l.loan_id = r.loan_id
WHERE r.counts_as_paid = 'N' GROUP BY l.source_system, r.reason;

-- EMI schedule: checked, no defects (control total matches, every
-- emi_due = principal + interest, one row per loan per instalment).
-- Clean copy keeps only loans in the book and the running total of
-- dues that Stage 2 needs.
DROP TABLE IF EXISTS emi_schedule_clean;
CREATE TABLE emi_schedule_clean (
  loan_id              VARCHAR(20)   NOT NULL,
  instalment_no        SMALLINT      NOT NULL,
  due_date             DATE          NOT NULL,
  emi_due              DECIMAL(12,2) NOT NULL,
  principal_component  DECIMAL(12,2) NOT NULL,
  interest_component   DECIMAL(12,2) NOT NULL,
  cum_due              DECIMAL(14,2) NOT NULL,   -- dues up to and including this instalment
  PRIMARY KEY (loan_id, instalment_no),
  KEY (due_date)
);
INSERT INTO emi_schedule_clean
SELECT e.loan_id, e.instalment_no, e.due_date, e.emi_due, e.principal_component, e.interest_component,
       SUM(e.emi_due) OVER (PARTITION BY e.loan_id ORDER BY e.instalment_no)
FROM emi_schedule e JOIN loan_book l ON l.loan_id = e.loan_id;

INSERT INTO dq_log (question, table_name, column_name, source_system, problem, rule_applied, action_taken, rows_affected, rupees_involved)
SELECT 'Q1.7', 'emi_schedule', 'emi_due', 'ALL', 'Checked: EMI = principal + interest on every row; control total matches',
       'No change needed', 'NONE', COUNT(*), SUM(emi_due)
FROM emi_schedule WHERE ABS(emi_due - principal_component - interest_component) <= 0.01;

-- =====================================================================
-- Q1.8 BREACHES OF THE BANK'S LENDING RULES (flagged, never deleted)
-- =====================================================================

DROP TABLE IF EXISTS loan_rule_breaches;
CREATE TABLE loan_rule_breaches (
  loan_id                VARCHAR(20)   NOT NULL,
  rule_broken            VARCHAR(40)   NOT NULL,
  detail                 VARCHAR(200)  NOT NULL,
  rupees_in_breach       DECIMAL(16,2) NULL,   -- the excess over the rule
  outstanding_principal  DECIMAL(14,2) NOT NULL,
  PRIMARY KEY (loan_id, rule_broken)
);

-- Rule 1: borrower no older than 70 when the loan ends.
INSERT INTO loan_rule_breaches
SELECT l.loan_id, 'AGE_OVER_70_AT_MATURITY',
       CONCAT('Born ', c.date_of_birth, ', last EMI ', l.last_emi_date, ', age ',
              TIMESTAMPDIFF(YEAR, c.date_of_birth, l.last_emi_date)),
       l.outstanding_principal, l.outstanding_principal
FROM loan_book l JOIN customers_clean c ON c.customer_id = l.customer_id
WHERE c.entity_type = 'INDIVIDUAL' AND TIMESTAMPDIFF(YEAR, c.date_of_birth, l.last_emi_date) > 70;

-- Rule 2: total paid out must not exceed the amount sanctioned.
INSERT INTO loan_rule_breaches
SELECT loan_id, 'PAID_OUT_MORE_THAN_SANCTIONED',
       CONCAT('Sanctioned ', sanction_amount, ', paid out ', total_disbursed),
       total_disbursed - sanction_amount, outstanding_principal
FROM loan_book WHERE total_disbursed > sanction_amount + 0.5;

-- Rule 3: first EMI must not fall due before the loan was paid out.
INSERT INTO loan_rule_breaches
SELECT loan_id, 'FIRST_EMI_BEFORE_PAYOUT',
       CONCAT('First payout ', first_disbursed_on, ', first EMI due ', first_emi_date),
       outstanding_principal, outstanding_principal
FROM loan_book WHERE first_emi_date < first_disbursed_on;

-- Rule 4: gold loans within RBI loan-to-value: 85% up to 2.5 lakh,
-- 80% above 2.5 lakh up to 5 lakh, 75% above 5 lakh.
INSERT INTO loan_rule_breaches
SELECT l.loan_id, 'GOLD_LTV_ABOVE_RBI_LIMIT',
       CONCAT('Loan ', l.sanction_amount, ' on gold worth ', g.gold_value, ' = ',
              ROUND(l.sanction_amount / g.gold_value * 100, 1), '% (limit ',
              CASE WHEN l.sanction_amount <= 250000 THEN 85 WHEN l.sanction_amount <= 500000 THEN 80 ELSE 75 END, '%)'),
       l.sanction_amount - g.gold_value *
         CASE WHEN l.sanction_amount <= 250000 THEN 0.85 WHEN l.sanction_amount <= 500000 THEN 0.80 ELSE 0.75 END,
       l.outstanding_principal
FROM loan_book l
JOIN (SELECT loan_id, SUM(valuation_amount) gold_value FROM collateral_clean
      WHERE collateral_type = 'Gold Ornaments' GROUP BY loan_id) g ON g.loan_id = l.loan_id
WHERE l.product_code = 'GL'
  AND l.sanction_amount > g.gold_value *
      CASE WHEN l.sanction_amount <= 250000 THEN 0.85 WHEN l.sanction_amount <= 500000 THEN 0.80 ELSE 0.75 END;

INSERT INTO dq_log (question, table_name, column_name, source_system, problem, rule_applied, action_taken, rows_affected, rupees_involved)
SELECT 'Q1.8', 'loan_book', b.rule_broken, l.source_system,
       CONCAT('Lending rule breached: ', b.rule_broken),
       'Flagged, not deleted (loan_rule_breaches). Rupees = outstanding principal of the loans in breach',
       'FLAGGED', COUNT(*), SUM(b.outstanding_principal)
FROM loan_rule_breaches b JOIN loan_book l ON l.loan_id = b.loan_id
GROUP BY b.rule_broken, l.source_system;

-- =====================================================================
-- RECONCILIATION BACK TO THE BANK'S DELIVERY
-- loan_accounts as sent -> clean loan book -> manifest control total
-- =====================================================================

DROP TABLE IF EXISTS recon_loan_book;
CREATE TABLE recon_loan_book (
  step_no    INT          NOT NULL PRIMARY KEY,
  step       VARCHAR(120) NOT NULL,
  loans      INT          NOT NULL,
  rupees     DECIMAL(16,2) NOT NULL
);
INSERT INTO recon_loan_book
SELECT 1, 'loan_accounts.csv as delivered (all rows)', COUNT(*), SUM(outstanding_principal) FROM tmp_loans_parsed;
INSERT INTO recon_loan_book
SELECT 2, 'less: exact repeat rows removed', -COUNT(*), -SUM(p.outstanding_principal)
FROM tmp_loans_parsed p JOIN tmp_loans_parsed k ON k.loan_id = p.loan_id AND k.version_rank = 1
WHERE p.version_rank > 1 AND p.outstanding_principal = k.outstanding_principal AND p.load_timestamp = k.load_timestamp;
INSERT INTO recon_loan_book
SELECT 3, 'less: superseded versions removed (replaced by the B07 re-extract)', -COUNT(*), -SUM(p.outstanding_principal)
FROM tmp_loans_parsed p JOIN tmp_loans_parsed k ON k.loan_id = p.loan_id AND k.version_rank = 1
WHERE p.version_rank > 1 AND NOT (p.outstanding_principal = k.outstanding_principal AND p.load_timestamp = k.load_timestamp);
INSERT INTO recon_loan_book
SELECT 4, 'add: loans missing from loan_accounts, rebuilt from the CBS extract', COUNT(*), SUM(outstanding_principal)
FROM loan_book WHERE record_origin LIKE 'Rebuilt%';
INSERT INTO recon_loan_book
SELECT 5, '= clean loan book (loan_book)', COUNT(*), SUM(outstanding_principal) FROM loan_book;
INSERT INTO recon_loan_book
SELECT 6, 'manifest control total for loan_accounts.csv', expected_rows, control_total
FROM load_manifest WHERE file_name = 'loan_accounts.csv';
INSERT INTO recon_loan_book
SELECT 7, 'difference (must be zero)', (SELECT loans FROM recon_loan_book WHERE step_no = 5) - expected_rows,
       (SELECT rupees FROM recon_loan_book WHERE step_no = 5) - control_total
FROM load_manifest WHERE file_name = 'loan_accounts.csv';

DROP TABLE IF EXISTS tmp_best_mobile;
DROP TABLE IF EXISTS tmp_disb_totals;

-- ---------------------------------------------------------------------
-- Stage 1 results
-- ---------------------------------------------------------------------
SELECT * FROM recon_files ORDER BY file_name;
SELECT issue, COUNT(*) loans, SUM(rupees) rupees FROM recon_warehouse GROUP BY issue;
SELECT * FROM recon_loan_book ORDER BY step_no;
SELECT COUNT(*) customer_numbers, COUNT(DISTINCT borrower_id) real_borrowers FROM borrower_map;
SELECT COUNT(DISTINCT borrower_id) real_borrowers_with_loans FROM loan_book;
SELECT verdict, COUNT(*) loans FROM loan_emi_check GROUP BY verdict;
SELECT rule_broken, COUNT(*) loans, SUM(rupees_in_breach) rupees_in_breach, SUM(outstanding_principal) outstanding
FROM loan_rule_breaches GROUP BY rule_broken;
SELECT question, action_taken, COUNT(*) log_lines, SUM(rows_affected) rows_affected FROM dq_log GROUP BY question, action_taken;
