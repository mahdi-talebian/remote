<#
.SYNOPSIS
    GUI setup wizard (employee side, one-time). v3 (LAN mode)

    - Validates the hostname and password
    - Runs deploy-employee.ps1 with live log (read from file - reliable)
    - Shows the SSH address on success; shows the exact error tail on failure

    No installation needed - Windows Forms / PowerShell.
    Run:  powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\SetupWizard.ps1
         (or just double-click SetupWizard.bat)

.NOTES
    Re-launches itself elevated if needed (deployment needs Admin).
    All live-log lines are ASCII so the log box stays readable; Persian text
    is shown in message boxes (which render Unicode correctly).
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------
# Elevation check (deployment needs Admin)
# ---------------------------------------------------------------
$isAdmin = ([System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [System.Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $r = [System.Windows.Forms.MessageBox]::Show(
        'برای استقرار، این برنامه باید با دسترسی Administrator اجرا شود.' + [Environment]::NewLine + [Environment]::NewLine +
        'آیا همین حالا با دسترسی Administrator دوباره اجرا شود؟',
        'دسترسی مدیر', 'YesNo', 'Question')
    if ($r -eq 'Yes') {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"' + $PSCommandPath + '"')
        ) -Verb RunAs
    }
    exit
}

# ---------------------------------------------------------------
# Theme
# ---------------------------------------------------------------
$cBg    = [System.Drawing.Color]::FromArgb(244, 246, 250)
$cCard  = [System.Drawing.Color]::White
$cNavy  = [System.Drawing.Color]::FromArgb(31, 45, 84)
$cText  = [System.Drawing.Color]::FromArgb(30, 35, 45)
$cBlue  = [System.Drawing.Color]::FromArgb(46, 107, 230)
$cGreen = [System.Drawing.Color]::FromArgb(21, 148, 74)
$cGray  = [System.Drawing.Color]::FromArgb(95, 104, 122)
$cLight = [System.Drawing.Color]::FromArgb(229, 233, 240)
$cLogBg = [System.Drawing.Color]::FromArgb(13, 20, 33)
$cLogFg = [System.Drawing.Color]::FromArgb(205, 220, 235)

$fBase  = New-Object System.Drawing.Font('Tahoma', 9)
$fBold  = New-Object System.Drawing.Font('Tahoma', 9, [System.Drawing.FontStyle]::Bold)
$fTitle = New-Object System.Drawing.Font('Tahoma', 12, [System.Drawing.FontStyle]::Bold)
$fMono  = New-Object System.Drawing.Font('Consolas', 9)

function New-FlatButton {
    param([string]$Text, [int]$W, [System.Drawing.Color]$Back, [System.Drawing.Color]$Fore)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Size = New-Object System.Drawing.Size($W, 36)
    $b.BackColor = $Back; $b.ForeColor = $Fore
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = 0
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.Font = $fBold
    $b.TabStop = $false
    return $b
}

# ---------------------------------------------------------------
# State
# ---------------------------------------------------------------
$script:Proc          = $null
$script:LastAddress   = ''
$script:OutPos        = 0
$script:ErrPos        = 0
$script:OutFile       = ''
$script:ErrFile       = ''

# ---------------------------------------------------------------
# Form shell
# ---------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'ویزارد استقرار دسترسی از راه دور - SSH'
$form.Size = New-Object System.Drawing.Size(780, 640)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $cBg
$form.Font = $fBase
$form.RightToLeft = 'Yes'
$form.MinimumSize = New-Object System.Drawing.Size(700, 560)

$layout = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'; $layout.ColumnCount = 1; $layout.RowCount = 5
$layout.BackColor = $cBg
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 60)))   | Out-Null
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 170))) | Out-Null
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))  | Out-Null
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 26)))   | Out-Null
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 58)))   | Out-Null
$form.Controls.Add($layout)

