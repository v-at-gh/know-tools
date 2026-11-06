#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Manages Windows portproxy forwards + matching firewall rules for the
know-infra multipass VM. Compatible with PowerShell 5.1 (Windows PowerShell)
and 7+ (PowerShell Core).

.DESCRIPTION
Creates/removes:
  - netsh portproxy v4tov4 entries (0.0.0.0:PORT -> VM_IP:VMPORT)
  - Windows Firewall inbound rules scoped to LocalSubnet

Idempotent. Refresh automatically updates all forwards if VM IP changed.

.EXAMPLE
.\port-forward.ps1 status
.\port-forward.ps1 up
.\port-forward.ps1 cleanup
.\port-forward.ps1 down
#>
param(
	[Parameter(Mandatory=$true)]
	[ValidateSet('up','down','status','cleanup','audit','refresh')]
	[string]$Action
)

$ErrorActionPreference = 'Stop'

Write-Host ("PowerShell {0}" -f $PSVersionTable.PSVersion) -ForegroundColor DarkGray

# --- configuration -----------------------------------------------------

$VM_NAME          = if ($env:MULTIPASS_VM_NAME) { $env:MULTIPASS_VM_NAME } else { 'know-infra' }
$FALLBACK_VM_IP   = '172.26.60.57'
$FW_PREFIX        = 'know-ci-'
$LISTEN_ADDRESS   = '0.0.0.0'

# Managed forwards: script creates/updates/removes both portproxy and firewall rule.
# SSH on 2022 is intentionally NOT managed — user keeps it under manual control.
$FORWARDS = @(
	@{ ListenPort=3001; VMPort=3001; Name='gitea-http'; Desc='Gitea HTTP/UI' },
	@{ ListenPort=2222; VMPort=2222; Name='gitea-ssh';  Desc='Gitea SSH' },
	@{ ListenPort=4317; VMPort=4317; Name='otlp-grpc';  Desc='OTLP gRPC (Mac telemetry)' },
	@{ ListenPort=4318; VMPort=4318; Name='otlp-http';  Desc='OTLP HTTP (Mac telemetry)' },
	@{ ListenPort=3000; VMPort=3000; Name='grafana';    Desc='Grafana UI' }
)

# --- preflight ---------------------------------------------------------

function Assert-Admin {
	$id = [Security.Principal.WindowsIdentity]::GetCurrent()
	$p  = New-Object Security.Principal.WindowsPrincipal($id)
	if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
		Write-Error "This script must be run as Administrator (portproxy + firewall rules)."
		exit 1
	}
}

function Assert-IPHelperRunning {
	$svc = Get-Service iphlpsvc -ErrorAction SilentlyContinue
	if (-not $svc) {
		Write-Error "IP Helper service (iphlpsvc) not found. Windows portproxy requires it."
		exit 1
	}
	if ($svc.Status -ne 'Running') {
		try {
			Start-Service iphlpsvc
			Write-Host "Started IP Helper service (required for portproxy)." -ForegroundColor Yellow
		} catch {
			Write-Error "Cannot start IP Helper service: $($_.Exception.Message). Portproxy will not work."
			exit 1
		}
	}
}

function Assert-FirewallProfilesEnabled {
	$disabled = (Get-NetFirewallProfile | Where-Object { $_.Enabled -ne 'True' }).Name
	if ($disabled) {
		Write-Warning "Windows Firewall is DISABLED on profile(s): $($disabled -join ', '). Rules will still be created but provide no protection."
	}
}

# --- helpers -----------------------------------------------------------

function Get-VmIp {
	if (Get-Command multipass -ErrorAction SilentlyContinue) {
		try {
			$raw = multipass info $VM_NAME --format json 2>$null | ConvertFrom-Json
			$ip  = $raw.info.$VM_NAME.ipv4
			if ($ip) { return $ip[0] }
		} catch { }
	}
	Write-Warning "multipass unavailable or VM '$VM_NAME' not found; using fallback $FALLBACK_VM_IP"
	return $FALLBACK_VM_IP
}

function Get-AllPortproxyEntries {
	$raw  = netsh interface portproxy show v4tov4
	$rows = @()
	foreach ($line in ($raw -split "`r?`n")) {
		if ($line -match '^\s*(\S+)\s+(\d+)\s+(\S+)\s+(\d+)\s*$') {
			$rows += [pscustomobject]@{
				ListenAddress  = $Matches[1]
				ListenPort     = [int]$Matches[2]
				ConnectAddress = $Matches[3]
				ConnectPort    = [int]$Matches[4]
			}
		}
	}
	return $rows
}

