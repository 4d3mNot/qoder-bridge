# motw-check.ps1 — report Mark-of-the-Web on a folder, and strip it when asked.
#   powershell -ExecutionPolicy Bypass -File motw-check.ps1 -Path .\qoder-bridge
#   powershell -ExecutionPolicy Bypass -File motw-check.ps1 -Path .\qoder-bridge -Unblock
param(
  [Parameter(Mandatory = $true)][string]$Path,
  [switch]$Unblock
)

$root = Resolve-Path -Path $Path -ErrorAction SilentlyContinue
if (-not $root) {
  # A scan of a path that does not exist must never print "no Mark of the Web" — that reads as a clean
  # bill of health for a folder this run never looked inside.
  "FAIL - no such path: $Path"
  exit 2
}
$files = @(Get-ChildItem -Path $root.ProviderPath -Recurse -File)
if ($files.Count -eq 0) {
  "FAIL - found 0 files under $($root.ProviderPath); nothing was scanned"
  exit 2
}
$marked = @()
foreach ($f in $files) {
  $stream = Get-Item -Path $f.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue
  if ($stream) { $marked += $f.FullName }
}

"scanned {0} file(s) under {1}" -f $files.Count, $root.ProviderPath
if ($marked.Count -eq 0) {
  "no Mark of the Web - SmartScreen will not warn on these files"
} else {
  "marked as downloaded ($($marked.Count)):"
  $marked | ForEach-Object { "  $_" }
  if ($Unblock) {
    $marked | ForEach-Object { Unblock-File -Path $_ }
    "ran Unblock-File on all of them"
    $still = @($marked | Where-Object { Get-Item -Path $_ -Stream Zone.Identifier -ErrorAction SilentlyContinue })
    "still marked after unblock: $($still.Count)"
  } else {
    "fix: powershell -ExecutionPolicy Bypass -File motw-check.ps1 -Path $Path -Unblock"
  }
}
