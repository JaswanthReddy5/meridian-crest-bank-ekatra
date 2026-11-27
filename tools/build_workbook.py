"""Stage 3: build the CRO workbook (stage3/Meridian_Crest_CRO_Dashboard.xlsx).

Uses ONLY the Stage 2 result files (results/*.csv) and the bank's three
Excel reference files (excel/*.xlsx). Every figure on the dashboard is a
formula over the loan-level result file, so the CRO can change the
filters and the SMA-2 assumption and everything follows.
Run:  python tools/build_workbook.py   then   scripts/finish_workbook.ps1
"""
import csv
from datetime import date
from pathlib import Path

import openpyxl
from openpyxl.chart import BarChart, LineChart, Reference
from openpyxl.chart.label import DataLabelList
from openpyxl.chart.shapes import GraphicalProperties
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter as L
from openpyxl.workbook.defined_name import DefinedName
from openpyxl.worksheet.datavalidation import DataValidation

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "results"
OUT = ROOT / "stage3" / "Meridian_Crest_CRO_Dashboard.xlsx"

# One colour per category, used on every panel.
COL = {"Standard": "4E9A06", "SMA-0": "E6B800", "SMA-1": "F08A24", "SMA-2": "D9481C", "NPA": "8B0000",
       "Finance": "808080", "Risk": "6A3D9A", "True": "1F3864", "Remove": "4E9A06", "Add": "8B0000",
       "Stress": "D9481C", "Base": "1F3864"}
CATS = ["Standard", "SMA-0", "SMA-1", "SMA-2", "NPA"]
NAVY = "1F3864"
thin = Side(style="thin", color="BFBFBF")
BOX = Border(left=thin, right=thin, top=thin, bottom=thin)
HDR_FILL = PatternFill("solid", fgColor=NAVY)
IN_FILL = PatternFill("solid", fgColor="FFF2CC")
SOFT = PatternFill("solid", fgColor="F2F2F2")


def read_csv(name):
    with open(RES / name, encoding="utf-8-sig", newline="") as f:
        rows = list(csv.reader(f))
    return rows[0], rows[1:]


def conv(v):
    if v == "":
        return None
    try:
        if len(v) == 10 and v[4] == "-" and v[7] == "-":
            return date.fromisoformat(v)
    except ValueError:
        pass
    try:
        f = float(v)
        return int(f) if f.is_integer() and "." not in v else f
    except ValueError:
        return v


def labels(fmt):
    dl_ = DataLabelList()
    dl_.showVal = True
    dl_.showSerName = False
    dl_.showCatName = False
    dl_.showLegendKey = False
    dl_.showPercent = False
    dl_.numFmt = fmt
    return dl_


def header(ws, row, col, labels, fill=HDR_FILL):
    for i, t in enumerate(labels):
        c = ws.cell(row, col + i, t)
        c.font = Font(bold=True, color="FFFFFF")
        c.fill = fill
        c.alignment = Alignment(wrap_text=True, vertical="center")
        c.border = BOX


def name(wb, nm, ref):
    wb.defined_names[nm] = DefinedName(nm, attr_text=ref)


def write_table(ws, hdr, rows, r0=1, c0=1):
    header(ws, r0, c0, hdr)
    for i, row in enumerate(rows):
        for j, v in enumerate(row):
            ws.cell(r0 + 1 + i, c0 + j, conv(v))


wb = openpyxl.Workbook()
dash = wb.active
dash.title = "Dashboard"
inp = wb.create_sheet("Inputs")
calc = wb.create_sheet("Calc")
plan = wb.create_sheet("Recovery_Plan")
deleg = wb.create_sheet("Delegation")
chk = wb.create_sheet("Checks")
dl = wb.create_sheet("Data_Loans")
db = wb.create_sheet("Data_Branches")
ds = wb.create_sheet("Data_Stage2")
lists = wb.create_sheet("Lists")
readme = wb.create_sheet("README")

# ---------------------------------------------------------------------
# Inputs: the bank's reference files + the plan's assumptions
# ---------------------------------------------------------------------
inp["A1"] = "INPUTS - every number the model uses that is not data. Yellow cells may be changed."
inp["A1"].font = Font(bold=True, size=13, color=NAVY)

ref = openpyxl.load_workbook(ROOT / "excel" / "rbi_norms_reference.xlsx", data_only=True)
inp["A3"] = "Provisioning rates (rbi_norms_reference.xlsx, sheet Provisioning)"
inp["A3"].font = Font(bold=True)
header(inp, 4, 1, ["category", "secured_rate", "unsecured_rate"])
r = 5
for row in ref["Provisioning"].iter_rows(min_row=6, values_only=True):
    if row[0] is None:
        break
    for j, v in enumerate(row[:3]):
        c = inp.cell(r, 1 + j, v)
        if j:
            c.number_format = "0.0%"
    r += 1
name(wb, "Prov_Cat", "Inputs!$A$5:$A$9")
name(wb, "Prov_Secured", "Inputs!$B$5:$B$9")
name(wb, "Prov_Unsecured", "Inputs!$C$5:$C$9")

inp["E3"] = "DPD bands (rbi_norms_reference.xlsx, sheet DPD_Buckets)"
inp["E3"].font = Font(bold=True)
header(inp, 4, 5, ["dpd_from", "category", "meaning"])
r = 5
for row in ref["DPD_Buckets"].iter_rows(min_row=6, values_only=True):
    if row[0] is None:
        break
    for j, v in enumerate(row[:3]):
        inp.cell(r, 5 + j, v)
    r += 1

dm = openpyxl.load_workbook(ROOT / "excel" / "delegation_matrix.xlsx", data_only=True)["Limits"]
inp["A12"] = "Delegation of lending powers, Rs (delegation_matrix.xlsx, sheet Limits)"
inp["A12"].font = Font(bold=True)
rows = [r for r in dm.iter_rows(min_row=5, values_only=True) if r[0]]
header(inp, 13, 1, list(rows[0]))
for i, row in enumerate(rows[1:]):
    for j, v in enumerate(row):
        c = inp.cell(14 + i, 1 + j, v)
        if j:
            c.number_format = "#,##0"
name(wb, "Deleg_Grades", "Inputs!$A$14:$A$17")
name(wb, "Deleg_Products", "Inputs!$B$13:$G$13")
name(wb, "Deleg_Limits", "Inputs!$B$14:$G$17")

bt = openpyxl.load_workbook(ROOT / "excel" / "branch_targets.xlsx", data_only=True)["Targets"]
inp["I3"] = "FY27 disbursal targets (branch_targets.xlsx)"
inp["I3"].font = Font(bold=True)
header(inp, 4, 9, ["ifsc", "branch_name", "fy27_disbursal_target"])
r = 5
for row in bt.iter_rows(min_row=6, values_only=True):
    if row[0] is None:
        break
    for j, v in enumerate(row[:3]):
        c = inp.cell(r, 9 + j, v)
        if j == 2:
            c.number_format = "#,##0"
    r += 1
name(wb, "Target_IFSC", f"Inputs!$I$5:$I${r - 1}")
name(wb, "Target_Amount", f"Inputs!$K$5:$K${r - 1}")

inp["A20"] = "Plan assumptions"
inp["A20"].font = Font(bold=True)
assumptions = [
    ("Recovery officers to deploy", 25, "0", "Officers"),
    ("Weight of SMA-1 rupees in recovery workload (NPA and SMA-2 count in full)", 0.5, "0%", "SMA1_Weight"),
    ("Lending-power test: branch NPA ratio at least this multiple of the zone ratio", 1.5, "0.0x", "LP_NPA_Multiple"),
    ("Lending-power test: and collection efficiency (Aug-Oct average) below", 0.80, "0%", "LP_CE_Floor"),
    ("Lending-power test: or this many loans approved above the officer's limit", 10, "0", "LP_Breach_Count"),
    ("Rupees in one crore", 10000000, "#,##0", "Crore"),
    ("Rupees in one lakh", 100000, "#,##0", "Lakh"),
]
for i, (lbl, v, fmt, nm) in enumerate(assumptions):
    inp.cell(21 + i, 1, lbl)
    c = inp.cell(21 + i, 5, v)
    c.number_format = fmt
    c.fill = IN_FILL
    c.border = BOX
    name(wb, nm, f"Inputs!$E${21 + i}")
name(wb, "Recovery_Officers", "Inputs!$E$21")

