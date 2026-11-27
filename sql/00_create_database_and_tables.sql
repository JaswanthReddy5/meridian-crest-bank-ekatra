-- =====================================================================
-- Meridian Crest Bank · Hubballi Zone · Project Ekatra
-- STAGE 0 : Build the bank's database exactly as the data dictionary says
--           (18 tables, every column, data type, primary and foreign key)
--
-- Runs top to bottom with no errors on MySQL 8.x and can be re-run:
-- it drops and recreates the database each time.
-- =====================================================================

DROP DATABASE IF EXISTS meridian_crest_bank;
CREATE DATABASE meridian_crest_bank
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_0900_ai_ci;
USE meridian_crest_bank;

-- ---------------------------------------------------------------------
-- REFERENCE DATA
-- ---------------------------------------------------------------------

-- T1 regions
CREATE TABLE regions (
  region_id       VARCHAR(4)  NOT NULL,
  region_name     VARCHAR(40) NOT NULL,
  region_hq_city  VARCHAR(40) NOT NULL,
  PRIMARY KEY (region_id)
);

-- T2 branches
CREATE TABLE branches (
  ifsc              CHAR(11)    NOT NULL,
  branch_code       VARCHAR(6)  NOT NULL,
  source_system     VARCHAR(5)  NOT NULL,
  branch_name       VARCHAR(60) NOT NULL,
  city              VARCHAR(40) NOT NULL,
  district          VARCHAR(40) NOT NULL,
  region_id         VARCHAR(4)  NOT NULL,
  branch_status     VARCHAR(10) NOT NULL,
  opened_on         DATE        NOT NULL,
  closed_on         DATE        NULL,
  merged_into_ifsc  CHAR(11)    NULL,
  PRIMARY KEY (ifsc),
  CONSTRAINT fk_branches_region
    FOREIGN KEY (region_id) REFERENCES regions (region_id),
  CONSTRAINT fk_branches_merged_into
    FOREIGN KEY (merged_into_ifsc) REFERENCES branches (ifsc)
);

-- T3 products
CREATE TABLE products (
  product_code       VARCHAR(6)   NOT NULL,
  product_name       VARCHAR(40)  NOT NULL,
  secured_flag       CHAR(1)      NOT NULL,
  max_tenure_months  SMALLINT     NOT NULL,
  min_rate           DECIMAL(5,2) NOT NULL,
  max_rate           DECIMAL(5,2) NOT NULL,
  PRIMARY KEY (product_code)
);

-- T4 officers
CREATE TABLE officers (
  officer_id      VARCHAR(10) NOT NULL,
  officer_name    VARCHAR(60) NOT NULL,
  grade           VARCHAR(10) NOT NULL,
  home_ifsc       CHAR(11)    NOT NULL,
  joined_on       DATE        NOT NULL,
  officer_status  VARCHAR(10) NOT NULL,
  PRIMARY KEY (officer_id),
  CONSTRAINT fk_officers_home_branch
    FOREIGN KEY (home_ifsc) REFERENCES branches (ifsc)
);

-- ---------------------------------------------------------------------
-- CUSTOMERS
-- ---------------------------------------------------------------------

-- T5 customers
CREATE TABLE customers (
  customer_id    VARCHAR(15) NOT NULL,
  source_system  VARCHAR(5)  NULL,
  customer_name  VARCHAR(80) NULL,
  pan            VARCHAR(12) NULL,
  date_of_birth  VARCHAR(20) NULL,
  gender         VARCHAR(10) NULL,
  occupation     VARCHAR(30) NULL,
  kyc_status     VARCHAR(12) NULL,
  created_on     VARCHAR(20) NULL,
  PRIMARY KEY (customer_id)
);

-- T6 customer_contacts
CREATE TABLE customer_contacts (
  contact_id     INT          NOT NULL,
  customer_id    VARCHAR(15)  NOT NULL,
  contact_type   VARCHAR(10)  NOT NULL,
  contact_value  VARCHAR(150) NULL,
  is_primary     CHAR(1)      NOT NULL,
  updated_on     DATE         NULL,
  PRIMARY KEY (contact_id),
  CONSTRAINT fk_contacts_customer
    FOREIGN KEY (customer_id) REFERENCES customers (customer_id)
);

-- T7 legacy_id_map   (meridian_customer_id is a business LINK to customers, not an FK)
CREATE TABLE legacy_id_map (
  pavanpur_customer_id  VARCHAR(15) NOT NULL,
  meridian_customer_id  VARCHAR(15) NOT NULL,
  match_basis           VARCHAR(20) NOT NULL,
  mapped_on             DATE        NOT NULL,
  PRIMARY KEY (pavanpur_customer_id)
);

-- ---------------------------------------------------------------------
-- LOANS AND PAYMENTS
-- (loan_id / customer_id / branch_code / product / officer columns are
--  business LINKS used in joins — not declared as constraints)
-- ---------------------------------------------------------------------

-- T8 loan_accounts
CREATE TABLE loan_accounts (
  record_id               INT         NOT NULL,
  loan_id                 VARCHAR(20) NULL,
  source_system           VARCHAR(5)  NULL,
  load_batch              VARCHAR(12) NULL,
  load_timestamp          DATETIME    NULL,
  customer_id             VARCHAR(15) NULL,
  branch_code             VARCHAR(6)  NULL,
  product                 VARCHAR(30) NULL,
  sourcing_channel        VARCHAR(15) NULL,
  sanctioning_officer_id  VARCHAR(10) NULL,
  sanction_date           VARCHAR(20) NULL,
  sanction_amount         VARCHAR(20) NULL,
  interest_rate           VARCHAR(10) NULL,
  tenure                  VARCHAR(10) NULL,
  emi_amount              VARCHAR(20) NULL,
  first_emi_date          VARCHAR(20) NULL,
  outstanding_principal   VARCHAR(20) NULL,
  cbs_asset_class         VARCHAR(10) NULL,
  PRIMARY KEY (record_id)
);

