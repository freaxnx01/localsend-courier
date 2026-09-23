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
        port                  = 53317
        pin                   = ''
        https                 = $true
        watchFolder           = ''
        fileExtensions        = @('.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.mp4', '.log')
        clipboard             = 'name'   # name | path | none
        localSendCli          = 'localsend-cli'
        deleteMarkerSuffix    = '.localsend-delete'
        pollIntervalSeconds   = 2
        stabilizeSeconds      = 1.5
        sendExistingOnStartup = $false
        stateFile             = ''
        logFile               = ''
        clipboardText         = [pscustomobject]@{
            enabled           = $false
            folder            = ''   # empty = <dataDir>\clips, which is watched too
            minChars          = 50
            hostInbox         = '/home/admin/localsend-inbox'
            hotkeyWindowsPath = 'Ctrl+Shift+L'
            hotkeyHostPath    = 'Ctrl+Shift+J'
            hotkeyOpenFolder  = 'Ctrl+Shift+O'
        }
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

    # Merge-Config is shallow, so a partial "clipboardText" block in config.json
    # would drop the defaults for every key it leaves out.
    $cfg.clipboardText = Merge-Config -Default (Get-DefaultConfig).clipboardText -Override $cfg.clipboardText

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
    if ([string]::IsNullOrWhiteSpace($cfg.clipboardText.folder)) {
        # Deliberately NOT the capture folder: a OneDrive "Files On-Demand"
        # folder accepts writes from the capturing app but rejects file creation
        # by other processes (every create fails with "Could not find file").
        # Dumps go somewhere writable, and Get-WatchedFolders watches it too.
        $cfg.clipboardText.folder = Join-Path $dataDir 'clips'
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
        throw "LocalSend CLI '$Cli' not found. Install it (see Get-LocalSendCli.ps1 / aduggleby/localsend-cli releases) or set 'localSendCli' to its full path."
    }
    $path = $cmd.Source

    # A different project ships a binary with the same name (reports v0.0.7,
    # flags --ip/--dapi, no --to/--direct/--protocol). It only fails once a
    # transfer is under way ("Fingerprint mismatch" / "Invalid body"), so probe
    # it here, once at startup, rather than mid-send.
    $verOut = ''
    $helpOut = ''
    try {
        $verOut  = (& $path '--version' 2>&1 | Out-String).Trim()
        $helpOut = (& $path 'send' '--help' 2>&1 | Out-String)
    } catch {
        Write-Log "Could not probe '$path' ($($_.Exception.Message)); skipping CLI identity check." 'WARN'
        return $path
    }

    # Prefer the grammar over the version string: any build that knows
    # --to/--direct speaks the dialect Send-ViaLocalSend emits.
    $hasGrammar = ($helpOut -match '--direct') -and ($helpOut -match '--to\b')
    $ver = $null
    if ($verOut -match '(\d+\.\d+)') { $ver = [version]$Matches[1] }
    if ($hasGrammar -or ($ver -and $ver -ge [version]'0.9')) { return $path }

    if ($ver -or ($helpOut -match '--dapi|--ip\b')) {
        $what = if ($verOut) { $verOut } else { ($helpOut -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1) }
        throw "LocalSend CLI '$path' reports '$what' - that is not aduggleby/localsend-cli 0.9.x (no --to/--direct/--protocol grammar; transfers would fail mid-send). Run sender\Get-LocalSendCli.ps1 to fetch the right binary, or set 'localSendCli' in config.json to its full path."
    }

    Write-Log "Could not identify the LocalSend CLI at '$path' (unrecognised --version/--help output); continuing anyway." 'WARN'
    return $path
}

