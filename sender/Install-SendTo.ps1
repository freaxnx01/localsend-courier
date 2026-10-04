#requires -Version 7.0
<#
.SYNOPSIS
    Add (or remove) an Explorer "Send to" entry that MOVES the selected files
    into a folder - typically one listed in watchFolder / extraWatchFolders.

.DESCRIPTION
    A plain folder shortcut in the SendTo folder copies the files. This entry
    runs move-to-folder.vbs through wscript instead, so the files are moved and
    no console window appears.

.PARAMETER Folder
    The folder to move files into. Created if it doesn't exist.

.PARAMETER Name
    The label shown under Send to. Defaults to the folder's name.

.PARAMETER Unregister
    Remove the Send to entry named -Name instead of creating it.

.EXAMPLE
    pwsh -NoProfile -File .\Install-SendTo.ps1 -Folder "$env:USERPROFILE\Downloads\_localsend-courier"
.EXAMPLE
    pwsh -NoProfile -File .\Install-SendTo.ps1 -Name _localsend-courier -Unregister
#>
[CmdletBinding()]
param(
    [string]$Folder,
    [string]$Name,
    [switch]$Unregister
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Name) {
    if (-not $Folder) { throw "Pass -Folder (and optionally -Name)." }
    $Name = Split-Path -Leaf $Folder
}
$shortcutPath = Join-Path ([Environment]::GetFolderPath('SendTo')) "$Name.lnk"

if ($Unregister) {
    if (Test-Path -LiteralPath $shortcutPath) {
        Remove-Item -LiteralPath $shortcutPath
        Write-Host "Removed Send to entry '$Name'." -ForegroundColor Green
    } else {
        Write-Host "No Send to entry '$Name' found." -ForegroundColor Yellow
    }
    return
}

if (-not $Folder) { throw "Pass -Folder." }
if (-not (Test-Path -LiteralPath $Folder)) { New-Item -ItemType Directory -Path $Folder | Out-Null }
$Folder = (Resolve-Path -LiteralPath $Folder).Path

$mover = Join-Path $PSScriptRoot 'move-to-folder.vbs'
if (-not (Test-Path -LiteralPath $mover)) { throw "Cannot find move-to-folder.vbs next to this installer." }

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath   = Join-Path $env:SystemRoot 'System32\wscript.exe'
$shortcut.Arguments    = "//NoLogo `"$mover`" `"$Folder`""
$shortcut.IconLocation = Join-Path $env:SystemRoot 'System32\shell32.dll,4'   # folder icon
$shortcut.Save()

Write-Host "Added Send to entry '$Name' -> moves files into $Folder" -ForegroundColor Green
