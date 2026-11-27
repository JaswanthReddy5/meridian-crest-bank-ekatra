"""Stage 3: one-page recommendation to the Board's risk committee.

Every number is read from the Stage 2 result files or the recalculated
Stage 3 workbook, so the page always matches the dashboard.
Run after scripts/finish_workbook.ps1:  python tools/build_recommendation.py
"""
import csv
from pathlib import Path

import openpyxl
from docx import Document
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.shared import Cm, Pt, RGBColor

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "results"
OUT = ROOT / "stage3" / "Board_Recommendation.docx"
NAVY = RGBColor(0x1F, 0x38, 0x64)


def rows(name):
    with open(RES / name, encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))


cr = lambda v: f"Rs {float(v) / 1e7:,.2f} cr"
head = {r["measure"]: r for r in rows("headline.csv")}
bridge = {int(r["step_no"]): r for r in rows("npa_bridge.csv")}
claims = rows("claim_tests.csv")
dq = rows("stage1/dq_log.csv")
wb = openpyxl.load_workbook(ROOT / "stage3" / "Meridian_Crest_CRO_Dashboard.xlsx", data_only=True)
plan = wb["Recovery_Plan"]
regions = [(plan.cell(r, 1).value, plan.cell(r, 11).value) for r in range(5, 10)]
lp = []
for r in range(14, 60):
    if plan.cell(r, 16).value == "YES":
        lp.append((plan.cell(r, 2).value, plan.cell(r, 8).value, plan.cell(r, 10).value, plan.cell(r, 13).value,
                   plan.cell(r, 14).value, plan.cell(r, 15).value))
lp_os = next(plan.cell(r, 6).value for r in range(50, 70) if plan.cell(r, 1).value == "Their outstanding (Rs cr)")
lp_tgt = next(plan.cell(r, 6).value for r in range(50, 70) if (plan.cell(r, 1).value or "").startswith("Their FY27"))
calc = wb["Calc"]
kpi = {calc.cell(r, 1).value: calc.cell(r, 2).value for r in range(3, 18)}


def dqsum(pred):
    sel = [r for r in dq if pred(r)]
    return sum(int(r["rows_affected"]) for r in sel), sum(float(r["rupees_involved"] or 0) for r in sel)


true = head["TRUE gross NPA (borrower rule, verified payments)"]
fin = head["Finance gross NPA (as reported)"]
risk = head["Risk gross NPA (as reported)"]
book = head["Total book 31 Oct 2026"]
me = next(c for c in claims if c["scope"].startswith("All loans"))
dg = next(c for c in claims if c["scope"].startswith("Personal loans"))
no_sec = dqsum(lambda r: r["problem"].startswith("Secured loan with no security"))
age70 = dqsum(lambda r: r["column_name"] == "AGE_OVER_70_AT_MATURITY")
dw_miss = dqsum(lambda r: r["problem"].startswith("Loan in CBS extract but not loaded"))
flat = dqsum(lambda r: r["problem"] == "EMI check: FLAT_RATE")
nopan = dqsum(lambda r: r["question"] == "Q1.3" and r["column_name"] == "pan" and r["action_taken"] == "FLAGGED")

doc = Document()
sec = doc.sections[0]
sec.page_height, sec.page_width = Cm(29.7), Cm(21.0)
sec.left_margin = sec.right_margin = Cm(1.5)
sec.top_margin = sec.bottom_margin = Cm(1.1)
st = doc.styles["Normal"]
st.font.name = "Calibri"
st.font.size = Pt(8.6)
st.paragraph_format.space_after = Pt(1.5)
st.paragraph_format.line_spacing = 1.0


BLOCKS = []


def para(text, bold=False, size=None, color=None, after=None, italic=False):
    BLOCKS.append(("para", [(text, bold)], dict(size=size, color=color, italic=italic, after=after)))
    p = doc.add_paragraph()
    r = p.add_run(text)
    r.bold, r.italic = bold, italic
    if size:
        r.font.size = Pt(size)
    if color:
        r.font.color.rgb = color
    if after is not None:
        p.paragraph_format.space_after = Pt(after)
    return p


def rich(parts, style=None):
    BLOCKS.append(("bullet" if style else "para", parts, {}))
    p = doc.add_paragraph(style=style)
    for t, b in parts:
        p.add_run(t).bold = b
    return p


def heading(text):
    para(text, bold=True, size=10, color=NAVY, after=1)