function Send-ViaLocalSend {
    param([pscustomobject]$Cfg, [string]$FilePath)

    # aduggleby/localsend-cli (v0.9.x) grammar: --protocol is a GLOBAL option and
    # must precede the 'send' subcommand. We address the host explicitly with
    # --direct <host:port> (skips flaky discovery); --to is still required as a
    # display label, so we reuse the host string for it.
    $port = if ($Cfg.PSObject.Properties.Match('port').Count -and $Cfg.port) { $Cfg.port } else { 53317 }
    $globalArgs = @()
    if (-not $Cfg.https) { $globalArgs += @('--protocol', 'http') }
    $arguments = $globalArgs + @('send', '--to', $Cfg.host, '--direct', "$($Cfg.host):$port", '--file', $FilePath)
    if (-not [string]::IsNullOrWhiteSpace($Cfg.pin)) { $arguments += @('--pin', $Cfg.pin) }

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
# Clipboard-text hotkeys
# ---------------------------------------------------------------------------

# PowerShell has no global hotkeys, so the feature lives in one C# type: a
# hidden message window owns the RegisterHotKey registrations and does the
# save/clipboard/notify work itself. It runs on its own STA thread because
# pwsh 7 is MTA while System.Windows.Forms.Clipboard requires STA; the poll
# loop on the main thread is untouched. Names of the files it writes go on a
# queue so the reconciler can send them without overwriting the path the
# hotkey just put on the clipboard.

$script:ClipTextHotkeySource = @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

public class ClipTextHotkeys
{
    private const int WM_HOTKEY = 0x0312;
    private const uint MOD_ALT = 0x0001, MOD_CONTROL = 0x0002, MOD_SHIFT = 0x0004, MOD_WIN = 0x0008;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    private sealed class MessageWindow : NativeWindow
    {
        private readonly Action<int> _onHotkey;

        public MessageWindow(Action<int> onHotkey)
        {
            _onHotkey = onHotkey;
            CreateHandle(new CreateParams());
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_HOTKEY) { _onHotkey((int)m.WParam); }
            base.WndProc(ref m);
        }
    }

    private readonly string _folder;
    private readonly int _minChars;
    private readonly string _hostInbox;
    private readonly string[] _specs;
    private MessageWindow _window;
    private NotifyIcon _tray;
    private System.Windows.Forms.Timer _trayTimer;

    public readonly ConcurrentQueue<string> Created = new ConcurrentQueue<string>();
    public readonly ConcurrentQueue<string> Messages = new ConcurrentQueue<string>();
    public readonly ManualResetEventSlim Ready = new ManualResetEventSlim(false);

    public ClipTextHotkeys(string folder, int minChars, string hostInbox,
                           string windowsPathKey, string hostPathKey, string openFolderKey)
    {
        _folder = folder;
        _minChars = minChars;
        _hostInbox = (hostInbox == null ? "" : hostInbox.TrimEnd('/'));
        _specs = new string[] { windowsPathKey, hostPathKey, openFolderKey };
    }

    public void Start()
    {
        Thread thread = new Thread(Run);
        thread.SetApartmentState(ApartmentState.STA);
        thread.IsBackground = true;
        thread.Name = "cliptext-hotkeys";
        thread.Start();
    }

    // Exposed so the save path can be exercised without synthesising a keystroke.
    public void Invoke(int id) { OnHotkey(id); }

    private void Run()
    {
        _window = new MessageWindow(OnHotkey);
        _tray = new NotifyIcon();
        _tray.Icon = SystemIcons.Information;
        _tray.Text = "screenpresso-localsend";
        _trayTimer = new System.Windows.Forms.Timer();
        _trayTimer.Interval = 6000;
        _trayTimer.Tick += delegate { _trayTimer.Stop(); _tray.Visible = false; };

        for (int i = 0; i < _specs.Length; i++)
        {
            uint mods, vk;
            if (!TryParseHotkey(_specs[i], out mods, out vk))
            {
                Messages.Enqueue("WARN|Could not parse hotkey '" + _specs[i] + "' - " + Describe(i) + " is inactive.");
                continue;
            }
            if (RegisterHotKey(_window.Handle, i + 1, mods, vk))
            {
                Messages.Enqueue("INFO|  hotkey      : " + _specs[i] + " - " + Describe(i));
            }
            else
            {
                Messages.Enqueue("WARN|Hotkey " + _specs[i] + " is already taken by another application - " + Describe(i) + " is inactive.");
            }
        }

        Ready.Set();
        Application.Run();
    }

    private static string Describe(int index)
    {
        if (index == 0) { return "save clipboard, Windows path back"; }
        if (index == 1) { return "save clipboard, host path back"; }
        return "open the folder";
    }

    private void OnHotkey(int id)
    {
        try
        {
            if (id == 3)
            {
                ProcessStartInfo info = new ProcessStartInfo("explorer.exe", "\"" + _folder + "\"");
                info.UseShellExecute = true;
                Process.Start(info);
                return;
            }
            SaveClipboard(id == 2);
        }
        catch (Exception ex)
        {
            Messages.Enqueue("ERROR|Hotkey " + id + " failed: " + ex.Message);
        }
    }

    private void SaveClipboard(bool hostPath)
    {
        string text = Clipboard.ContainsText() ? Clipboard.GetText() : null;
        if (string.IsNullOrWhiteSpace(text))
        {
            Notify("Clipboard is empty or not text", "Nothing saved.");
            return;
        }
        if (text.Length < _minChars)
        {
            Notify("Clipboard too short (" + text.Length + " chars)", "Minimum is " + _minChars + " - nothing saved.");
            return;
        }

        Directory.CreateDirectory(_folder);
        string name = UniqueName();
        string full = Path.Combine(_folder, name);
        File.WriteAllText(full, text, new UTF8Encoding(false));

        // Enqueue BEFORE touching the clipboard: the reconciler has to know this
        // file is hotkey-made before it can pick it up, or its own
        // "clipboard <- filename" would overwrite the path set just below.
        Created.Enqueue(name);

        string value = hostPath ? _hostInbox + "/" + name : full;
        Clipboard.SetText(value);

        double kb = Math.Round(new FileInfo(full).Length / 1024.0, 1);
        Notify("Clipboard saved (" + kb + " KB)", value);
        Messages.Enqueue("INFO|Clipboard text -> " + name + " (" + kb + " KB); clipboard <- " + value);
    }

    // The name is second-resolution, so two saves inside the same second would
    // collide - and since the file is also sent, the second would silently
    // replace the host's copy of the first.
    private string UniqueName()
    {
        string stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
        string candidate = "console-" + stamp + ".log";
        int suffix = 2;
        while (File.Exists(Path.Combine(_folder, candidate)))
        {
            candidate = "console-" + stamp + "-" + suffix + ".log";
            suffix++;
        }
        return candidate;
    }

    private void Notify(string title, string text)
    {
        if (_tray == null) { return; }
        _tray.Visible = true;
        _tray.ShowBalloonTip(4000, title, text, ToolTipIcon.Info);
        _trayTimer.Stop();
        _trayTimer.Start();
    }

    private static bool TryParseHotkey(string spec, out uint mods, out uint vk)
    {
        mods = 0;
        vk = 0;
        if (string.IsNullOrWhiteSpace(spec)) { return false; }
        foreach (string raw in spec.Split('+'))
        {
            string part = raw.Trim();
            switch (part.ToLowerInvariant())
            {
                case "ctrl":
                case "control": mods |= MOD_CONTROL; break;
                case "shift": mods |= MOD_SHIFT; break;
                case "alt": mods |= MOD_ALT; break;
                case "win": mods |= MOD_WIN; break;
                default:
                    Keys key;
                    if (!Enum.TryParse<Keys>(part, true, out key)) { return false; }
                    vk = (uint)key;
                    break;
            }
        }
        return vk != 0 && mods != 0;
    }
}
'@

