' Start a command with no visible window (SW_HIDE at creation) and wait for it.
' Used by the scheduled task that Install-Sender.ps1 registers: with Windows Terminal as
' the default console host, pwsh -WindowStyle Hidden still opens a Terminal window.
' Returns the command's exit code, so the task's restart-on-failure settings keep working.
' Usage: wscript.exe //B //NoLogo run-hidden.vbs <exe> [args...]
Set args = WScript.Arguments
If args.Count = 0 Then WScript.Quit 1
cmd = ""
For i = 0 To args.Count - 1
    a = args(i)
    If InStr(a, " ") > 0 Or a = "" Then a = """" & a & """"
    cmd = cmd & a & " "
Next
WScript.Quit CreateObject("WScript.Shell").Run(Trim(cmd), 0, True)