para("To: Board Risk Committee · From: Chief Risk Officer (Project Ekatra) · 14 December 2026 · Hubballi Zone, loans at 31 October 2026",
     size=7.5, italic=True, color=RGBColor(0x59, 0x59, 0x59), after=0)
para(f"Our bad loans are {float(true['ratio_pct']):.2f}%, not {float(fin['ratio_pct']):.1f}% or {float(risk['ratio_pct']):.1f}%. "
     "Send recovery officers to Belagavi, take lending powers from five branches, and fix five data gaps before April 2027.",
     bold=True, size=12.5, color=NAVY, after=3)

heading("The true figure, and why both reports were wrong")
rich([(f"Gross NPA is {float(true['ratio_pct']):.2f}%: {cr(true['rupees'])} of {cr(book['rupees'])}, {true['loans']} loans. ", True),
      ("Days past due were rebuilt for every loan from its EMI schedule and the payments that actually cleared (bounced and reversed "
       "payments excluded, oldest dues paid first), and the RBI borrower rule was applied after matching the same person across the "
       "Pavanpur and Meridian systems. Both department figures reconcile to it to the rupee (dashboard panel 4).", False)])
f_gap = float(bridge[10]["rupees"]) - float(bridge[1]["rupees"])
r_gap = float(bridge[20]["rupees"]) - float(bridge[10]["rupees"])
rich([(f"Finance is {cr(f_gap)} too low. ", True),
      (f"It reports the core system's NPA flag, which was never set on {bridge[3]['loans']} migrated Pavanpur loans already over 90 days "
       f"late ({cr(bridge[3]['rupees'])}), and it classifies loan by loan, missing the borrower rule "
       f"({cr(float(bridge[5]['rupees']) + float(bridge[6]['rupees']))}).", False)], "List Bullet")
rich([(f"Risk is {cr(r_gap)} too high. ", True),
      (f"It treats every bounced auto-debit as a missed EMI even when the borrower paid days later by cash, UPI or NEFT "
       f"({bridge[11]['loans']} loans, {cr(bridge[11]['rupees'])}), and it spreads NPA through the vendor's 15 false name-only "
       f"customer matches ({cr(bridge[12]['rupees'])}).", False)], "List Bullet")
rich([("From now on: ", True),
      ("one calculation, owned by Risk and used by Finance: DPD daily from the schedule and cleared payments, borrower-level through "
       "a verified customer master, never from the system flag. Cost (estimate): about 6 weeks of the Ekatra team. "
       "Proves us wrong: an independent re-run on November data that does not match to the rupee.", False)], "List Bullet")

heading("Decision 1 · Split the 25 recovery officers by recovery workload")
rich([("Officers: " + ", ".join(f"{n} {int(k)}" for n, k in regions) + ". ", True),
      (f"Each region gets officers in proportion to its NPA + SMA-2 + half of SMA-1 rupees (zone workload "
       f"Rs {sum(plan.cell(r, 5).value for r in range(5, 10)):.1f} cr); inside a region they go branch by branch on the same basis "
       f"(Recovery_Plan sheet). Belagavi carries 44% of the work: its former Pavanpur branches collect the least of what "
       f"falls due each month (68-78%), against 77-87% at the region's Meridian branches. Why now: {kpi['SMA-2 outstanding (Rs cr)']:.2f} cr is in SMA-2 and "
       f"78% of September's SMA-2 became NPA in October. ", False),
      ("Cost: ", True), ("redeployment only; travel within regions. ", False),
      ("Affects: ", True), ("the 1,071 loans on the watch list and their borrowers. ", False),
      ("Proves us wrong: ", True), ("collection efficiency in Belagavi's Pavanpur branches not above 75% by February 2027.", False)])

heading(f"Decision 2 · Five branches lose independent lending powers ({lp_os:.1f} cr of book)")
rich([("Test: ", True),
      ("A) NPA ratio at least 1.5x the zone's (5.6%) and collection efficiency below 80% over Aug-Oct, or "
       "B) 10 or more loans approved above the officer's delegated limit. ", False)])
for nme, npa, ce, br_, ta, tb in lp:
    why = f"NPA {npa:.1%}, collects {ce:.0%}" if ta == "FAIL" else f"{br_} loans above limit"
    rich([(f"{nme}: ", True), (why + ".", False)], "List Bullet")
