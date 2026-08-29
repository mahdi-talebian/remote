<#
.SYNOPSIS
    GUI control panel (admin side).

    Shows every employee machine in your Tailscale tailnet with online/offline
    status and SSH addresses. Double-click a row (or press "Connect") to open
    an SSH terminal to that machine.

    No installation needed - built with Windows Forms / PowerShell.
    Run:  powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\AdminConsole.ps1
         (or just double-click AdminConsole.bat)

.NOTES
    Requires: Tailscale installed & logged in on THIS machine (admin side).
    PowerShell 5.1+ (ships with Windows 10/11).
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------
# Theme
# ---------------------------------------------------------------
$cBg    = [System.Drawing.Color]::FromArgb(244, 246, 250)
$cCard  = [System.Drawing.Color]::White
$cNavy  = [System.Drawing.Color]::FromArgb(31, 45, 84)
$cText  = [System.Drawing.Color]::FromArgb(30, 35, 45)
$cBlue  = [System.Drawing.Color]::FromArgb(46, 107, 230)
$cGreen = [System.Drawing.Color]::FromArgb(21, 148, 74)
$cRed   = [System.Drawing.Color]::FromArgb(220, 38, 38)
$cGray  = [System.Drawing.Color]::FromArgb(95, 104, 122)
$cLight = [System.Drawing.Color]::FromArgb(229, 233, 240)

$fBase   = New-Object System.Drawing.Font('Tahoma', 9)
$fBold   = New-Object System.Drawing.Font('Tahoma', 9, [System.Drawing.FontStyle]::Bold)
$fTitle  = New-Object System.Drawing.Font('Tahoma', 13, [System.Drawing.FontStyle]::Bold)
$fMono   = New-Object System.Drawing.Font('Consolas', 9.5)

function New-FlatButton {
    param([string]$Text, [int]$W, [System.Drawing.Color]$Back, [System.Drawing.Color]$Fore, [System.Drawing.Font]$F)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Size = New-Object System.Drawing.Size($W, 34)
    $b.BackColor = $Back; $b.ForeColor = $Fore
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = 0
    $b.FlatAppearance.MouseOverBackColor = $cLight
    if ($Back -ne $cLight) { $b.FlatAppearance.MouseOverBackColor = $Back }
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.Font = $F
    $b.TabStop = $false
    return $b
}

# ---------------------------------------------------------------
# State
# ---------------------------------------------------------------
$tsExe = 'C:\Program Files\Tailscale\tailscale.exe'
if (-not (Test-Path $tsExe)) {
    $tsExe = Get-Command tailscale -ErrorAction SilentlyContinue | ForEach-Object { $_.Source }
}
$script:Rows       = @()
$script:Tailnet    = ''
$script:RefreshJob = $null
$script:ToastTimer = $null

# ---------------------------------------------------------------
# Form shell
# ---------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'کنسول مدیریت از راه دور — SSH کارمندان'
$form.Size = New-Object System.Drawing.Size(1020, 680)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $cBg
$form.Font = $fBase
$form.RightToLeft = 'Yes'
$form.MinimumSize = New-Object System.Drawing.Size(860, 560)

$layout = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'; $layout.ColumnCount = 1; $layout.RowCount = 4
$layout.BackColor = $cBg
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 64)))  | Out-Null
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 58)))  | Out-Null
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))  | Out-Null
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 36)))  | Out-Null
$form.Controls.Add($layout)

# --- header -----------------------------------------------------
$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Fill'; $header.BackColor = $cNavy; $header.Padding = New-Object System.Windows.Forms.Padding(0, 0, 18, 0)
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "کنسول مدیریت SSH کارمندان`r`nلیست سیستم ها و اتصال از راه دور"
$lblTitle.ForeColor = [System.Drawing.Color]::White
$lblTitle.Font = $fTitle
$lblTitle.Dock = 'Fill'
$lblTitle.TextAlign = 'MiddleRight'
$header.Controls.Add($lblTitle)
$layout.Controls.Add($header, 0, 0)

# --- toolbar ----------------------------------------------------
$toolbar = New-Object System.Windows.Forms.Panel
$toolbar.Dock = 'Fill'; $toolbar.BackColor = $cCard; $toolbar.Padding = New-Object System.Windows.Forms.Padding(10, 10, 10, 6)

