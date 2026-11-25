# Removes Yapshot for the current user, and its settings. Screenshots are left alone.
#   irm https://raw.githubusercontent.com/baney75/yapshot/main/uninstall.ps1 | iex
# Also removes Shotate and Snapmark, the names Yapshot had before.
$ErrorActionPreference = "Stop"
foreach ($name in "Yapshot", "Shotate", "Snapmark") {
  Get-Process $name -ErrorAction SilentlyContinue | Stop-Process -Force
  $uninstaller = Join-Path $env:LOCALAPPDATA "$name\uninstall.exe"
  if (Test-Path $uninstaller) { Start-Process $uninstaller -ArgumentList "/S" -Wait }
  Remove-Item (Join-Path $env:APPDATA $name.ToLower()) -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "Yapshot is uninstalled. Your screenshots are still in Pictures\Screenshots."