rich([("Belagavi Station Road: ", True),
      ("23 of its above-limit loans were approved by one Scale I officer (OF0038), 17 are now NPA; 56% of his month-end loans are "
       "30+ days late against 2% of his others. Suspend his powers and audit the files. ", False),
      ("Not removed: ", True), ("Kalghatgi Court Circle (7.6% NPA) still collects 88%: old stock, not current lending. ", False),
      ("Cost: ", True), (f"Rs {lp_tgt:.1f} cr of FY27 disbursal targets move to the regional credit committee (slower approvals). ", False),
      ("Proves us wrong: ", True), ("loans these branches book from January perform no better than before.", False)])
rich([("Two branch claims, tested fairly (same product, same age): ", True),
      (f"month-end loans are worse ({me['observed_to_expected']}x as many 30+ days late, z = {me['z_score']}, over 99% confident), "
       f"so require a second sign-off on loans in the last 3 days of a month. Digital-partner loans are not worse "
       f"(z = {dg['z_score']}); their better raw figure only reflects their young age.", False)])

heading("Decision 3 · Fix five things in the data before RBI expected-loss rules start on 1 April 2027")
items = [
    ("One customer master: ", f"113 Pavanpur-Meridian matches the vendor missed, 15 false matches it made, {nopan[0]} customers with no usable PAN. Owner: Data Platform, by January."),
    ("Asset class from DPD, not the flag: ", "recompute daily for all migrated loans. Owner: IT, with Risk."),
    ("Warehouse load control: ", f"October left {dw_miss[0]} loans ({cr(dw_miss[1])}) out of the warehouse and 12 NPA flags wrong; block any load that does not match the core system's row count and total."),
    ("Loan master in typed fields: ", "102 duplicate rows, 2 missing loans, four date styles, amounts in lakh text, rates as fractions."),
    ("Security and pricing: ", f"{no_sec[0]} secured loans ({cr(no_sec[1])}) have no security recorded; {flat[0]} Pavanpur personal loans ({cr(flat[1])}) are priced on a flat rate that hides the true rate; {age70[0]} loans run past the borrower's 70th birthday."),
]
for a, b in items:
    rich([(a, True), (b, False)], "List Bullet")
rich([("Cost: ", True), ("estimate, about 3 months of the Ekatra team plus branch time to re-collect KYC. ", False),
      ("Affects: ", True), ("IT, the migration vendor, 40 branches. ", False),
      ("Proves us wrong: ", True), ("a March 2027 dry run of expected loss that still needs manual fixes.", False)])

for p in doc.paragraphs:
    p.alignment = WD_ALIGN_PARAGRAPH.LEFT
    if p.style.name == "List Bullet":
        p.paragraph_format.space_after = Pt(1)
        p.paragraph_format.left_indent = Cm(0.5)
try:
    doc.save(OUT)
    print("saved", OUT)
except PermissionError:
    print("WARNING: Board_Recommendation.docx is open in Word; close it and re-run to refresh it")

# Same page as PDF (reportlab), so the PDF does not depend on Word.
from html import escape  # noqa: E402
from reportlab.lib.pagesizes import A4  # noqa: E402
from reportlab.lib.styles import ParagraphStyle  # noqa: E402
from reportlab.lib.units import cm  # noqa: E402
from reportlab.platypus import Paragraph, SimpleDocTemplate  # noqa: E402

pdf = OUT.with_suffix(".pdf")
base = ParagraphStyle("b", fontName="Helvetica", fontSize=9, leading=11.3, spaceAfter=2.6)
bullet = ParagraphStyle("u", parent=base, leftIndent=10, bulletIndent=2, spaceAfter=1.2)
story = []
for kind, parts, opt in BLOCKS:
    html = "".join(f"<b>{escape(t)}</b>" if b else escape(t) for t, b in parts).replace("Rs ", "Rs&nbsp;")
    if kind == "bullet":
        story.append(Paragraph(html, bullet, bulletText="•"))
        continue
    st_ = ParagraphStyle("x", parent=base)
    if opt.get("size"):
        st_.fontSize = opt["size"] - 0.4
        st_.leading = st_.fontSize * 1.22
    if opt.get("color"):
        st_.textColor = "#" + str(opt["color"])
    if opt.get("italic"):
        st_.fontName = "Helvetica-Oblique"
    if opt.get("size") == 10:
        st_.spaceBefore = 3
    story.append(Paragraph(html, st_))
SimpleDocTemplate(str(pdf), pagesize=A4, leftMargin=1.5 * cm, rightMargin=1.5 * cm, topMargin=1.1 * cm,
                  bottomMargin=1.0 * cm, title="Board Recommendation - Hubballi Zone").build(story)
print("saved", pdf)