$flowL = New-Object System.Windows.Forms.FlowLayoutPanel
$flowL.Dock = 'Left'; $flowL.Width = 700; $flowL.Height = 40; $flowL.FlowDirection = 'LeftToRight'
$flowL.WrapContents = $false; $flowL.Padding = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)

$btnRefresh = New-FlatButton 'بروزرسانی' 130 $cBlue ([System.Drawing.Color]::White) $fBold
$btnConnect = New-FlatButton 'اتصال SSH' 100 $cGreen ([System.Drawing.Color]::White) $fBold
$btnCopy    = New-FlatButton 'کپی آدرس' 100 $cGray ([System.Drawing.Color]::White) $fBold
$btnSave    = New-FlatButton 'ذخیره لیست' 100 $cGray ([System.Drawing.Color]::White) $fBold
$btnWizard  = New-FlatButton 'ویزارد استقرار' 130 $cNavy ([System.Drawing.Color]::White) $fBold
$btnHelp    = New-FlatButton 'راهنما' 80 $cLight $cText $fBold
foreach ($b in @($btnRefresh, $btnConnect, $btnCopy, $btnSave, $btnWizard, $btnHelp)) {
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    $flowL.Controls.Add($b)
}

$flowR = New-Object System.Windows.Forms.FlowLayoutPanel
$flowR.Dock = 'Right'; $flowR.Width = 330; $flowR.Height = 40; $flowR.FlowDirection = 'RightToLeft'
$flowR.WrapContents = $false; $flowR.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
$flowR.RightToLeft = 'Yes'

$lblUser = New-Object System.Windows.Forms.Label
$lblUser.Text = 'کاربر:'; $lblUser.AutoSize = $true; $lblUser.ForeColor = $cText
$txtUser = New-Object System.Windows.Forms.TextBox
$txtUser.Text = 'it_remote'; $txtUser.Width = 110; $txtUser.Font = $fMono
$txtUser.RightToLeft = 'No'
$chkOffline = New-Object System.Windows.Forms.CheckBox
$chkOffline.Text = 'نمایش آفلاین ها'; $chkOffline.AutoSize = $true; $chkOffline.ForeColor = $cText
$lblSearch = New-Object System.Windows.Forms.Label
$lblSearch.Text = 'جستجو:'; $lblSearch.AutoSize = $true; $lblSearch.ForeColor = $cText
$txtSearch = New-Object System.Windows.Forms.TextBox
$txtSearch.Width = 130; $txtSearch.RightToLeft = 'No'
foreach ($c in @($lblUser, $txtUser, $chkOffline, $lblSearch, $txtSearch)) {
    $c.Margin = New-Object System.Windows.Forms.Padding(0, 0, 6, 0)
    $flowR.Controls.Add($c)
}
$toolbar.Controls.Add($flowL)
$toolbar.Controls.Add($flowR)
$layout.Controls.Add($toolbar, 0, 1)

# --- machine list -------------------------------------------------
$card = New-Object System.Windows.Forms.Panel
$card.Dock = 'Fill'; $card.BackColor = $cCard; $card.Padding = New-Object System.Windows.Forms.Padding(14)

$listView = New-Object System.Windows.Forms.ListView
$listView.Dock = 'Fill'
$listView.View = 'Details'
$listView.FullRowSelect = $true
$listView.MultiSelect = $false
$listView.GridLines = $false
$listView.BorderStyle = 'None'
$listView.BackColor = $cCard
$listView.ForeColor = $cText
$listView.Font = $fBase
$listView.HeaderStyle = 'Nonclickable'
$listView.RightToLeft = 'No'
$listView.RightToLeftLayout = $false
$listView.ShowItemToolTips = $true
[void]$listView.Columns.Add('وضعیت', 90)
[void]$listView.Columns.Add('نام دستگاه', 190)
[void]$listView.Columns.Add('آدرس SSH', 380)
[void]$listView.Columns.Add('IP شبکه خصوصی', 160)

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miConnect = New-Object System.Windows.Forms.ToolStripMenuItem('اتصال SSH')
$miCopy    = New-Object System.Windows.Forms.ToolStripMenuItem('کپی آدرس')
[void]$menu.Items.Add($miConnect)
[void]$menu.Items.Add($miCopy)
$listView.ContextMenuStrip = $menu

