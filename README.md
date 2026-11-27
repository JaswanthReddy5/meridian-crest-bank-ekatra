# Meridian Crest Bank · Hubballi Zone · Project Ekatra

Hackathon work on the Meridian Crest Bank data pack (delivery of 1 Nov 2026,
by Talenciaglobal). MySQL 8.4 + MySQL Workbench.

## Stage status

| Stage | What | Status |
|---|---|---|
| 0 | Build the database: 18 tables, exact columns, types, PK/FK from the data dictionary | **Done** – `sql/00_create_database_and_tables.sql` |
| 1 | Load the delivery (brief comes after Stage 0 hand-over) | Load script ready – `sql/01_load_data.sql`, all 18 files load with row counts matching the CSVs |
| 2+ | — | Not started |

The hand-over script for Stage 0 is **`sql/00_create_database_and_tables.sql`**.
It runs top to bottom without errors and is safe to re-run (drops and
recreates `meridian_crest_bank`). Every later stage appends to the SQL work in `sql/`.

## Repo layout

```
sql/00_create_database_and_tables.sql   Stage 0 – database + 18 tables
sql/01_load_data.sql                    Loads data/*.csv (generated, do not hand-edit)
tools/make_load_sql.py                  Generates 01_load_data.sql from the CSV headers
scripts/run_all.ps1                     Rebuild DB + load everything in one go
data/                                   The 18 delivered CSV files (load into MySQL)
excel/                                  delegation_matrix, rbi_norms_reference, branch_targets (Stage 3, Excel only – do NOT load)
docs/                                   data_dictionary.pdf, bank context PDF, original pack README
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
3. Rebuild the database and load all data:
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\run_all.ps1
   ```
   It prints a row count per table at the end.

### Running in Workbench instead

- Stage 0: open `sql/00_create_database_and_tables.sql` and run it (⚡).
- Loading: `01_load_data.sql` uses paths relative to the repo root, which
  Workbench can't resolve. Either use `scripts/run_all.ps1`, or find/replace
  `'data/` with your absolute path, e.g. `'C:/Users/you/meridian-crest-bank/data/`
  (forward slashes). The Workbench connection needs
  *Edit Connection → Advanced → Others:* `OPT_LOCAL_INFILE=1`.
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

## Things spotted while loading (for later stages)

Not fixed – the raw tables hold the data as delivered.

- `loan_accounts` has **8,366** rows but the manifest expects **8,266** → ~100 extra rows (likely duplicate loan_ids across load batches).
- `dw_snapshot_oct2026` has **8,235** rows vs 8,266 in `cbs_extract_oct2026` → 31 loans missing from the warehouse.
- `load_manifest` lists 17 files (not itself).
- `disbursements` mixes formats: `₹12,10,000` and `03/07/2024` next to `3795000` and `2026-02-11`.
- `customers` has inconsistent name casing (e.g. `naveen mulla`); dates of birth stored as text.
- `branch_code` is not unique across systems (e.g. `1007`, `1012` exist in both CBS-M and CBS-P) – join branches on `branch_code` **and** `source_system`, or via IFSC.
- Finance reports gross NPA 3.1 %, Risk 4.4 % – the reconciliation is the core of the case (see `docs/Meridian_Crest_Bank_Context.pdf`).