function Add-Forward {
	param([int]$LP, [string]$VmIp, [int]$VP)
	netsh interface portproxy delete v4tov4 listenport=$LP listenaddress=$LISTEN_ADDRESS 2>$null | Out-Null
	netsh interface portproxy add    v4tov4 listenport=$LP listenaddress=$LISTEN_ADDRESS connectport=$VP connectaddress=$VmIp | Out-Null
}

function Remove-Forward {
	param([int]$LP)
	netsh interface portproxy delete v4tov4 listenport=$LP listenaddress=$LISTEN_ADDRESS 2>$null | Out-Null
}

function Get-FirewallRuleForPort {
	param([int]$Port)
	Get-NetFirewallRule -DisplayName "$FW_PREFIX*-$Port" -ErrorAction SilentlyContinue |
		Where-Object { $_.Direction -eq 'Inbound' } |
		Select-Object -First 1
}

function Get-AllKnowFirewallRules {
	Get-NetFirewallRule -DisplayName "$FW_PREFIX*" -ErrorAction SilentlyContinue
}

function Add-FirewallRuleForPort {
	param([int]$Port, [string]$Name)
	$display = "$FW_PREFIX$Name-$Port"
	Remove-NetFirewallRule -DisplayName $display -ErrorAction SilentlyContinue
	New-NetFirewallRule `
		-DisplayName   $display `
		-Direction     Inbound `
		-Protocol      TCP `
		-LocalPort     $Port `
		-RemoteAddress LocalSubnet `
		-Action        Allow `
		-Profile       Any `
		-Description   "Portproxy forward to know-infra VM (managed by port-forward.ps1)" | Out-Null
}

function Remove-FirewallRuleForPort {
	param([int]$Port)
	Get-NetFirewallRule -DisplayName "$FW_PREFIX*-$Port" -ErrorAction SilentlyContinue |
		ForEach-Object { Remove-NetFirewallRule -Name $_.Name -ErrorAction SilentlyContinue }
}

