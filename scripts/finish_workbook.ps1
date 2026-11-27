# Open the Stage 3 workbook in Excel, recalculate every formula, save it,
# and export the Dashboard sheet as a one-page PDF.
# Usage: powershell -ExecutionPolicy Bypass -File scripts\finish_workbook.ps1
$repo = Split-Path -Parent $PSScriptRoot
$xlsx = Join-Path $repo 'stage3\Meridian_Crest_CRO_Dashboard.xlsx'
$pdf  = Join-Path $repo 'stage3\Meridian_Crest_CRO_Dashboard.pdf'

$xl = New-Object -ComObject Excel.Application
$xl.Visible = $false
$xl.DisplayAlerts = $false
try {
    $wb = $xl.Workbooks.Open($xlsx)
    $xl.CalculateFull()
    $wb.Save()
    $ws = $wb.Worksheets.Item('Dashboard')
    $ws.ExportAsFixedFormat(0, $pdf, 0, $true, $false)   # 0 = PDF, standard quality, ignore print areas = false
    $chk = $wb.Worksheets.Item('Checks')
    "Checks: " + $chk.Range('E11').Text
    foreach ($r in 4..9) { "{0,-28} {1,22} {2,22} {3}" -f $chk.Cells.Item($r,1).Text, $chk.Cells.Item($r,2).Text, $chk.Cells.Item($r,3).Text, $chk.Cells.Item($r,5).Text }
    $c = $wb.Worksheets.Item('Calc')
    foreach ($r in 3..17) { "{0,-40} {1}" -f $c.Cells.Item($r,1).Text, $c.Cells.Item($r,2).Text }
    $wb.Close($true)
} finally {
    $xl.Quit()
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($xl) | Out-Null
}
"PDF: $pdf"