inp["A30"] = "Age bands: EMIs fallen due by 31 Oct 2026"
inp["A30"].font = Font(bold=True)
header(inp, 31, 1, ["from_emis", "band"])
bands = [(0, "01-03"), (4, "04-06"), (7, "07-12"), (13, "13-18"), (19, "19-24"), (25, "25+")]
for i, (a, b) in enumerate(bands):
    inp.cell(32 + i, 1, a)
    inp.cell(32 + i, 2, b)
name(wb, "Band_From", "Inputs!$A$32:$A$37")
name(wb, "Band_Name", "Inputs!$B$32:$B$37")
inp.column_dimensions["A"].width = 30
for c in "BCDEFGHIJK":
    inp.column_dimensions[c].width = 15

# ---------------------------------------------------------------------
# Data_Loans: results/loan_level.csv + helper columns (formulas)
# ---------------------------------------------------------------------
hdr, rows = read_csv("loan_level.csv")
write_table(dl, hdr, rows)
N = len(rows)
last = N + 1
col = {h: L(i + 1) for i, h in enumerate(hdr)}
helpers = ["in_view", "prov_rate", "provision", "npa_rate", "stress_unit", "stress_extra", "officer_limit",
           "above_limit", "npa_os", "at_stake", "age_band", "watch_key", "breach_key", "sma2_os", "sma1_os"]
h0 = len(hdr) + 1
for i, h in enumerate(helpers):
    col[h] = L(h0 + i)
header(dl, 1, h0, helpers, fill=PatternFill("solid", fgColor="7F6000"))
c = col
for r in range(2, last + 1):
    f = {
        "in_view": f'=IF(AND(OR(Sel_Region="All",{c["region_name"]}{r}=Sel_Region),OR(Sel_Product="All",{c["product_code"]}{r}=Sel_Product),'
                   f'OR(Sel_Bank="All",{c["source_bank"]}{r}=Sel_Bank),OR(Sel_Channel="All",{c["sourcing_channel"]}{r}=Sel_Channel)),1,0)',
        "prov_rate": f'=IF({c["secured_flag"]}{r}="Y",INDEX(Prov_Secured,MATCH({c["category_31oct"]}{r},Prov_Cat,0)),INDEX(Prov_Unsecured,MATCH({c["category_31oct"]}{r},Prov_Cat,0)))',
        "provision": f'={c["outstanding_principal"]}{r}*{c["prov_rate"]}{r}',
        "npa_rate": f'=IF({c["secured_flag"]}{r}="Y",INDEX(Prov_Secured,MATCH("NPA",Prov_Cat,0)),INDEX(Prov_Unsecured,MATCH("NPA",Prov_Cat,0)))',
        "stress_unit": f'=IF({c["category_31oct"]}{r}="SMA-2",{c["outstanding_principal"]}{r}*({c["npa_rate"]}{r}-{c["prov_rate"]}{r}),0)',
        "stress_extra": f'={c["stress_unit"]}{r}*Slippage',
        "officer_limit": f'=IF({c["officer_grade"]}{r}="","",INDEX(Deleg_Limits,MATCH({c["officer_grade"]}{r},Deleg_Grades,0),MATCH({c["product_code"]}{r},Deleg_Products,0)))',
        "above_limit": f'=IF(ISNUMBER({c["officer_limit"]}{r}),IF({c["sanction_amount"]}{r}>{c["officer_limit"]}{r},1,0),0)',
        "npa_os": f'=IF({c["category_31oct"]}{r}="NPA",{c["outstanding_principal"]}{r},0)',
        "at_stake": f'=IF(OR({c["category_31oct"]}{r}="NPA",{c["category_31oct"]}{r}="SMA-1",{c["category_31oct"]}{r}="SMA-2"),{c["outstanding_principal"]}{r},0)',
        "age_band": f'=LOOKUP({c["emis_due_by_31oct"]}{r},Band_From,Band_Name)',
        "watch_key": f'=IF(AND({c["in_view"]}{r}=1,OR({c["became_npa_october"]}{r}="Y",{c["category_31oct"]}{r}="SMA-2")),{c["outstanding_principal"]}{r}+ROW()/Crore,0)',
        "breach_key": f'=IF(AND({c["in_view"]}{r}=1,{c["above_limit"]}{r}=1),ROW(),"")',
        "sma2_os": f'=IF({c["category_31oct"]}{r}="SMA-2",{c["outstanding_principal"]}{r},0)',
        "sma1_os": f'=IF({c["category_31oct"]}{r}="SMA-1",{c["outstanding_principal"]}{r},0)',
    }
    for h in helpers:
        dl[f"{c[h]}{r}"] = f[h]
for h in hdr + helpers:
    name(wb, "L_" + h, f"Data_Loans!${c[h]}$2:${c[h]}${last}")
dl.freeze_panes = "B2"
for i in range(1, h0 + len(helpers)):
    dl.column_dimensions[L(i)].width = 13

# ---------------------------------------------------------------------
# Data_Branches and Data_Stage2: other result files used for checks/labels
# ---------------------------------------------------------------------
bh, br = read_csv("branch_summary.csv")
write_table(db, bh, br)
bcol = {h: L(i + 1) for i, h in enumerate(bh)}
NB = len(br)
for h in bh:
    name(wb, "B_" + h, f"Data_Branches!${bcol[h]}$2:${bcol[h]}${NB + 1}")
db.freeze_panes = "C2"

r0 = 1
blocks = {}
for fname in ["headline.csv", "npa_bridge.csv", "cause_codes.csv", "claim_tests.csv", "movement_matrix.csv", "red_flags.csv"]:
    h, rr = read_csv(fname)
    ds.cell(r0, 1, fname).font = Font(bold=True, size=12, color=NAVY)
    write_table(ds, h, rr, r0 + 1, 1)
    blocks[fname] = (r0 + 2, r0 + 1 + len(rr), {x: L(i + 1) for i, x in enumerate(h)})
    r0 += len(rr) + 4
ds.column_dimensions["A"].width = 45
ds.column_dimensions["B"].width = 60

# ---------------------------------------------------------------------
# Lists for the dashboard drop-downs
# ---------------------------------------------------------------------
def uniq(h):
    return sorted({row[hdr.index(h)] for row in rows if row[hdr.index(h)]})

for j, (h, title) in enumerate([("region_name", "Region"), ("product_code", "Product"),
                                ("source_bank", "Source bank"), ("sourcing_channel", "Sourcing channel")]):
    vals = ["All"] + uniq(h)
    lists.cell(1, 1 + j, title).font = Font(bold=True)
    for i, v in enumerate(vals):
        lists.cell(2 + i, 1 + j, v)
    name(wb, f"List_{j}", f"Lists!${L(1 + j)}$2:${L(1 + j)}${1 + len(vals)}")

# ---------------------------------------------------------------------
# Calc: every panel's numbers (follow the dashboard filters via in_view)
# ---------------------------------------------------------------------
calc["A1"] = "CALCULATIONS - formulas only. All follow the dashboard filters (L_in_view = 1)."
calc["A1"].font = Font(bold=True, size=13, color=NAVY)
IV = "L_in_view,1"


def cr(expr):  # rupees -> crore
    return f"=({expr})/Crore"


# KPIs
kpis = [
    ("Loans in view", f"=SUMIFS(L_in_view,{IV})", "#,##0"),
    ("Book outstanding (Rs cr)", cr(f"SUMIFS(L_outstanding_principal,{IV})"), "#,##0.00"),
    ("TRUE NPA (Rs cr)", cr(f"SUMIFS(L_npa_os,{IV})"), "#,##0.00"),
    ("TRUE gross NPA %", f'=IFERROR(SUMIFS(L_npa_os,{IV})/SUMIFS(L_outstanding_principal,{IV}),0)', "0.00%"),
    ("Finance gross NPA %", f'=IFERROR(SUMIFS(L_outstanding_principal,{IV},L_finance_class,"NPA")/SUMIFS(L_outstanding_principal,{IV}),0)', "0.00%"),
    ("Risk gross NPA %", f'=IFERROR(SUMIFS(L_outstanding_principal,{IV},L_risk_class,"NPA")/SUMIFS(L_outstanding_principal,{IV}),0)', "0.00%"),
    ("Provision required today (Rs cr)", cr(f"SUMIFS(L_provision,{IV})"), "#,##0.00"),
    ("Extra provision if SMA-2 slips (Rs cr)", cr(f"SUMIFS(L_stress_extra,{IV})"), "#,##0.00"),
    ("Provision after slippage (Rs cr)", "=B9+B10", "#,##0.00"),
    ("SMA-2 outstanding (Rs cr)", cr(f"SUMIFS(L_sma2_os,{IV})"), "#,##0.00"),
    ("NPA borrowers' loans", f'=COUNTIFS(L_in_view,1,L_category_31oct,"NPA")', "#,##0"),
    ("Loans above officer's limit", f"=SUMIFS(L_above_limit,{IV})", "#,##0"),
    ("Rs approved above limit (cr)", cr(f"SUMIFS(L_sanction_amount,{IV},L_above_limit,1)"), "#,##0.00"),
    ("Became NPA in October (Rs cr)", cr(f'SUMIFS(L_outstanding_principal,{IV},L_became_npa_october,"Y")'), "#,##0.00"),
    ("Recovery officers", "=Recovery_Officers", "0"),
]
header(calc, 2, 1, ["KPI", "value"])
K = {}
for i, (lbl, f, fmt) in enumerate(kpis):
    calc.cell(3 + i, 1, lbl)
    cc = calc.cell(3 + i, 2, f)
    cc.number_format = fmt
    K[lbl] = f"Calc!$B${3 + i}"

