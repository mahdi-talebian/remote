<#
.SYNOPSIS
    End-to-end test suite for the Remote Admin package (Linux/CI).

    Simulates the FULL flow with two roles sharing a fake tailnet:
      AGENT   : deploy-employee.ps1  (real execution, as root, on this host)
      ADMIN   : get-addresses.ps1    (real execution, as user)
    The Tailscale CLI is mocked (tests/mock/tailscale, installed at
    /usr/local/bin/tailscale) and reproduces the customer's real-world
    scenario: an EMAIL-STYLE tailnet name (mmdtalebian.animid@gmail.com)
    which makes naive address building produce invalid SSH host names.

    The SSH part is 100% REAL:
      - real user 'it_remote' created on this host by the deploy script
      - real sshd (the sandbox's own, port 22), real password auth
      - real OpenSSH client (via sshpass) logging in with the address
        the scripts produced.

.REQUIRES
    - PowerShell 7 (pwsh) at /tmp/pwshdir/pwsh   (edit $env:PWSH below)
    - sudo (passwordless), sshd on port 22, sshpass installed
    - mock tailscale installed at /usr/local/bin/tailscale
#>

$ErrorActionPreference = 'Stop'
$PWSH       = if ($env:E2E_PWSH) { $env:E2E_PWSH } else { '/tmp/pwshdir/pwsh' }
$Root       = Split-Path $PSScriptRoot -Parent
$Deploy     = Join-Path $Root 'deploy-employee.ps1'
$GetAddr    = Join-Path $Root 'get-addresses.ps1'
$Wizard     = Join-Path $Root 'gui\SetupWizard.ps1'
$Console    = Join-Path $Root 'gui\AdminConsole.ps1'
$Mock       = '/usr/local/bin/tailscale'
$Pass       = 'Test-Pass-147!xyZ'      # the SSH password (set by deploy as root)
$RunDir     = '/tmp/e2e-remote-admin'

# ---------------------------------------------------------------
$script:Results = @()
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    $script:Results += [pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail }
    if ($Ok) { Write-Host ("PASS  " + $Name) -ForegroundColor Green }
    else     { Write-Host ("FAIL  " + $Name + '  ->  ' + $Detail) -ForegroundColor Red }
}

function Remove-RunDir { sudo rm -rf $RunDir; New-Item -ItemType Directory -Force -Path $RunDir | Out-Null }

function Fix-Ownership {
    # deploy runs as root (sudo) and creates root-owned state dirs; give them
    # back to the current user so the mock can be driven from both roles.
    $u = (& id -un); $g = (& id -gn)
    & sudo chown -R ("{0}:{1}" -f $u, $g) $RunDir 2>$null
}

function Invoke-Deploy {
    param([string]$State, [string]$Base, [string]$Hostname, [string]$Key,
          [string]$Tailnet = '', [string]$DnsName = '', [string]$Ip = '127.0.0.1',
          [string]$MockHost = 'mock-host')
    $a = @('env')
    $a += "TS_MOCK_STATE=$State"; $a += "TS_MOCK_IP=$Ip"; $a += "TS_MOCK_HOST=$MockHost"; $a += "RA_BASEDIR=$Base"
    if ($Tailnet) { $a += "TS_MOCK_TAILNET=$Tailnet" }
    if ($DnsName) { $a += "TS_MOCK_DNSNAME=$DnsName" }
    $a += @($PWSH, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Deploy,
            '-TailscaleAuthKey', $Key, '-AdminPassword', $Pass, '-Hostname', $Hostname)
    $out = (& sudo @a 2>&1 | Out-String)
    [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
}

function Get-FunctionText {
    param([string]$Path, [string]$Name)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $fn = $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $Name }, $true) | Select-Object -First 1
    if (-not $fn) { return $null }
    return $fn.Extent.Text
}

# ===============================================================
Write-Host '==== Remote Admin - end-to-end test suite ====' -ForegroundColor Cyan
Remove-RunDir

# ---------------------------------------------------------------
# TEST 0: all scripts parse
# ---------------------------------------------------------------
$allOk = $true
foreach ($f in @($Deploy, $GetAddr, $Wizard, $Console, (Join-Path $Root 'gui\AdminConsole.ps1'))) {
    $t = $null; $e = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$t, [ref]$e) | Out-Null
    if ($e.Count) { $allOk = $false; Check ('parse: ' + (Split-Path $f -Leaf)) $false ($e[0].Message) }
}
if ($allOk) { Check 'parse: all 5 PowerShell scripts' $true }