function Start-ClipboardTextHotkeys {
    param([pscustomobject]$Cfg)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    if (-not ('ClipTextHotkeys' -as [type])) {
        # WinForms comes from the loaded assemblies (Message lives in
        # Windows.Forms.Primitives, not Windows.Forms). The BCL pieces must be
        # simple names instead: .Assembly.Location resolves those to
        # System.Private.CoreLib, which the compiler will not accept as the
        # reference for a forwarded type.
        $references = @(
            [System.Windows.Forms.Form].Assembly.Location
            [System.Windows.Forms.Message].Assembly.Location
            [System.Drawing.Icon].Assembly.Location
            [System.Diagnostics.Process].Assembly.Location
            'System.Runtime'
            'System.Collections.Concurrent'
            'System.Threading'
            'System.Threading.Thread'
            'System.Text.Encoding.Extensions'
            'System.ComponentModel.Primitives'
            'netstandard'
        )
        Add-Type -TypeDefinition $script:ClipTextHotkeySource -ReferencedAssemblies $references
    }

    $settings = $Cfg.clipboardText
    $folder = if ([string]::IsNullOrWhiteSpace($settings.folder)) { $Cfg.watchFolder } else { $settings.folder }

    $hotkeys = [ClipTextHotkeys]::new(
        $folder, [int]$settings.minChars, $settings.hostInbox,
        $settings.hotkeyWindowsPath, $settings.hotkeyHostPath, $settings.hotkeyOpenFolder)
    $hotkeys.Start()

    if (-not $hotkeys.Ready.Wait(5000)) {
        Write-Log "Clipboard hotkey thread did not report ready within 5s." 'WARN'
    }
    return $hotkeys
}

