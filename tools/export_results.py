"""Export every Stage 1 / Stage 2 result table to results/*.csv.

Same thing as Workbench "Export recordset to CSV" for each table, but
repeatable. Reads MYSQL_USER / MYSQL_PASSWORD from .env. Run from anywhere:
    python tools/export_results.py
"""
import csv
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MYSQL = r"C:\Program Files\MySQL\MySQL Server 8.4\bin\mysql.exe"

# Stage 2 result files (the only data Stage 3 may use) and the Stage 1
# evidence tables.
STAGE2 = [
    "r_headline", "r_npa_bridge", "r_bridge_check", "r_npa_reconciliation_loans",
    "r_loan_dpd", "r_loan_level", "r_category_summary", "r_movement_matrix",
    "r_new_npa_october", "r_claim_tests", "r_claim_cohorts", "r_vintage",
    "r_collection_efficiency", "r_branch_summary", "r_product_summary",
    "r_officer_summary", "r_watchlist_loans", "r_red_flags", "r_cause_codes",
]
STAGE1 = [
    "dq_log", "recon_files", "recon_warehouse", "recon_loan_book",
    "customer_exceptions", "identity_decisions", "borrower_map",
    "loan_emi_check", "loan_rule_breaches",
]


def env():
    cfg = {}
    for line in (ROOT / ".env").read_text(encoding="utf-8-sig").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip()
    return cfg


def export(table, out_dir, cfg):
    e = dict(os.environ, MYSQL_PWD=cfg["MYSQL_PASSWORD"])
    res = subprocess.run(
        [MYSQL, "-u", cfg["MYSQL_USER"], "--default-character-set=utf8mb4", "-B",
         "meridian_crest_bank", "-e", f"SELECT * FROM {table}"],
        capture_output=True, env=e, check=True)
    lines = res.stdout.decode("utf-8").splitlines()
    out = out_dir / f"{table.removeprefix('r_')}.csv"
    with open(out, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        for line in lines:
            w.writerow(["" if v == "NULL" else v.replace("\\n", " ").replace("\\t", " ")
                        for v in line.split("\t")])
    return out, len(lines) - 1


def main():
    cfg = env()
    for tables, sub in ((STAGE2, "results"), (STAGE1, "results/stage1")):
        d = ROOT / sub
        d.mkdir(parents=True, exist_ok=True)
        for t in tables:
            out, n = export(t, d, cfg)
            print(f"{n:7d} rows  {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