# --- header ---------------------------------------------------
$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Fill'; $header.BackColor = $cNavy; $header.Padding = New-Object System.Windows.Forms.Padding(0, 0, 18, 0)
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'ویزارد استقرار دسترسی از راه دور' + [Environment]::NewLine + 'این برنامه یک بار اجرا می شود و کامپیوتر را برای اتصال SSH آماده می کند'
$lblTitle.ForeColor = [System.Drawing.Color]::White
$lblTitle.Font = $fTitle
$lblTitle.Dock = 'Fill'; $lblTitle.TextAlign = 'MiddleRight'
$header.Controls.Add($lblTitle)
$layout.Controls.Add($header, 0, 0)

# --- inputs ---------------------------------------------------
$group = New-Object System.Windows.Forms.GroupBox
$group.Dock = 'Fill'; $group.Text = '  تنظیمات  '
$group.ForeColor = $cText
$group.Padding = New-Object System.Windows.Forms.Padding(16, 10, 16, 6)

$lblHost = New-Object System.Windows.Forms.Label
$lblHost.Text = 'نام دستگاه (برای نمایش در فهرست):'; $lblHost.AutoSize = $true; $lblHost.Location = New-Object System.Drawing.Point(440, 30)
$txtHost = New-Object System.Windows.Forms.TextBox
$txtHost.Text = $env:COMPUTERNAME; $txtHost.Location = New-Object System.Drawing.Point(200, 27); $txtHost.Width = 260
$txtHost.RightToLeft = 'No'; $txtHost.Font = $fMono

$lblPass = New-Object System.Windows.Forms.Label
$lblPass.Text = 'رمز عبور مدیر (it_remote):'; $lblPass.AutoSize = $true; $lblPass.Location = New-Object System.Drawing.Point(440, 64)
$txtPass = New-Object System.Windows.Forms.TextBox
$txtPass.Location = New-Object System.Drawing.Point(200, 61); $txtPass.Width = 480
$txtPass.UseSystemPasswordChar = $true; $txtPass.RightToLeft = 'No'

$lblPass2 = New-Object System.Windows.Forms.Label
$lblPass2.Text = 'تکرار رمز عبور:'; $lblPass2.AutoSize = $true; $lblPass2.Location = New-Object System.Drawing.Point(492, 98)
$txtPass2 = New-Object System.Windows.Forms.TextBox
$txtPass2.Location = New-Object System.Drawing.Point(200, 95); $txtPass2.Width = 480
$txtPass2.UseSystemPasswordChar = $true; $txtPass2.RightToLeft = 'No'

$chkShow = New-Object System.Windows.Forms.CheckBox
$chkShow.Text = 'نمایش رمز عبور'; $chkShow.AutoSize = $true
$chkShow.Location = New-Object System.Drawing.Point(200, 129)
$chkShow.ForeColor = $cGray

foreach ($c in @($lblHost, $txtHost, $lblPass, $txtPass, $lblPass2, $txtPass2, $chkShow)) {
    $group.Controls.Add($c)
}
$layout.Controls.Add($group, 0, 1)

# --- log ------------------------------------------------------
$logPanel = New-Object System.Windows.Forms.Panel
$logPanel.Dock = 'Fill'; $logPanel.BackColor = $cCard; $logPanel.Padding = New-Object System.Windows.Forms.Padding(14)
$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Dock = 'Fill'
$logBox.Multiline = $true; $logBox.ReadOnly = $true; $logBox.ScrollBars = 'Both'
$logBox.WordWrap = $false; $logBox.BackColor = $cLogBg; $logBox.ForeColor = $cLogFg
$logBox.Font = $fMono; $logBox.BorderStyle = 'None'; $logBox.RightToLeft = 'No'
$logBox.Text = 'Ready. Press the START button to begin.' + [Environment]::NewLine
$logPanel.Controls.Add($logBox)
$layout.Controls.Add($logPanel, 0, 2)

