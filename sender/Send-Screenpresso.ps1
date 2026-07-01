#requires -Version 7.0
<#
.SYNOPSIS
    Watch the Screenpresso capture folder and forward new files over LocalSend,
    copying each filename to the clipboard and mirroring local deletions to the
    receiving host via delete-marker files.

.DESCRIPTION
    Runs a poll loop that reconciles the watch folder against a small JSON state
    file. New (settled) files are sent with `localsend-cli send`; files that
    disappear locally trigger a `<name>.localsend-delete` marker so a companion
    watcher on the host can remove the received copy.

.PARAMETER ConfigPath
    Path to the JSON config file. Defaults to config.json next to this script.

.PARAMETER Once
    Run a single reconcile pass and exit (useful for testing / scheduled sweeps).

.EXAMPLE
    pwsh -NoProfile -File .\Send-Screenpresso.ps1 -ConfigPath .\config.json
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [switch]$Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

function Get-DefaultConfig {
    [pscustomobject]@{
        host                  = ''
        pin                   = ''
        https                 = $true
        watchFolder           = ''
        fileExtensions        = @('.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.mp4')
        clipboard             = 'name'   # name | path | none
        localSendCli          = 'localsend-cli'
        deleteMarkerSuffix    = '.localsend-delete'
        pollIntervalSeconds   = 2
        stabilizeSeconds      = 1.5
        sendExistingOnStartup = $false
        stateFile             = ''
        logFile               = ''
    }
}

function Merge-Config {
    param([pscustomobject]$Default, [pscustomobject]$Override)
    $result = $Default.PSObject.Copy()
    if ($null -ne $Override) {
        foreach ($prop in $Override.PSObject.Properties) {
            $result | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
        }
    }
    $result
}

function Resolve-Config {
    param([string]$Path)

    $override = $null
    if (Test-Path -LiteralPath $Path) {
        $override = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } else {
        Write-Warning "Config file '$Path' not found - using defaults (host must be set)."
    }
    $cfg = Merge-Config -Default (Get-DefaultConfig) -Override $override

    if ([string]::IsNullOrWhiteSpace($cfg.watchFolder)) {
        $cfg.watchFolder = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'Screenpresso'
    }

    $dataDir = Join-Path $env:LOCALAPPDATA 'screenpresso-localsend'
    if ([string]::IsNullOrWhiteSpace($cfg.stateFile)) {
        $cfg.stateFile = Join-Path $dataDir 'state.json'
    }
    if ([string]::IsNullOrWhiteSpace($cfg.logFile)) {
        $cfg.logFile = Join-Path $dataDir 'sender.log'
    }

    if ([string]::IsNullOrWhiteSpace($cfg.host)) {
        throw "Config error: 'host' is required (target IP or hostname)."
    }

    # Normalize extensions to lower-case with a leading dot.
    $cfg.fileExtensions = @($cfg.fileExtensions | ForEach-Object {
        $e = $_.ToString().ToLowerInvariant()
        if (-not $e.StartsWith('.')) { $e = ".$e" }
        $e
    })

    return $cfg
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

$script:LogFile = $null

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding utf8 } catch { }
    }
}

# ---------------------------------------------------------------------------
# State (map of file name -> metadata)
# ---------------------------------------------------------------------------

function Import-State {
    param([string]$Path)
    $state = @{}
    if (Test-Path -LiteralPath $Path) {
        try {
            $obj = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            foreach ($prop in $obj.PSObject.Properties) { $state[$prop.Name] = $prop.Value }
        } catch {
            Write-Log "Could not read state file '$Path': $($_.Exception.Message)" 'WARN'
        }
    }
    return $state
}

function Save-State {
    param([hashtable]$State, [string]$Path)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ($State | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $Path -Encoding utf8
}

# ---------------------------------------------------------------------------
# LocalSend CLI
# ---------------------------------------------------------------------------

function Assert-Cli {
    param([string]$Cli)
    $cmd = Get-Command $Cli -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "LocalSend CLI '$Cli' not found. Install it (go install github.com/0w0mewo/localsend-cli@latest) or set 'localSendCli' to its full path."
    }
    return $cmd.Source
}

function Send-ViaLocalSend {
    param([pscustomobject]$Cfg, [string]$FilePath)

    $arguments = @('send', '--ip', $Cfg.host, '-f', $FilePath)
    if (-not [string]::IsNullOrWhiteSpace($Cfg.pin)) { $arguments += @('-p', $Cfg.pin) }
    if (-not $Cfg.https) { $arguments += '--https=false' }

    $output = & $Cfg.localSendCli @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "localsend-cli exit ${LASTEXITCODE}: $output" 'ERROR'
        return $false
    }
    return $true
}

