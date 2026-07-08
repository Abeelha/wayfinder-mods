' Silent launcher for the WFQoL Watchdog (no console flash). This is what the Desktop shortcut runs.
' Starts the watchdog, which launches Wayfinder via Steam and auto-relaunches on crash/freeze.
Dim shell, fso, dir
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
shell.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\wf-watchdog.ps1""", 0, False