# --- progress ---------------------------------------------------
$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Dock = 'Fill'; $progress.Style = 'Blocks'; $progress.Minimum = 0; $progress.Maximum = 100; $progress.Value = 0
$progressPanel = New-Object System.Windows.Forms.Panel
$progressPanel.Dock = 'Fill'; $progressPanel.BackColor = $cBg; $progressPanel.Padding = New-Object System.Windows.Forms.Padding(14, 6, 14, 6)
$progressPanel.Controls.Add($progress)
$layout.Controls.Add($progressPanel, 0, 3)

# --- buttons ---------------------------------------------------
$btnPanel = New-Object System.Windows.Forms.Panel
$btnPanel.Dock = 'Fill'; $btnPanel.BackColor = $cCard; $btnPanel.Padding = New-Object System.Windows.Forms.Padding(14, 8, 14, 8)
$flow = New-Object System.Windows.Forms.FlowLayoutPanel
$flow.Dock = 'Fill'; $flow.FlowDirection = 'RightToLeft'; $flow.WrapContents = $false
$flow.Padding = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
$flow.RightToLeft = 'Yes'

$btnRun   = New-FlatButton 'شروع استقرار' 150 $cBlue ([System.Drawing.Color]::White)
$btnCopy  = New-FlatButton 'کپی آدرس SSH' 130 $cGreen ([System.Drawing.Color]::White)
$btnClose = New-FlatButton 'بستن' 80 $cLight $cText
$btnCopy.Enabled = $false
foreach ($b in @($btnRun, $btnCopy, $btnClose)) {
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    $flow.Controls.Add($b)
}
$btnPanel.Controls.Add($flow)
$layout.Controls.Add($btnPanel, 0, 4)

# ---------------------------------------------------------------
# Log helpers
# ---------------------------------------------------------------
function Add-LogText {
    param([string]$Text)
    $logBox.AppendText($Text + [Environment]::NewLine)
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
}

function Get-NewLines {
    param([string]$Path, [ref]$Pos)
    if (-not (Test-Path $Path)) { return @() }
    try {
        # @(...) is critical: with a single line Get-Content returns a STRING,
        # and string indexing would return single CHARACTERS, losing the line.
        $all = @(Get-Content -Path $Path -Encoding UTF8 -ErrorAction Stop)
    } catch { return @() }
    $new = @()
    if ($all.Count -gt $Pos.Value) {
        $new = @($all[$Pos.Value..($all.Count - 1)])   # keep it an array of strings
        $Pos.Value = $all.Count
    }
    return $new
}

function Parse-Address {
    <#
        Extracts the FULL usable 'ssh user@host' address from one log/file
        line. Tolerates every format the deploy script can emit:
          'SSH-ADDRESS: ssh it_remote@100.64.1.5'   (older format)
          'SSH-ADDRESS: it_remote@100.64.1.5'       (current format)
          'ssh it_remote@pc-01.mycorp.ts.net'       (last-address.txt)
          'it_remote@100.64.1.5'                    (bare)
        Returns '' when the line carries no valid address (e.g. the broken
        partial marker 'SSH-ADDRESS: ssh', which must NEVER be accepted).
    #>
    param([string]$Line)
    $t = ($Line -replace [char]0x200C, ' ').Trim()
    if ($t -match '(?i)^SSH-ADDRESS:\s*ssh\s+(\S+@\S+)') { return ('ssh ' + $matches[1]) }
    if ($t -match '(?i)^SSH-ADDRESS:\s*(\S+@\S+)')       { return ('ssh ' + $matches[1]) }
    if ($t -match '(?i)^ssh\s+(\S+@\S+)')                { return ('ssh ' + $matches[1]) }
    if ($t -match '^(\S+@\S+)$')                         { return ('ssh ' + $matches[1]) }
    return ''
}

