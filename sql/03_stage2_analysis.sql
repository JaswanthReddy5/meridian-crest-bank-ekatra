-- =====================================================================
-- Meridian Crest Bank · Hubballi Zone · Project Ekatra
-- STAGE 2 · How bad is the loan book, really?
--
-- Uses only the clean Stage 1 tables (loan_book, borrower_map,
-- repayments_clean, emi_schedule_clean, customers_clean, collateral_clean,
-- loan_rule_breaches) plus reference data (branches, regions, products,
-- officers) and the two department lists we must reconcile to.
-- Every table starting r_ is exported to results/*.csv for Stage 3.
-- =====================================================================

USE meridian_crest_bank;
SET NAMES utf8mb4;
SET SQL_SAFE_UPDATES = 0;
SET SESSION sql_mode = REPLACE(@@SESSION.sql_mode, 'ONLY_FULL_GROUP_BY', '');

-- ---------------------------------------------------------------------
-- RBI categories by days past due (same bands as rbi_norms_reference)
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_category;
DELIMITER $$
CREATE FUNCTION fn_category(dpd INT) RETURNS VARCHAR(10)
DETERMINISTIC NO SQL
BEGIN
  RETURN CASE WHEN dpd <= 0 THEN 'Standard' WHEN dpd <= 30 THEN 'SMA-0'
              WHEN dpd <= 60 THEN 'SMA-1' WHEN dpd <= 90 THEN 'SMA-2' ELSE 'NPA' END;
END$$
DELIMITER ;

-- =====================================================================
-- Q2.1 HOW LATE IS EVERY LOAN, REALLY? (30 Sep and 31 Oct 2026)
--
-- Rules (context document, "Banking in five minutes"):
--  * DPD = age in days of the oldest amount still unpaid; the due date
--    itself counts as day 1 (unpaid at end of 5 Sep -> 31 Oct = 57 days).
--  * Money received pays the oldest dues first; a part payment does not
--    stop the clock.
-- Payments counted: SUCCESS payments received on or before the date.
-- Payments left out, and why:
--  * BOUNCED NACH: the debit failed, no money arrived.
--  * A payment later REVERSED (cheque/NACH returned) and the reversal
--    entry itself: the money never stayed with the bank.
--  * Payments after the as-of date.
-- A shortfall of up to Rs 1 is treated as paid (paise rounding).
-- =====================================================================

DROP TABLE IF EXISTS s2_dates;
CREATE TABLE s2_dates (as_of_date DATE PRIMARY KEY);
INSERT INTO s2_dates VALUES ('2026-09-30'), ('2026-10-31');

DROP TABLE IF EXISTS s2_paid_asof;
CREATE TABLE s2_paid_asof AS
SELECT d.as_of_date, r.loan_id, SUM(r.amount) paid_to_date
FROM s2_dates d JOIN repayments_clean r ON r.payment_date <= d.as_of_date AND r.counts_as_paid = 'Y'
GROUP BY d.as_of_date, r.loan_id;
ALTER TABLE s2_paid_asof ADD PRIMARY KEY (loan_id, as_of_date);

DROP TABLE IF EXISTS s2_loan_dpd;
CREATE TABLE s2_loan_dpd (
  loan_id             VARCHAR(20)   NOT NULL,
  as_of_date          DATE          NOT NULL,
  borrower_id         VARCHAR(15)   NOT NULL,
  dues_to_date        DECIMAL(14,2) NOT NULL,
  paid_to_date        DECIMAL(14,2) NOT NULL,
  overdue_amount      DECIMAL(14,2) NOT NULL,
  oldest_unpaid_due   DATE          NULL,
  dpd                 INT           NOT NULL,
  loan_category       VARCHAR(10)   NOT NULL,   -- on the loan's own DPD
  final_category      VARCHAR(10)   NULL,       -- after the borrower rule
  npa_by_borrower_rule CHAR(1)      NULL,       -- Y = NPA only because another loan of the borrower is NPA
  PRIMARY KEY (loan_id, as_of_date),
  KEY (borrower_id, as_of_date)
);

-- A loan is on the 30 Sep book only if it had been paid out by then.
INSERT INTO s2_loan_dpd (loan_id, as_of_date, borrower_id, dues_to_date, paid_to_date, overdue_amount,
                         oldest_unpaid_due, dpd, loan_category)
SELECT l.loan_id, d.as_of_date, l.borrower_id,
       COALESCE(MAX(e.cum_due), 0),
       COALESCE(p.paid_to_date, 0),
       GREATEST(COALESCE(MAX(e.cum_due), 0) - COALESCE(p.paid_to_date, 0), 0),
       MIN(CASE WHEN e.cum_due > COALESCE(p.paid_to_date, 0) + 1 THEN e.due_date END),
       COALESCE(DATEDIFF(d.as_of_date, MIN(CASE WHEN e.cum_due > COALESCE(p.paid_to_date, 0) + 1 THEN e.due_date END)) + 1, 0),
       'TBD'
FROM loan_book l
JOIN s2_dates d ON l.first_disbursed_on <= d.as_of_date
LEFT JOIN emi_schedule_clean e ON e.loan_id = l.loan_id AND e.due_date <= d.as_of_date
LEFT JOIN s2_paid_asof p ON p.loan_id = l.loan_id AND p.as_of_date = d.as_of_date
GROUP BY l.loan_id, d.as_of_date, l.borrower_id, p.paid_to_date;

UPDATE s2_loan_dpd SET loan_category = fn_category(dpd);

-- Borrower rule (RBI Master Circular 4.2.7): if any loan of a real
-- borrower (Stage 1 identity) is NPA, every loan of that borrower is NPA.
DROP TABLE IF EXISTS tmp_npa_borrowers;
CREATE TABLE tmp_npa_borrowers AS
SELECT DISTINCT borrower_id, as_of_date FROM s2_loan_dpd WHERE loan_category = 'NPA';
ALTER TABLE tmp_npa_borrowers ADD PRIMARY KEY (borrower_id, as_of_date);

UPDATE s2_loan_dpd s
LEFT JOIN tmp_npa_borrowers b ON b.borrower_id = s.borrower_id AND b.as_of_date = s.as_of_date
SET s.final_category = IF(b.borrower_id IS NOT NULL, 'NPA', s.loan_category),
    s.npa_by_borrower_rule = IF(b.borrower_id IS NOT NULL AND s.loan_category <> 'NPA', 'Y', 'N');
DROP TABLE tmp_npa_borrowers;

-- Deliverable 2.1: DPD and category for every loan on both dates.
DROP TABLE IF EXISTS r_loan_dpd;
CREATE TABLE r_loan_dpd AS
SELECT l.loan_id, l.borrower_id, l.branch_ifsc, l.product_code, l.outstanding_principal outstanding_31oct,
       s.dpd dpd_30sep, s.loan_category loan_category_30sep, s.final_category category_30sep,
       o.dpd dpd_31oct, o.loan_category loan_category_31oct, o.final_category category_31oct,
       o.npa_by_borrower_rule npa_by_borrower_rule_31oct, o.overdue_amount overdue_31oct, o.oldest_unpaid_due oldest_unpaid_due_31oct
FROM loan_book l
JOIN s2_loan_dpd o ON o.loan_id = l.loan_id AND o.as_of_date = '2026-10-31'
LEFT JOIN s2_loan_dpd s ON s.loan_id = l.loan_id AND s.as_of_date = '2026-09-30';
ALTER TABLE r_loan_dpd ADD PRIMARY KEY (loan_id);

-- =====================================================================
-- Q2.2 WHICH NUMBER IS RIGHT?
-- Gross NPA ratio = rupees outstanding in NPA loans / all rupees outstanding
-- (31 Oct balances, the same balances Finance and Risk used).
-- =====================================================================

DROP TABLE IF EXISTS s2_compare;
CREATE TABLE s2_compare AS
SELECT l.loan_id, l.source_system, l.customer_id, l.borrower_id, l.outstanding_principal os,
       d.dpd true_dpd, d.loan_category true_loan_cat, d.final_category true_cat, d.npa_by_borrower_rule,
       f.asset_class fin_class, r.asset_class risk_class, r.dpd risk_dpd,
       (f.asset_class = 'NPA') fin_npa, (r.asset_class = 'NPA') risk_npa, (d.final_category = 'NPA') true_npa,
       -- does this loan's borrower rule rest on a Pavanpur <-> Meridian link?
       EXISTS (SELECT 1 FROM s2_loan_dpd x WHERE x.borrower_id = l.borrower_id AND x.as_of_date = '2026-10-31'
               AND x.loan_category = 'NPA'
               AND x.loan_id IN (SELECT loan_id FROM loan_book WHERE customer_id = l.customer_id)) same_customer_npa,
       -- did the loan bounce NACH and get paid by another route afterwards?
       EXISTS (SELECT 1 FROM repayments_clean b WHERE b.loan_id = l.loan_id AND b.payment_status = 'BOUNCED'
               AND b.payment_date <= '2026-10-31') had_bounce,
       m.match_basis vendor_link_basis
FROM loan_book l
JOIN s2_loan_dpd d ON d.loan_id = l.loan_id AND d.as_of_date = '2026-10-31'
JOIN finance_npa_oct2026 f ON f.loan_id = l.loan_id
JOIN risk_npa_oct2026 r ON r.loan_id = l.loan_id
LEFT JOIN legacy_id_map m ON l.customer_id IN (m.pavanpur_customer_id, m.meridian_customer_id);
ALTER TABLE s2_compare ADD PRIMARY KEY (loan_id);

-- Each loan that a department classifies differently from the truth gets
-- exactly one cause, so the steps add up to the rupee.
ALTER TABLE s2_compare ADD COLUMN fin_cause VARCHAR(120) NULL, ADD COLUMN risk_cause VARCHAR(120) NULL;

UPDATE s2_compare SET fin_cause = CASE
  WHEN fin_npa AND NOT true_npa THEN
    'F1 CBS flag still NPA after the borrower cleared arrears (flag not upgraded)'
  WHEN true_npa AND NOT fin_npa AND true_dpd > 90 AND source_system = 'CBS-P' THEN
    'F2 Over 90 DPD but CBS flag says STD: migrated Pavanpur loans (arrears history lost in migration)'
  WHEN true_npa AND NOT fin_npa AND true_dpd > 90 THEN
    'F3 Over 90 DPD but CBS flag says STD: Meridian loans (flag not refreshed)'
  WHEN true_npa AND NOT fin_npa AND same_customer_npa THEN
    'F4 Borrower rule: another loan of the same customer is NPA (Finance classifies loan by loan)'
  WHEN true_npa AND NOT fin_npa THEN
    'F5 Borrower rule across the merger: same person''s Pavanpur/Meridian loan is NPA'
  END;

UPDATE s2_compare SET risk_cause = CASE
  WHEN risk_npa AND NOT true_npa AND risk_dpd > 90 THEN
    'R1 Risk counts a bounced auto-debit as missed even when the EMI was paid days later by cash/UPI/NEFT'
  WHEN risk_npa AND NOT true_npa AND vendor_link_basis = 'NAME' THEN
    'R2 Risk spread NPA through the vendor''s false name-only matches (different people)'
  WHEN risk_npa AND NOT true_npa THEN
    'R3 Risk spread NPA to a borrower whose other loan is not truly NPA'
  WHEN true_npa AND NOT risk_npa AND true_dpd > 90 AND risk_dpd = true_dpd - 1 THEN
    'R4 Risk starts the count a day late: 90 DPD (SMA-2) instead of 91 (NPA)'
  WHEN true_npa AND NOT risk_npa AND true_dpd > 90 THEN
    'R5 Over 90 DPD on true payments but not in Risk''s list'
  WHEN true_npa AND NOT risk_npa THEN
    'R6 Borrower rule: link found in Stage 1 that the vendor map missed (Risk only uses the vendor map)'
  END;

-- Headline: the true figure, Finance and Risk, on the same book.
DROP TABLE IF EXISTS r_headline;
CREATE TABLE r_headline (
  measure     VARCHAR(80)   NOT NULL PRIMARY KEY,
  loans       INT           NULL,
  rupees      DECIMAL(16,2) NULL,
  ratio_pct   DECIMAL(8,3)  NULL
);
INSERT INTO r_headline
SELECT 'Total book 31 Oct 2026', COUNT(*), SUM(os), NULL FROM s2_compare;
INSERT INTO r_headline
SELECT 'Finance gross NPA (as reported)', SUM(fin_npa), SUM(IF(fin_npa, os, 0)), SUM(IF(fin_npa, os, 0)) / SUM(os) * 100 FROM s2_compare;
INSERT INTO r_headline
SELECT 'Risk gross NPA (as reported)', SUM(risk_npa), SUM(IF(risk_npa, os, 0)), SUM(IF(risk_npa, os, 0)) / SUM(os) * 100 FROM s2_compare;
INSERT INTO r_headline
SELECT 'TRUE gross NPA (borrower rule, verified payments)', SUM(true_npa), SUM(IF(true_npa, os, 0)), SUM(IF(true_npa, os, 0)) / SUM(os) * 100 FROM s2_compare;
INSERT INTO r_headline
SELECT 'True NPA before borrower rule (loan by loan)', SUM(true_dpd > 90), SUM(IF(true_dpd > 90, os, 0)), SUM(IF(true_dpd > 90, os, 0)) / SUM(os) * 100 FROM s2_compare;
INSERT INTO r_headline
SELECT 'Gap: counted bad by one department but not the other', SUM(fin_npa <> risk_npa), SUM(IF(fin_npa <> risk_npa, os, 0)), NULL FROM s2_compare;
INSERT INTO r_headline
SELECT CONCAT('True ', final_category, ' 31 Oct'), COUNT(*), SUM(l.outstanding_principal),
       SUM(l.outstanding_principal) / (SELECT SUM(outstanding_principal) FROM loan_book) * 100
FROM s2_loan_dpd d JOIN loan_book l USING (loan_id) WHERE d.as_of_date = '2026-10-31' GROUP BY final_category;
INSERT INTO r_headline
SELECT CONCAT('True ', final_category, ' 30 Sep'), COUNT(*), SUM(l.outstanding_principal),
       SUM(l.outstanding_principal) / (SELECT SUM(l2.outstanding_principal) FROM s2_loan_dpd d2 JOIN loan_book l2 USING (loan_id) WHERE d2.as_of_date = '2026-09-30') * 100
FROM s2_loan_dpd d JOIN loan_book l USING (loan_id) WHERE d.as_of_date = '2026-09-30' GROUP BY final_category;

-- One bridge: Finance 3.1% -> every correction -> TRUE -> Risk 4.4%.
-- The steps after TRUE are Risk's errors, signed as they move from TRUE
-- to Risk's figure.
DROP TABLE IF EXISTS r_npa_bridge;
CREATE TABLE r_npa_bridge (
  step_no      INT           NOT NULL PRIMARY KEY,
  step         VARCHAR(140)  NOT NULL,
  step_type    VARCHAR(10)   NOT NULL,   -- START, ADD, REMOVE, TOTAL
  loans        INT           NOT NULL,
  rupees       DECIMAL(16,2) NOT NULL,
  running_npa  DECIMAL(16,2) NULL,
  running_pct  DECIMAL(8,3)  NULL
);
SET @book := (SELECT SUM(os) FROM s2_compare);

INSERT INTO r_npa_bridge (step_no, step, step_type, loans, rupees)
SELECT 1, 'Finance: gross NPA as reported (CBS asset-class flag)', 'START', SUM(fin_npa), SUM(IF(fin_npa, os, 0)) FROM s2_compare;
INSERT INTO r_npa_bridge (step_no, step, step_type, loans, rupees)
SELECT 1 + CAST(SUBSTRING(fin_cause, 2, 1) AS UNSIGNED), SUBSTRING(fin_cause, 4),
       IF(fin_npa, 'REMOVE', 'ADD'), COUNT(*), SUM(IF(fin_npa, -os, os))
FROM s2_compare WHERE fin_cause IS NOT NULL GROUP BY fin_cause, fin_npa;
INSERT INTO r_npa_bridge (step_no, step, step_type, loans, rupees)
SELECT 10, 'TRUE gross NPA', 'TOTAL', SUM(true_npa), SUM(IF(true_npa, os, 0)) FROM s2_compare;
-- Risk's errors, read from TRUE towards Risk: loans Risk wrongly counts
-- are added, loans Risk misses are removed.
INSERT INTO r_npa_bridge (step_no, step, step_type, loans, rupees)
SELECT 10 + CAST(SUBSTRING(risk_cause, 2, 1) AS UNSIGNED), SUBSTRING(risk_cause, 4),
       IF(risk_npa, 'ADD', 'REMOVE'), COUNT(*), SUM(IF(risk_npa, os, -os))
FROM s2_compare WHERE risk_cause IS NOT NULL GROUP BY risk_cause, risk_npa;
INSERT INTO r_npa_bridge (step_no, step, step_type, loans, rupees)
SELECT 20, 'Risk: gross NPA as reported', 'TOTAL', SUM(risk_npa), SUM(IF(risk_npa, os, 0)) FROM s2_compare;

-- Running total: START/TOTAL rows hold their own level; ADD/REMOVE
-- rows add to the level above them.
SET @run := 0;
UPDATE r_npa_bridge SET running_npa = (@run := IF(step_type IN ('START', 'TOTAL'), rupees, @run + rupees))
ORDER BY step_no;
UPDATE r_npa_bridge SET running_pct = running_npa / @book * 100;

-- Proof that the bridge closes: level before each TOTAL equals the TOTAL.
DROP TABLE IF EXISTS r_bridge_check;
CREATE TABLE r_bridge_check AS
SELECT 'Finance + corrections = TRUE' check_name,
       (SELECT rupees FROM r_npa_bridge WHERE step_no = 1) + (SELECT COALESCE(SUM(rupees), 0) FROM r_npa_bridge WHERE step_no BETWEEN 2 AND 9)
       - (SELECT rupees FROM r_npa_bridge WHERE step_no = 10) difference
UNION ALL
SELECT 'TRUE + Risk errors = Risk',
       (SELECT rupees FROM r_npa_bridge WHERE step_no = 10) + (SELECT COALESCE(SUM(rupees), 0) FROM r_npa_bridge WHERE step_no BETWEEN 11 AND 19)
       - (SELECT rupees FROM r_npa_bridge WHERE step_no = 20);

-- Loan-by-loan reconciliation list (every loan where a department is wrong).
DROP TABLE IF EXISTS r_npa_reconciliation_loans;
CREATE TABLE r_npa_reconciliation_loans AS
SELECT loan_id, source_system, customer_id, borrower_id, os outstanding_principal, true_dpd, true_cat,
       fin_class, fin_cause, risk_class, risk_dpd, risk_cause
FROM s2_compare WHERE fin_cause IS NOT NULL OR risk_cause IS NOT NULL;

-- =====================================================================
-- Q2.3 IS THE BANK LENDING ITSELF INTO TROUBLE?
-- =====================================================================

-- Movement of the book between 30 Sep and 31 Oct (balances at 31 Oct;
-- 30 Sep balances were not delivered).
DROP TABLE IF EXISTS r_movement_matrix;
CREATE TABLE r_movement_matrix AS
SELECT COALESCE(s.final_category, 'New in October') category_30sep, o.final_category category_31oct,
       COUNT(*) loans, SUM(l.outstanding_principal) outstanding_31oct
FROM s2_loan_dpd o JOIN loan_book l ON l.loan_id = o.loan_id
LEFT JOIN s2_loan_dpd s ON s.loan_id = o.loan_id AND s.as_of_date = '2026-09-30'
WHERE o.as_of_date = '2026-10-31'
GROUP BY 1, 2;

-- Where the leak into NPA comes from: loans that became NPA in October.
DROP TABLE IF EXISTS r_new_npa_october;
CREATE TABLE r_new_npa_october AS
SELECT l.loan_id, l.branch_ifsc, b.branch_name, l.region_id, l.product_code, l.source_system, l.sourcing_channel,
       s.final_category category_30sep, s.dpd dpd_30sep, o.dpd dpd_31oct, o.npa_by_borrower_rule,
       l.outstanding_principal
FROM s2_loan_dpd o JOIN loan_book l ON l.loan_id = o.loan_id
JOIN s2_loan_dpd s ON s.loan_id = o.loan_id AND s.as_of_date = '2026-09-30'
JOIN branches b ON b.ifsc = l.branch_ifsc
WHERE o.as_of_date = '2026-10-31' AND o.final_category = 'NPA' AND s.final_category <> 'NPA';

-- Months on book at 31 Oct, the flags the two claims are about, and a
-- performance measure that is fair to young loans: is the loan 30+ days
-- late, compared only with loans of the same product sanctioned in the
-- same month (same age).
DROP TABLE IF EXISTS s2_perf;
CREATE TABLE s2_perf AS
SELECT l.loan_id, l.product_code, l.source_system, l.sourcing_channel, l.branch_ifsc, l.sanctioning_officer_id,
       DATE_FORMAT(l.sanction_date, '%Y-%m') sanction_month,
       PERIOD_DIFF(202610, EXTRACT(YEAR_MONTH FROM l.first_emi_date)) + 1 emis_due_by_31oct,
       (DAY(LAST_DAY(l.sanction_date)) - DAY(l.sanction_date)) < 3 month_end_flag,
       (l.sourcing_channel = 'Digital Partner') digital_flag,
       (d.dpd > 30) late30, (d.final_category = 'NPA') npa, l.outstanding_principal os
FROM loan_book l JOIN s2_loan_dpd d ON d.loan_id = l.loan_id AND d.as_of_date = '2026-10-31';
ALTER TABLE s2_perf ADD PRIMARY KEY (loan_id);

-- Claim tests. Each test group is compared with the control loans of the
-- same product and the same sanction month, so age and product mix
-- cannot explain the difference. Expected = what the test group would
-- show at the control loans' rate in each cohort. z = (O - E) / sqrt(V).
DROP TABLE IF EXISTS r_claim_tests;
CREATE TABLE r_claim_tests (
  claim            VARCHAR(80)  NOT NULL,
  scope            VARCHAR(120) NOT NULL,
  test_loans       INT, test_late30 INT, test_rate_pct DECIMAL(6,2),
  control_loans    INT, control_late30 INT, control_rate_pct DECIMAL(6,2),
  expected_late30  DECIMAL(10,2), observed_to_expected DECIMAL(6,2), z_score DECIMAL(6,2),
  verdict          VARCHAR(200)
);

-- Claim 1: loans sanctioned in the last 3 days of a month are as good.
INSERT INTO r_claim_tests (claim, scope, test_loans, test_late30, control_loans, control_late30, expected_late30, z_score)
SELECT 'Month-end loans (sanctioned in last 3 days of month) are as good as others',
       'All loans; compared within product x sanction month',
       SUM(nt), SUM(bt), SUM(nc), SUM(bc), SUM(nt * pc), (SUM(bt) - SUM(nt * pc)) / SQRT(SUM(nt * pc * (1 - pc)))
FROM (
  SELECT product_code, sanction_month,
         SUM(month_end_flag) nt, SUM(month_end_flag * late30) bt,
         SUM(1 - month_end_flag) nc, SUM((1 - month_end_flag) * late30) bc,
         SUM((1 - month_end_flag) * late30) / SUM(1 - month_end_flag) pc
  FROM s2_perf GROUP BY product_code, sanction_month
  HAVING SUM(month_end_flag) > 0 AND SUM(1 - month_end_flag) > 0
) c;

-- Claim 2: digital-partner loans are as good as branch loans. Only
-- personal loans booked in CBS-M from June 2025 are digital, so compare
-- with branch personal loans of the same sanction month.
INSERT INTO r_claim_tests (claim, scope, test_loans, test_late30, control_loans, control_late30, expected_late30, z_score)
SELECT 'Digital-partner loans are as good as branch loans',
       'Personal loans, CBS-M, sanctioned Jun 2025 - Sep 2026; compared within sanction month',
       SUM(nt), SUM(bt), SUM(nc), SUM(bc), SUM(nt * pc), (SUM(bt) - SUM(nt * pc)) / SQRT(SUM(nt * pc * (1 - pc)))
FROM (
  SELECT sanction_month,
         SUM(digital_flag) nt, SUM(digital_flag * late30) bt,
         SUM(1 - digital_flag) nc, SUM((1 - digital_flag) * late30) bc,
         SUM((1 - digital_flag) * late30) / SUM(1 - digital_flag) pc
  FROM s2_perf WHERE product_code = 'PL' AND source_system = 'CBS-M' AND sourcing_channel IS NOT NULL
  GROUP BY sanction_month HAVING SUM(digital_flag) > 0 AND SUM(1 - digital_flag) > 0
) c;

-- The raw comparison the branches quote (no age control), for contrast.
INSERT INTO r_claim_tests (claim, scope, test_loans, test_late30, control_loans, control_late30)
SELECT 'Digital-partner loans are as good as branch loans', 'RAW: all personal loans, no age control (misleading)',
       SUM(digital_flag), SUM(digital_flag * late30), SUM(1 - digital_flag), SUM((1 - digital_flag) * late30)
FROM s2_perf WHERE product_code = 'PL' AND sourcing_channel IS NOT NULL;
INSERT INTO r_claim_tests (claim, scope, test_loans, test_late30, control_loans, control_late30)
SELECT 'Month-end loans (sanctioned in last 3 days of month) are as good as others', 'RAW: all loans, no control',
       SUM(month_end_flag), SUM(month_end_flag * late30), SUM(1 - month_end_flag), SUM((1 - month_end_flag) * late30)
FROM s2_perf;

UPDATE r_claim_tests SET
  test_rate_pct = test_late30 / test_loans * 100,
  control_rate_pct = control_late30 / control_loans * 100,
  observed_to_expected = test_late30 / NULLIF(expected_late30, 0);
UPDATE r_claim_tests SET verdict = CASE
  WHEN z_score IS NULL THEN 'Context only'
  WHEN z_score >= 2.58 THEN CONCAT('Claim REJECTED: ', ROUND((observed_to_expected - 1) * 100), '% more loans 30+ days late than same-age loans (z = ', z_score, ', over 99% confident)')
  WHEN z_score >= 1.96 THEN CONCAT('Claim REJECTED at 95%: ', ROUND((observed_to_expected - 1) * 100), '% worse (z = ', z_score, ')')
  WHEN z_score <= -1.96 THEN CONCAT('Better than same-age loans (z = ', z_score, ')')
  ELSE CONCAT('Claim stands: no significant difference (z = ', z_score, ')') END;

-- Same comparison month by month of age, for the chart in Stage 3.
DROP TABLE IF EXISTS r_claim_cohorts;
CREATE TABLE r_claim_cohorts AS
SELECT 'Digital vs branch (PL, CBS-M)' test, sanction_month,
       SUM(digital_flag) test_loans, ROUND(AVG(IF(digital_flag, late30, NULL)) * 100, 2) test_late30_pct,
       SUM(1 - digital_flag) control_loans, ROUND(AVG(IF(digital_flag, NULL, late30)) * 100, 2) control_late30_pct
FROM s2_perf WHERE product_code = 'PL' AND source_system = 'CBS-M' AND sanction_month >= '2025-06' AND sourcing_channel IS NOT NULL
GROUP BY sanction_month
UNION ALL
SELECT 'Month-end vs rest (all loans)', sanction_month,
       SUM(month_end_flag), ROUND(AVG(IF(month_end_flag, late30, NULL)) * 100, 2),
       SUM(1 - month_end_flag), ROUND(AVG(IF(month_end_flag, NULL, late30)) * 100, 2)
FROM s2_perf GROUP BY sanction_month;

-- How loans behave as they age: share 30+ days late and NPA by number of
-- EMIs that have fallen due.
DROP TABLE IF EXISTS r_vintage;
CREATE TABLE r_vintage AS
SELECT product_code,
       CASE WHEN emis_due_by_31oct <= 3 THEN '01-03' WHEN emis_due_by_31oct <= 6 THEN '04-06'
            WHEN emis_due_by_31oct <= 12 THEN '07-12' WHEN emis_due_by_31oct <= 18 THEN '13-18'
            WHEN emis_due_by_31oct <= 24 THEN '19-24' ELSE '25+' END emis_due_band,
       IF(digital_flag, 'Digital Partner', 'Branch') channel,
       IF(month_end_flag, 'Month-end', 'Other days') sanction_timing,
       source_system,
       COUNT(*) loans, SUM(late30) late30_loans, SUM(npa) npa_loans, SUM(os) outstanding,
       SUM(IF(npa, os, 0)) npa_outstanding
FROM s2_perf GROUP BY 1, 2, 3, 4, 5;

-- =====================================================================
-- Q2.4 WHO SHOULD THE COMMITTEE WORRY ABOUT?
-- =====================================================================

-- Collection efficiency, May - Oct 2026: amount collected against
-- instalments due in the month / amount due in the month. Money is
-- applied to the oldest dues first, so a payment that only clears old
-- arrears does not count as collecting this month's instalment.
DROP TABLE IF EXISTS s2_months;
CREATE TABLE s2_months (month_end DATE PRIMARY KEY);
INSERT INTO s2_months VALUES ('2026-05-31'), ('2026-06-30'), ('2026-07-31'), ('2026-08-31'), ('2026-09-30'), ('2026-10-31');

DROP TABLE IF EXISTS s2_paid_month_end;
CREATE TABLE s2_paid_month_end AS
SELECT m.month_end, r.loan_id, SUM(r.amount) paid
FROM s2_months m JOIN repayments_clean r ON r.payment_date <= m.month_end AND r.counts_as_paid = 'Y'
GROUP BY m.month_end, r.loan_id;
ALTER TABLE s2_paid_month_end ADD PRIMARY KEY (loan_id, month_end);

DROP TABLE IF EXISTS r_collection_efficiency;
CREATE TABLE r_collection_efficiency AS
SELECT l.branch_ifsc, DATE_FORMAT(m.month_end, '%Y-%m') month,
       SUM(e.emi_due) amount_due,
       SUM(LEAST(GREATEST(COALESCE(p.paid, 0) - (e.cum_due - e.emi_due), 0), e.emi_due)) amount_collected
FROM s2_months m
JOIN emi_schedule_clean e ON e.due_date BETWEEN DATE_SUB(m.month_end, INTERVAL DAY(m.month_end) - 1 DAY) AND m.month_end
JOIN loan_book l ON l.loan_id = e.loan_id
LEFT JOIN s2_paid_month_end p ON p.loan_id = e.loan_id AND p.month_end = m.month_end
GROUP BY l.branch_ifsc, m.month_end;
ALTER TABLE r_collection_efficiency ADD COLUMN efficiency_pct DECIMAL(6,2);
UPDATE r_collection_efficiency SET efficiency_pct = amount_collected / amount_due * 100;

-- Branch table: rupees at stake and six months of collection efficiency.
DROP TABLE IF EXISTS r_branch_summary;
CREATE TABLE r_branch_summary AS
SELECT b.ifsc branch_ifsc, b.branch_name, b.region_id, r.region_name,
       IF(b.source_system = 'CBS-P', 'Pavanpur (former)', 'Meridian') branch_origin,
       COUNT(*) loans, SUM(l.outstanding_principal) outstanding,
       SUM(IF(d.final_category = 'NPA', l.outstanding_principal, 0)) npa_outstanding,
       SUM(IF(d.final_category = 'SMA-2', l.outstanding_principal, 0)) sma2_outstanding,
       SUM(IF(d.final_category = 'SMA-1', l.outstanding_principal, 0)) sma1_outstanding,
       SUM(IF(d.final_category = 'SMA-0', l.outstanding_principal, 0)) sma0_outstanding,
       SUM(IF(d.final_category IN ('NPA', 'SMA-1', 'SMA-2'), l.outstanding_principal, 0)) rupees_at_stake,
       SUM(IF(d.final_category = 'NPA', 1, 0)) npa_loans,
       SUM(IF(d.final_category = 'NPA' AND s.final_category <> 'NPA', l.outstanding_principal, 0)) new_npa_october,
       SUM(IF(d.final_category = 'NPA', l.outstanding_principal, 0)) / SUM(l.outstanding_principal) * 100 gross_npa_pct
FROM loan_book l
JOIN branches b ON b.ifsc = l.branch_ifsc
JOIN regions r ON r.region_id = b.region_id
JOIN s2_loan_dpd d ON d.loan_id = l.loan_id AND d.as_of_date = '2026-10-31'
LEFT JOIN s2_loan_dpd s ON s.loan_id = l.loan_id AND s.as_of_date = '2026-09-30'
GROUP BY b.ifsc;
ALTER TABLE r_branch_summary
  ADD COLUMN ce_2026_05 DECIMAL(6,2), ADD COLUMN ce_2026_06 DECIMAL(6,2), ADD COLUMN ce_2026_07 DECIMAL(6,2),
  ADD COLUMN ce_2026_08 DECIMAL(6,2), ADD COLUMN ce_2026_09 DECIMAL(6,2), ADD COLUMN ce_2026_10 DECIMAL(6,2),
  ADD COLUMN zone_npa_rank INT;
UPDATE r_branch_summary s JOIN (
  SELECT branch_ifsc,
         MAX(IF(month = '2026-05', efficiency_pct, NULL)) m5, MAX(IF(month = '2026-06', efficiency_pct, NULL)) m6,
         MAX(IF(month = '2026-07', efficiency_pct, NULL)) m7, MAX(IF(month = '2026-08', efficiency_pct, NULL)) m8,
         MAX(IF(month = '2026-09', efficiency_pct, NULL)) m9, MAX(IF(month = '2026-10', efficiency_pct, NULL)) m10
  FROM r_collection_efficiency GROUP BY branch_ifsc
) c USING (branch_ifsc)
SET s.ce_2026_05 = c.m5, s.ce_2026_06 = c.m6, s.ce_2026_07 = c.m7,
    s.ce_2026_08 = c.m8, s.ce_2026_09 = c.m9, s.ce_2026_10 = c.m10;
UPDATE r_branch_summary s JOIN (
  SELECT branch_ifsc, RANK() OVER (ORDER BY gross_npa_pct DESC) rk FROM r_branch_summary
) x USING (branch_ifsc) SET s.zone_npa_rank = x.rk;

-- Product table.
DROP TABLE IF EXISTS r_product_summary;
CREATE TABLE r_product_summary AS
SELECT l.product_code, p.product_name, p.secured_flag, l.source_system,
       COUNT(*) loans, SUM(l.outstanding_principal) outstanding,
       SUM(IF(d.final_category = 'NPA', l.outstanding_principal, 0)) npa_outstanding,
       SUM(IF(d.final_category IN ('SMA-1', 'SMA-2'), l.outstanding_principal, 0)) sma12_outstanding,
       SUM(IF(d.final_category = 'NPA', l.outstanding_principal, 0)) / SUM(l.outstanding_principal) * 100 gross_npa_pct
FROM loan_book l JOIN products p USING (product_code)
JOIN s2_loan_dpd d ON d.loan_id = l.loan_id AND d.as_of_date = '2026-10-31'
GROUP BY l.product_code, l.source_system;

-- People: officers who approved the loans.
DROP TABLE IF EXISTS r_officer_summary;
CREATE TABLE r_officer_summary AS
SELECT o.officer_id, o.officer_name, o.grade, o.home_ifsc, ob.branch_name home_branch, o.officer_status,
       COUNT(*) loans_approved, SUM(l.sanction_amount) amount_approved,
       SUM(IF(d.final_category = 'NPA', 1, 0)) npa_loans,
       SUM(IF(d.final_category = 'NPA', l.outstanding_principal, 0)) npa_outstanding,
       ROUND(SUM(IF(d.final_category = 'NPA', 1, 0)) / COUNT(*) * 100, 1) npa_loan_pct,
       SUM(IF((DAY(LAST_DAY(l.sanction_date)) - DAY(l.sanction_date)) < 3, 1, 0)) month_end_loans,
       COUNT(DISTINCT l.branch_ifsc) branches_lent_in
FROM loan_book l
JOIN officers o ON o.officer_id = l.sanctioning_officer_id
JOIN branches ob ON ob.ifsc = o.home_ifsc
JOIN s2_loan_dpd d ON d.loan_id = l.loan_id AND d.as_of_date = '2026-10-31'
GROUP BY o.officer_id;

-- Early warning: loans not yet NPA that show trouble now.
--   * SMA-1 / SMA-2 today
--   * moved to a worse category in October
--   * auto-debit bounced 2+ times in Aug-Oct (paying late by other means)
DROP TABLE IF EXISTS s2_bounces_recent;
CREATE TABLE s2_bounces_recent AS
SELECT loan_id, COUNT(*) bounces_aug_oct FROM repayments_clean
WHERE payment_status = 'BOUNCED' AND payment_date BETWEEN '2026-08-01' AND '2026-10-31' GROUP BY loan_id;
ALTER TABLE s2_bounces_recent ADD PRIMARY KEY (loan_id);

-- Watchlist: every loan to act on first, with the reason.
DROP TABLE IF EXISTS r_watchlist_loans;
CREATE TABLE r_watchlist_loans AS
SELECT l.loan_id, l.borrower_id, c.customer_name, cc.mobile, l.branch_ifsc, b.branch_name, l.region_id,
       l.product_code, l.source_system, l.sourcing_channel, l.sanctioning_officer_id,
       l.outstanding_principal, d.dpd dpd_31oct, d.final_category category_31oct,
       s.final_category category_30sep, COALESCE(br.bounces_aug_oct, 0) nach_bounces_aug_oct,
       CASE
         WHEN d.final_category = 'NPA' AND s.final_category <> 'NPA' THEN '1 Became NPA in October'
         WHEN d.final_category = 'SMA-2' THEN '2 SMA-2: will be NPA within 30 days unless paid'
         WHEN d.final_category = 'SMA-1' AND s.final_category IN ('Standard', 'SMA-0') THEN '3 Slipped to SMA-1 in October'
         WHEN d.final_category = 'NPA' THEN '4 NPA: recovery'
         WHEN COALESCE(br.bounces_aug_oct, 0) >= 2 THEN '5 Early warning: auto-debit bounced 2+ times in 3 months'
         WHEN d.final_category = 'SMA-1' THEN '6 SMA-1'
       END watch_reason
FROM loan_book l
JOIN s2_loan_dpd d ON d.loan_id = l.loan_id AND d.as_of_date = '2026-10-31'
LEFT JOIN s2_loan_dpd s ON s.loan_id = l.loan_id AND s.as_of_date = '2026-09-30'
LEFT JOIN s2_bounces_recent br ON br.loan_id = l.loan_id
JOIN branches b ON b.ifsc = l.branch_ifsc
JOIN customers_clean c ON c.customer_id = l.customer_id
LEFT JOIN customers_clean cc ON cc.customer_id = l.customer_id
WHERE d.final_category IN ('NPA', 'SMA-1', 'SMA-2') OR COALESCE(br.bounces_aug_oct, 0) >= 2;

-- Things that look wrong rather than unlucky.
DROP TABLE IF EXISTS r_red_flags;
CREATE TABLE r_red_flags (
  flag          VARCHAR(120) NOT NULL,
  subject       VARCHAR(60)  NOT NULL,
  loans         INT          NULL,
  rupees        DECIMAL(16,2) NULL,
  evidence      VARCHAR(300) NULL
);

-- Officers whose NPA rate is far above the zone rate for their volume.
INSERT INTO r_red_flags
SELECT 'Officer NPA rate more than twice the zone rate (20+ loans)', CONCAT(officer_id, ' ', officer_name),
       loans_approved, npa_outstanding,
       CONCAT(grade, ', ', home_branch, ', ', officer_status, ': ', npa_loans, ' of ', loans_approved, ' loans NPA (',
              npa_loan_pct, '%) vs zone ', (SELECT ROUND(AVG(final_category = 'NPA') * 100, 1) FROM s2_loan_dpd WHERE as_of_date = '2026-10-31'), '%')
FROM r_officer_summary
WHERE loans_approved >= 20
  AND npa_loan_pct > 2 * (SELECT AVG(final_category = 'NPA') * 100 FROM s2_loan_dpd WHERE as_of_date = '2026-10-31');

-- Month-end lending: the whole zone books about 29% of its loans in the
-- last 3 days of the month (an even spread would be about 10%) - a
-- target-chasing pattern. Flag the branches and officers whose
-- month-end loans go bad at least twice as often as their other loans.
INSERT INTO r_red_flags
SELECT 'Month-end loans go bad 2x+ as often as the same branch''s other loans', CONCAT(p.branch_ifsc, ' ', b.branch_name),
       SUM(p.month_end_flag), SUM(IF(p.month_end_flag, p.os, 0)),
       CONCAT(ROUND(AVG(p.month_end_flag) * 100), '% of loans booked in last 3 days; ',
              ROUND(AVG(IF(p.month_end_flag, p.late30, NULL)) * 100, 1), '% of them 30+ DPD vs ',
              ROUND(AVG(IF(p.month_end_flag, NULL, p.late30)) * 100, 1), '% of other loans')
FROM s2_perf p JOIN branches b ON b.ifsc = p.branch_ifsc
GROUP BY p.branch_ifsc
HAVING SUM(p.month_end_flag) >= 20
   AND AVG(IF(p.month_end_flag, p.late30, NULL)) >= 2 * AVG(IF(p.month_end_flag, NULL, p.late30))
   AND AVG(IF(p.month_end_flag, p.late30, NULL)) >= 0.15;
INSERT INTO r_red_flags
SELECT 'Officer''s month-end loans go bad 2x+ as often as their other loans', CONCAT(p.sanctioning_officer_id, ' ', o.officer_name),
       SUM(p.month_end_flag), SUM(IF(p.month_end_flag, p.os, 0)),
       CONCAT(o.grade, ', ', ob.branch_name, ': ', ROUND(AVG(p.month_end_flag) * 100), '% of loans booked in last 3 days; ',
              ROUND(AVG(IF(p.month_end_flag, p.late30, NULL)) * 100, 1), '% of them 30+ DPD vs ',
              ROUND(AVG(IF(p.month_end_flag, NULL, p.late30)) * 100, 1), '% of other loans')
FROM s2_perf p JOIN officers o ON o.officer_id = p.sanctioning_officer_id JOIN branches ob ON ob.ifsc = o.home_ifsc
GROUP BY p.sanctioning_officer_id
HAVING SUM(p.month_end_flag) >= 10
   AND AVG(IF(p.month_end_flag, p.late30, NULL)) >= 2 * GREATEST(AVG(IF(p.month_end_flag, NULL, p.late30)), 0.01)
   AND AVG(IF(p.month_end_flag, p.late30, NULL)) >= 0.20;

-- Lending-rule breaches from Stage 1, by rule.
INSERT INTO r_red_flags
SELECT CONCAT('Lending rule breached: ', rule_broken), 'Zone', COUNT(*), SUM(outstanding_principal),
       'See loan_rule_breaches (Stage 1 Q1.8)'
FROM loan_rule_breaches GROUP BY rule_broken;

-- Persons carrying a company PAN, and one mobile shared by different borrowers.
INSERT INTO r_red_flags
SELECT 'Individual borrower recorded with a company PAN', 'Zone', COUNT(DISTINCT l.loan_id), SUM(l.outstanding_principal),
       'PAN 4th letter is C on a person: identity cannot be verified'
FROM customers_clean c JOIN loan_book l ON l.customer_id = c.customer_id
WHERE c.pan_status = 'UNFIXABLE: company PAN on a person';
INSERT INTO r_red_flags
SELECT 'Same mobile number on different borrowers', 'Zone', COUNT(*), NULL,
       'Possible proxy borrowers or agent-supplied numbers; see customers_clean'
FROM (SELECT c.mobile FROM customers_clean c JOIN borrower_map m USING (customer_id)
      WHERE c.mobile IS NOT NULL GROUP BY c.mobile HAVING COUNT(DISTINCT m.borrower_id) > 1) x;
INSERT INTO r_red_flags
SELECT 'Pavanpur personal loans priced on a flat rate (true rate understated)', 'CBS-P PL', COUNT(*), SUM(l.outstanding_principal),
       'EMI = P x (1 + rate x years) / months; borrowers pay far more than the stated rate'
FROM loan_emi_check e JOIN loan_book l USING (loan_id) WHERE e.verdict = 'FLAT_RATE';

-- Loan-level table for Stage 3 (every panel and every slicer runs from
-- this file). Officer grade is included so the delegation limits can be
-- tested in Excel against delegation_matrix.xlsx.
DROP TABLE IF EXISTS r_loan_level;
CREATE TABLE r_loan_level AS
SELECT l.loan_id, l.borrower_id, l.customer_id, l.branch_ifsc, b.branch_name, l.region_id, rg.region_name,
       IF(l.source_system = 'CBS-P', 'Pavanpur', 'Meridian') source_bank,
       COALESCE(l.sourcing_channel, 'Unknown') sourcing_channel,
       l.product_code, p.product_name, l.secured_flag,
       l.sanctioning_officer_id, o.grade officer_grade, o.officer_status,
       l.sanction_date, l.sanction_amount, l.total_disbursed, l.interest_rate, l.tenure_months,
       pf.emis_due_by_31oct, IF(pf.month_end_flag, 'Y', 'N') month_end_sanction,
       l.outstanding_principal,
       d.dpd_30sep, d.category_30sep, d.dpd_31oct, d.loan_category_31oct, d.category_31oct,
       d.npa_by_borrower_rule_31oct, d.overdue_31oct,
       c.fin_class finance_class, c.risk_class, c.risk_dpd,
       COALESCE(LEFT(c.fin_cause, 2), '') finance_cause_code, COALESCE(LEFT(c.risk_cause, 2), '') risk_cause_code,
       IF(d.dpd_31oct > 30, 'Y', 'N') late30_31oct,
       IF(d.category_31oct = 'NPA' AND d.category_30sep <> 'NPA', 'Y', 'N') became_npa_october,
       COALESCE(bo.bounces_aug_oct, 0) nach_bounces_aug_oct,
       IF(EXISTS (SELECT 1 FROM loan_rule_breaches x WHERE x.loan_id = l.loan_id), 'Y', 'N') rule_breach
FROM loan_book l
JOIN branches b ON b.ifsc = l.branch_ifsc
JOIN regions rg ON rg.region_id = l.region_id
JOIN products p ON p.product_code = l.product_code
LEFT JOIN officers o ON o.officer_id = l.sanctioning_officer_id
JOIN r_loan_dpd d ON d.loan_id = l.loan_id
JOIN s2_compare c ON c.loan_id = l.loan_id
JOIN s2_perf pf ON pf.loan_id = l.loan_id
LEFT JOIN s2_bounces_recent bo ON bo.loan_id = l.loan_id;
ALTER TABLE r_loan_level ADD PRIMARY KEY (loan_id);

-- Cause codes used in r_loan_level (F = Finance, R = Risk).
DROP TABLE IF EXISTS r_cause_codes;
CREATE TABLE r_cause_codes AS
SELECT DISTINCT LEFT(fin_cause, 2) code, SUBSTRING(fin_cause, 4) cause, 'Finance' department FROM s2_compare WHERE fin_cause IS NOT NULL
UNION
SELECT DISTINCT LEFT(risk_cause, 2), SUBSTRING(risk_cause, 4), 'Risk' FROM s2_compare WHERE risk_cause IS NOT NULL;

-- Category totals on both dates (for the movement panel).
DROP TABLE IF EXISTS r_category_summary;
CREATE TABLE r_category_summary AS
SELECT d.as_of_date, d.final_category category, COUNT(*) loans, SUM(l.outstanding_principal) outstanding_31oct_balance
FROM s2_loan_dpd d JOIN loan_book l USING (loan_id) GROUP BY d.as_of_date, d.final_category;

-- ---------------------------------------------------------------------
-- Stage 2 results
-- ---------------------------------------------------------------------
SELECT * FROM r_headline ORDER BY measure;
SELECT step_no, step, step_type, loans, rupees, running_npa, running_pct FROM r_npa_bridge ORDER BY step_no;
SELECT * FROM r_bridge_check;
SELECT claim, scope, test_rate_pct, control_rate_pct, observed_to_expected, z_score, verdict FROM r_claim_tests;
SELECT category_30sep, category_31oct, loans, outstanding_31oct FROM r_movement_matrix ORDER BY 1, 2;
SELECT branch_ifsc, branch_name, loans, rupees_at_stake, gross_npa_pct, ce_2026_05, ce_2026_10
FROM r_branch_summary ORDER BY gross_npa_pct DESC LIMIT 10;
SELECT * FROM r_red_flags;
