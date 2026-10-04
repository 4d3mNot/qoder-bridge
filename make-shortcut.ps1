# make-shortcut.ps1 — puts a "Qoder Bridge" launcher on the Desktop.
# Re-running it just refreshes the same shortcut.
$repo = "C:\Users\4d3m\Documents\Qoder\2026-09-27\36e872e6\qoder-bridge"
$desktop = [Environment]::GetFolderPath("Desktop")
$target = Join-Path $repo "start-bridge.bat"

if (-not (Test-Path $target)) { throw "missing $target" }

$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut((Join-Path $desktop "Qoder Bridge.lnk"))
$link.TargetPath = $target
$link.WorkingDirectory = $repo
$link.Description = "Start the Qoder <> Roblox Studio bridge on 127.0.0.1:8346"
$link.IconLocation = "$env:SystemRoot\System32\shell32.dll,137"
$link.Save()

Write-Output "shortcut: $(Join-Path $desktop 'Qoder Bridge.lnk')"
Write-Output "target:   $target"