function Get-AuthoritativeAddress {
    # The deploy script always writes these files - they are the most
    # reliable source of the SSH address (independent of console encoding).
    $dir = if ($env:RA_ADDR_DIR) { $env:RA_ADDR_DIR } else { 'C:\ProgramData\RemoteAdmin' }
    $candidates = @(
        (Join-Path $dir 'last-address.txt'),
        (Join-Path $dir 'ssh-address.txt')
    )
    foreach ($f in $candidates) {
        if (-not (Test-Path $f)) { continue }
        try {
            $lines = @(Get-Content -Path $f -Encoding UTF8 -ErrorAction Stop)
        } catch { continue }
        foreach ($l in $lines) {
            $a = Parse-Address -Line $l
            if ($a) { return $a }
        }
    }
    return ''
}

function Show-FinalError {
    param([int]$ExitCode, [string[]]$TailLines)
    $tail = ($TailLines | Select-Object -Last 25) -join [Environment]::NewLine
    if (-not $tail) { $tail = '(no output was produced - the script may not have started)' }
    [System.Windows.Forms.MessageBox]::Show(
        'استقرار با خطا پایان یافت (کد خروج: ' + $ExitCode + ').' + [Environment]::NewLine + [Environment]::NewLine +
        'آخرین خروجی:' + [Environment]::NewLine + $tail + [Environment]::NewLine + [Environment]::NewLine +
        'رایج ترین دلایل:' + [Environment]::NewLine +
        '1) فایروال/آنتی‌ویروس مانع نصب یا اجرای OpenSSH Server شده است' + [Environment]::NewLine +
        '2) متن کامل خطا را کپی کنید و برای پشتیبانی بفرستید',
        'خطا', 'OK', 'Error') | Out-Null
}

function Show-Success {
    $addrPlain = $script:LastAddress
    if ($addrPlain -notmatch '^ssh\s') { $addrPlain = 'ssh ' + $addrPlain }
    $hostPart  = if ($addrPlain -match '@(\S+)') { $matches[1] } else { $addrPlain }
    $extra = ''
    if ($script:AddressIsFallback) {
        $extra = [Environment]::NewLine + [Environment]::NewLine +
            'آدرس دقیق و کامل همیشه در این فایل است:' + [Environment]::NewLine +
            'C:\ProgramData\RemoteAdmin\ssh-address.txt'
    } elseif ($hostPart -match '@') {
        $extra = [Environment]::NewLine + [Environment]::NewLine +
            'نکته: نام tailnet شما شامل @ است و ssh با آن مشکل دارد.' + [Environment]::NewLine +
            'از آدرس IP استفاده کنید (در این فایل روی همین کامپیوتر):' + [Environment]::NewLine +
            'C:\ProgramData\RemoteAdmin\ssh-address.txt'
    }
    [System.Windows.Forms.MessageBox]::Show(
        'استقرار با موفقیت انجام شد.' + [Environment]::NewLine + [Environment]::NewLine +
        'آدرس SSH این کامپیوتر:' + [Environment]::NewLine +
        $addrPlain + [Environment]::NewLine + [Environment]::NewLine +
        '(در کلیپ بورد هم کپی شد)' + [Environment]::NewLine +
        'رمز ورود = همان رمزی که وارد کردید.' + [Environment]::NewLine +
        'روی سیستم مدیر از ترمینال یا کنسول مدیریت: ' + $addrPlain + ' استفاده کنید.' + $extra,
        'موفق', 'OK', 'Information') | Out-Null
}

# ---------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------
$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 400