# ---------------------------------------------------------------
# TEST 1: AGENT deploy, EMAIL-STYLE tailnet  (the customer's exact scenario)
# ---------------------------------------------------------------
$state1 = "$RunDir/state1"; $base1 = "$RunDir/agent1"
$r1 = Invoke-Deploy -State $state1 -Base $base1 -Hostname 'mock-agent' -Key 'tskey-auth-TESTKEY123' `
        -Tailnet 'mmdtalebian.animid@gmail.com' -DnsName 'mock-agent.mmdtalebian.animid@gmail.com' `
        -Ip '127.0.0.1' -MockHost 'mock-agent'
Fix-Ownership
Check 'deploy#1 exit code = 0'                    ($r1.ExitCode -eq 0) ("exit=$($r1.ExitCode)")
Check 'deploy#1 prints [DEPLOY-STATUS] SUCCESS'   ($r1.Output -match '\[DEPLOY-STATUS\] SUCCESS')
Check 'deploy#1 marker = it_remote@127.0.0.1 (bare, email tailnet)' `
      ($r1.Output -match 'SSH-ADDRESS: it_remote@127\.0\.0\.1') ($r1.Output -replace "`r?`n", ' | ' | Select-String 'SSH-ADDRESS' | ForEach-Object { $_.Line })
Check 'deploy#1 no CLIXML noise'                  ($r1.Output -notmatch '<Obj|Object Version=')

$last1  = Join-Path $base1 'last-address.txt'
$addr1  = Join-Path $base1 'ssh-address.txt'
Check 'deploy#1 wrote last-address.txt'           (Test-Path $last1)
if (Test-Path $last1) {
    $v = (Get-Content $last1 -Raw -Encoding UTF8).Trim()
    Check 'deploy#1 last-address.txt content' ($v -eq 'ssh it_remote@127.0.0.1') ("got: $v")
}
if (Test-Path $addr1) {
    $c = Get-Content $addr1 -Raw -Encoding UTF8
    Check 'deploy#1 ssh-address.txt has SSH-ADDRESS + IP fallback' ($c -match 'SSH-ADDRESS: ssh it_remote@127\.0\.0\.1' -and $c -match 'IP fallback: ssh it_remote@127\.0\.0\.1')
}

# ---------------------------------------------------------------
# TEST 2: 'both sides see each other' (shared fake tailnet)
# ---------------------------------------------------------------
# admin machine joins the same tailnet, then each side lists the other
$null = & env "TS_MOCK_STATE=$state1" TS_MOCK_HOST=controller TS_MOCK_IP=127.0.0.2 $Mock up --authkey tskey-auth-ADMINKEY --hostname controller 2>&1
$agentView = (& env "TS_MOCK_STATE=$state1" TS_MOCK_HOST=mock-agent TS_MOCK_IP=127.0.0.1 $Mock status 2>&1 | Out-String)
$adminView = (& env "TS_MOCK_STATE=$state1" TS_MOCK_HOST=controller TS_MOCK_IP=127.0.0.2 $Mock status 2>&1 | Out-String)
Check 'agent sees controller in tailnet'  ($agentView -match 'controller')
Check 'admin sees agent in tailnet'       ($adminView -match 'mock-agent')
Check 'admin sees agent ONLINE'           ($adminView -match 'mock-agent' -and $adminView -notmatch 'mock-agent.*offline')

# ---------------------------------------------------------------
# TEST 3: ADMIN side - get-addresses.ps1 lists the agent + correct address
# ---------------------------------------------------------------
$env:TS_MOCK_STATE = $state1
$env:TS_MOCK_HOST  = 'controller'
$env:TS_MOCK_IP    = '127.0.0.2'
$env:TS_MOCK_TAILNET = 'mmdtalebian.animid@gmail.com'
$ga = (& $PWSH -NoProfile -ExecutionPolicy Bypass -File $GetAddr 2>&1 | Out-String)
Check 'get-addresses shows agent as ONLINE'  ($ga -match '\[ONLINE \] ssh it_remote@127\.0\.0\.1')
Check 'get-addresses saves ssh-addresses.txt' (Test-Path (Join-Path $Root 'ssh-addresses.txt'))
Remove-Item Env:TS_MOCK_STATE, Env:TS_MOCK_HOST, Env:TS_MOCK_IP, Env:TS_MOCK_TAILNET -ErrorAction SilentlyContinue

# ---------------------------------------------------------------
# TEST 4: REAL SSH connection with the produced address + password
# ---------------------------------------------------------------
$ssh = (& sshpass -p $Pass ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null `
        -o PreferredAuthentications=password -o PubkeyAuthentication=no `
        it_remote@127.0.0.1 'hostname; echo SSH-CONNECTED' 2>&1 | Out-String)
Check 'REAL ssh login succeeds (password auth, address from scripts)' ($LASTEXITCODE -eq 0 -and $ssh -match 'SSH-CONNECTED') $ssh

# ---------------------------------------------------------------
# TEST 5: AGENT deploy, NORMAL tailnet  (DNS address must be used)
# ---------------------------------------------------------------
$state2 = "$RunDir/state2"; $base2 = "$RunDir/agent2"
$r2 = Invoke-Deploy -State $state2 -Base $base2 -Hostname 'agent2' -Key 'tskey-auth-TESTKEY456' `
        -Tailnet 'mycorp.ts.net' -DnsName 'agent2.mycorp.ts.net' -Ip '127.0.0.3' -MockHost 'agent2'