# Branch table (40 branches)
BR0 = 21
calc.cell(BR0 - 1, 1, "Branches (filtered)").font = Font(bold=True)
bhdr = ["branch_ifsc", "branch_name", "region", "outstanding", "npa_os", "sma2_os", "at_stake", "provision",
        "stress_extra", "above_limit_loans", "npa_pct", "prov_key", "npa_key", "stake_key", "total_prov"]
header(calc, BR0, 1, bhdr)
for i, row in enumerate(br):
    r = BR0 + 1 + i
    calc.cell(r, 1, row[bh.index("branch_ifsc")])
    calc.cell(r, 2, row[bh.index("branch_name")])
    calc.cell(r, 3, row[bh.index("region_name")])
    s = lambda fld: f"=SUMIFS({fld},L_branch_ifsc,$A{r},{IV})"
    calc.cell(r, 4, s("L_outstanding_principal"))
    calc.cell(r, 5, s("L_npa_os"))
    calc.cell(r, 6, s("L_sma2_os"))
    calc.cell(r, 7, s("L_at_stake"))
    calc.cell(r, 8, s("L_provision"))
    calc.cell(r, 9, s("L_stress_extra"))
    calc.cell(r, 10, s("L_above_limit"))
    calc.cell(r, 11, f"=IFERROR(E{r}/D{r},0)")
    calc.cell(r, 12, f"=H{r}+I{r}+ROW()/Crore")
    calc.cell(r, 13, f"=E{r}+ROW()/Crore")
    calc.cell(r, 14, f"=G{r}+ROW()/Crore")
    calc.cell(r, 15, f"=H{r}+I{r}")
BR1 = BR0 + NB
for cl in "DEFGHIO":
    for r in range(BR0 + 1, BR1 + 1):
        calc[f"{cl}{r}"].number_format = "#,##0"
for r in range(BR0 + 1, BR1 + 1):
    calc[f"K{r}"].number_format = "0.00%"

# Top-10 tables for charts: by provision, by NPA, by rupees at stake
T0 = BR1 + 3


def top10(r_start, title, key_col, cols):
    calc.cell(r_start - 1, 1, title).font = Font(bold=True)
    header(calc, r_start, 1, ["rank", "branch"] + [c_[0] for c_ in cols])
    for k in range(1, 11):
        r = r_start + k
        calc.cell(r, 1, k)
        rng = f"${key_col}${BR0 + 1}:${key_col}${BR1}"
        m = f"MATCH(LARGE({rng},$A{r}),{rng},0)"
        calc.cell(r, 2, f"=INDEX($B${BR0 + 1}:$B${BR1},{m})")
        for j, (_, src, fmt) in enumerate(cols):
            cc = calc.cell(r, 3 + j, f"=INDEX(${src}${BR0 + 1}:${src}${BR1},{m}){'/Crore' if fmt == 'cr' else ''}")
            cc.number_format = "0.00" if fmt == "cr" else ("0.0%" if fmt == "pct" else "#,##0")
    return r_start + 1, r_start + 10


P1 = top10(T0, "Top 10 branches by provision (Rs cr)", "L",
           [("Provision today", "H", "cr"), ("Extra if SMA-2 slips", "I", "cr")])
P2 = top10(T0 + 14, "Top 10 branches by NPA (Rs cr)", "M", [("NPA Rs cr", "E", "cr"), ("NPA %", "K", "pct")])
W1 = top10(T0 + 28, "Top 10 branches by rupees at stake (NPA + SMA-1 + SMA-2)", "N",
           [("At stake Rs cr", "G", "cr"), ("NPA %", "K", "pct"), ("Region", "C", "txt"), ("IFSC", "A", "txt")])

# Concentration
C0 = T0 + 42
calc.cell(C0, 1, "Share of NPA rupees in the top 5 branches")
calc.cell(C0, 2, f"=IFERROR(SUM(C{P2[0]}:C{P2[0] + 4})*Crore/SUMIFS(L_npa_os,{IV}),0)").number_format = "0.0%"
calc.cell(C0 + 1, 1, "Share of the book in those 5 branches")
calc.cell(C0 + 1, 2, f"=IFERROR(SUMPRODUCT(SUMIFS(D{BR0 + 1}:D{BR1},B{BR0 + 1}:B{BR1},B{P2[0]}:B{P2[0] + 4}))/SUMIFS(L_outstanding_principal,{IV}),0)").number_format = "0.0%"
K["top5_npa_share"] = f"Calc!$B${C0}"
K["top5_book_share"] = f"Calc!$B${C0 + 1}"

# Product table
PR0 = C0 + 4
calc.cell(PR0 - 1, 1, "Products (filtered)").font = Font(bold=True)
header(calc, PR0, 1, ["product", "outstanding cr", "NPA cr", "NPA %", "SMA-1+2 cr"])
for i, p in enumerate(["HL", "LAP", "VL", "GL", "PL", "MSME"]):
    r = PR0 + 1 + i
    calc.cell(r, 1, p)
    calc.cell(r, 2, cr(f"SUMIFS(L_outstanding_principal,L_product_code,$A{r},{IV})")).number_format = "0.00"
    calc.cell(r, 3, cr(f"SUMIFS(L_npa_os,L_product_code,$A{r},{IV})")).number_format = "0.00"
    calc.cell(r, 4, f"=IFERROR(C{r}/B{r},0)").number_format = "0.0%"
    calc.cell(r, 5, cr(f"SUMIFS(L_sma1_os,L_product_code,$A{r},{IV})+SUMIFS(L_sma2_os,L_product_code,$A{r},{IV})")).number_format = "0.00"
PROD = (PR0 + 1, PR0 + 6)

# Category on both dates (Rs cr at 31 Oct balances) - panel 3
CA0 = PR0 + 10
calc.cell(CA0 - 1, 1, "Book by category, 30 Sep vs 31 Oct (Rs cr, 31 Oct balances)").font = Font(bold=True)
header(calc, CA0, 1, ["date"] + CATS)
for i, (lbl, fld) in enumerate([("30 Sep 2026", "L_category_30sep"), ("31 Oct 2026", "L_category_31oct")]):
    r = CA0 + 1 + i
    calc.cell(r, 1, lbl)
    for j, cat in enumerate(CATS):
        calc.cell(r, 2 + j, cr(f'SUMIFS(L_outstanding_principal,{fld},"{cat}",{IV})')).number_format = "0.00"

# Movement matrix (loans)
MV0 = CA0 + 5
calc.cell(MV0 - 1, 1, "Movement Sep -> Oct (number of loans; rows = 30 Sep, columns = 31 Oct)").font = Font(bold=True)
header(calc, MV0, 1, ["30 Sep \\ 31 Oct"] + CATS)
for i, a in enumerate(CATS + ["(new in Oct)"]):
    r = MV0 + 1 + i
    calc.cell(r, 1, a)
    crit = f'L_category_30sep,"{a}"' if a != "(new in Oct)" else 'L_category_30sep,""'
    for j, b in enumerate(CATS):
        calc.cell(r, 2 + j, f'=COUNTIFS({crit},L_category_31oct,"{b}",{IV})')
