' Verdaccio Toolbox - silent launcher (no console window)
' Double-click to start the UI server hidden; browser opens automatically.
' Use run-ui.bat instead if you need to see server logs.

Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

rootDir = fso.GetParentFolderName(WScript.ScriptFullName)
shell.CurrentDirectory = rootDir & "\ui"

' 0 = hidden window, False = do not wait
shell.Run "node server.js", 0, False
