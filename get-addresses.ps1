<#
.SYNOPSIS
    Run on YOUR machine (the one with Tailscale installed and logged into
    the same tailnet). Lists every employee machine and prints its SSH
    address, then saves the list to .\ssh-addresses.txt

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\get-addresses.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\get-addresses.ps1 -ShowOffline -UserName it_remote
#>

param(
    [string]$UserName = 'it_remote',
    [switch]$ShowOffline
)

# --- Tailscale CLI discovery (PATH first, then the Windows install path) ---
$tsExe = $null
$tsCmd = Get-Command tailscale -ErrorAction SilentlyContinue
if ($tsCmd) { $tsExe = $tsCmd.Source }
if (-not $tsExe -and (Test-Path 'C:\Program Files\Tailscale\tailscale.exe')) {
    $tsExe = 'C:\Program Files\Tailscale\tailscale.exe'
}
if (-not $tsExe) {
    Write-Host 'Tailscale CLI not found. Install it from https://tailscale.com/download/windows' -ForegroundColor Yellow
    exit 1
}

# --- tailnet name (for the *.ts.net magic DNS addresses) ---
$tailnet = ''
try {
    $j = (& $tsExe status --json 2>$null | Out-String) | ConvertFrom-Json
    if ($j -and $j.CurrentTailnet) { $tailnet = [string]$j.CurrentTailnet.Name }
} catch { }

# ssh cannot handle '@' or spaces in the host part
$safeTailnet = ($tailnet -match '^[A-Za-z0-9.\-]+$')

# --- parse `tailscale status` text output ---
$rows = @()
$lines = @(& $tsExe status 2>$null)
foreach ($line in $lines) {
    if ($line -notmatch '^(\d{1,3}\.){3}\d{1,3}\s+\S+') { continue }   # peer lines only
    $p      = $line -split '\s+'
    $ip     = $p[0]
    $host   = $p[1]
    $online = $line -notmatch 'offline'
    if (-not $online -and -not $ShowOffline) { continue }

    # build a safe SSH address
    if ($host -match '@| ')    { $dns = '';               $addr = "$UserName@$ip" }
    elseif ($safeTailnet -eq $false) { $dns = '';         $addr = "$UserName@$ip" }
    elseif ($host -match '\.') { $dns = $host;            $addr = "$UserName@$host" }
    elseif ($tailnet)          { $dns = "$host.$tailnet"; $addr = "$UserName@$dns" }
    else                       { $dns = '';               $addr = "$UserName@$ip" }

    $rows += [pscustomobject]@{
        Online  = $online
        Host    = $host
        IP      = $ip
        DNS     = $dns
        Address = $addr
    }
}

if (-not $rows) {
    Write-Host 'No machines found in the tailnet. Is Tailscale running and logged in?'
    exit 0
}

# --- print ---
Write-Host '============================================================'
Write-Host ('  SSH addresses  (user: {0})' -f $UserName)
Write-Host '============================================================'
foreach ($r in ($rows | Sort-Object -Property @{Expression = 'Online'; Descending = $true}, Host)) {
    $state = if ($r.Online) { 'ONLINE ' } else { 'OFFLINE' }
    Write-Host ('[{0}] ssh {1}' -f $state, $r.Address)
}

# --- save ---
$out = @()
$out += 'Generated: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')
$out += ('User: {0}   (password = the one you chose when deploying)' -f $UserName)
$out += ''
foreach ($r in ($rows | Sort-Object -Property Host)) {
    $state = if ($r.Online) { 'ONLINE' } else { 'OFFLINE' }
    $out += ('[{0}] ssh {1}' -f $state, $r.Address)
    $out += ('        ip: {0}   dns: {1}' -f $r.IP, $r.DNS)
}
$out | Set-Content -Path (Join-Path $PSScriptRoot 'ssh-addresses.txt') -Encoding UTF8
Write-Host ('Saved to: {0}' -f (Join-Path $PSScriptRoot 'ssh-addresses.txt'))
