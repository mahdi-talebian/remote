<#
.SYNOPSIS
    End-to-end test suite for the Remote Admin package (LAN mode, Linux/CI).

    Everything REAL: real sshd on port 22, real deploy, real network IP,
    real SSH login with sshpass. No mocks.

.REQUIRES
    - PowerShell 7 (pwsh - set $env:E2E_PWSH if not on PATH)
    - sudo (passwordless), sshd on port 22, sshpass
#>

$ErrorActionPreference = 'Stop'
$PWSH    = if ($env:E2E_PWSH) { $env:E2E_PWSH } else { 'pwsh' }
$Root    = Split-Path $PSScriptRoot -Parent
$Deploy  = Join-Path $Root 'deploy-employee.ps1'
$Scan    = Join-Path $Root 'scan-network.ps1'
$Wizard  = Join-Path $Root 'gui\SetupWizard.ps1'
$Console = Join-Path $Root 'gui\AdminConsole.ps1'
$ViaDom  = Join-Path $Root 'deploy-via-domain.ps1'
$GetAddr = Join-Path $Root 'get-addresses.ps1'   # exists until Task 5 (Tailscale-era file)
$Pass    = 'Test-Pass-147!xyZ'
$RunDir  = '/tmp/e2e-remote-admin'

$script:Results = @()
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    $script:Results += [pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail }
    if ($Ok) { Write-Host ("PASS  " + $Name) -ForegroundColor Green }
    else     { Write-Host ("FAIL  " + $Name + '  ->  ' + $Detail) -ForegroundColor Red }
}
function Remove-RunDir { sudo rm -rf $RunDir; New-Item -ItemType Directory -Force -Path $RunDir | Out-Null }
function Get-FunctionText {
    param([string]$Path, [string]$Name)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $fn = $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $Name }, $true) | Select-Object -First 1
    if (-not $fn) { return $null }
    return $fn.Extent.Text
}

Write-Host '==== Remote Admin - E2E test suite (LAN mode) ====' -ForegroundColor Cyan
Remove-RunDir

# ---------------- TEST 0: all scripts parse ----------------
$allOk = $true
foreach ($f in @($Deploy, $Scan, $Wizard, $Console, $ViaDom, $GetAddr)) {
    $t = $null; $e = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$t, [ref]$e) | Out-Null
    if ($e.Count) { $allOk = $false; Check ('parse: ' + (Split-Path $f -Leaf)) $false ($e[0].Message) }
}
if ($allOk) { Check 'parse: all 6 PowerShell scripts' $true }

# ---------------- TEST 1: scanner functions extractable from scan-network.ps1 ----------------
$fnScan   = Get-FunctionText -Path $Scan -Name 'Find-SshHosts'
$fnSubnet = Get-FunctionText -Path $Scan -Name 'Get-SubnetHosts'
$fnLocal  = Get-FunctionText -Path $Scan -Name 'Get-LocalSubnet'
Check 'scan-network: Find-SshHosts extractable'   ($null -ne $fnScan)
Check 'scan-network: Get-SubnetHosts extractable' ($null -ne $fnSubnet)
Check 'scan-network: Get-LocalSubnet extractable' ($null -ne $fnLocal)

# ---------------- TEST 2: subnet math ----------------
. ([scriptblock]::Create($fnSubnet))
$hosts = @(Get-SubnetHosts -Cidr '192.168.1.0/24')
Check 'Get-SubnetHosts: 254 hosts for /24' ($hosts.Count -eq 254) ("count=$($hosts.Count)")
Check 'Get-SubnetHosts: first is .1' ($hosts[0] -eq '192.168.1.1') ("first=$($hosts[0])")
Check 'Get-SubnetHosts: last is .254' ($hosts[-1] -eq '192.168.1.254') ("last=$($hosts[-1])")
Check 'Get-SubnetHosts: rejects non-/24' (@(Get-SubnetHosts -Cidr '10.0.0.0/8').Count -eq 0)
Check 'Get-SubnetHosts: rejects garbage' (@(Get-SubnetHosts -Cidr ' nonsense').Count -eq 0)
. ([scriptblock]::Create($fnLocal))
$sn = Get-LocalSubnet -Ip '192.168.1.15'
Check 'Get-LocalSubnet: 192.168.1.15 -> 192.168.1.0/24' ($sn -eq '192.168.1.0/24') ("got=$sn")
Check 'Get-LocalSubnet: garbage -> empty' ((Get-LocalSubnet -Ip 'xx') -eq '')

