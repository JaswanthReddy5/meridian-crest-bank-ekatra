# Meridian Crest Bank · Hubballi Zone · Project Ekatra

Hackathon work on the Meridian Crest Bank data pack (delivery of 1 Nov 2026,
by Talenciaglobal). MySQL 8.4 + MySQL Workbench.

## Stage status

| Stage | What | Status |
|---|---|---|
| 0 | Build the database: 18 tables, exact columns, types, PK/FK from the data dictionary | **Done** – `sql/00_create_database_and_tables.sql` |
| 1 | Can we trust the data? Load, reconcile, clean, data quality log | **Done** – `sql/01_load_data.sql` + `sql/02_stage1_clean.sql`, log in `stage1/Data_Quality_Log.xlsx` |
| 2 | How bad is the loan book? True NPA, reconciliation, trends, watchlist | **Done** – `sql/03_stage2_analysis.sql`, result CSVs in `results/`, note in `notes/stage2_note.md` |
| 3 | What should the Board do? Excel model, one-page dashboard, recommendation | **Done** – `stage3/` (workbook, dashboard PDF, Board recommendation) |

### Headline results (31 Oct 2026)

| | Gross NPA | Rs |
|---|---|---|
| Finance (as reported) | 3.08% | 30.02 cr |
| **True (DPD from EMIs + cleared payments, RBI borrower rule)** | **3.73%** | **36.33 cr** of 974.51 cr, 533 loans |
| Risk (as reported) | 4.42% | 43.07 cr |

- **Finance is Rs 6.30 cr too low.**
  - 52 migrated Pavanpur loans over 90 DPD were never flagged NPA in CBS (Rs 1.88 cr).
  - It applies no borrower rule (Rs 4.72 cr).
  - Rs 0.29 cr of its NPA flags are stale.
- **Risk is Rs 6.75 cr too high.**
  - It counts bounced NACH debits as missed even when the EMI was paid later (Rs 5.46 cr).
  - It spreads NPA through the vendor's 15 false name-only matches (Rs 0.70 cr) and from loans that are not truly NPA (Rs 0.78 cr).
  - Less Rs 0.19 cr of links it misses.
- Both bridges close to Rs 0.00 (`results/npa_bridge.csv`, `results/bridge_check.csv`).
- **Stage 1:**
  - 8,366 delivered rows become 8,266 loans = manifest control total Rs 9,745,135,816.49 (`results/stage1/recon_loan_book.csv`).
  - The warehouse is missing 37 loans (Rs 5.53 cr) and 12 NPA flags.
  - 7,645 customer numbers resolve to 7,222 real borrowers (7,022 with loans).
- **Stage 3:**
  - Provision Rs 10.22 cr.
  - 25 recovery officers: Belagavi 11, Hubballi-Dharwad 5, Vijayapura-Bagalkot 5, Gadag-Haveri 3, Uttara Kannada 1.
  - 5 branches lose lending powers.
  - 40 loans were approved above the officer's limit, 23 of them by one officer.

## Repo layout

```
sql/00_create_database_and_tables.sql   Stage 0 – database + 18 tables
sql/01_load_data.sql                    Loads data/*.csv (generated, do not hand-edit)
sql/02_stage1_clean.sql                 Stage 1 – reconcile, profile, clean, identity, rule breaches, dq_log
sql/03_stage2_analysis.sql              Stage 2 – DPD on 30 Sep/31 Oct, true NPA, bridge, claims, branches
tools/make_load_sql.py                  Generates 01_load_data.sql from the CSV headers
tools/export_results.py                 Exports every result table to results/*.csv
tools/build_workbook.py                 Stage 3 – builds the Excel model + dashboard from results/ and excel/
tools/build_recommendation.py           Stage 3 – one-page Board recommendation (docx + pdf)
tools/mysql.sh                          Run a .sql file with the .env credentials (Git Bash)
scripts/run_all.ps1                     Rebuild DB + load + Stage 1 + Stage 2 + export, in one go (~2 min)
scripts/finish_workbook.ps1             Recalculate the workbook in Excel and export the dashboard PDF
data/                                   The 18 delivered CSV files (load into MySQL)
excel/                                  delegation_matrix, rbi_norms_reference, branch_targets (Stage 3, Excel only)
results/                                Stage 2 result CSVs (the only data Stage 3 uses); results/stage1/ = Stage 1 evidence
stage1/Data_Quality_Log.xlsx            Stage 1 hand-over: every problem, rule, rows, rupees + reconciliations
stage3/                                 Meridian_Crest_CRO_Dashboard.xlsx / .pdf, Board_Recommendation.docx / .pdf
notes/stage2_note.md                    Stage 2 note: estimate before, what we learned after
docs/                                   data_dictionary.pdf, bank context PDF, original pack README
```