Check 'deploy#2 exit code = 0'  ($r2.ExitCode -eq 0) ("exit=$($r2.ExitCode)")
Check 'deploy#2 address = it_remote@agent2.mycorp.ts.net (DNS, clean tailnet)' `
      ($r2.Output -match 'SSH-ADDRESS: it_remote@agent2\.mycorp\.ts\.net')
$v2 = if (Test-Path (Join-Path $base2 'last-address.txt')) { (Get-Content (Join-Path $base2 'last-address.txt') -Raw -Encoding UTF8).Trim() } else { '' }
Check 'deploy#2 last-address.txt = DNS form' ($v2 -eq 'ssh it_remote@agent2.mycorp.ts.net') ("got: $v2")

# ---------------------------------------------------------------
# TEST 6: NEGATIVE - the auth-key mistake from the customer (a ts.net ADDRESS
#         in the key field) must produce a clear FAILURE, not a fake success
# ---------------------------------------------------------------
$r3 = Invoke-Deploy -State "$RunDir/state3" -Base "$RunDir/agent3" -Hostname 'badkey' `
        -Key 'desktop-u5qn4rb.taila3f232.ts.net' -Tailnet 'mmdtalebian.animid@gmail.com' -MockHost 'badkey'
Check 'deploy#bad-key exit code = 1'          ($r3.ExitCode -eq 1) ("exit=$($r3.ExitCode)")
Check 'deploy#bad-key marks FAILED'           ($r3.Output -match '\[DEPLOY-STATUS\] FAILED')
Check 'deploy#bad-key warns about tskey-auth' ($r3.Output -match 'tskey-auth')