K["roll_sma2_npa"] = f"Calc!$F${MV0 + 4}"
calc.cell(MV0 + 8, 1, "SMA-2 on 30 Sep that became NPA by 31 Oct")
calc.cell(MV0 + 8, 2, f"=IFERROR(F{MV0 + 4}/SUM(B{MV0 + 4}:F{MV0 + 4}),0)").number_format = "0%"
calc.cell(MV0 + 9, 1, "SMA-1 on 30 Sep that got worse by 31 Oct")
calc.cell(MV0 + 9, 2, f"=IFERROR(SUM(E{MV0 + 3}:F{MV0 + 3})/SUM(B{MV0 + 3}:F{MV0 + 3}),0)").number_format = "0%"
K["sma2_roll"] = f"Calc!$B${MV0 + 8}"
K["sma1_roll"] = f"Calc!$B${MV0 + 9}"

# Age curves: share of loans 30+ DPD by EMIs fallen due
AG0 = MV0 + 13
calc.cell(AG0 - 1, 1, "Share of loans 30+ days late, by age (EMIs fallen due)").font = Font(bold=True)
header(calc, AG0, 1, ["age band", "Month-end sanction", "Other days", "Digital partner (PL)", "Branch (PL)"])
for i, (_, b) in enumerate(bands):
    r = AG0 + 1 + i
    calc.cell(r, 1, b)
    defs = [('L_month_end_sanction,"Y"',), ('L_month_end_sanction,"N"',),
            ('L_sourcing_channel,"Digital Partner",L_product_code,"PL"',), ('L_sourcing_channel,"Branch",L_product_code,"PL"',)]
    for j, (crit,) in enumerate(defs):
        calc.cell(r, 2 + j, f'=IFERROR(COUNTIFS(L_age_band,$A{r},{crit},L_late30_31oct,"Y",{IV})/COUNTIFS(L_age_band,$A{r},{crit},{IV}),NA())').number_format = "0.0%"
AGE = (AG0 + 1, AG0 + 6)

# NPA bridge: Finance -> causes -> TRUE -> Risk causes -> Risk
chh, chr_ = read_csv("cause_codes.csv")
fin_codes = sorted([x for x in chr_ if x[2] == "Finance"])
risk_codes = sorted([x for x in chr_ if x[2] == "Risk"])
BG0 = AG0 + 10
calc.cell(BG0 - 1, 1, "Bridge: Finance 3.1% -> TRUE -> Risk 4.4% (Rs cr). Invisible/Up/Down drive the waterfall chart.").font = Font(bold=True)
header(calc, BG0, 1, ["step", "change Rs cr", "level Rs cr", "level %", "invisible", "up", "down", "total", "label"])
steps = [("Finance (CBS flag)", "start", f'SUMIFS(L_outstanding_principal,L_finance_class,"NPA",{IV})')]
short = {"F1": "Stale NPA flag", "F2": "Pavanpur loans >90 DPD flagged STD", "F3": "Meridian loans >90 DPD flagged STD",
         "F4": "Borrower rule (same customer)", "F5": "Borrower rule across merger",
         "R1": "Bounced NACH paid later", "R2": "Vendor's false name matches", "R3": "Spread from non-NPA loans",
         "R4": "Day count 1 short", "R5": "Other", "R6": "Missed identity links"}
for code, cause, _ in fin_codes:
    sign = "-" if code == "F1" else ""
    steps.append((short.get(code, code), "delta", f'{sign}SUMIFS(L_outstanding_principal,L_finance_cause_code,"{code}",{IV})'))
steps.append(("TRUE NPA", "total", f"SUMIFS(L_npa_os,{IV})"))
for code, cause, _ in risk_codes:
    sign = "-" if code == "R6" else ""
    steps.append((short.get(code, code), "delta", f'{sign}SUMIFS(L_outstanding_principal,L_risk_cause_code,"{code}",{IV})'))
steps.append(("Risk (as reported)", "total", f'SUMIFS(L_outstanding_principal,L_risk_class,"NPA",{IV})'))
for i, (lbl, kind, expr) in enumerate(steps):
    r = BG0 + 1 + i
    calc.cell(r, 1, lbl)
    calc.cell(r, 2, cr(expr)).number_format = "0.00"
    if kind in ("start", "total"):
        calc.cell(r, 3, f"=B{r}")
        calc.cell(r, 5, 0)
        calc.cell(r, 6, 0)
        calc.cell(r, 7, 0)
        calc.cell(r, 8, f"=B{r}")
    else:
        calc.cell(r, 3, f"=C{r - 1}+B{r}")
        calc.cell(r, 5, f"=MIN(C{r - 1},C{r})")
        calc.cell(r, 6, f"=MAX(B{r},0)")
        calc.cell(r, 7, f"=MAX(-B{r},0)")
        calc.cell(r, 8, 0)
    calc.cell(r, 4, f"=IFERROR(C{r}*Crore/SUMIFS(L_outstanding_principal,{IV}),0)").number_format = "0.00%"
    fmt_ = '"0.00"' if kind in ("start", "total") else '"+0.00;-0.00"'
    calc.cell(r, 9, f'=A{r}&" "&TEXT(B{r},{fmt_})')
    for cl in "CEFGH":
        calc[f"{cl}{r}"].number_format = "0.00"
BG = (BG0 + 1, BG0 + len(steps))
K["bridge_true_row"] = BG0 + 1 + len(fin_codes) + 1

# Sensitivity: provision as the SMA-2 slippage assumption moves
SE0 = BG[1] + 4
calc.cell(SE0 - 1, 1, "Provision (Rs cr) if this share of today's SMA-2 turns NPA next month").font = Font(bold=True)
header(calc, SE0, 1, ["slippage", "provision Rs cr"])
for i in range(11):
    r = SE0 + 1 + i
    calc.cell(r, 1, i / 10).number_format = "0%"
    calc.cell(r, 2, cr(f"SUMIFS(L_provision,{IV})+A{r}*SUMIFS(L_stress_unit,{IV})")).number_format = "0.00"
SENS = (SE0 + 1, SE0 + 11)

# Watchlist loans (became NPA in October or SMA-2), largest first
WL0 = SE0 + 15
calc.cell(WL0 - 1, 1, "Loans to act on first: became NPA in October or SMA-2 (largest first)").font = Font(bold=True)
wl_cols = [("loan", "loan_id"), ("branch", "branch_name"), ("product", "product_code"),
           ("category", "category_31oct"), ("DPD", "dpd_31oct"), ("Rs lakh", "outstanding_principal"),
           ("officer", "sanctioning_officer_id")]
header(calc, WL0, 1, ["rank"] + [a for a, _ in wl_cols])
for k in range(1, 11):
    r = WL0 + k
    calc.cell(r, 1, k)
    m = f"MATCH(LARGE(L_watch_key,$A{r}),L_watch_key,0)"
    for j, (_, h) in enumerate(wl_cols):
        v = f"=IFERROR(INDEX(L_{h},{m}){'/Lakh' if h == 'outstanding_principal' else ''},\"\")"
        cc = calc.cell(r, 2 + j, v)
        if h == "outstanding_principal":
            cc.number_format = "0.0"
WL = (WL0 + 1, WL0 + 10)

# Officers with loans above their limit (filtered)
OF0 = WL0 + 14
calc.cell(OF0 - 1, 1, "Officers who approved loans above their delegated limit").font = Font(bold=True)
oh, orows = read_csv("officer_summary.csv")
header(calc, OF0, 1, ["officer", "name", "grade", "home branch", "loans above limit", "Rs above-limit sanctioned cr",
                      "of which NPA now", "key"])
for i, row in enumerate(orows):
    r = OF0 + 1 + i
    calc.cell(r, 1, row[oh.index("officer_id")])
    calc.cell(r, 2, row[oh.index("officer_name")])
    calc.cell(r, 3, row[oh.index("grade")])
    calc.cell(r, 4, row[oh.index("home_branch")])
    calc.cell(r, 5, f"=SUMIFS(L_above_limit,L_sanctioning_officer_id,$A{r},{IV})")
    calc.cell(r, 6, cr(f"SUMIFS(L_sanction_amount,L_sanctioning_officer_id,$A{r},L_above_limit,1,{IV})")).number_format = "0.00"
    calc.cell(r, 7, f'=COUNTIFS(L_sanctioning_officer_id,$A{r},L_above_limit,1,L_category_31oct,"NPA",{IV})')
    calc.cell(r, 8, f"=E{r}+ROW()/Crore")
