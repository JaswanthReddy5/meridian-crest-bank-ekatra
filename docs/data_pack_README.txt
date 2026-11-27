MERIDIAN CREST BANK · HUBBALLI ZONE · DATA DELIVERY OF 1 NOVEMBER 2026
Developed by Talenciaglobal

This pack contains:
  18 CSV files   -> load into MySQL (one table per file; see data_dictionary.pdf)
   3 XLSX files  -> use in Excel only (Stage 3); do not load into MySQL

CSV format
  - Comma separated, first row is the header, UTF-8 encoding.
  - Text that contains a comma is enclosed in double quotes.
  - Empty fields mean no value was sent.

Loading in MySQL Workbench
  - Large files (emi_schedule, repayments) load much faster with
    LOAD DATA LOCAL INFILE than with the Table Data Import Wizard.
  - LOAD DATA LOCAL INFILE needs local_infile enabled on the server
    (SET GLOBAL local_infile = 1;) and on the connection
    (Workbench: Edit Connection > Advanced > Others: OPT_LOCAL_INFILE=1).
  - On Windows, write file paths with forward slashes: 'C:/mcb/regions.csv'.
  - Workbench blocks some UPDATE statements in safe update mode;
    run SET SQL_SAFE_UPDATES = 0; if you see error 1175.
  - Before exporting a result to CSV, set the row limit to "Don't Limit",
    otherwise only the first 1,000 rows are exported.

Files
  Reference data   : regions, branches, products, officers
  Customers        : customers, customer_contacts, legacy_id_map
  Loans & payments : loan_accounts, disbursements, collateral, emi_schedule, repayments, nach_mandates
  Reports/pipeline : finance_npa_oct2026, risk_npa_oct2026, cbs_extract_oct2026, dw_snapshot_oct2026, load_manifest
  Excel            : delegation_matrix.xlsx, rbi_norms_reference.xlsx, branch_targets.xlsx
