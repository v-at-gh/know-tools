#Requires -Version 5.1
<#
.SYNOPSIS
Read-only inventory of know-server runtime data (databases, logs, output, qaps).

.PARAMETER Root
Path to project root, e.g. ~\data\src\github.com\v-at-gh\know-server

.EXAMPLE
.\validate-userdata.ps1 ~\data\src\github.com\v-at-gh\know-server
#>
param(
	[Parameter(Mandatory=$true)]
	[string]$Root
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Root -PathType Container)) {
	Write-Error "Not a directory: $Root"; exit 3
}
$Root = (Resolve-Path $Root).Path

$script:Warn = 0
$script:Err  = 0

function Write-Section($title) {
	Write-Host ""
	Write-Host "## $title" -ForegroundColor Cyan
	Write-Host ""
}

function Write-Kv($k, $v, $color) {
	$label = "${k}:"
	if ($color) {
		Write-Host ("  {0,-10} {1}" -f $label, $v) -ForegroundColor $color
	} else {
		Write-Host ("  {0,-10} {1}" -f $label, $v)
	}
}

function Format-Bytes([long]$b) {
	if ($b -lt 1024)       { return "$b B" }
	if ($b -lt 1048576)    { return ("{0:N1} KB" -f ($b / 1024)) }
	if ($b -lt 1073741824) { return ("{0:N1} MB" -f ($b / 1048576)) }
	return ("{0:N1} GB" -f ($b / 1073741824))
}

$Sqlite = (Get-Command sqlite3.exe, sqlite3 -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $Sqlite) {
	Write-Error "sqlite3 not found in PATH. Install: winget install SQLite.SQLite, then reopen terminal."
	exit 3
}

# Returns array of output lines, always array (empty if query failed or no rows)
function Sqlite-Query {
	param([string]$db, [string]$sql)
	try {
		$out = & $Sqlite $db $sql 2>$null
		if ($LASTEXITCODE -ne 0) { return @() }
		if (-not $out) { return @() }
		return @($out)
	} catch {
		return @()
	}
}

Write-Host "================================================================"
Write-Host "know-server user data inventory"
Write-Host "root:    $Root"
Write-Host "when:    $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
Write-Host "host:    $env:COMPUTERNAME"
Write-Host "script:  validate-userdata v1.0"
Write-Host "================================================================"