$card.Controls.Add($listView)
$layout.Controls.Add($card, 0, 2)

# --- status bar ----------------------------------------------------
$footer = New-Object System.Windows.Forms.Panel
$footer.Dock = 'Fill'; $footer.BackColor = $cCard; $footer.Padding = New-Object System.Windows.Forms.Padding(0, 0, 16, 0)
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Dock = 'Fill'; $lblStatus.TextAlign = 'MiddleRight'
$lblStatus.ForeColor = $cGray; $lblStatus.Font = $fBase
$lblStatus.Text = 'آماده. دکمه «بروزرسانی» را بزنید. (راهنما: دوبار کلیک روی هر ردیف = اتصال)'
$footer.Controls.Add($lblStatus)
$layout.Controls.Add($footer, 0, 3)

# ---------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------
function Update-Status {
    $total = $script:Rows.Count
    $online = @($script:Rows | Where-Object { $_.Online }).Count
    $offline = $total - $online
    $tn = if ($script:Tailnet) { "  |  tailnet: $($script:Tailnet)" } else { '' }
    $lblStatus.Text = "$online آنلاین  •  $offline آفلاین  (کل: $total)$tn"
}

function Build-Address {
    param($Row)
    $h  = [string]$Row.Host
    $tn = [string]$script:Tailnet
    $safeTn = ($tn -match '^[A-Za-z0-9.\-]+$')   # SSH cannot parse '@'/' ' inside host names
    if ($h -match '@| ')      { return "$($txtUser.Text)@$($Row.IP)" }   # unsafe hostname -> IP
    if ($safeTn -eq $false)   { return "$($txtUser.Text)@$($Row.IP)" }   # unsafe tailnet (email) -> IP
    if ($h -match '\.')       { return "$($txtUser.Text)@$h" }           # already a full DNS name
    if ($tn -ne '')           { return "$($txtUser.Text)@$h.$tn" }
    return "$($txtUser.Text)@$($Row.IP)"
}

function New-ListViewItem {
    <#
        Bulletproof ListViewItem creation.

        IMPORTANT: PowerShell's New-Object UNROLLS an array passed inline -
        New-Object X([string[]]@(...)) turns the array into separate arguments
        and the constructor lookup FAILS ('Cannot find an overload ...') with
        $item = $null, which then breaks every following line (this was the
        root cause of the 'Cannot index into a null array' cascade).
        ::new() binds the string[] constructor directly instead.
    #>
    param([string[]]$Values)
    try {
        $it = [System.Windows.Forms.ListViewItem]::new([string[]]$Values)
        if ($null -ne $it -and $it.SubItems.Count -ge 1) { return $it }
    } catch { }
    try {
        $it = [System.Windows.Forms.ListViewItem]::new([string]$Values[0])
        if ($Values.Count -gt 1) {
            $rest = [string[]]@($Values[1..($Values.Count - 1)])
            $it.SubItems.AddRange($rest)
        }
        return $it
    } catch { return $null }
}

function Rebuild-List {
    $listView.BeginUpdate()
    $listView.Items.Clear()
    $q = $txtSearch.Text.Trim()
    $warnings = @()
    foreach ($row in $script:Rows) {
        if ($null -eq $row) { continue }
        if (-not $chkOffline.Checked -and -not $row.Online) { continue }
        $addr = Build-Address $row
        if ($q -ne '' -and $addr -notlike "*$q*" -and $row.Host -notlike "*$q*" -and $row.IP -notlike "*$q*") { continue }
        $stText = $(if ($row.Online) { 'آنلاین' } else { 'آفلاین' })
        $item = New-ListViewItem -Values ([string[]]@($stText, [string]$row.Host, [string]$addr, [string]$row.IP))
        if ($null -eq $item) { $warnings += ('row {0}: could not create ListViewItem' -f $row.Host); continue }
        $item.Tag = $addr
        try {
            if ($row.Online) { $item.SubItems[0].ForeColor = $cGreen } else { $item.SubItems[0].ForeColor = $cRed }
            $item.SubItems[0].Font = $fBold
            $item.ToolTipText = "ssh $addr"
        } catch { }
        [void]$listView.Items.Add($item)
    }
    $listView.EndUpdate()
    Update-Status
    if ($warnings.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show(
            'بعضی ردیف ها ساخته نشدند:' + [Environment]::NewLine +
            ($warnings -join [Environment]::NewLine),
            'خطا', 'OK', 'Warning') | Out-Null
    }
}

