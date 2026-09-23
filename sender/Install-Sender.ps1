#requires -Version 7.0
<#
.SYNOPSIS
    Register (or remove) a hidden per-user scheduled task that runs
    Send-Screenpresso.ps1 at logon and keeps it running.

.PARAMETER ConfigPath
    Path to the sender config.json. Defaults to config.json next to this script.

.PARAMETER TaskName
    Scheduled task name. Default: 'localsend-courier'.

.PARAMETER Unregister
    Remove the scheduled task instead of creating it.

.EXAMPLE
    pwsh -NoProfile -File .\Install-Sender.ps1 -ConfigPath .\config.json
.EXAMPLE
    pwsh -NoProfile -File .\Install-Sender.ps1 -Unregister
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string]$TaskName = 'localsend-courier',
    [switch]$Unregister
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Unregister) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed scheduled task '$TaskName'." -ForegroundColor Green
    } else {
        Write-Host "No scheduled task '$TaskName' found." -ForegroundColor Yellow
    }
    return
}

$scriptPath = Join-Path $PSScriptRoot 'Send-Screenpresso.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) { throw "Cannot find Send-Screenpresso.ps1 next to this installer." }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config '$ConfigPath' not found. Copy config.example.json to config.json and edit it first." }

$pwsh = (Get-Process -Id $PID).Path   # the pwsh that's running this installer
$argList = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`" -ConfigPath `"$ConfigPath`""

$action    = New-ScheduledTaskAction -Execute $pwsh -Argument $argList
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 3 `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "Registered scheduled task '$TaskName'." -ForegroundColor Green
Write-Host "It starts at your next logon. Start it now with:" -ForegroundColor Green
Write-Host "    Start-ScheduledTask -TaskName '$TaskName'"