OF1 = OF0 + len(orows)
TOPOF0 = OF1 + 3
calc.cell(TOPOF0 - 1, 1, "Top 5 officers by loans above limit").font = Font(bold=True)
header(calc, TOPOF0, 1, ["rank", "officer", "name", "grade", "home branch", "above limit", "Rs cr", "NPA now"])
for k in range(1, 6):
    r = TOPOF0 + k
    calc.cell(r, 1, k)
    m = f"MATCH(LARGE($H${OF0 + 1}:$H${OF1},$A{r}),$H${OF0 + 1}:$H${OF1},0)"
    for j, src in enumerate("ABCDEFG"):
        cc = calc.cell(r, 2 + j, f"=INDEX(${src}${OF0 + 1}:${src}${OF1},{m})")
        if src == "F":
            cc.number_format = "0.00"
TOPOF = (TOPOF0 + 1, TOPOF0 + 5)
calc.column_dimensions["A"].width = 38
calc.column_dimensions["B"].width = 26
for cl in "CDEFGHIJKLMNO":
    calc.column_dimensions[cl].width = 14

# ---------------------------------------------------------------------
# Recovery_Plan: zone-wide (not filtered) - officers and lending powers
# ---------------------------------------------------------------------
plan["A1"] = "RECOVERY PLAN - zone-wide, all filters ignored. Assumptions on the Inputs sheet."
plan["A1"].font = Font(bold=True, size=13, color=NAVY)
plan["A3"] = "Split of the recovery officers by region: in proportion to recovery workload = NPA + SMA-2 + (SMA-1 x weight) rupees"
header(plan, 4, 1, ["region", "NPA Rs cr", "SMA-2 Rs cr", "SMA-1 Rs cr", "workload Rs cr", "share", "exact quota",
                    "whole officers", "remainder", "extra", "OFFICERS"])
regions = uniq("region_name")
for i, rg in enumerate(regions):
    r = 5 + i
    plan.cell(r, 1, rg)
    plan.cell(r, 2, cr(f'SUMIFS(L_npa_os,L_region_name,$A{r})'))
    plan.cell(r, 3, cr(f'SUMIFS(L_sma2_os,L_region_name,$A{r})'))
    plan.cell(r, 4, cr(f'SUMIFS(L_sma1_os,L_region_name,$A{r})'))
    plan.cell(r, 5, f"=B{r}+C{r}+D{r}*SMA1_Weight")
    plan.cell(r, 6, f"=E{r}/SUM($E$5:$E${4 + len(regions)})").number_format = "0.0%"
    plan.cell(r, 7, f"=F{r}*Recovery_Officers").number_format = "0.00"
    plan.cell(r, 8, f"=INT(G{r})")
    plan.cell(r, 9, f"=G{r}-H{r}+ROW()/Crore").number_format = "0.000"
    plan.cell(r, 10, f"=IF(RANK(I{r},$I$5:$I${4 + len(regions)})<=Recovery_Officers-SUM($H$5:$H${4 + len(regions)}),1,0)")
    plan.cell(r, 11, f"=H{r}+J{r}").font = Font(bold=True)
    for cl in "BCDE":
        plan[f"{cl}{r}"].number_format = "0.00"
RG1 = 4 + len(regions)
plan.cell(RG1 + 1, 1, "Total").font = Font(bold=True)
plan.cell(RG1 + 1, 11, f"=SUM(K5:K{RG1})").font = Font(bold=True)
for cl in "BCDE":
    plan.cell(RG1 + 1, " ABCDEFGHIJK".index(cl), f"=SUM({cl}5:{cl}{RG1})").number_format = "0.00"

PB0 = RG1 + 4
plan.cell(PB0 - 1, 1, "Branch test: who should lose independent lending powers, and where each region's officers go").font = Font(bold=True)
pbh = ["branch_ifsc", "branch", "region", "origin", "loans", "outstanding cr", "NPA cr", "NPA %", "x zone",
       "CE Aug-Oct avg", "CE May", "CE Oct", "loans above limit", "test A: high NPA + weak collection",
       "test B: limit breaches", "LOSE LENDING POWERS?", "workload cr", "quota", "whole", "remainder key",
       "extra", "OFFICERS", "FY27 target cr"]
header(plan, PB0, 1, pbh)
for i, row in enumerate(br):
    r = PB0 + 1 + i
    g = lambda h: row[bh.index(h)]
    plan.cell(r, 1, g("branch_ifsc"))
    plan.cell(r, 2, g("branch_name"))
    plan.cell(r, 3, g("region_name"))
    plan.cell(r, 4, g("branch_origin"))
    plan.cell(r, 5, f"=COUNTIFS(L_branch_ifsc,$A{r})")
    plan.cell(r, 6, cr(f"SUMIFS(L_outstanding_principal,L_branch_ifsc,$A{r})")).number_format = "0.00"
    plan.cell(r, 7, cr(f"SUMIFS(L_npa_os,L_branch_ifsc,$A{r})")).number_format = "0.00"
    plan.cell(r, 8, f"=G{r}/F{r}").number_format = "0.0%"
    plan.cell(r, 9, f"=H{r}/(SUM(L_npa_os)/SUM(L_outstanding_principal))").number_format = "0.0x"
    plan.cell(r, 10, f"=AVERAGE(INDEX(B_ce_2026_08,MATCH($A{r},B_branch_ifsc,0)),INDEX(B_ce_2026_09,MATCH($A{r},B_branch_ifsc,0)),INDEX(B_ce_2026_10,MATCH($A{r},B_branch_ifsc,0)))/100").number_format = "0.0%"
    plan.cell(r, 11, f"=INDEX(B_ce_2026_05,MATCH($A{r},B_branch_ifsc,0))/100").number_format = "0.0%"
    plan.cell(r, 12, f"=INDEX(B_ce_2026_10,MATCH($A{r},B_branch_ifsc,0))/100").number_format = "0.0%"
    plan.cell(r, 13, f"=SUMIFS(L_above_limit,L_branch_ifsc,$A{r})")
    plan.cell(r, 14, f'=IF(AND(I{r}>=LP_NPA_Multiple,J{r}<LP_CE_Floor),"FAIL","pass")')
    plan.cell(r, 15, f'=IF(M{r}>=LP_Breach_Count,"FAIL","pass")')
    plan.cell(r, 16, f'=IF(OR(N{r}="FAIL",O{r}="FAIL"),"YES","no")').font = Font(bold=True)
    plan.cell(r, 17, cr(f"SUMIFS(L_npa_os,L_branch_ifsc,$A{r})+SUMIFS(L_sma2_os,L_branch_ifsc,$A{r})+SMA1_Weight*SUMIFS(L_sma1_os,L_branch_ifsc,$A{r})")).number_format = "0.00"
    # Region's officers shared among its branches by workload, whole
    # officers by largest remainder inside the region.
    rr_ = f"$C${PB0 + 1}:$C${PB0 + NB}"
    plan.cell(r, 18, f"=INDEX($K$5:$K${RG1},MATCH($C{r},$A$5:$A${RG1},0))*Q{r}/SUMIFS($Q${PB0 + 1}:$Q${PB0 + NB},{rr_},$C{r})").number_format = "0.00"
    plan.cell(r, 19, f"=INT(R{r})")
    plan.cell(r, 20, f"=R{r}-S{r}+ROW()/Crore").number_format = "0.000"
    plan.cell(r, 21, f"=IF(COUNTIFS({rr_},$C{r},$T${PB0 + 1}:$T${PB0 + NB},\">\"&T{r})+1<=INDEX($K$5:$K${RG1},MATCH($C{r},$A$5:$A${RG1},0))-SUMIFS($S${PB0 + 1}:$S${PB0 + NB},{rr_},$C{r}),1,0)")
    plan.cell(r, 22, f"=S{r}+U{r}").font = Font(bold=True)
    plan.cell(r, 23, f"=IFERROR(INDEX(Target_Amount,MATCH($A{r},Target_IFSC,0))/Crore,0)").number_format = "0.00"
PB1 = PB0 + NB
plan.cell(PB1 + 2, 1, "Branches that lose lending powers")
plan.cell(PB1 + 2, 6, f'=COUNTIF(P{PB0 + 1}:P{PB1},"YES")').font = Font(bold=True)
plan.cell(PB1 + 3, 1, "Their outstanding (Rs cr)")
plan.cell(PB1 + 3, 6, f'=SUMIFS(F{PB0 + 1}:F{PB1},P{PB0 + 1}:P{PB1},"YES")').number_format = "0.00"
plan.cell(PB1 + 4, 1, "Their FY27 disbursal target (Rs cr) that must now go to the regional credit committee")
plan.cell(PB1 + 4, 6, f'=SUMIFS(W{PB0 + 1}:W{PB1},P{PB0 + 1}:P{PB1},"YES")').number_format = "0.00"
plan.cell(PB1 + 5, 1, "Officers placed (must equal the officers available)")
plan.cell(PB1 + 5, 6, f"=SUM(V{PB0 + 1}:V{PB1})").font = Font(bold=True)
plan.column_dimensions["A"].width = 22
plan.column_dimensions["B"].width = 28
for i in range(3, 24):
    plan.column_dimensions[L(i)].width = 12