function Start-Deployment {
    $hostName = $txtHost.Text.Trim()
    $pass1    = $txtPass.Text
    $pass2    = $txtPass2.Text

    # --- validation ---
    if ($hostName -notmatch '^[A-Za-z0-9\-]{1,63}$') {
        [System.Windows.Forms.MessageBox]::Show(
            'نام دستگاه نامعتبر است. فقط حروف انگلیسی، عدد و خط تیره (حداکثر 63 کاراکتر).',
            'اعتبارسنجی', 'OK', 'Warning') | Out-Null
        return
    }
    if ($pass1.Length -lt 8) {
        [System.Windows.Forms.MessageBox]::Show(
            'رمز عبور باید حداقل 8 کاراکتر باشد (پیشنهاد: 14 کاراکتر ترکیبی).',
            'اعتبارسنجی', 'OK', 'Warning') | Out-Null
        return
    }
    if ($pass1 -ne $pass2) {
        [System.Windows.Forms.MessageBox]::Show('تکرار رمز عبور با رمز اصلی یکی نیست.', 'اعتبارسنجی', 'OK', 'Warning') | Out-Null
        return
    }
    if ($pass1 -match '"') {
        [System.Windows.Forms.MessageBox]::Show('رمز عبور نباید شامل علامت " باشد.', 'اعتبارسنجی', 'OK', 'Warning') | Out-Null
        return
    }

    $deployScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'deploy-employee.ps1'
    if (-not (Test-Path $deployScript)) { $deployScript = Join-Path $PSScriptRoot 'deploy-employee.ps1' }
    if (-not (Test-Path $deployScript)) {
        [System.Windows.Forms.MessageBox]::Show(
            "فایل deploy-employee.ps1 پیدا نشد." + [Environment]::NewLine +
            "منتظر کنار این برنامه: " + [Environment]::NewLine + $deployScript,
            'خطا', 'OK', 'Error') | Out-Null
        return
    }

    # --- reset UI ---
    $logBox.Text = ''
    $group.Enabled = $false
    $btnRun.Enabled = $false
    $btnClose.Enabled = $false
    $btnCopy.Enabled = $false
    $progress.Style = 'Marquee'
    $script:LastAddress = ''
    $script:HostName = $hostName
    $script:OutPos = 0; $script:ErrPos = 0
    $script:OutFile = Join-Path $env:TEMP ("remoteadmin_out_{0}.log" -f $PID)
    $script:ErrFile = Join-Path $env:TEMP ("remoteadmin_err_{0}.log" -f $PID)
    Remove-Item $script:OutFile, $script:ErrFile -Force -ErrorAction SilentlyContinue

    Add-LogText 'Starting deployment (this can take several minutes)...'
    Add-LogText ('Script : ' + $deployScript)
    Add-LogText ''

    # --- launch ---
    # Arguments are passed via environment variables + -EncodedCommand so that
    # ANY password/path (even with spaces or quotes) is transmitted safely.
    $env:RA_PASS = $pass1
    $env:RA_HOST = $hostName
    $inner = @(
        '$WarningPreference = ''SilentlyContinue'''
        '$ProgressPreference = ''SilentlyContinue'''
        '& "{0}" -AdminPassword $env:RA_PASS -Hostname $env:RA_HOST' -f $deployScript
    ) -join [Environment]::NewLine
    $b64   = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($inner))
    try {
        $p = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $b64) `
            -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $script:OutFile `
            -RedirectStandardError  $script:ErrFile
        $script:Proc = $p
        $pollTimer.Start()
    } catch {
        $env:RA_PASS = $null; $env:RA_HOST = $null
        Add-LogText ('ERROR starting the deploy script: ' + $_.Exception.Message)
        $group.Enabled = $true; $btnRun.Enabled = $true; $btnClose.Enabled = $true
        $progress.Style = 'Blocks'; $progress.Value = 0
    }
}

