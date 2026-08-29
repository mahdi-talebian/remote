<#
.SYNOPSIS
    One-time deployment script for employee machines. (v3 - cross-platform)

    - Enables OpenSSH Server (sshd) with password auth, auto-start
      (Windows: OpenSSH capability + service; Linux: sshd binary + service)
    - Creates a local administrator account (default: it_remote)
    - Installs/joins the Tailscale client (auto-reconnect, no public IP)
    - Opens firewall port 22 on the Tailscale interface (Windows; Linux: skipped)
    - Writes the SSH address to <BaseDir>\ssh-address.txt and last-address.txt
    - Prints markers for the GUI wizard:
          SSH-ADDRESS: ssh it_remote@pc-01.<tailnet>.ts.net
          [DEPLOY-STATUS] SUCCESS

    Console output is intentionally ASCII-English (readable in any encoding);
    the full bilingual log is written to <BaseDir>\deploy.log.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\deploy-employee.ps1 `
        -TailscaleAuthKey "tskey-auth-XXXX" -AdminPassword "ChangeMe-Str0ng!" -Hostname "accounting-pc-01"

.NOTES
    Run as Administrator (Windows) or root (Linux). Idempotent - safe to re-run.
    BaseDir: Windows = C:\ProgramData\RemoteAdmin
             Linux   = $HOME/.remote-admin   (override with $env:RA_BASEDIR)
    Tailscale discovery: 'tailscale' in PATH first, then the Windows install path.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$TailscaleAuthKey,

    [Parameter(Mandatory = $true)]
    [string]$AdminPassword,

    [string]$Hostname = $env:COMPUTERNAME,
    [string]$UserName = 'it_remote',
    [switch]$SkipTailscale,
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
$script:HadWarnings = $false
function LogWarn {
    param([string]$Message)
    $script:HadWarnings = $true
    Log ('[WARNING] ' + $Message)
}
function Exit-Script {
    param([int]$Code, [string]$Mark)
    Log "[DEPLOY-STATUS] $Mark"
    exit $Code
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
    Log "= Remote Admin deploy v3 (OS: $(if ($IsWin) { 'Windows' } else { 'Unix' })) ="

    # ---------------------------------------------------------------
    # 1. Auth key sanity check (catches the most common mistake)
    # ---------------------------------------------------------------
    if (-not $SkipTailscale -and $TailscaleAuthKey -notmatch 'tskey') {
        LogWarn ("The auth key does not look like a Tailscale key. Value starts with: {0}" -f $TailscaleAuthKey.Substring(0, [Math]::Min(20, $TailscaleAuthKey.Length)))
        LogWarn 'Expected something like: tskey-auth-XXXXXXXXXXXXX  (generate it at login.tailscale.com/admin/settings/keys, tick Reusable)'
    }

    # --- Tailscale CLI discovery (PATH first, then Windows install path) ---
    $tsExe = $null
    $tsCmd = Get-Command tailscale -ErrorAction SilentlyContinue
    if ($tsCmd) { $tsExe = $tsCmd.Source }
    if (-not $tsExe -and $IsWin -and (Test-Path 'C:\Program Files\Tailscale\tailscale.exe')) {
        $tsExe = 'C:\Program Files\Tailscale\tailscale.exe'
    }

    # ---------------------------------------------------------------
    # 2. OpenSSH Server (sshd)
    # ---------------------------------------------------------------
    Log 'Step 1/5: OpenSSH Server ...'
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
    # 3. Remote administration account
    # ---------------------------------------------------------------
    Log ('Step 2/5: remote account {0} ...' -f $UserName)
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
    # 4. Tailscale
    # ---------------------------------------------------------------
    $tsOk = $false
    if (-not $SkipTailscale) {
        Log 'Step 3/5: Tailscale ...'
        if (-not $tsExe -and $IsWin) {
            $winget = Get-Command winget -ErrorAction SilentlyContinue
            if ($winget) {
                Log 'Installing Tailscale via winget...'
                try {
                    & winget install --id tailscale.tailscale -e --silent --accept-package-agreements --accept-source-agreements
                    Start-Sleep -Seconds 5
                } catch { LogWarn ("winget install: {0}" -f $_.Exception.Message) }
            }
            if (-not $tsExe) {
                Log 'Winget not available, downloading Tailscale installer...'
                try {
                    Invoke-WebRequest -Uri 'https://pkgs.tailscale.com/stable/tailscale-setup.exe' `
                        -OutFile "$env:TEMP\tailscale-setup.exe" -UseBasicParsing
                    Start-Process -FilePath "$env:TEMP\tailscale-setup.exe" -ArgumentList '/quiet', '/norestart' -Wait
                } catch {
                    LogWarn ("Tailscale auto-install failed: {0}" -f $_.Exception.Message)
                    LogWarn 'Install Tailscale manually from https://tailscale.com/download/windows then re-run this script.'
                }
            }
            $waitUntil = (Get-Date).AddMinutes(3)
            while (-not $tsExe -and (Get-Date) -lt $waitUntil) {
                Start-Sleep -Seconds 5
                $c = Get-Command tailscale -ErrorAction SilentlyContinue
                if ($c) { $tsExe = $c.Source }
                if (-not $tsExe -and (Test-Path 'C:\Program Files\Tailscale\tailscale.exe')) { $tsExe = 'C:\Program Files\Tailscale\tailscale.exe' }
            }
        } elseif (-not $tsExe) {
            LogWarn 'tailscale CLI not found - install Tailscale (https://tailscale.com/download) then re-run.'
        }

        if ($tsExe) {
            $hostClean = ($Hostname -replace '[^a-zA-Z0-9-]', '-').ToLower()
            Log ("Joining tailnet as host '{0}' ..." -f $hostClean)
            & $tsExe up --authkey $TailscaleAuthKey --hostname $hostClean --accept-dns --timeout 90s
            if ($LASTEXITCODE -ne 0) {
                LogWarn ("tailscale up exited with code {0} - retrying once ..." -f $LASTEXITCODE)
                Start-Sleep -Seconds 8
                & $tsExe up --authkey $TailscaleAuthKey --hostname $hostClean --accept-dns --timeout 90s
                if ($LASTEXITCODE -ne 0) {
                    LogWarn 'tailscale up failed again. Check the auth key (must be tskey-auth-..., tick Reusable when creating it).'
                } else { $tsOk = $true }
            } else { $tsOk = $true }
            if ($tsOk) { Log 'Tailscale is up (background service, auto-reconnects after reboot).' }
        } else {
            LogWarn 'Tailscale is not available - the SSH address will not be reachable from outside.'
        }
    } else {
        Log 'Step 3/5: Tailscale skipped (-SkipTailscale).'
    }

    # ---------------------------------------------------------------
    # 5. Firewall: inbound 22, prefer the Tailscale interface only
    # ---------------------------------------------------------------
    if ($IsWin) {
        Log 'Step 4/5: firewall ...'
        try {
            Remove-NetFirewallRule -DisplayName 'OpenSSH Server (Tailscale only)' -ErrorAction SilentlyContinue
            $onTs = $false
            if (Get-NetAdapter -Name 'Tailscale' -ErrorAction SilentlyContinue) { $onTs = $true }
            if ($onTs) {
                New-NetFirewallRule -DisplayName 'OpenSSH Server (Tailscale only)' -Direction Inbound `
                    -Protocol TCP -LocalPort 22 -Action Allow -InterfaceAlias 'Tailscale' -ErrorAction Stop | Out-Null
                Log 'Firewall: port 22 allowed on the Tailscale interface only.'
            } else {
                New-NetFirewallRule -DisplayName 'OpenSSH Server (Tailscale only)' -Direction Inbound `
                    -Protocol TCP -LocalPort 22 -Action Allow -ErrorAction Stop | Out-Null
                LogWarn 'Firewall: Tailscale adapter not found - port 22 allowed on ALL interfaces (tighten as soon as possible).'
            }
        } catch { LogWarn ("Firewall rule failed: {0}" -f $_.Exception.Message) }
    } else {
        Log 'Step 4/5: firewall ... skipped (Windows-specific step; port 22 is governed by the OS firewall).'
    }

    # ---------------------------------------------------------------
    # 6. Build the SSH address
    # ---------------------------------------------------------------
    Log 'Step 5/5: building SSH address ...'
    $ip4 = ''; $tailnet = ''; $dnsName = ''
    if ($tsExe) {
        # 1) plain text command - the most reliable source of the tailnet IP
        $ips = @(& $tsExe ip -4 2>$null | Where-Object { $_ -and $_.Trim() -ne '' })
        if ($ips -and $ips.Count -gt 0) { $ip4 = [string]($ips[0]).Trim() }
        # 2) JSON fallback (also gives the tailnet + DNS names)
        try {
            $j = (& $tsExe status --json 2>$null | Out-String) | ConvertFrom-Json
            if ($j) {
                if ($j.CurrentTailnet) { $tailnet = [string]$j.CurrentTailnet.Name }
                if ($j.Self) {
                    if (-not $ip4 -and $j.Self.TailscaleIPs) { $ip4 = [string]@($j.Self.TailscaleIPs)[0] }
                    if ($j.Self.DNSName) { $dnsName = ([string]$j.Self.DNSName).TrimEnd('.') }
                }
            }
        } catch { }
    }

    $hostLower = ($Hostname -replace '[^a-zA-Z0-9-]', '-').ToLower()
    if (-not $dnsName) { $dnsName = "$hostLower.$tailnet" }
    # SSH cannot parse '@' or spaces inside the host part -> fall back to the
    # tailnet IP (this happens with email-style tailnets, e.g. user@gmail.com)
    if ($dnsName -match '^[A-Za-z0-9.\-]+$') { $sshAddress = "$UserName@$dnsName" }
    elseif ($ip4)                            { $sshAddress = "$UserName@$ip4" }
    else                                     { $sshAddress = "$UserName@$hostLower" }

    $summary = @(
        '===================================================================='
        ('  REMOTE SSH ADDRESS  ->   ssh {0}' -f $sshAddress)
        ('  IP fallback        ->   ssh {0}@{1}' -f $UserName, $ip4)
        ('  User / Password    ->   {0} / <the AdminPassword you entered>' -f $UserName)
        '  From YOUR machine (Tailscale logged in), run get-addresses.ps1 or open AdminConsole.'
        '===================================================================='
    )
    foreach ($s in $summary) { Log $s }

    Write-Host ('SSH-ADDRESS: {0}' -f $sshAddress)
    Write-Host ('IP-FALLBACK: {0}' -f "$UserName@$ip4")

    Set-Content -Path $AddrFile -Encoding UTF8 -Value @(
        "SSH-ADDRESS: ssh $sshAddress"
        "IP fallback: ssh $UserName@$ip4"
        "DNS name:    $dnsName"
        "Hostname:    $hostLower"
        "User:        $UserName"
        "Tailnet:     $tailnet"
        "Log:         $LogFile"
    )
    # single-line file with ONLY the usable address - easy to read programmatically
    Set-Content -Path (Join-Path $BaseDir 'last-address.txt') -Encoding UTF8 -Value ("ssh {0}" -f $sshAddress)

    if ($tsOk -or $SkipTailscale) {
        Log 'Deployment complete.'
        Exit-Script -Code 0 -Mark 'SUCCESS'
    } else {
        LogWarn 'Tailscale did NOT join the tailnet - the SSH address will NOT be reachable from outside.'
        LogWarn 'Fix the auth key (tskey-auth-..., Reusable ticked) and re-run, or install Tailscale manually.'
        Exit-Script -Code 1 -Mark 'FAILED : tailscale did not join the tailnet'
    }

} catch {
    Log ("[DEPLOY-STATUS] FAILED : {0}" -f $_.Exception.Message)
    Log ('Stack: ' + $_.ScriptStackTrace)
    Write-Host 'DEPLOY-STATUS: FAILED'
    exit 1
}