plan.freeze_panes = f"C{PB0 + 1}"
K["lp_count"] = f"Recovery_Plan!$F${PB1 + 2}"
K["lp_os"] = f"Recovery_Plan!$F${PB1 + 3}"
LPR = (PB0 + 1, PB1)

# ---------------------------------------------------------------------
# Delegation: every loan approved above its officer's limit (filtered)
# ---------------------------------------------------------------------
deleg["A1"] = "EVERY LOAN APPROVED ABOVE ITS OFFICER'S LIMIT (follows the dashboard filters)"
deleg["A1"].font = Font(bold=True, size=13, color=NAVY)
deleg["A2"] = "Limit = delegation_matrix.xlsx for the officer's grade and the loan's product."
dcols = ["loan_id", "branch_name", "product_code", "sanctioning_officer_id", "officer_grade", "sanction_date",
         "sanction_amount", "officer_limit", "category_31oct", "outstanding_principal", "month_end_sanction"]
header(deleg, 4, 1, ["#"] + dcols + ["Rs above limit"])
for k in range(1, 81):
    r = 4 + k
    deleg.cell(r, 1, k)
    rowref = f"AGGREGATE(15,6,L_breach_key,$A{r})"
    for j, h in enumerate(dcols):
        cc = deleg.cell(r, 2 + j, f'=IFERROR(INDEX(Data_Loans!${c[h]}:${c[h]},{rowref}),"")')
        if h in ("sanction_amount", "officer_limit", "outstanding_principal"):
            cc.number_format = "#,##0"
        if h == "sanction_date":
            cc.number_format = "dd-mmm-yyyy"
    deleg.cell(r, 2 + len(dcols), f'=IFERROR(H{r}-I{r},"")').number_format = "#,##0"
for i in range(1, 15):
    deleg.column_dimensions[L(i)].width = 15

# ---------------------------------------------------------------------
# Checks: workbook totals vs the Stage 2 result files (filters = All)
# ---------------------------------------------------------------------
chk["A1"] = "CHECKS - every headline ties to the Stage 2 results to the rupee (independent of filters)"
chk["A1"].font = Font(bold=True, size=13, color=NAVY)
header(chk, 3, 1, ["check", "workbook (Rs)", "Stage 2 result file (Rs)", "difference", "OK?"])
hs, he, hc = blocks["headline.csv"]
bs, be, bc = blocks["npa_bridge.csv"]


def hl(measure):
    return f'SUMIFS(Data_Stage2!$C${hs}:$C${he},Data_Stage2!$A${hs}:$A${he},"{measure}")'


checks = [
    ("Total book", "SUM(L_outstanding_principal)", hl("Total book 31 Oct 2026")),
    ("TRUE NPA", "SUM(L_npa_os)", hl("TRUE gross NPA (borrower rule, verified payments)")),
    ("Finance NPA", 'SUMIFS(L_outstanding_principal,L_finance_class,"NPA")', hl("Finance gross NPA (as reported)")),
    ("Risk NPA", 'SUMIFS(L_outstanding_principal,L_risk_class,"NPA")', hl("Risk gross NPA (as reported)")),
    ("SMA-2 31 Oct", "SUM(L_sma2_os)", hl("True SMA-2 31 Oct")),
    ("Finance->TRUE corrections", 'SUMIFS(L_outstanding_principal,L_finance_cause_code,"<>",L_category_31oct,"NPA")-SUMIFS(L_outstanding_principal,L_finance_cause_code,"<>",L_category_31oct,"<>NPA")',
     f"SUMIFS(Data_Stage2!$E${bs}:$E${be},Data_Stage2!$A${bs}:$A${be},\">1\",Data_Stage2!$A${bs}:$A${be},\"<10\")"),
]
for i, (lbl, a, b) in enumerate(checks):
    r = 4 + i
    chk.cell(r, 1, lbl)
    chk.cell(r, 2, f"={a}").number_format = "#,##0.00"
    chk.cell(r, 3, f"={b}").number_format = "#,##0.00"
    chk.cell(r, 4, f"=ROUND(B{r}-C{r},2)").number_format = "#,##0.00"
    chk.cell(r, 5, f'=IF(D{r}=0,"OK","CHECK")')
chk.cell(4 + len(checks) + 1, 1, "All checks")
chk.cell(4 + len(checks) + 1, 5, f'=IF(COUNTIF(E4:E{3 + len(checks)},"OK")={len(checks)},"ALL OK","CHECK")').font = Font(bold=True)
K["checks"] = f"Checks!$E${4 + len(checks) + 1}"
chk.column_dimensions["A"].width = 30
for cl in "BCD":
    chk.column_dimensions[cl].width = 22

# ---------------------------------------------------------------------
# DASHBOARD (one page)
# ---------------------------------------------------------------------
d = dash
for i in range(1, 27):
    d.column_dimensions[L(i)].width = 9.5
d.column_dimensions["A"].width = 2
d.sheet_view.showGridLines = False
d["B1"] = "Hubballi Zone: 3.73% of the loan book is truly bad - Finance (3.1%) misses Rs 6.3 cr, Risk (4.4%) adds Rs 6.7 cr that is not bad"
d["B1"].font = Font(bold=True, size=18, color=NAVY)
d["B2"] = ("CRO dashboard for the Board risk committee, 14 Dec 2026 · Loans at 31 Oct 2026 · Source: Stage 2 results "
           "(true DPD from EMIs and cleared payments, RBI borrower rule) · Change the yellow cells: every panel follows")
d["B2"].font = Font(italic=True, size=9, color="595959")

# Controls (inputs)
d["B4"] = "FILTERS & ASSUMPTION"
d["B4"].font = Font(bold=True, color="FFFFFF")
d["B4"].fill = PatternFill("solid", fgColor="7F6000")
d.merge_cells("B4:E4")
ctrl = [("Region", "All", "List_0", "Sel_Region"), ("Product", "All", "List_1", "Sel_Product"),
        ("Source bank", "All", "List_2", "Sel_Bank"), ("Sourcing channel", "All", "List_3", "Sel_Channel"),
        ("SMA-2 turning NPA next month", 0.25, None, "Slippage")]
for i, (lbl, v, lst, nm) in enumerate(ctrl):
    r = 5 + i
    d.cell(r, 2, lbl).font = Font(size=9)
    d.merge_cells(start_row=r, start_column=2, end_row=r, end_column=3)
    cc = d.cell(r, 4, v)
    d.merge_cells(start_row=r, start_column=4, end_row=r, end_column=5)
    cc.fill = IN_FILL
    cc.border = BOX
    cc.font = Font(bold=True, size=10)
    name(wb, nm, f"Dashboard!$D${r}")
    if lst:
        dv = DataValidation(type="list", formula1=f"={lst}", allow_blank=False)
        d.add_data_validation(dv)
        dv.add(f"D{r}")
    else:
        cc.number_format = "0%"
        dv = DataValidation(type="decimal", operator="between", formula1="0", formula2="1")
        d.add_data_validation(dv)
        dv.add(f"D{r}")

