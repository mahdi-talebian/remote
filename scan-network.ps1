<#
.SYNOPSIS
    Scans the local network (default: the /24 subnet of this machine's LAN IP)
    for hosts with an open SSH port (22) and prints their SSH addresses.
    Saves the list to .\ssh-addresses.txt  (LAN mode)

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scan-network.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scan-network.ps1 -Subnet 192.168.1.0/24 -UserName it_remote
#>

param(
    [string]$UserName = 'it_remote',
    [string]$Subnet = ''
)

# --- shared LAN helpers (kept standalone on purpose; gui\AdminConsole.ps1 carries its own copy) ---

function Get-LocalIp {
    # Best-effort LAN IPv4 of THIS machine (default-route interface first).
    $isWin = ($env:OS -eq 'Windows_NT')
    if ($isWin) {
        try {
            $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
                Sort-Object RouteMetric | Select-Object -First 1
            if ($route) {
                $ip = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } | Select-Object -First 1
                if ($ip) { return [string]$ip.IPAddress }
            }
        } catch { }
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceAlias -ne 'Loopback' -and $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
            Select-Object -First 1
        if ($ip) { return [string]$ip.IPAddress }
        return ''
    }
    $out = (& ip route get 1.1.1.1 2>$null | Select-Object -First 1)
    if ($out -match 'src\s+(\d{1,3}(?:\.\d{1,3}){3})') { return $matches[1] }
    $out = (& hostname -I 2>$null | Select-Object -First 1)
    if ($out) { return ([string]$out).Trim().Split(' ')[0] }
    return ''
}

function Get-LocalSubnet {
    # The /24 that contains the given (or this machine's) LAN IP:  '192.168.1.0/24'
    param([string]$Ip = '')
    if (-not $Ip) { $Ip = Get-LocalIp }
    if ($Ip -notmatch '^(\d{1,3}\.){3}\d{1,3}$') { return '' }
    return ('{0}.0/24' -f (($Ip.Split('.')[0..2]) -join '.'))
}

function Get-SubnetHosts {
    # '192.168.1.0/24' -> 192.168.1.1 .. 192.168.1.254   (string[])
    param([string]$Cidr)
    if ($Cidr -notmatch '^(\d{1,3}\.){3}\d{1,3}/24$') { return @() }
    $base = ($Cidr.Split('/')[0]).Split('.')[0..2] -join '.'
    return @(1..254 | ForEach-Object { '{0}.{1}' -f $base, $_ })
}

function Find-SshHosts {
    # Parallel async TCP-connect sweep for an open TCP port. Returns the IPs that answered.
    param([string]$Cidr, [int]$Port = 22, [int]$TimeoutMs = 800, [string[]]$ExcludeIps = @())
    if (-not $Cidr) { return @() }
    $targets = @(Get-SubnetHosts -Cidr $Cidr | Where-Object { $ExcludeIps -notcontains $_ })
    if ($targets.Count -eq 0) { return @() }
    $pending = @()
    foreach ($ip in $targets) {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($ip, $Port, $null, $null)
        $pending += [pscustomobject]@{ Client = $client; Async = $iar; Ip = $ip }
    }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    $found = @()
    foreach ($p in $pending) {
        $remain = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $signaled = $p.Async.AsyncWaitHandle.WaitOne($remain)
        if ($signaled -and $p.Client.Connected) { $found += $p.Ip }
        try { $p.Client.Close() } catch { }
    }
    return @($found)
}

function Get-HostNameForIp {
    # Best-effort reverse DNS; '' when it cannot be resolved.
    param([string]$Ip)
    try {
        $entry = [System.Net.Dns]::GetHostEntry($Ip)
        if ($entry -and $entry.HostName) { return ($entry.HostName -split '\.')[0] }
    } catch { }
    return ''
}

# --- main ---
$cidr = $Subnet
if (-not $cidr) { $cidr = Get-LocalSubnet }
if (-not $cidr) {
    Write-Host 'Could not determine the local subnet. Pass it explicitly: -Subnet 192.168.1.0/24'
    exit 1
}
$own = Get-LocalIp
Write-Host ('Scanning {0} for SSH (port 22) ... (takes a few seconds)' -f $cidr)
$ips = Find-SshHosts -Cidr $cidr -ExcludeIps @($own)
$rows = @()
foreach ($ip in $ips) {
    $rows += [pscustomobject]@{ Host = (Get-HostNameForIp -Ip $ip); IP = $ip; Address = ('{0}@{1}' -f $UserName, $ip) }
}
if (-not $rows) {
    Write-Host 'No SSH hosts found. Are the employee machines deployed and on the same network?'
    exit 0
}
Write-Host '============================================================'
Write-Host ('  SSH addresses on {0}  (user: {1})' -f $cidr, $UserName)
Write-Host '============================================================'
foreach ($r in $rows) {
    $name = if ($r.Host) { '  (' + $r.Host + ')' } else { '' }
    Write-Host ('ssh {0}{1}' -f $r.Address, $name)
}
$out = @()
$out += 'Generated: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')
$out += ('User: {0}   (password = the one chosen at deployment)' -f $UserName)
$out += ''
foreach ($r in $rows) {
    $out += ('ssh {0}' -f $r.Address)
    $out += ('        ip: {0}   host: {1}' -f $r.IP, $r.Host)
}
$out | Set-Content -Path (Join-Path $PSScriptRoot 'ssh-addresses.txt') -Encoding UTF8
Write-Host ('Saved to: {0}' -f (Join-Path $PSScriptRoot 'ssh-addresses.txt'))