Write-Section "DATABASES"
foreach ($name in @('app','content','users','tasks','server')) {
	$db = Join-Path $Root "state\$name.db"
	Write-Host "--- $name.db ---"

	if (-not (Test-Path $db -PathType Leaf)) {
		Write-Kv "status" "MISSING" "Yellow"
		$script:Warn++
		Write-Host ""
		continue
	}

	$fi = Get-Item $db
	Write-Kv "size" ((Format-Bytes $fi.Length) + " (" + $fi.Length + " bytes)")
	Write-Kv "mtime" $fi.LastWriteTime.ToString("yyyy-MM-dd HH:mm")

	$wal = "$db-wal"
	if (Test-Path $wal -PathType Leaf) {
		$wfi = Get-Item $wal
		Write-Kv "WAL" ("present, " + (Format-Bytes $wfi.Length))
		if ($wfi.Length -gt 10485760) {
			Write-Kv "WARN" "WAL over 10MB; checkpoint may be needed" "Yellow"
			$script:Warn++
		}
	} else {
		Write-Kv "WAL" "absent"
	}

	$journal = Sqlite-Query $db "PRAGMA journal_mode;" | Select-Object -First 1
	Write-Kv "journal" $(if ($journal) { $journal } else { "?" })

	$integrity = Sqlite-Query $db "PRAGMA quick_check(1);" | Select-Object -First 1
	if ($integrity -eq 'ok') {
		Write-Kv "integrity" "ok" "Green"
	} else {
		$integrityMsg = if ($integrity) { $integrity } else { "query failed" }
		Write-Kv "integrity" ("PROBLEM: " + $integrityMsg) "Red"
		$script:Err++
	}

	$tables = Sqlite-Query $db "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;"
	if ($tables.Count -gt 0) {
		Write-Host "  tables:"
		foreach ($t in $tables) {
			$tt = "$t".Trim()
			if (-not $tt) { continue }
			$rc = Sqlite-Query $db ("SELECT COUNT(*) FROM `"" + $tt + "`";") | Select-Object -First 1
			$countStr = if ($rc) { $rc } else { "?" }
			$sfx = if ($tt -match '_fts_|_embeddings_|_embedding_index') { " (internal)" } else { "" }
			Write-Host ("    {0}: {1}{2}" -f $tt, $countStr, $sfx)
		}
	} else {
		Write-Kv "tables" "NONE (empty DB?)" "Yellow"
		$script:Warn++
	}
	Write-Host ""
}

Write-Section "LOGS (state\logs\)"
$logsDir = Join-Path $Root "state\logs"
if (Test-Path $logsDir -PathType Container) {
	$files = @(Get-ChildItem -Path $logsDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object Name)
	$totalBytes = 0
	foreach ($f in $files) { $totalBytes += $f.Length }
	$newest = ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
	$oldest = ($files | Sort-Object LastWriteTime | Select-Object -First 1).LastWriteTime

	Write-Host "  file                              size       last-modified"
	foreach ($f in $files) {
		Write-Host ("  {0,-32} {1,-10} {2}" -f $f.Name, (Format-Bytes $f.Length), $f.LastWriteTime.ToString("yyyy-MM-dd HH:mm"))
	}
	Write-Host ""
	Write-Kv "files"  $files.Count
	Write-Kv "total"  (Format-Bytes $totalBytes)
	Write-Kv "oldest" $(if ($oldest) { $oldest.ToString("yyyy-MM-dd HH:mm") } else { "n/a" })
	Write-Kv "newest" $(if ($newest) { $newest.ToString("yyyy-MM-dd HH:mm") } else { "n/a" })
	if ($newest -and ((Get-Date) - $newest).TotalHours -gt 24) {
		Write-Kv "WARN" "no log modified in last 24h; services may be down" "Yellow"
		$script:Warn++
	}
} else {
	Write-Kv "status" "MISSING: $logsDir" "Yellow"
	$script:Warn++
}
Write-Host ""

Write-Section "OUTPUT (datasets + knowledge)"
$output = Join-Path $Root "output"
if (Test-Path $output -PathType Container) {
	foreach ($sub in @('datasets','knowledge','syllabus')) {
		$p = Join-Path $output $sub
		if (Test-Path $p -PathType Container) {
			$items = @(Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue)
			$sz = 0
			foreach ($it in $items) { $sz += $it.Length }
			Write-Host ("  {0,-12} {1,6} files, {2}" -f "$sub/", $items.Count, (Format-Bytes $sz))
			$langs = @(Get-ChildItem $p -Directory -ErrorAction SilentlyContinue).Count
			if ($langs -gt 0) {
				Write-Host "    languages: $langs"
			}
		} else {
			Write-Kv "status" "${sub}/ MISSING" "Yellow"
			$script:Warn++
		}
	}
} else {
	Write-Kv "status" "MISSING: $output" "Yellow"
	$script:Warn++
}
Write-Host ""

Write-Section "QAPS (state\qaps\)"
$qaps = Join-Path $Root "state\qaps"
$manifest = Join-Path $Root "state\manifest.json"
if (Test-Path $qaps -PathType Container) {
	$qFiles = @(Get-ChildItem $qaps -Filter '*.qap' -File -ErrorAction SilentlyContinue)
	$qSum = 0
	foreach ($qf in $qFiles) { $qSum += $qf.Length }
	Write-Kv "qap files" ("$($qFiles.Count), total " + (Format-Bytes $qSum))

	if (Test-Path $manifest -PathType Leaf) {
		$mfi = Get-Item $manifest
		$packCount = "?"
		try {
			$json = Get-Content $manifest -Raw | ConvertFrom-Json
			$packCount = @($json.packs).Count
		} catch { }
		Write-Kv "manifest" ((Format-Bytes $mfi.Length) + ", $packCount packs, modified " + $mfi.LastWriteTime.ToString("yyyy-MM-dd HH:mm"))
	} else {
		Write-Kv "manifest" "MISSING; run update_manifest.py" "Yellow"
		$script:Warn++
	}
} else {
	Write-Kv "status" "MISSING: $qaps" "Yellow"
	$script:Warn++
}
Write-Host ""

Write-Section "FILESYSTEM"
$rootItem = Get-Item $Root
$driveName = $rootItem.PSDrive.Name
$disk = Get-PSDrive -Name $driveName
$total = $disk.Used + $disk.Free
$freePct = 0
if ($total -gt 0) { $freePct = [math]::Round(($disk.Free / $total) * 100, 1) }
Write-Host ("  drive {0}:  free {1} of {2} ({3}% free)" -f $driveName, (Format-Bytes $disk.Free), (Format-Bytes $total), $freePct)
if ($freePct -lt 10) {
	Write-Kv "WARN" ("only {0} free" -f (Format-Bytes $disk.Free)) "Yellow"
	$script:Warn++
}
Write-Host ""

Write-Host "================================================================"
Write-Host "SUMMARY"
Write-Host ("  warnings: {0}" -f $script:Warn) -ForegroundColor $(if ($script:Warn -gt 0) { "Yellow" } else { "Green" })
Write-Host ("  errors:   {0}" -f $script:Err)  -ForegroundColor $(if ($script:Err  -gt 0) { "Red"    } else { "Green" })
Write-Host "================================================================"

if ($script:Err  -gt 0) { exit 2 }
if ($script:Warn -gt 0) { exit 1 }
exit 0