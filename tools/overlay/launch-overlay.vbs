' Silent launcher for the WFQoL overlay (no console flash). Used by the
' Startup-folder shortcut created by install-autostart.ps1.
Dim shell, fso, dir
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
shell.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\WFQoL-Overlay.ps1""", 0, False