# ---------------------------------------------------------------
# Refresh (background job, so the UI stays responsive)
# ---------------------------------------------------------------
$refreshTimer = New-Object System.Windows.Forms.Timer
$refreshTimer.Interval = 400

function Invoke-Refresh {
    if ($script:RefreshJob -and $script:RefreshJob.State -eq 'Running') { return }
    $btnRefresh.Enabled = $false
    $btnRefresh.Text = 'در حال بروزرسانی...'
    $script:RefreshJob = Start-Job -ScriptBlock {
        param($tailscaleExe)
        $rows = @(); $tn = ''; $err = ''
        try {
            $lines = & $tailscaleExe status 2>$null | Where-Object { $_ -match '^(\d{1,3}\.){3}\d{1,3}\s+\S+' }
            foreach ($line in $lines) {
                $p = $line -split '\s+'
                if ($p.Count -lt 2) { continue }
                $rows += [pscustomobject]@{
                    Host   = $p[1]
                    IP     = $p[0]
                    Online = ($line -notmatch 'offline')
                }
            }
        } catch { $err = [string]$_.Exception.Message }
        try {
            $json = (& $tailscaleExe status --json 2>$null | Out-String)
            $j = $json | ConvertFrom-Json
            if ($j -and $j.CurrentTailnet) { $tn = [string]$j.CurrentTailnet.Name }
        } catch { }
        [pscustomobject]@{ Rows = $rows; Tailnet = $tn; Error = $err }
    } -ArgumentList $tsExe
    $refreshTimer.Start()
}

$refreshTimer.Add_Tick({
    if (-not $script:RefreshJob) { $refreshTimer.Stop(); return }
    if ($script:RefreshJob.State -eq 'Running') { return }
    $refreshTimer.Stop()
    $res = Receive-Job $script:RefreshJob
    Remove-Job $script:RefreshJob -Force
    $script:RefreshJob = $null
    $btnRefresh.Enabled = $true
    $btnRefresh.Text = 'بروزرسانی'
    if ($res -is [pscustomobject]) {
        if ($res.Error) {
            [System.Windows.Forms.MessageBox]::Show(
                "خطا در خواندن اطلاعات Tailscale:`r`n$($res.Error)`r`n`r`nآیا Tailscale روی این سیستم نصب و لاگین شده است؟",
                'خطا', 'OK', 'Warning') | Out-Null
        }
        $script:Rows = $res.Rows
        $script:Tailnet = if ($res.Tailnet) { $res.Tailnet } else { $script:Tailnet }
    }
    Rebuild-List
})

# ---------------------------------------------------------------
# Actions
# ---------------------------------------------------------------
function Show-SelectedAddress {
    $sel = $listView.SelectedItems
    if ($sel.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('ابتدا یک سیستم را از لیست انتخاب کنید.', 'اتصال', 'OK', 'Information') | Out-Null
        return $null
    }
    return [string]$sel[0].Tag
}

