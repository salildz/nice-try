' launch.vbs  -  runs fake-desktop.ps1 without showing a console window.
' Keep this file in the SAME folder as fake-desktop.ps1.
Set sh = CreateObject("WScript.Shell")
folder = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & folder & "\fake-desktop.ps1""", 0, False