# KPI tiles
tiles = [
    ("TRUE gross NPA", f'=TEXT({K["TRUE gross NPA %"]},"0.00%")', f'="Rs "&TEXT({K["TRUE NPA (Rs cr)"]},"0.00")&" cr of Rs "&TEXT({K["Book outstanding (Rs cr)"]},"#,##0")&" cr"', COL["True"]),
    ("Finance says", f'=TEXT({K["Finance gross NPA %"]},"0.00%")', '="CBS flag, loan by loan"', COL["Finance"]),
    ("Risk says", f'=TEXT({K["Risk gross NPA %"]},"0.00%")', '="bounces counted as missed"', COL["Risk"]),
    ("Provision required", f'="Rs "&TEXT({K["Provision required today (Rs cr)"]},"0.00")&" cr"', f'="+Rs "&TEXT({K["Extra provision if SMA-2 slips (Rs cr)"]},"0.00")&" cr if "&TEXT(Slippage,"0%")&" of SMA-2 slips"', COL["NPA"]),
    ("Approved above limit", f'={K["Loans above officer\'s limit"]}&" loans"', f'="Rs "&TEXT({K["Rs approved above limit (cr)"]},"0.00")&" cr sanctioned"', COL["SMA-2"]),
    ("Branches to lose powers", f'={K["lp_count"]}', f'="Rs "&TEXT({K["lp_os"]},"0")&" cr of book"', COL["SMA-1"]),
]
for i, (t, v, sub, colr) in enumerate(tiles):
    c0 = 7 + i * 3
    for rr in (4, 5, 6, 7, 8, 9):
        for cc_ in range(c0, c0 + 3):
            d.cell(rr, cc_).fill = PatternFill("solid", fgColor="F7F7F7")
    d.cell(4, c0, t).font = Font(bold=True, size=9, color=colr)
    d.merge_cells(start_row=4, start_column=c0, end_row=4, end_column=c0 + 2)
    x = d.cell(5, c0, v)
    x.font = Font(bold=True, size=20, color=colr)
    x.alignment = Alignment(horizontal="left", vertical="center")
    d.merge_cells(start_row=5, start_column=c0, end_row=7, end_column=c0 + 2)
    y = d.cell(8, c0, sub)
    y.font = Font(size=8, color="595959")
    y.alignment = Alignment(wrap_text=True, vertical="top")
    d.merge_cells(start_row=8, start_column=c0, end_row=9, end_column=c0 + 2)
d.cell(10, 2, f'="Checks against Stage 2 results: "&{K["checks"]}').font = Font(size=8, italic=True, color="595959")


def panel_title(row, col_, text, sub):
    cc = d.cell(row, col_, text)
    cc.font = Font(bold=True, size=11, color=NAVY)
    s = d.cell(row + 1, col_, sub)
    s.font = Font(size=8, italic=True, color="595959")


# Panel 1 - provision and stress
panel_title(12, 2, "", "")
d.cell(12, 2).value = (f'="1 · Provision Rs "&TEXT({K["Provision required today (Rs cr)"]},"0.00")&" cr today; Rs "&'
                       f'TEXT({K["Provision after slippage (Rs cr)"]},"0.00")&" cr if "&TEXT(Slippage,"0%")&" of SMA-2 turns NPA"')
d.cell(13, 2).value = "Top 10 branches by provision (Rs cr): today + extra if SMA-2 slips. Line: zone provision as the assumption moves 0-100%."

ch = BarChart()
ch.type = "bar"
ch.grouping = "stacked"
ch.overlap = 100
ch.style = 10
data = Reference(calc, min_col=3, max_col=4, min_row=P1[0] - 1, max_row=P1[1])
cats = Reference(calc, min_col=2, min_row=P1[0], max_row=P1[1])
ch.add_data(data, titles_from_data=True)
ch.set_categories(cats)
ch.series[0].graphicalProperties.solidFill = COL["Base"]
ch.series[1].graphicalProperties.solidFill = COL["Stress"]
ch.x_axis.scaling.orientation = "maxMin"
ch.legend.position = "b"
ch.height, ch.width = 8.5, 13
ch.y_axis.majorGridlines = None
ch.x_axis.delete = False
ch.y_axis.delete = False
d.add_chart(ch, "B14")

ln = LineChart()
data = Reference(calc, min_col=2, min_row=SENS[0] - 1, max_row=SENS[1])
ln.add_data(data, titles_from_data=True)
ln.set_categories(Reference(calc, min_col=1, min_row=SENS[0], max_row=SENS[1]))
ln.series[0].graphicalProperties.line.solidFill = COL["Stress"]
ln.series[0].graphicalProperties.line.width = 28000
ln.x_axis.number_format = "0%"
ln.legend = None
ln.height, ln.width = 8.5, 8.2
ln.x_axis.delete = False
ln.y_axis.delete = False
d.add_chart(ln, "I14")

# Panel 2 - where the NPAs are and who approved them
d.cell(12, 15).value = (f'="2 · Top 5 branches hold "&TEXT({K["top5_npa_share"]},"0%")&" of NPA on "&TEXT({K["top5_book_share"]},"0%")'
                        f'&" of the book; "&{K["Loans above officer\'s limit"]}&" loans approved above limit"')
d.cell(12, 15).font = Font(bold=True, size=11, color=NAVY)
d.cell(13, 15).value = "NPA by branch (Rs cr, top 10) and NPA % by product. Table: officers with most loans above their delegated limit."
d.cell(13, 15).font = Font(size=8, italic=True, color="595959")
b2 = BarChart()
b2.type = "bar"
b2.style = 10
b2.add_data(Reference(calc, min_col=3, min_row=P2[0] - 1, max_row=P2[1]), titles_from_data=True)
b2.set_categories(Reference(calc, min_col=2, min_row=P2[0], max_row=P2[1]))
b2.series[0].graphicalProperties.solidFill = COL["NPA"]
b2.x_axis.scaling.orientation = "maxMin"
b2.legend = None
b2.y_axis.majorGridlines = None
b2.dataLabels = labels("0.0")
b2.height, b2.width = 6.2, 11
b2.x_axis.delete = False
b2.y_axis.delete = False
d.add_chart(b2, "O14")
b3 = BarChart()
b3.style = 10
b3.add_data(Reference(calc, min_col=4, min_row=PROD[0] - 1, max_row=PROD[1]), titles_from_data=True)
b3.set_categories(Reference(calc, min_col=1, min_row=PROD[0], max_row=PROD[1]))
b3.series[0].graphicalProperties.solidFill = COL["NPA"]
b3.legend = None
b3.y_axis.number_format = "0%"
b3.y_axis.majorGridlines = None
b3.dataLabels = labels("0.0%")
b3.height, b3.width = 6.2, 10
b3.x_axis.delete = False
b3.y_axis.delete = False
d.add_chart(b3, "U14")
# officer table under panel 2
header(d, 27, 15, ["Officer", "", "Grade", "Home branch", "", "Above limit", "Rs cr", "NPA now"])
d.merge_cells("O27:P27")
d.merge_cells("R27:S27")
for k in range(5):
    r = 28 + k
    src = TOPOF[0] + k
    d.cell(r, 15, f"=Calc!B{src}&\" \"&Calc!C{src}")
    d.merge_cells(start_row=r, start_column=15, end_row=r, end_column=16)
    d.cell(r, 17, f"=Calc!D{src}")
    d.cell(r, 18, f"=Calc!E{src}")
    d.merge_cells(start_row=r, start_column=18, end_row=r, end_column=19)
    d.cell(r, 20, f"=Calc!F{src}")
    d.cell(r, 21, f"=Calc!G{src}").number_format = "0.00"
    d.cell(r, 22, f"=Calc!H{src}")
    for cc_ in range(15, 23):
        d.cell(r, cc_).font = Font(size=8)
        d.cell(r, cc_).border = BOX

# Panel 3 - movement and age
d.cell(34, 2).value = (f'="3 · Book is worsening: SMA-2 grew to Rs "&TEXT({K["SMA-2 outstanding (Rs cr)"]},"0.0")&" cr; "&TEXT({K["sma2_roll"]},"0%")'
                       f'&" of Sep SMA-2 became NPA; month-end loans go bad faster at every age"')
d.cell(34, 2).font = Font(bold=True, size=11, color=NAVY)
d.cell(35, 2).value = "Left: Rs cr by category, 30 Sep vs 31 Oct (Standard not shown). Right: % of loans 30+ DPD by EMIs fallen due - digital loans track branch loans of the same age."
d.cell(35, 2).font = Font(size=8, italic=True, color="595959")
mv = BarChart()
mv.type = "col"
mv.grouping = "clustered"
mv.style = 10
mv.add_data(Reference(calc, min_col=3, max_col=6, min_row=CA0, max_row=CA0 + 2), titles_from_data=True)
mv.set_categories(Reference(calc, min_col=1, min_row=CA0 + 1, max_row=CA0 + 2))
for s_, cat in zip(mv.series, CATS[1:]):
    s_.graphicalProperties.solidFill = COL[cat]
