#requires -Version 7.0
<#
.SYNOPSIS
    Convenience bootstrap: install the third-party LocalSend CLI on Windows.

.DESCRIPTION
    This project targets aduggleby/localsend-cli - a Rust CLI built for
    non-interactive automation. It ships as prebuilt binaries (there is no
    `go install`); this script points you at the releases page and, if `cargo`
    is available, offers to build from source.

.EXAMPLE
    pwsh -NoProfile -File .\Get-LocalSendCli.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo     = 'https://github.com/aduggleby/localsend-cli'
$releases = "$repo/releases"

if (Get-Command localsend-cli -ErrorAction SilentlyContinue) {
    Write-Host "localsend-cli is already on PATH: $((Get-Command localsend-cli).Source)" -ForegroundColor Green
    return
}

if (Get-Command cargo -ErrorAction SilentlyContinue) {
    Write-Host "Building via 'cargo install --git $repo localsend-cli' ..."
    & cargo install --git $repo localsend-cli
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "cargo install failed with exit $LASTEXITCODE. Download a prebuilt binary instead:"
        Write-Host "    $releases"
        return
    }
    $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
    Write-Host "Installed to $cargoBin" -ForegroundColor Green
    if ($env:PATH -notlike "*$cargoBin*") {
        Write-Warning "Add '$cargoBin' to your PATH, or set 'localSendCli' in config.json to the full exe path."
    }
} else {
    Write-Warning "Rust/cargo not found. Download a prebuilt localsend-cli.exe from:"
    Write-Host "    $releases"
    Write-Host "Then put localsend-cli.exe on PATH or set 'localSendCli' in config.json to the full path."
}