function Test-PortListening {
	param([int]$Port)
	[bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
}

# --- commands ----------------------------------------------------------

function Show-Status {
	$vmIp = Get-VmIp
	$all  = Get-AllPortproxyEntries
	$managedPorts = @($FORWARDS | ForEach-Object { $_.ListenPort })

	# one CIM query for all know-ci rules
	$ourRules = @(Get-AllKnowFirewallRules)
	$rulesByPort = @{}
	foreach ($rule in $ourRules) {
		if ("$($rule.DisplayName)" -match "$FW_PREFIX.*-(\d+)$") {
			$rulesByPort[[int]$Matches[1]] = $rule
		}
	}

	$iphlpsvc = Get-Service iphlpsvc -ErrorAction SilentlyContinue
	$iphlpStr =
		if (-not $iphlpsvc) { 'SERVICE MISSING' }
		elseif ($iphlpsvc.Status -ne 'Running') { "NOT RUNNING ($($iphlpsvc.Status))" }
		else { 'RUNNING' }

	Write-Host ""
	Write-Host "VM IP (resolved): $vmIp" -ForegroundColor Cyan
	Write-Host "IP Helper (iphlpsvc): $iphlpStr" -ForegroundColor $(if ($iphlpStr -eq 'RUNNING') { 'Green' } else { 'Red' })
	if ($iphlpStr -ne 'RUNNING') {
		Write-Host "  portproxy entries exist but kernel listener is INACTIVE until iphlpsvc runs." -ForegroundColor Yellow
		Write-Host "  Fix: .\port-forward.ps1 up  (starts iphlpsvc)" -ForegroundColor Yellow
	}
	Write-Host ""

	$hdr = "  {0,-5}  {1,-24} {2,-22} {3,-8} {4}" -f 'Port','Proxy','Firewall','Listen','Name'
	Write-Host $hdr -ForegroundColor Cyan
	Write-Host ("  {0,-5}  {1,-24} {2,-22} {3,-8} {4}" -f '----','-----','--------','------','----') -ForegroundColor Cyan

	foreach ($f in $FORWARDS) {
		$proxy = $all | Where-Object { $_.ListenPort -eq $f.ListenPort } | Select-Object -First 1
		$fw    = $rulesByPort[$f.ListenPort]
		$lst   = Test-PortListening $f.ListenPort

		$proxyStr =
			if (-not $proxy)                         { 'MISSING' }
			elseif ($proxy.ConnectAddress -ne $vmIp) { "STALE($($proxy.ConnectAddress))" }
			else                                     { "OK $($proxy.ConnectAddress):$($proxy.ConnectPort)" }

		$enabledStr = if ($fw) { "$($fw.Enabled)" } else { '' }
		$fwStr =
			if (-not $fw)                          { 'MISSING' }
			elseif ($enabledStr -notmatch 'True')  { 'DISABLED' }
			else                                   { 'OK' }

		$lstStr = if ($lst) { 'LISTEN' } else { 'NO' }

		$color =
			if ($proxyStr -like 'OK*' -and $fwStr -eq 'OK' -and $lst) { 'Green' }
			elseif ($proxyStr -eq 'MISSING' -and -not $fw -and -not $lst) { 'DarkGray' }
			else { 'Yellow' }

		$row = "  {0,-5}  {1,-24} {2,-22} {3,-8} {4}" -f $f.ListenPort, $proxyStr, $fwStr, $lstStr, $f.Name
		Write-Host $row -ForegroundColor $color
	}

	$unmanaged = $all | Where-Object { $_.ListenPort -notin $managedPorts }
	if ($unmanaged) {
		Write-Host ""
		Write-Host "Unmanaged portproxy entries (not touched by this script):" -ForegroundColor Yellow
		foreach ($r in $unmanaged) {
			Write-Host ("  [UNMANAGED] {0,5} -> {1}:{2}" -f $r.ListenPort, $r.ConnectAddress, $r.ConnectPort) -ForegroundColor Magenta
		}
	}

	$orphanFw = @()
	foreach ($rule in $ourRules) {
		if ("$($rule.DisplayName)" -match "$FW_PREFIX.*-(\d+)$") {
			if ([int]$Matches[1] -notin $managedPorts) {
				$orphanFw += $rule
			}
		}
	}
	if ($orphanFw.Count -gt 0) {
		Write-Host ""
		Write-Host "Orphaned know-ci firewall rules (stale ports):" -ForegroundColor Yellow
		foreach ($r in $orphanFw) {
			Write-Host ("  [ORPHAN] {0}" -f $r.DisplayName) -ForegroundColor Magenta
		}
	}

	Write-Host ""
	Write-Host "Note: run '.\port-forward.ps1 audit' to scan for OTHER firewall rules on managed ports (slow, CIM-bound)." -ForegroundColor DarkGray
	Write-Host ""
}

function Invoke-Audit {
	Assert-Admin
	$managedPorts = @($FORWARDS | ForEach-Object { $_.ListenPort })

	Write-Host "Loading inbound firewall rules (single CIM query)..." -ForegroundColor DarkGray
	try {
		$allRules = @(Get-NetFirewallRule -Direction Inbound -ErrorAction Stop)
	} catch {
		Write-Host "CIM query failed: $($_.Exception.Message)" -ForegroundColor Red
		return
	}
	Write-Host "  Loaded $($allRules.Count) rules." -ForegroundColor DarkGray

	$candidates = @()
	foreach ($rule in $allRules) {
		if ("$($rule.Action)"     -notmatch 'Allow') { continue }
		if ("$($rule.Enabled)"    -notmatch 'True')  { continue }
		if ("$($rule.DisplayName)" -like "$FW_PREFIX*") { continue }
		$candidates += $rule
	}
	Write-Host "  $($candidates.Count) enabled allow rules outside know-ci prefix." -ForegroundColor DarkGray

	if ($candidates.Count -eq 0) {
		Write-Host "No candidate rules to scan." -ForegroundColor Green
		return
	}

	Write-Host "Querying port filters per candidate (may take 30-90s on PS 5.1)..." -ForegroundColor DarkGray
	$matches = @()
	$i = 0
	foreach ($rule in $candidates) {
		$i++
		if ($i % 20 -eq 0) {
			Write-Host ("  ... {0}/{1}" -f $i, $candidates.Count) -ForegroundColor DarkGray
		}
		try {
			$pf = $rule | Get-NetFirewallPortFilter -ErrorAction Stop
			if (-not $pf) { continue }
			$lp = $pf.LocalPort
			if (-not $lp) { continue }
			foreach ($item in @($lp)) {
				$s = "$item"
				if ($s -match '^\d+$' -and [int]$s -in $managedPorts) {
					$matches += [pscustomobject]@{
						Port        = [int]$s
						DisplayName = "$($rule.DisplayName)"
					}
					break
				}
			}
		} catch { }
	}

	if ($matches.Count -eq 0) {
		Write-Host ""
		Write-Host "No other firewall rules found on managed ports. Clean." -ForegroundColor Green
	} else {
		Write-Host ""
		Write-Host "Other firewall rules on managed ports:" -ForegroundColor Yellow
		foreach ($m in $matches) {
			Write-Host ("  Port {0,-5} -> {1}" -f $m.Port, $m.DisplayName)
		}
	}
}

function Invoke-Up {
	Assert-Admin
	Assert-IPHelperRunning
	Assert-FirewallProfilesEnabled
	$vmIp = Get-VmIp
	Write-Host "Applying portproxy + firewall to VM at $vmIp" -ForegroundColor Cyan
	foreach ($f in $FORWARDS) {
		Add-Forward             -LP $f.ListenPort -VmIp $vmIp -VP $f.VMPort
		Add-FirewallRuleForPort -Port $f.ListenPort -Name $f.Name
		Write-Host ("  [OK] {0,5} -> {1}:{2}  +fw LocalSubnet  {3}" -f $f.ListenPort, $vmIp, $f.VMPort, $f.Desc) -ForegroundColor Green
	}
	Write-Host ""
	Write-Host "Verify from Mac:"
	Write-Host "  nc -zv 172.20.10.4 3001 && echo gitea-http OK"
	Write-Host "  nc -zv 172.20.10.4 2222 && echo gitea-ssh OK"
	Write-Host "  nc -zv 172.20.10.4 4317 && echo otlp-grpc OK"
	Write-Host "  nc -zv 172.20.10.4 3000 && echo grafana OK"
}

function Invoke-Down {
	Assert-Admin
	Write-Host "Removing all managed portproxy + firewall rules" -ForegroundColor Cyan
	foreach ($f in $FORWARDS) {
		Remove-Forward             -LP $f.ListenPort
		Remove-FirewallRuleForPort -Port $f.ListenPort
		Write-Host ("  [REMOVED] {0,5}  {1}" -f $f.ListenPort, $f.Name)
	}
	Write-Host ""
	Write-Host "Note: SSH forward on 2022 was never managed by this script and was NOT removed." -ForegroundColor Yellow
}

function Invoke-Cleanup {
	Assert-Admin
	Write-Host "Scanning for unmanaged portproxy entries and orphan firewall rules..." -ForegroundColor Cyan
	$managedPorts = @($FORWARDS | ForEach-Object { $_.ListenPort })

	$unmanaged = (Get-AllPortproxyEntries) | Where-Object { $_.ListenPort -notin $managedPorts }
	foreach ($r in $unmanaged) {
		Write-Host ("  [UNMANAGED portproxy] {0} -> {1}:{2}" -f $r.ListenPort, $r.ConnectAddress, $r.ConnectPort) -ForegroundColor Yellow
		$resp = Read-Host "    Remove? [y/N]"
		if ($resp -eq 'y') {
			Remove-Forward -LP $r.ListenPort
			Write-Host "    [REMOVED]"
		}
	}

	foreach ($rule in (Get-AllKnowFirewallRules)) {
		if ($rule.DisplayName -match "$FW_PREFIX.*-(\d+)$") {
			if ([int]$Matches[1] -notin $managedPorts) {
				Write-Host ("  [ORPHAN firewall] {0}" -f $rule.DisplayName) -ForegroundColor Yellow
				$resp = Read-Host "    Remove? [y/N]"
				if ($resp -eq 'y') {
					Remove-NetFirewallRule -Name $rule.Name
					Write-Host "    [REMOVED]"
				}
			}
		}
	}
	Write-Host "Done."
}

switch ($Action) {
	'up'      { Invoke-Up }
	'down'    { Invoke-Down }
	'status'  { Show-Status }
	'audit'   { Invoke-Audit }
	'cleanup' { Invoke-Cleanup }
	'refresh' { Invoke-Up }
}