mv.y_axis.majorGridlines = None
mv.legend.position = "t"
mv.height, mv.width = 8.5, 9.5
mv.x_axis.delete = False
mv.y_axis.delete = False
d.add_chart(mv, "B36")
ag = LineChart()
ag.add_data(Reference(calc, min_col=2, max_col=5, min_row=AGE[0] - 1, max_row=AGE[1]), titles_from_data=True)
ag.set_categories(Reference(calc, min_col=1, min_row=AGE[0], max_row=AGE[1]))
for s_, colr, dash_ in zip(ag.series, [COL["NPA"], COL["Standard"], COL["Risk"], COL["Finance"]],
                           ["solid", "solid", "dash", "dash"]):
    s_.graphicalProperties.line.solidFill = colr
    s_.graphicalProperties.line.width = 25000
    s_.graphicalProperties.line.dashStyle = dash_
    s_.smooth = False
ag.y_axis.number_format = "0%"
ag.legend.position = "t"
ag.height, ag.width = 8.5, 11.5
ag.x_axis.delete = False
ag.y_axis.delete = False
d.add_chart(ag, "G36")

# Panel 4 - bridge
d.cell(34, 15).value = (f'="4 · Two numbers become one: Finance "&TEXT({K["Finance gross NPA %"]},"0.00%")&" + Rs "&'
                        f'TEXT(Calc!C{K["bridge_true_row"]}-Calc!C{BG[0]},"0.00")&" cr = TRUE "&TEXT({K["TRUE gross NPA %"]},"0.00%")&"; Risk adds Rs "&'
                        f'TEXT(Calc!C{BG[1]}-Calc!C{K["bridge_true_row"]},"0.00")&" cr in errors"')
d.cell(34, 15).font = Font(bold=True, size=11, color=NAVY)
d.cell(35, 15).value = "Rs crore of NPA (value under each bar). Grey = Finance, navy = TRUE, purple = Risk; red bars add NPA, green bars remove it."
d.cell(35, 15).font = Font(size=8, italic=True, color="595959")
wf = BarChart()
wf.type = "col"
wf.grouping = "stacked"
wf.overlap = 100
wf.style = 10
wf.add_data(Reference(calc, min_col=5, max_col=8, min_row=BG[0] - 1, max_row=BG[1]), titles_from_data=True)
wf.set_categories(Reference(calc, min_col=9, min_row=BG[0], max_row=BG[1]))
from openpyxl.drawing.line import LineProperties  # noqa: E402
wf.varyColors = False
wf.style = 2
wf.series[0].spPr = GraphicalProperties(noFill=True, ln=LineProperties(noFill=True))
for s_ in wf.series:
    s_.invertIfNegative = False
wf.series[1].graphicalProperties.solidFill = COL["Add"]
wf.series[2].graphicalProperties.solidFill = COL["Remove"]
wf.series[3].graphicalProperties.solidFill = COL["True"]
from openpyxl.chart.marker import DataPoint  # noqa: E402
pt = DataPoint(idx=0)
pt.graphicalProperties.solidFill = COL["Finance"]
wf.series[3].dPt.append(pt)
pt2 = DataPoint(idx=BG[1] - BG[0])
pt2.graphicalProperties.solidFill = COL["Risk"]
wf.series[3].dPt.append(pt2)
wf.legend = None
wf.y_axis.majorGridlines = None
wf.gapWidth = 40
wf.height, wf.width = 8.5, 21
wf.x_axis.delete = False
wf.y_axis.delete = False
d.add_chart(wf, "O36")

# Watchlist
d.cell(54, 2).value = "WATCHLIST · branches with most rupees at stake (NPA + SMA-1 + SMA-2) and the loans to act on first (follow the filters)"
d.cell(54, 2).font = Font(bold=True, size=11, color=NAVY)
header(d, 55, 2, ["#", "Branch", "", "", "Region", "", "At stake cr", "NPA %", "Loses powers?", "Officers"])
d.merge_cells("C55:E55")
d.merge_cells("F55:G55")
for k in range(10):
    r = 56 + k
    src = W1[0] + k
    d.cell(r, 2, k + 1)
    d.cell(r, 3, f"=Calc!B{src}")
    d.merge_cells(start_row=r, start_column=3, end_row=r, end_column=5)
    d.cell(r, 6, f"=Calc!E{src}")
    d.merge_cells(start_row=r, start_column=6, end_row=r, end_column=7)
    d.cell(r, 8, f"=Calc!C{src}").number_format = "0.00"
    d.cell(r, 9, f"=Calc!D{src}").number_format = "0.0%"
    d.cell(r, 10, f'=IFERROR(INDEX(Recovery_Plan!$P${LPR[0]}:$P${LPR[1]},MATCH(Calc!F{src},Recovery_Plan!$A${LPR[0]}:$A${LPR[1]},0)),"")')
    d.cell(r, 11, f'=IFERROR(INDEX(Recovery_Plan!$V${LPR[0]}:$V${LPR[1]},MATCH(Calc!F{src},Recovery_Plan!$A${LPR[0]}:$A${LPR[1]},0)),"")').number_format = "0"
    for cc_ in range(2, 12):
        d.cell(r, cc_).font = Font(size=8)
        d.cell(r, cc_).border = BOX
header(d, 55, 13, ["#", "Loan", "", "Branch", "", "", "Product", "Category", "DPD", "Rs lakh", "Officer"])
d.merge_cells("N55:O55")
d.merge_cells("P55:R55")
for k in range(10):
    r = 56 + k
    src = WL[0] + k
    d.cell(r, 13, k + 1)
    d.cell(r, 14, f"=Calc!B{src}")
    d.merge_cells(start_row=r, start_column=14, end_row=r, end_column=15)
    d.cell(r, 16, f"=Calc!C{src}")
    d.merge_cells(start_row=r, start_column=16, end_row=r, end_column=18)
    d.cell(r, 19, f"=Calc!D{src}")
    d.cell(r, 20, f"=Calc!E{src}")
    d.cell(r, 21, f"=Calc!F{src}")
    d.cell(r, 22, f"=Calc!G{src}").number_format = "0.0"
    d.cell(r, 23, f"=Calc!H{src}")
    for cc_ in range(13, 24):
        d.cell(r, cc_).font = Font(size=8)
        d.cell(r, cc_).border = BOX
d.cell(67, 2).value = '="Recovery officers by region: ' + " · ".join(f'{rg} "&Recovery_Plan!K{5 + i}&"' for i, rg in enumerate(regions)) + '"'
d.cell(67, 2).font = Font(bold=True, size=9, color=NAVY)
d.cell(68, 2).value = ("Definitions: DPD counts from the due date (day 1); money pays the oldest dues first; bounced and reversed payments do not count; "
                       "if one loan of a person is NPA, all their loans are NPA (Pavanpur and Meridian records matched by PAN or name + date of birth). "
                       "Provision rates: rbi_norms_reference.xlsx. Limits: delegation_matrix.xlsx.")
d.cell(68, 2).font = Font(size=7, italic=True, color="595959")

d.print_area = "A1:Z68"
d.page_setup.orientation = "landscape"
d.page_setup.paperSize = 8  # A3
d.page_setup.fitToWidth = 1
d.page_setup.fitToHeight = 1
d.sheet_properties.pageSetUpPr.fitToPage = True
d.print_options.horizontalCentered = True
d.page_margins.left = d.page_margins.right = 0.3
d.page_margins.top = d.page_margins.bottom = 0.3

# ---------------------------------------------------------------------
# README
# ---------------------------------------------------------------------
readme_lines = [
    "Meridian Crest Bank · Hubballi Zone · Stage 3 workbook",
    "",
    "Dashboard   one page for the CRO. Yellow cells (region, product, source bank, sourcing channel, SMA-2 slippage) are the only things to change.",
    "Inputs      the bank's reference files (provisioning rates, DPD bands, delegation matrix, FY27 targets) and the plan's assumptions.",
    "Calc        every panel's numbers, formulas only, following the filters.",
    "Recovery_Plan  zone-wide split of the 25 recovery officers and the lending-power test per branch.",
    "Delegation  every loan approved above its officer's limit (follows the filters).",
    "Checks      workbook totals vs the Stage 2 result files: must say ALL OK.",
    "Data_*      the Stage 2 CSV result files, unchanged (plus helper formula columns on Data_Loans).",
    "",
    "Rules: no number is typed into a formula; inputs live on Inputs or in the yellow dashboard cells.",
]
for i, t in enumerate(readme_lines):
    readme.cell(1 + i, 1, t)
readme["A1"].font = Font(bold=True, size=13, color=NAVY)
readme.column_dimensions["A"].width = 140

OUT.parent.mkdir(exist_ok=True)
wb.save(OUT)
print("saved", OUT)