# Drains both queues: created file names become clipboard suppressions for the
# reconciler, log messages go to the sender log.
function Sync-HotkeyQueues {
    param($Hotkeys, [System.Collections.Generic.HashSet[string]]$SuppressClipboard)

    $name = ''
    while ($Hotkeys.Created.TryDequeue([ref]$name)) { [void]$SuppressClipboard.Add($name) }

    $message = ''
    while ($Hotkeys.Messages.TryDequeue([ref]$message)) {
        $parts = $message.Split('|', 2)
        Write-Log $parts[1] $parts[0]
    }
}

# ---------------------------------------------------------------------------
# Reconcile
# ---------------------------------------------------------------------------

# The capture folder, plus the clipboard-dump folder when the hotkeys write
# somewhere else - a dump has to be watched to be sent and delete-mirrored.
function Get-WatchedFolders {
    param([pscustomobject]$Cfg)
    $folders = @($Cfg.watchFolder)
    if ($Cfg.clipboardText.enabled -and $Cfg.clipboardText.folder -ne $Cfg.watchFolder) {
        $folders += $Cfg.clipboardText.folder
    }
    return $folders
}

function Get-WatchedFiles {
    param([pscustomobject]$Cfg)
    $map = @{}
    foreach ($folder in Get-WatchedFolders -Cfg $Cfg) {
        if (-not (Test-Path -LiteralPath $folder)) { continue }
        Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue |
            Where-Object { $Cfg.fileExtensions -contains $_.Extension.ToLowerInvariant() } |
            Where-Object { -not $_.Name.EndsWith($Cfg.deleteMarkerSuffix) } |
            ForEach-Object { $map[$_.Name] = $_ }
    }
    return $map
}

function Invoke-Reconcile {
    param(
        [pscustomobject]$Cfg,
        [hashtable]$State,
        [System.Collections.Generic.HashSet[string]]$SuppressClipboard
    )

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
            if ($SuppressClipboard.Contains($name)) {
                # A clipboard hotkey wrote this file and already put the path on
                # the clipboard - don't replace it with the bare file name.
                [void]$SuppressClipboard.Remove($name)
            } else {
                Set-ClipboardValue -Cfg $Cfg -File $file
            }
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
Write-Log "  watch folder : $((Get-WatchedFolders -Cfg $cfg) -join ' | ')"
Write-Log "  target host  : $($cfg.host):$($cfg.port) (https=$($cfg.https), pin=$([bool]$cfg.pin))"
Write-Log "  cli          : $cliPath"
Write-Log "  state file   : $($cfg.stateFile)"

$suppressClipboard = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$hotkeys = $null
if ($cfg.clipboardText.enabled) {
    try {
        $hotkeys = Start-ClipboardTextHotkeys -Cfg $cfg
        Sync-HotkeyQueues -Hotkeys $hotkeys -SuppressClipboard $suppressClipboard
    } catch {
        Write-Log "Clipboard hotkeys unavailable: $($_.Exception.Message)" 'WARN'
        $hotkeys = $null
    }
}

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
    if ($hotkeys) { Sync-HotkeyQueues -Hotkeys $hotkeys -SuppressClipboard $suppressClipboard }
    if (Invoke-Reconcile -Cfg $cfg -State $state -SuppressClipboard $suppressClipboard) { Save-State -State $state -Path $cfg.stateFile }
    Write-Log "Single reconcile pass complete."
    return
}

Write-Log "Watching (poll every $($cfg.pollIntervalSeconds)s). Ctrl+C to stop."
while ($true) {
    try {
        if ($hotkeys) { Sync-HotkeyQueues -Hotkeys $hotkeys -SuppressClipboard $suppressClipboard }
        if (Invoke-Reconcile -Cfg $cfg -State $state -SuppressClipboard $suppressClipboard) { Save-State -State $state -Path $cfg.stateFile }
    } catch {
        Write-Log "Reconcile error: $($_.Exception.Message)" 'ERROR'
    }
    Start-Sleep -Seconds $cfg.pollIntervalSeconds
}