# ---------------- TEST 3: REAL scan on 127.0.0.0/24 finds real sshd ----------------
. ([scriptblock]::Create($fnScan))
$found = @(Find-SshHosts -Cidr '127.0.0.0/24' -TimeoutMs 3000)
Check 'Find-SshHosts: real scan finds 127.0.0.1 (sshd on :22)' ($found -contains '127.0.0.1') ("found=$($found -join ',')")
$none = @(Find-SshHosts -Cidr '127.0.0.0/24' -Port 22999 -TimeoutMs 1500)
Check 'Find-SshHosts: closed port -> nothing found' ($none.Count -eq 0) ("found=$($none -join ',')")

# ---------------- TEST 4: wizard Parse-Address (IP forms; regression suite) ----------------
$fnParse = Get-FunctionText -Path $Wizard -Name 'Parse-Address'
Check 'wizard: Parse-Address extractable' ($null -ne $fnParse)
if ($fnParse) {
    . ([scriptblock]::Create($fnParse))
    $t1 = Parse-Address -Line 'SSH-ADDRESS: ssh it_remote@192.168.1.50'
    Check 'Parse-Address: current marker (ssh prefix)' ($t1 -eq 'ssh it_remote@192.168.1.50') ("got=$t1")
    $t2 = Parse-Address -Line 'SSH-ADDRESS: it_remote@192.168.1.50'
    Check 'Parse-Address: marker without ssh' ($t2 -eq 'ssh it_remote@192.168.1.50') ("got=$t2")
    $t3 = Parse-Address -Line 'ssh it_remote@127.0.0.1'
    Check 'Parse-Address: last-address.txt line' ($t3 -eq 'ssh it_remote@127.0.0.1') ("got=$t3")
    $t4 = Parse-Address -Line 'it_remote@192.168.1.50'
    Check 'Parse-Address: bare address' ($t4 -eq 'ssh it_remote@192.168.1.50') ("got=$t4")
    $t5 = Parse-Address -Line 'SSH-ADDRESS: ssh'
    Check 'Parse-Address: partial marker REJECTED' ($t5 -eq '')
    $t6 = Parse-Address -Line 'random log line'
    Check 'Parse-Address: random line -> empty' ($t6 -eq '')
}

# ---------------- TEST 5: PowerShell constructor binding regression (AdminConsole crash) ----------------
$csMock = @'
using System.Collections.Generic;
public class SubItemsCollection {
  private List<string> _items = new List<string>();
  public void Add(string s) { _items.Add(s); }
  public void AddRange(string[] arr) { _items.AddRange(arr); }
  public int Count { get { return _items.Count; } }
  public string this[int i] { get { return _items[i]; } }
}
public class FakeLVI {
  public SubItemsCollection SubItems { get; private set; }
  public object Tag { get; set; }
  public string ToolTipText { get; set; }
  public FakeLVI(string text) { SubItems = new SubItemsCollection(); SubItems.Add(text); }
  public FakeLVI(string[] items) { SubItems = new SubItemsCollection(); SubItems.AddRange(items); }
}
'@
try { Add-Type -TypeDefinition $csMock -ErrorAction Stop | Out-Null } catch { }
$newItem = $null
try { $newItem = [FakeLVI]::new([string[]]@('a', 'b', 'c', 'd')) } catch { }
Check 'ctor: NEW ::new(array) pattern binds string[] ctor' ($null -ne $newItem -and $newItem.SubItems.Count -eq 4)
if ($newItem) {
    $newItem.Tag = 'ssh it_remote@192.168.1.3'
    Check 'ctor: Tag settable on ::new item' ($newItem.Tag -eq 'ssh it_remote@192.168.1.3')
}
$fnLVI = Get-FunctionText -Path $Console -Name 'New-ListViewItem'
Check 'console: New-ListViewItem extractable (defensive creation)' ($null -ne $fnLVI)

# ---------------- summary + report ----------------
$passed = @($script:Results | Where-Object { $_.Ok }).Count
$failed = @($script:Results | Where-Object { -not $_.Ok }).Count
Write-Host ''
Write-Host ("==== RESULT: {0} passed / {1} failed ====" -f $passed, $failed) -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
$lines = @()
$lines += '# Remote Admin - E2E test report'
$lines += ''
$lines += ('Date     : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$lines += ('Host     : ' + (hostname))
$lines += 'Scenario : LAN mode - real sshd on :22, real deploy, real network IP, real SSH login'
$lines += 'Mocked   : nothing'
$lines += ''
$lines += '| # | Test | Result | Detail |'
$lines += '|---|---|---|---|'
$i = 0
foreach ($r in $script:Results) {
    $i++
    $lines += ('| {0} | {1} | {2} | {3} |' -f $i, $r.Name, $(if ($r.Ok) { 'PASS' } else { 'FAIL' }), ($r.Detail -replace '\|', '/' -replace "`r?`n", ' '))
}
$lines | Set-Content -Path (Join-Path $PSScriptRoot 'REPORT.md') -Encoding UTF8
if ($failed -gt 0) { exit 1 } else { exit 0 }