### Rebuilding the Stage 3 files

```powershell
python toolsuild_workbook.py
powershell -ExecutionPolicy Bypass -File scriptsinish_workbook.ps1
python toolsuild_recommendation.py
```

## Setup for a teammate (Windows)

1. Install MySQL Server 8.4 and Workbench:
   ```powershell
   winget install --id Oracle.MySQL -e
   winget install --id Oracle.MySQLWorkbench -e
   ```
   Configure the server (MySQL Configurator, or initialise it yourself) and add
   `local_infile=1` under `[mysqld]` and `[client]` in `my.ini`.
2. Clone this repo and create `.env` from the example, with your own MySQL password:
   ```powershell
   Copy-Item .env.example .env
   ```
3. Rebuild the database, load all data and run Stages 1–2:
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\run_all.ps1
   ```
   It prints the reconciliations and results, and writes `results/*.csv`.

### Running in Workbench instead

- Stage 0: open `sql/00_create_database_and_tables.sql` and run it (⚡).
- Loading: `01_load_data.sql` uses paths relative to the repo root, which
  Workbench can't resolve. Either use `scripts/run_all.ps1`, or make a
  Workbench copy (`sql/01_load_data_workbench.sql`, git-ignored because the
  paths are machine-specific):
  1. find/replace `'data/` with your absolute path, e.g.
     `'C:/Users/you/meridian-crest-bank/data/` (forward slashes);
  2. replace `LOAD DATA LOCAL INFILE` with `LOAD DATA INFILE` — Workbench 26
     rejects the local-infile connection option, so the server reads the files;
  3. in `my.ini` under `[mysqld]` add
     `secure_file_priv="C:/Users/you/meridian-crest-bank/data"` and restart the
     MySQL service (admin).
  Running it shows "N rows affected" per table in the Output panel.
- Before exporting a result to CSV set the row limit to **Don't Limit**.
- Error 1175 on UPDATE → `SET SQL_SAFE_UPDATES = 0;`

## Load notes

- Every empty CSV field is loaded as `NULL`; everything else is loaded exactly
  as the source sent it (columns the dictionary types as `VARCHAR` keep the raw text).
- Files use CRLF line endings; the load splits on LF and trims the trailing CR,
  so it behaves the same from the mysql CLI and from Workbench.
- Control totals from `load_manifest` match after load:
  `cbs_extract_oct2026.outstanding_principal` = 9,745,135,816.49,
  `emi_schedule.emi_due` = 4,086,198,894.51, `repayments.amount` = 3,911,978,694.66.

## Key rules used (details in the SQL comments)

- **Dates:**
  - Slash dates are MM/DD/YYYY in CBS-M and DD/MM/YYYY in CBS-P; no value contradicts this.
  - 5-digit values are Excel serial dates.
- **Duplicate loan rows:** keep the latest `load_timestamp`. The B07 re-extract matches the CBS extract balance.
- **Missing loans:** the 2 loans missing from `loan_accounts` are rebuilt from the CBS extract and related tables.
- **Rates and branches:**
  - Rates below 1 are fractions, so they are multiplied by 100.
  - CBS-P branch codes are padded to 4 digits.
  - Closed branches pass their loans to `merged_into_ifsc`.
- **Identity:**
  - A Pavanpur and a Meridian customer are the same person if the PAN, name and DOB all agree, or if the name and DOB agree with no conflicting PAN.
  - Different PAN or DOB → refused.
- **Payments:**
  - Bounced, reversed and reversal entries do not count.
  - 9 same-day repeat payments do count; each was a catch-up of an overdue EMI.
- **DPD:**
  - Day 1 = the due date.
  - Money pays the oldest dues first.
  - A shortfall of up to Rs 1 counts as paid.
  - Borrower rule applied on the matched identity.
