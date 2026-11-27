# Rebuild the database, load all CSVs, run Stage 1 cleaning and Stage 2
# analysis, and export the result CSVs (results/).
# Usage (from anywhere):  powershell -ExecutionPolicy Bypass -File scripts\run_all.ps1
# Reads MYSQL_USER / MYSQL_PASSWORD from .env in the repo root (copy .env.example).

$repo  = Split-Path -Parent $PSScriptRoot
$mysql = 'C:\Program Files\MySQL\MySQL Server 8.4\bin\mysql.exe'
if (-not (Test-Path $mysql)) { $mysql = 'mysql' }

$cfg = @{}
Get-Content "$repo\.env" | Where-Object { $_ -match '=' } | ForEach-Object {
    $k, $v = $_ -split '=', 2; $cfg[$k.Trim()] = $v.Trim()
}
$env:MYSQL_PWD = $cfg['MYSQL_PASSWORD']
$user = $cfg['MYSQL_USER']

# Pipe the scripts as UTF-8 (Windows PowerShell defaults to ASCII, which
# turns the rupee sign into "?" and breaks the amount parser).
$OutputEncoding = New-Object System.Text.UTF8Encoding $false

Push-Location $repo
try {
    foreach ($f in 'sql\00_create_database_and_tables.sql', 'sql\01_load_data.sql',
                   'sql\02_stage1_clean.sql', 'sql\03_stage2_analysis.sql') {
        Write-Host "== $f"
        Get-Content $f -Raw -Encoding UTF8 | & $mysql --local-infile=1 --default-character-set=utf8mb4 -u $user --table
        if ($LASTEXITCODE -ne 0) { throw "$f failed" }
    }
    Write-Host "== export results"
    python tools\export_results.py
} finally { Pop-Location; Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue }
