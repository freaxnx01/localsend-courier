#requires -Version 7.0
<#
.SYNOPSIS
    Convenience bootstrap: install the third-party LocalSend CLI on Windows.

.DESCRIPTION
    Uses `go install` when Go is available. Otherwise prints the releases URL for
    a manual download. The CLI is 0w0mewo/localsend-cli.

.EXAMPLE
    pwsh -NoProfile -File .\Get-LocalSendCli.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (Get-Command localsend-cli -ErrorAction SilentlyContinue) {
    Write-Host "localsend-cli is already on PATH: $((Get-Command localsend-cli).Source)" -ForegroundColor Green
    return
}

if (Get-Command go -ErrorAction SilentlyContinue) {
    Write-Host "Installing via 'go install github.com/0w0mewo/localsend-cli@latest' ..."
    & go install github.com/0w0mewo/localsend-cli@latest
    if ($LASTEXITCODE -ne 0) { throw "go install failed with exit $LASTEXITCODE" }

    $goBin = & go env GOPATH
    $binDir = Join-Path $goBin.Trim() 'bin'
    Write-Host "Installed to $binDir" -ForegroundColor Green
    if ($env:PATH -notlike "*$binDir*") {
        Write-Warning "Add '$binDir' to your PATH, or set 'localSendCli' in config.json to the full exe path."
    }
} else {
    Write-Warning "Go not found. Download a prebuilt binary from:"
    Write-Host "    https://github.com/0w0mewo/localsend-cli/releases"
    Write-Host "Then put localsend-cli.exe on PATH or set 'localSendCli' in config.json."
}
