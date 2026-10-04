' Send To target: moves the selected files into a folder - typically one the sender
' watches. A plain folder shortcut in the SendTo folder copies instead of moving.
' Install-SendTo.ps1 creates the shortcut that calls this.
' Usage: wscript.exe //NoLogo move-to-folder.vbs <target-folder> <file> [file...]
Option Explicit

Dim fso, target, i, source, destination, skipped
Set fso = CreateObject("Scripting.FileSystemObject")
If WScript.Arguments.Count < 2 Then WScript.Quit 1
target = WScript.Arguments(0)
If Not fso.FolderExists(target) Then fso.CreateFolder target

For i = 1 To WScript.Arguments.Count - 1
    source = WScript.Arguments(i)
    destination = fso.BuildPath(target, fso.GetFileName(source))
    If Not fso.FileExists(source) Then
        skipped = skipped & vbCrLf & source & "  (not a file)"
    ElseIf fso.FileExists(destination) Then
        skipped = skipped & vbCrLf & source & "  (already in the target folder)"
    Else
        fso.MoveFile source, destination
    End If
Next

If Len(skipped) > 0 Then MsgBox "Not moved:" & skipped, vbExclamation, "localsend-courier"