-- T9 disbursements
CREATE TABLE disbursements (
  disbursement_id    VARCHAR(16) NOT NULL,
  loan_id            VARCHAR(20) NOT NULL,
  tranche_no         SMALLINT    NOT NULL,
  disbursement_date  VARCHAR(20) NULL,
  amount             VARCHAR(20) NULL,
  payment_mode       VARCHAR(10) NULL,
  PRIMARY KEY (disbursement_id)
);

-- T10 collateral
CREATE TABLE collateral (
  collateral_id      VARCHAR(16)  NOT NULL,
  loan_id            VARCHAR(20)  NOT NULL,
  collateral_type    VARCHAR(20)  NULL,
  description        VARCHAR(100) NULL,
  gold_weight_grams  DECIMAL(8,2) NULL,
  valuation_amount   VARCHAR(20)  NULL,
  valuation_date     VARCHAR(20)  NULL,
  PRIMARY KEY (collateral_id)
);

-- T11 emi_schedule   (composite primary key)
CREATE TABLE emi_schedule (
  loan_id              VARCHAR(20)   NOT NULL,
  instalment_no        SMALLINT      NOT NULL,
  due_date             DATE          NOT NULL,
  emi_due              DECIMAL(12,2) NOT NULL,
  principal_component  DECIMAL(12,2) NOT NULL,
  interest_component   DECIMAL(12,2) NOT NULL,
  PRIMARY KEY (loan_id, instalment_no)
);

-- T12 repayments   (reversal_of is a LINK back to repayments.payment_id)
CREATE TABLE repayments (
  payment_id      VARCHAR(16)   NOT NULL,
  loan_id         VARCHAR(20)   NOT NULL,
  payment_date    DATE          NOT NULL,
  amount          DECIMAL(12,2) NOT NULL,
  payment_mode    VARCHAR(10)   NOT NULL,
  payment_status  VARCHAR(10)   NOT NULL,
  reversal_of     VARCHAR(16)   NULL,
  PRIMARY KEY (payment_id)
);

-- T13 nach_mandates
CREATE TABLE nach_mandates (
  mandate_id      VARCHAR(16)   NOT NULL,
  loan_id         VARCHAR(20)   NOT NULL,
  debit_bank      VARCHAR(40)   NOT NULL,
  account_last4   CHAR(4)       NOT NULL,
  max_amount      DECIMAL(12,2) NOT NULL,
  start_date      DATE          NOT NULL,
  end_date        DATE          NULL,
  mandate_status  VARCHAR(10)   NOT NULL,
  PRIMARY KEY (mandate_id)
);

-- ---------------------------------------------------------------------
-- REPORTS AND PIPELINE
-- ---------------------------------------------------------------------

-- T14 finance_npa_oct2026
CREATE TABLE finance_npa_oct2026 (
  loan_id                VARCHAR(20)   NOT NULL,
  customer_id            VARCHAR(15)   NOT NULL,
  branch_code            VARCHAR(6)    NOT NULL,
  outstanding_principal  DECIMAL(14,2) NOT NULL,
  asset_class            VARCHAR(10)   NOT NULL,
  report_date            DATE          NOT NULL,
  PRIMARY KEY (loan_id)
);

-- T15 risk_npa_oct2026
CREATE TABLE risk_npa_oct2026 (
  loan_id                VARCHAR(20)   NOT NULL,
  customer_id            VARCHAR(15)   NOT NULL,
  branch_code            VARCHAR(6)    NOT NULL,
  outstanding_principal  DECIMAL(14,2) NOT NULL,
  dpd                    INT           NOT NULL,
  asset_class            VARCHAR(10)   NOT NULL,
  report_date            DATE          NOT NULL,
  PRIMARY KEY (loan_id)
);

-- T16 cbs_extract_oct2026
CREATE TABLE cbs_extract_oct2026 (
  loan_id                VARCHAR(20)   NOT NULL,
  branch_code            VARCHAR(6)    NOT NULL,
  product_code           VARCHAR(6)    NOT NULL,
  outstanding_principal  DECIMAL(14,2) NOT NULL,
  emi_amount             DECIMAL(12,2) NOT NULL,
  cbs_asset_class        VARCHAR(10)   NOT NULL,
  extract_date           DATE          NOT NULL,
  PRIMARY KEY (loan_id)
);

-- T17 dw_snapshot_oct2026
CREATE TABLE dw_snapshot_oct2026 (
  loan_id                VARCHAR(20)   NOT NULL,
  branch_code            VARCHAR(6)    NOT NULL,
  product_code           VARCHAR(6)    NOT NULL,
  outstanding_principal  DECIMAL(14,2) NOT NULL,
  emi_amount             DECIMAL(12,2) NOT NULL,
  cbs_asset_class        VARCHAR(10)   NOT NULL,
  dw_load_date           DATE          NOT NULL,
  PRIMARY KEY (loan_id)
);

-- T18 load_manifest
CREATE TABLE load_manifest (
  file_name       VARCHAR(60)   NOT NULL,
  source_system   VARCHAR(10)   NOT NULL,
  extract_date    DATE          NOT NULL,
  expected_rows   INT           NOT NULL,
  control_column  VARCHAR(40)   NULL,
  control_total   DECIMAL(16,2) NULL,
  delivered_on    DATETIME      NOT NULL,
  PRIMARY KEY (file_name)
);

-- Quick check: should list 18 tables
SELECT COUNT(*) AS table_count
FROM information_schema.tables
WHERE table_schema = 'meridian_crest_bank';
