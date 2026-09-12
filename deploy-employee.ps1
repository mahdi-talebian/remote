<#
.SYNOPSIS
    One-time deployment script for employee machines. (v4 - LAN mode)

    - Enables OpenSSH Server (sshd) with password auth, auto-start
      (Windows: OpenSSH capability + service; Linux: sshd binary + service)
    - Creates a local administrator account (default: it_remote)
    - Opens firewall port 22 for the local network (Private/Domain profiles)
      and switches Public network profiles to Private
    - Writes the SSH address to <BaseDir>\ssh-address.txt and last-address.txt
    - Prints markers for the GUI wizard:
          SSH-ADDRESS: it_remote@192.168.1.50
          [DEPLOY-STATUS] SUCCESS

    Console output is intentionally ASCII-English (readable in any encoding);
    the full log is written to <BaseDir>\deploy.log.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\deploy-employee.ps1 `
        -AdminPassword "ChangeMe-Str0ng!" -Hostname "accounting-pc-01"

.NOTES
    Run as Administrator (Windows) or root (Linux). Idempotent - safe to re-run.
    BaseDir: Windows = C:\ProgramData\RemoteAdmin
             Linux   = $HOME/.remote-admin   (override with $env:RA_BASEDIR)
    The SSH address is the machine's LAN IPv4 (the admin PC must be on the
    same network / behind the same router).
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$AdminPassword,

    [string]$Hostname = $env:COMPUTERNAME,
    [string]$UserName = 'it_remote',
    [string]$LanIp = '',
    [switch]$AllowNonAdmin
)

$ErrorActionPreference = 'Stop'
$WarningPreference    = 'SilentlyContinue'
$ProgressPreference   = 'SilentlyContinue'

# --- OS detection (PS 7 has $IsWindows; PS 5.1 uses $env:OS) -----------------
$IsWin = ($env:OS -eq 'Windows_NT') -or ($PSVersionTable.PSVersion.Major -ge 6 -and $IsWindows -eq $true)

$BaseDir = if ($IsWin) { 'C:\ProgramData\RemoteAdmin' }
           elseif ($env:RA_BASEDIR) { $env:RA_BASEDIR }
           else { Join-Path $HOME '.remote-admin' }
$LogFile  = Join-Path $BaseDir 'deploy.log'
$AddrFile = Join-Path $BaseDir 'ssh-address.txt'

# --- logging: console (ASCII only) + file (UTF-8, full detail) -------------
function Log {
    param([string]$Message)
    Write-Host $Message
    try { Add-Content -Path $LogFile -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
}
function LogWarn {
    param([string]$Message)
    Log ('[WARNING] ' + $Message)
}
function Exit-Script {
    param([int]$Code, [string]$Mark)
    Log "[DEPLOY-STATUS] $Mark"
    exit $Code
}

function Get-LocalIp {
    # Best-effort LAN IPv4 (default-route interface first). -LanIp overrides.
    param([string]$Override)
    if ($Override) { return $Override }
    if ($IsWin) {
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

try {

    # ---------------------------------------------------------------
    # 0. Must run elevated
    # ---------------------------------------------------------------
    $isAdmin = $false
    if ($IsWin) {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } else {
        $uidOut = (& id -u 2>$null | Select-Object -First 1)
        $isAdmin = ($uidOut -eq '0')
    }
    if (-not $isAdmin -and -not $AllowNonAdmin) {
        Log 'ERROR: this script must run as Administrator (Windows) or root (Linux).'
        exit 1
    }
    New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
    Log '= Remote Admin deploy v4 (LAN mode) ='

    # ---------------------------------------------------------------
    # 1. OpenSSH Server (sshd)
    # ---------------------------------------------------------------
    Log 'Step 1/4: OpenSSH Server ...'
    if ($IsWin) {
        $sshdPresent = $false
        try { if (Get-Service -Name sshd -ErrorAction SilentlyContinue) { $sshdPresent = $true } } catch { }
        if (-not $sshdPresent) {
            try {
                $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction SilentlyContinue
                if (-not $cap -or $cap.State -ne 'Installed') {
                    Log 'Installing OpenSSH Server capability (this can take a few minutes)...'
                    Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
                }
            } catch { LogWarn ("OpenSSH capability install failed: {0}" -f $_.Exception.Message) }
        }
        try {
            Set-Service -Name sshd -StartupType Automatic -ErrorAction Stop
            Start-Service -Name sshd -ErrorAction Stop
            Log 'OpenSSH Server service is running (auto-start).'
        } catch { LogWarn ("Could not start sshd: {0}" -f $_.Exception.Message) }
        $cfgFile = Join-Path $env:ProgramData 'ssh\sshd_config'
        if (Test-Path $cfgFile) {
            $cfg = Get-Content -Path $cfgFile
            $cfg = $cfg -replace '^\s*#?\s*PasswordAuthentication\s+\S+',       'PasswordAuthentication yes'
            $cfg = $cfg -replace '^\s*#?\s*KbdInteractiveAuthentication\s+\S+', 'KbdInteractiveAuthentication no'
            $cfg = $cfg -replace '^\s*#?\s*ChallengeResponseAuthentication\s+\S+', 'ChallengeResponseAuthentication no'
            Set-Content -Path $cfgFile -Value $cfg -Encoding Ascii
            try { Restart-Service -Name sshd -ErrorAction Stop } catch { }
            Log 'sshd_config: password authentication enabled.'
        } else { LogWarn 'sshd_config not found (OpenSSH Server may not be installed yet).' }
    } else {
        $sshdCmd = Get-Command sshd -ErrorAction SilentlyContinue
        if ($sshdCmd) {
            Log ('OpenSSH server binary found: {0}' -f $sshdCmd.Source)
            try {
                $st = (& systemctl is-active ssh 2>$null | Select-Object -First 1)
                if ($st -eq 'active') { Log 'sshd service is active.' }
                else { LogWarn 'sshd not running - start it with: sudo systemctl enable --now ssh' }
            } catch { LogWarn ('Could not probe sshd service: {0}' -f $_.Exception.Message) }
        } else {
            LogWarn 'sshd binary not found - the SSH server must be installed/enabled by the OS administrator.'
        }
    }

    # ---------------------------------------------------------------
    # 2. Remote administration account
    # ---------------------------------------------------------------
    Log ('Step 2/4: remote account {0} ...' -f $UserName)
    if ($IsWin) {
        $secPwd = ConvertTo-SecureString -String $AdminPassword -AsPlainText -Force
        if (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue) {
            Set-LocalUser -Name $UserName -Password $secPwd
        } else {
            New-LocalUser -Name $UserName -Password $secPwd -PasswordNeverExpires `
                -FullName 'Remote Admin' -Description 'Remote administration account' | Out-Null
        }
        $admins = Get-LocalGroup -SID 'S-1-5-32-544'   # Administrators (language-independent)
        $isMember = $false
        try { $null = Get-LocalGroupMember -Group $admins -Member $UserName -ErrorAction Stop; $isMember = $true } catch { }
        if ($isMember) { Log ("{0} is already a member of Administrators." -f $UserName) }
        else {
            try { Add-LocalGroupMember -Group $admins -Member $UserName -ErrorAction Stop }
            catch { LogWarn ("Add to Administrators failed: {0}" -f $_.Exception.Message) }
        }
        Log ("Local user '{0}' ready (member of Administrators)." -f $UserName)
    } else {
        $uidChk = (& id -u $UserName 2>$null | Select-Object -First 1)
        if ($uidChk) {
            Log ("local user '{0}' already exists (uid {1})." -f $UserName, $uidChk)
        } else {
            $out = (& useradd -m -s /bin/bash $UserName 2>&1)
            if ($LASTEXITCODE -eq 0) { Log ("local user '{0}' created." -f $UserName) }
            else { LogWarn ("useradd failed: {0}" -f (($out | Out-String).Trim())) }
        }
        if ((& id -u) -eq '0') {
            ("{0}:{1}" -f $UserName, $AdminPassword) | & chpasswd 2>$null
            if ($LASTEXITCODE -eq 0) { Log ('password for {0} updated.' -f $UserName) }
            else { LogWarn ('chpasswd failed - set the password manually.') }
        } else {
            LogWarn 'not running as root - password change skipped (set it manually).'
        }
    }

    # ---------------------------------------------------------------
    # 3. Firewall: inbound 22 on the local network (LAN mode)
    # ---------------------------------------------------------------
    if ($IsWin) {
        Log 'Step 3/4: firewall (LAN) ...'
        try {
            Remove-NetFirewallRule -DisplayName 'OpenSSH Server (Tailscale only)' -ErrorAction SilentlyContinue
            Remove-NetFirewallRule -DisplayName 'OpenSSH Server (LAN)' -ErrorAction SilentlyContinue
            New-NetFirewallRule -DisplayName 'OpenSSH Server (LAN)' -Direction Inbound `
                -Protocol TCP -LocalPort 22 -Action Allow -Profile Private, Domain -ErrorAction Stop | Out-Null
            Log 'Firewall: port 22 allowed (Private/Domain profiles).'
        } catch { LogWarn ("Firewall rule failed: {0}" -f $_.Exception.Message) }
        try {
            $pubs = @(Get-NetConnectionProfile | Where-Object { $_.NetworkCategory -eq 'Public' })
            foreach ($p in $pubs) {
                Set-NetConnectionProfile -InterfaceIndex $p.InterfaceIndex -NetworkCategory Private
                Log ("network profile '{0}' switched Public -> Private (required for the firewall rule)." -f $p.Name)
            }
        } catch { LogWarn ("Could not switch network profile to Private: {0}" -f $_.Exception.Message) }
    } else {
        Log 'Step 3/4: firewall ... skipped (Windows-specific step; port 22 is governed by the OS firewall).'
    }

    # ---------------------------------------------------------------
    # 4. Build the SSH address (LAN IP)
    # ---------------------------------------------------------------
    Log 'Step 4/4: building SSH address ...'
    $ip4 = Get-LocalIp -Override $LanIp
    $hostLower = ($Hostname -replace '[^a-zA-Z0-9-]', '-').ToLower()
    if ($ip4) { $sshAddress = "$UserName@$ip4" }
    else {
        LogWarn 'No LAN IPv4 found - falling back to the hostname (may not resolve).'
        $sshAddress = "$UserName@$hostLower"
    }

    $summary = @(
        '===================================================================='
        ('  REMOTE SSH ADDRESS  ->   ssh {0}' -f $sshAddress)
        ('  Alternative (name)  ->   ssh {0}@{1}   (works if the name resolves)' -f $UserName, $hostLower)
        ('  User / Password    ->   {0} / <the AdminPassword you entered>' -f $UserName)
        '  Both PCs must be on the SAME local network (same router).'
        '  From YOUR machine: run AdminConsole (refresh) or scan-network.ps1.'
        '===================================================================='
    )
    foreach ($s in $summary) { Log $s }

    Write-Host ('SSH-ADDRESS: {0}' -f $sshAddress)
    Write-Host ('IP-FALLBACK: {0}' -f $sshAddress)

    Set-Content -Path $AddrFile -Encoding UTF8 -Value @(
        "SSH-ADDRESS: ssh $sshAddress"
        "IP fallback: ssh $sshAddress"
        "Hostname:    $hostLower"
        "User:        $UserName"
        "Log:         $LogFile"
    )
    Set-Content -Path (Join-Path $BaseDir 'last-address.txt') -Encoding UTF8 -Value ("ssh {0}" -f $sshAddress)

    if ($ip4) {
        Log 'Deployment complete.'
        Exit-Script -Code 0 -Mark 'SUCCESS'
    } else {
        LogWarn 'No LAN IPv4 was found - the address may not be reachable.'
        Exit-Script -Code 1 -Mark 'FAILED : no LAN IPv4 found'
    }

} catch {
    Log ("[DEPLOY-STATUS] FAILED : {0}" -f $_.Exception.Message)
    Log ('Stack: ' + $_.ScriptStackTrace)
    Write-Host 'DEPLOY-STATUS: FAILED'
    exit 1
}