function Send-DeleteMarker {
    param([pscustomobject]$Cfg, [string]$Name)

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) 'screenpresso-localsend'
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $markerName = "$Name$($Cfg.deleteMarkerSuffix)"
    $markerPath = Join-Path $tmpDir $markerName
    # Content is the target name too, as a belt-and-braces fallback for the host.
    Set-Content -LiteralPath $markerPath -Value $Name -Encoding utf8 -NoNewline

    try {
        return Send-ViaLocalSend -Cfg $Cfg -FilePath $markerPath
    } finally {
        Remove-Item -LiteralPath $markerPath -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Clipboard
# ---------------------------------------------------------------------------

function Set-ClipboardValue {
    param([pscustomobject]$Cfg, [System.IO.FileInfo]$File)
    switch ($Cfg.clipboard) {
        'none' { return }
        'path' { $value = $File.FullName }
        default { $value = $File.Name }
    }
    try {
        Set-Clipboard -Value $value
        Write-Log "Clipboard <- $value"
    } catch {
        Write-Log "Failed to set clipboard: $($_.Exception.Message)" 'WARN'
    }
}

# ---------------------------------------------------------------------------
# Reconcile
# ---------------------------------------------------------------------------

function Get-WatchedFiles {
    param([pscustomobject]$Cfg)
    if (-not (Test-Path -LiteralPath $Cfg.watchFolder)) { return @{} }
    $map = @{}
    Get-ChildItem -LiteralPath $Cfg.watchFolder -File -ErrorAction SilentlyContinue |
        Where-Object { $Cfg.fileExtensions -contains $_.Extension.ToLowerInvariant() } |
        Where-Object { -not $_.Name.EndsWith($Cfg.deleteMarkerSuffix) } |
        ForEach-Object { $map[$_.Name] = $_ }
    return $map
}

function Invoke-Reconcile {
    param([pscustomobject]$Cfg, [hashtable]$State)

    $current = Get-WatchedFiles -Cfg $Cfg
    $now = Get-Date
    $changed = $false

    # --- New / not-yet-sent files ---
    foreach ($name in $current.Keys) {
        if ($State.ContainsKey($name)) { continue }
        $file = $current[$name]

        # Wait until the file has been idle long enough (writes finished).
        $idle = ($now - $file.LastWriteTime).TotalSeconds
        if ($idle -lt $Cfg.stabilizeSeconds) { continue }

        Write-Log "Sending new file: $name ($([math]::Round($file.Length/1KB,1)) KB)"
        if (Send-ViaLocalSend -Cfg $Cfg -FilePath $file.FullName) {
            $State[$name] = [pscustomobject]@{
                size   = $file.Length
                sentAt = $now.ToString('o')
            }
            Set-ClipboardValue -Cfg $Cfg -File $file
            $changed = $true
        }
    }

    # --- Files that were sent but have since been deleted locally ---
    foreach ($name in @($State.Keys)) {
        if ($current.ContainsKey($name)) { continue }
        Write-Log "Local delete detected: $name -> sending delete marker"
        if (Send-DeleteMarker -Cfg $Cfg -Name $name) {
            $State.Remove($name)
            $changed = $true
        }
    }

    return $changed
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$cfg = Resolve-Config -Path $ConfigPath
$dataDir = Split-Path -Parent $cfg.stateFile
if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
$script:LogFile = $cfg.logFile

$cliPath = Assert-Cli -Cli $cfg.localSendCli

Write-Log "screenpresso-localsend sender starting"
Write-Log "  watch folder : $($cfg.watchFolder)"
Write-Log "  target host  : $($cfg.host) (https=$($cfg.https), pin=$([bool]$cfg.pin))"
Write-Log "  cli          : $cliPath"
Write-Log "  state file   : $($cfg.stateFile)"

if (-not (Test-Path -LiteralPath $cfg.watchFolder)) {
    Write-Log "Watch folder does not exist yet; it will be picked up once Screenpresso creates it." 'WARN'
}

$state = Import-State -Path $cfg.stateFile

# On first run, adopt any existing files as "known" (unless configured to send
# them) so we don't blast the whole folder or mistake them for deletions.
if ($state.Count -eq 0 -and -not $cfg.sendExistingOnStartup) {
    $existing = Get-WatchedFiles -Cfg $cfg
    foreach ($name in $existing.Keys) {
        $state[$name] = [pscustomobject]@{ size = $existing[$name].Length; sentAt = 'preexisting' }
    }
    if ($existing.Count -gt 0) {
        Write-Log "Adopted $($existing.Count) pre-existing file(s) without sending (sendExistingOnStartup=false)."
        Save-State -State $state -Path $cfg.stateFile
    }
}

if ($Once) {
    if (Invoke-Reconcile -Cfg $cfg -State $state) { Save-State -State $state -Path $cfg.stateFile }
    Write-Log "Single reconcile pass complete."
    return
}

Write-Log "Watching (poll every $($cfg.pollIntervalSeconds)s). Ctrl+C to stop."
while ($true) {
    try {
        if (Invoke-Reconcile -Cfg $cfg -State $state) { Save-State -State $state -Path $cfg.stateFile }
    } catch {
        Write-Log "Reconcile error: $($_.Exception.Message)" 'ERROR'
    }
    Start-Sleep -Seconds $cfg.pollIntervalSeconds
}