$pollTimer.Add_Tick({
    if (-not $script:Proc) { $pollTimer.Stop(); return }

    # 1) stream new output lines into the log box
    $newOut = @(Get-NewLines -Path $script:OutFile -Pos ([ref]$script:OutPos))
    $newErr = @(Get-NewLines -Path $script:ErrFile -Pos ([ref]$script:ErrPos))
    foreach ($l in $newOut) {
        $a = Parse-Address -Line $l
        if ($a) { $script:LastAddress = $a }
        Add-LogText $l
    }
    foreach ($l in $newErr) {
        if ($l -match 'RefId=|Object Version=|S="serialize"|^\s*<') { continue }   # skip CLIXML noise
        Add-LogText ('[ERR] ' + $l)
    }

    # 2) still running?
    if (-not $script:Proc.HasExited) { return }

    # 3) finished
    $pollTimer.Stop()
    $exitCode = $script:Proc.ExitCode
    $script:Proc = $null

    # flush anything left in the files
    $newOut = @(Get-NewLines -Path $script:OutFile -Pos ([ref]$script:OutPos))
    foreach ($l in $newOut) {
        $a = Parse-Address -Line $l
        if ($a) { $script:LastAddress = $a }
        Add-LogText $l
    }
    $newErr = @(Get-NewLines -Path $script:ErrFile -Pos ([ref]$script:ErrPos))
    foreach ($l in $newErr) {
        if ($l -match 'RefId=|Object Version=|S="serialize"|^\s*<') { continue }   # skip CLIXML noise
        Add-LogText ('[ERR] ' + $l)
    }

    $all = @()
    foreach ($f in @($script:OutFile, $script:ErrFile)) {
        if (Test-Path $f) { $all += @(Get-Content $f -Encoding UTF8 -ErrorAction SilentlyContinue) }
    }

    $progress.Style = 'Blocks'; $progress.Value = 100
    $group.Enabled = $true; $btnRun.Enabled = $true; $btnClose.Enabled = $true

    # --- recovery: streamed line -> full output -> address files -> hostname ---
    # A partial value (e.g. 'ssh' without '@') must be treated as MISSING,
    # otherwise the recovery chain below never runs.
    if (-not $script:LastAddress -or $script:LastAddress -notmatch '@') { $script:LastAddress = '' }
    if (-not $script:LastAddress) {
        foreach ($l in $all) {
            $a = Parse-Address -Line $l
            if ($a) { $script:LastAddress = $a; break }
        }
    }
    if (-not $script:LastAddress) {
        $script:LastAddress = Get-AuthoritativeAddress
    }
    if (-not $script:LastAddress) {
        $script:LastAddress = 'ssh it_remote@' + (($script:HostName) -replace '[^a-zA-Z0-9-]', '-').ToLower()
        $script:AddressIsFallback = $true
    }

    $okMark = ($all -join ' ') -match '\[DEPLOY-STATUS\] SUCCESS'

    # The exit code is authoritative: deploy-employee.ps1 exits 0 ONLY on success.
    if ($exitCode -eq 0 -or $okMark) {
        Add-LogText ''
        Add-LogText '=== DEPLOYMENT FINISHED OK ==='
        Add-LogText ('SSH-ADDRESS: ' + $script:LastAddress)
        # auto-copy so the address can never get lost
        try { Set-Clipboard -Value $script:LastAddress } catch { }
        $btnCopy.Enabled = $true
        Show-Success
    } else {
        Add-LogText ''
        Add-LogText ('=== DEPLOYMENT FAILED (exit code: ' + $exitCode + ') ===')
        Show-FinalError -ExitCode $exitCode -TailLines $all
    }

    $env:RA_PASS = $null; $env:RA_HOST = $null
    Remove-Item $script:OutFile, $script:ErrFile -Force -ErrorAction SilentlyContinue
})

# ---------------------------------------------------------------
# Wire events
# ---------------------------------------------------------------
$btnRun.Add_Click({ Start-Deployment })
$chkShow.Add_CheckedChanged({
    $txtPass.UseSystemPasswordChar  = -not $chkShow.Checked
    $txtPass2.UseSystemPasswordChar = -not $chkShow.Checked
})
$btnCopy.Add_Click({
    if ($script:LastAddress) {
        Set-Clipboard -Value $script:LastAddress
        $btnCopy.Text = 'کپی شد!'
        $t = New-Object System.Windows.Forms.Timer
        $t.Interval = 1200
        $t.Add_Tick({ $t.Stop(); $t.Dispose(); $btnCopy.Text = 'کپی آدرس SSH' })
        $t.Start()
    }
})
$btnClose.Add_Click({ $form.Close() })

# ---------------------------------------------------------------
[void]$form.ShowDialog()