function Invoke-Connect {
    $addr = Show-SelectedAddress
    if (-not $addr) { return }
    if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "کلاینت ssh روی این سیستم پیدا نشد.`r`n`r`nبرای نصب (یک بار):`r`npowershell -Command `"Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0`"`r`n`r`nآیا راهنمای نصب باز شود؟",
            'کلاینت SSH', 'YesNo', 'Question') | Out-Null
        if ($r -eq 'Yes') { Start-Process 'https://learn.microsoft.com/windows-server/administration/openssh/openssh_install_firstuse' }
        return
    }
    Start-Process -FilePath 'cmd.exe' -ArgumentList @('/k', "ssh $addr")
}

function Invoke-Copy {
    $addr = Show-SelectedAddress
    if (-not $addr) { return }
    Set-Clipboard -Value $addr
    $btnCopy.Text = 'کپی شد!'
    $script:ToastTimer = New-Object System.Windows.Forms.Timer
    $script:ToastTimer.Interval = 1200
    $script:ToastTimer.Add_Tick({
        $script:ToastTimer.Stop(); $script:ToastTimer.Dispose(); $script:ToastTimer = $null
        $btnCopy.Text = 'کپی آدرس'
    })
    $script:ToastTimer.Start()
}

function Invoke-Save {
    if ($listView.Items.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('لیستی برای ذخیره وجود ندارد.', 'ذخیره', 'OK', 'Information') | Out-Null
        return
    }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'Text (*.txt)|*.txt|All files (*.*)|*.*'
    $dlg.FileName = 'ssh-addresses.txt'
    $dlg.Title = 'ذخیره لیست آدرس های SSH'
    if ($dlg.ShowDialog() -eq 'OK') {
        $lines = @()
        $lines += 'Generated: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')
        $lines += 'User: ' + $txtUser.Text
        $lines += ''
        foreach ($row in $script:Rows) {
            $st = $(if ($row.Online) { 'ONLINE ' } else { 'OFFLINE' })
            $lines += "[$st] ssh $(Build-Address $row)"
        }
        Set-Content -Path $dlg.FileName -Value $lines -Encoding UTF8
        [System.Windows.Forms.MessageBox]::Show('ذخیره شد: ' + $dlg.FileName, 'ذخیره', 'OK', 'Information') | Out-Null
    }
    $dlg.Dispose()
}

function Invoke-Help {
    [System.Windows.Forms.MessageBox]::Show(
        @'
کنسول مدیریت SSH کارمندان
------------------------------
1) روی هر کامپیوتر کارمند، پوشه gui را کپی کنید و SetupWizard.bat را اجرا کنید
   (کلید Tailscale + رمز عبور را همان جا وارد می کنند).
2) اینجا دکمه «بروزرسانی» را بزنید تا سیستم ها با وضعیت آنلاین/آفلاین بیایند.
3) دوبار کلیک روی هر ردیف (یا دکمه «اتصال SSH») ترمینال را باز می کند.
   رمز ورود = همان رمزی که در ویزارد وارد شد.

آدرس ها فقط از داخل شبکه Tailscale (tailnet خودتان) قابل استفاده اند
و روی اینترنت در دسترس نیستند.
'@, 'راهنما', 'OK', 'Information') | Out-Null
}

function Invoke-Wizard {
    $wizard = Join-Path $PSScriptRoot 'SetupWizard.ps1'
    if (-not (Test-Path $wizard)) {
        [System.Windows.Forms.MessageBox]::Show(
            "فایل SetupWizard.ps1 کنار این برنامه پیدا نشد.`r`nمنتظر:`r`n$wizard",
            'ویزارد استقرار', 'OK', 'Warning') | Out-Null
        return
    }
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"' + $wizard + '"')
    )
}

# ---------------------------------------------------------------
# Wire events
# ---------------------------------------------------------------
$btnRefresh.Add_Click({ Invoke-Refresh })
$btnConnect.Add_Click({ Invoke-Connect })
$btnCopy.Add_Click({ Invoke-Copy })
$btnSave.Add_Click({ Invoke-Save })
$btnHelp.Add_Click({ Invoke-Help })
$btnWizard.Add_Click({ Invoke-Wizard })
$miConnect.Add_Click({ Invoke-Connect })
$miCopy.Add_Click({ Invoke-Copy })
$listView.Add_DoubleClick({ Invoke-Connect })
$txtUser.Add_TextChanged({ Rebuild-List })
$chkOffline.Add_CheckedChanged({ Rebuild-List })
$txtSearch.Add_TextChanged({ Rebuild-List })
$form.Add_Shown({ Invoke-Refresh })
$form.Add_FormClosing({
    if ($script:RefreshJob -and $script:RefreshJob.State -eq 'Running') {
        Stop-Job $script:RefreshJob -ErrorAction SilentlyContinue
        Remove-Job $script:RefreshJob -Force -ErrorAction SilentlyContinue
    }
})

# ---------------------------------------------------------------
[void]$form.ShowDialog()