# ---------------------------------------------------------------
# TEST 7: wizard helpers (functions extracted from the real shipped file)
# ---------------------------------------------------------------
$src    = Get-FunctionText -Path $Wizard -Name 'Get-NewLines'
$srcA   = Get-FunctionText -Path $Wizard -Name 'Get-AuthoritativeAddress'
$srcP   = Get-FunctionText -Path $Wizard -Name 'Parse-Address'
Check 'wizard: Get-NewLines / Get-AuthoritativeAddress / Parse-Address extractable' ($src -and $srcA -and $srcP)
if ($src -and $srcA -and $srcP) {
    Invoke-Expression $src
    Invoke-Expression $srcA
    Invoke-Expression $srcP

    # --- regression fixes for the 'address shows as ssh only' bug ---
    Check 'Parse-Address: current marker (bare) -> full'   ((Parse-Address 'SSH-ADDRESS: it_remote@127.0.0.1') -eq 'ssh it_remote@127.0.0.1')
    Check 'Parse-Address: old marker (ssh prefix) -> full' ((Parse-Address 'SSH-ADDRESS: ssh it_remote@127.0.0.1') -eq 'ssh it_remote@127.0.0.1')
    Check 'Parse-Address: last-address.txt line -> full'   ((Parse-Address 'ssh it_remote@agent2.mycorp.ts.net') -eq 'ssh it_remote@agent2.mycorp.ts.net')
    Check 'Parse-Address: bare address -> full'            ((Parse-Address 'it_remote@100.64.1.9') -eq 'ssh it_remote@100.64.1.9')
    Check 'Parse-Address: partial marker "SSH-ADDRESS: ssh" REJECTED' ((Parse-Address 'SSH-ADDRESS: ssh') -eq '')
    Check 'Parse-Address: random log line -> empty'        ((Parse-Address 'Step 1/5: OpenSSH Server ...') -eq '')
    Check 'Parse-Address: Tailnet line -> empty'           ((Parse-Address 'Tailnet: mmdtalebian.animid@gmail.com') -eq '')

    # --- wizard streaming simulation over REAL deploy output ---
    $addrFromLog = ''
    foreach ($l in ($r1.Output -split "`r?`n")) {
        $a = Parse-Address -Line $l
        if ($a) { $addrFromLog = $a }
    }
    Check 'wizard streaming sim: full address recovered from deploy#1 log' ($addrFromLog -eq 'ssh it_remote@127.0.0.1') ("got: $addrFromLog")

    # regression for the original bug: a file that currently has exactly ONE line
    $tmpF = Join-Path $RunDir 'one-line.txt'
    Set-Content -Path $tmpF -Value 'SSH-ADDRESS: ssh it_remote@127.0.0.1' -Encoding UTF8
    $pos = 0
    $got = @(Get-NewLines -Path $tmpF -Pos ([ref]$pos))
    Check 'wizard Get-NewLines: single-line file returns the LINE (bug fixed)' `
          ($got.Count -eq 1 -and $got[0] -match 'SSH-ADDRESS') ("count=$($got.Count), first='$($got[0])'")
    Add-Content -Path $tmpF -Value 'line two' -Encoding UTF8
    $got2 = @(Get-NewLines -Path $tmpF -Pos ([ref]$pos))
    Check 'wizard Get-NewLines: incremental read works' ($got2.Count -eq 1 -and $got2[0] -eq 'line two')

    $env:RA_ADDR_DIR = "$RunDir/addrdir"; New-Item -ItemType Directory -Force -Path $env:RA_ADDR_DIR | Out-Null
    Set-Content -Path (Join-Path $env:RA_ADDR_DIR 'last-address.txt') -Value 'ssh it_remote@127.0.0.1' -Encoding UTF8
    Check 'wizard address recovery from last-address.txt' ((Get-AuthoritativeAddress) -eq 'ssh it_remote@127.0.0.1')
    Remove-Item (Join-Path $env:RA_ADDR_DIR 'last-address.txt') -Force
    Set-Content -Path (Join-Path $env:RA_ADDR_DIR 'ssh-address.txt') -Value @('SSH-ADDRESS: ssh it_remote@agent2.mycorp.ts.net', 'x') -Encoding UTF8
    Check 'wizard address recovery from ssh-address.txt' ((Get-AuthoritativeAddress) -eq 'ssh it_remote@agent2.mycorp.ts.net')
    Remove-Item Env:RA_ADDR_DIR
}

# ---------------------------------------------------------------
# TEST 8: AdminConsole Build-Address (extracted from the real shipped file)
# ---------------------------------------------------------------
$srcB = Get-FunctionText -Path $Console -Name 'Build-Address'
Check 'console: Build-Address extractable' ($null -ne $srcB)
if ($srcB) {
    Invoke-Expression $srcB
    $txtUser = [pscustomobject]@{ Text = 'it_remote' }
    $script:Tailnet = 'mmdtalebian.animid@gmail.com'
    $row = [pscustomobject]@{ Host = 'mock-agent'; IP = '127.0.0.1' }
    Check 'console Build-Address: email tailnet -> IP form' ((Build-Address $row) -eq 'it_remote@127.0.0.1')
    $script:Tailnet = 'mycorp.ts.net'
    Check 'console Build-Address: clean tailnet -> DNS form' ((Build-Address $row) -eq 'it_remote@mock-agent.mycorp.ts.net')
    $row2 = [pscustomobject]@{ Host = 'agent2.mycorp.ts.net'; IP = '127.0.0.3' }
    Check 'console Build-Address: full DNS row stays as-is' ((Build-Address $row2) -eq 'it_remote@agent2.mycorp.ts.net')
}

# ---------------------------------------------------------------
# TEST 9: PowerShell constructor binding - the AdminConsole crash
# (regression for the user-reported 'Cannot index into a null array'
#  cascade: New-Object UNROLLS an inline string[] into separate args,
#  the ListViewItem ctor lookup fails, $item becomes $null, and every
#  following line (SubItems[0], ToolTipText, Items.Add) explodes.)
# ---------------------------------------------------------------
$csMock = @'
public class FakeLVI {
  public class SubItemsCollection {
    private System.Collections.Generic.List<string> _items = new System.Collections.Generic.List<string>();
    public string this[int i] { get { return _items[i]; } }
    public void Add(string s) { _items.Add(s); }
    public void AddRange(string[] arr) { _items.AddRange(arr); }
    public int Count { get { return _items.Count; } }
  }
  public SubItemsCollection SubItems { get; private set; }
  public object Tag { get; set; }
  public string ToolTipText { get; set; }
  public FakeLVI(string text) { SubItems = new SubItemsCollection(); SubItems.Add(text); }
  public FakeLVI(string[] items) { SubItems = new SubItemsCollection(); SubItems.AddRange(items); }
}
'@
try { Add-Type -TypeDefinition $csMock -ErrorAction Stop | Out-Null } catch { }

$oldItem = $null
$oldErr = ''
try { $oldItem = New-Object FakeLVI([string[]]@('a', 'b', 'c', 'd')) } catch { $oldErr = $_.Exception.Message }
Check 'ctor: OLD New-Object(array) pattern fails (the shipped bug)' ($null -eq $oldItem) ("got object, but should be null; err=$oldErr")

$newItem = $null
try { $newItem = [FakeLVI]::new([string[]]@('a', 'b', 'c', 'd')) } catch { }
Check 'ctor: NEW ::new(array) pattern binds string[] ctor' ($null -ne $newItem -and $newItem.SubItems.Count -eq 4 -and $newItem.SubItems[0] -eq 'a') ("subitems=$($newItem.SubItems.Count)")
if ($newItem) {
    $newItem.Tag = 'ssh it_remote@100.1.2.3'; $newItem.ToolTipText = 'tip'
    Check 'ctor: Tag/ToolTipText settable on ::new item' ($newItem.Tag -eq 'ssh it_remote@100.1.2.3' -and $newItem.ToolTipText -eq 'tip')
}
$fb = $null
try {
    $fb = [FakeLVI]::new('col0'); $fb.SubItems.AddRange([string[]]@('col1', 'col2', 'col3'))
} catch { }
Check 'ctor: ::new(text) + SubItems.AddRange fallback works' ($null -ne $fb -and $fb.SubItems.Count -eq 4)

$welcome = Get-FunctionText -Path $Console -Name 'New-ListViewItem'
Check 'console: New-ListViewItem extractable (defensive creation)' ($null -ne $welcome)

$passed = @($script:Results | Where-Object { $_.Ok }).Count
$failed = @($script:Results | Where-Object { -not $_.Ok }).Count
Write-Host ''
Write-Host ("==== RESULT: {0} passed / {1} failed ====" -f $passed, $failed) -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })

# report file
$lines = @()
$lines += '# Remote Admin - E2E test report'
$lines += ''
$lines += ('Date     : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$lines += ('Host     : ' + (hostname))
$lines += ('Scenario : email-style tailnet (mmdtalebian.animid@gmail.com) + clean tailnet (mycorp.ts.net)')
$lines += ('Real SSH : sshd on 127.0.0.1:22, user it_remote, password auth, OpenSSH client via sshpass')
$lines += ('Mocked   : tailscale CLI control plane only')
$lines += ''
$lines += '| # | Test | Result | Detail |'
$lines += '|---|---|---|---|'
$i = 0
foreach ($r in $script:Results) {
    $i++
    $lines += ('| {0} | {1} | {2} | {3} |' -f $i, $r.Name, $(if ($r.Ok) { 'PASS' } else { 'FAIL' }), ($r.Detail -replace '\|', '/' -replace "`r?`n", ' '))
}
$lines | Set-Content -Path (Join-Path $PSScriptRoot 'REPORT.md') -Encoding UTF8
Write-Host ('Report: ' + (Join-Path $PSScriptRoot 'REPORT.md'))

if ($failed -gt 0) { exit 1 } else { exit 0 }
