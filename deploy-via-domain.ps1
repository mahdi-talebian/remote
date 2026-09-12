<#
.SYNOPSIS
    (Optional) Deploys deploy-employee.ps1 to many Windows machines remotely.

    Requirements:
      - Machines are reachable from your computer (same network / VPN)
      - WinRM is enabled on them (Set-Item WSMan:\localhost\Client\TrustedHosts -Value *,
        or domain GPO "Enable Remote PowerShell"; for a quick test on one machine:
        Enable-PSRemoting -SkipNetworkProfileCheck)
      - Your credentials are an administrator on those machines
    Alternative without WinRM: use PsExec (sysinternals):
      psexec \\pc-01 -s -i powershell -ExecutionPolicy Bypass -File C:\deploy-employee.ps1 -AdminPassword '...'

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\deploy-via-domain.ps1 `
        -ComputerNames pc-01,pc-02,pc-03 `
        -AdminPassword "ChangeMe-Str0ng!"
#>

param(
    [Parameter(Mandatory = $true)]
    [string[]]$ComputerNames,

    [Parameter(Mandatory = $true)]
    [string]$AdminPassword,

    [System.Management.Automation.PSCredential]$Credential
)

$script = Join-Path $PSScriptRoot 'deploy-employee.ps1'

foreach ($c in $ComputerNames) {
    Write-Host "=== $c ===" -ForegroundColor Cyan
    try {
        $common = @{ ComputerName = $c; FilePath = $script; ErrorAction = 'Stop' }
        if ($Credential) { $common.Credential = $Credential }
        Invoke-Command @common -ArgumentList $AdminPassword
        Write-Host ("{0}: OK" -f $c) -ForegroundColor Green
    } catch {
        Write-Warning ("{0}: {1}" -f $c, $_.Exception.Message)
    }
}
