# Save stage3\Board_Recommendation.docx as PDF with Word.
# Usage: powershell -ExecutionPolicy Bypass -File scripts\docx_to_pdf.ps1
$repo = Split-Path -Parent $PSScriptRoot
$doc  = Join-Path $repo 'stage3\Board_Recommendation.docx'
$pdf  = Join-Path $repo 'stage3\Board_Recommendation.pdf'
$w = New-Object -ComObject Word.Application
$w.Visible = $false
try {
    $d = $w.Documents.Open($doc)
    "Pages: " + $d.ComputeStatistics(2)
    $d.ExportAsFixedFormat([string]$pdf, 17)   # 17 = PDF
    $d.Close($false)
} finally { $w.Quit() }
"PDF: $pdf"
