# Removes Shotate for the current user, and its settings. Screenshots are left alone.
#   irm https://raw.githubusercontent.com/baney75/shotate/main/uninstall.ps1 | iex
# Also removes Snapmark, the name Shotate had before 0.12.
$ErrorActionPreference = "Stop"
foreach ($name in "Shotate", "Snapmark") {
  Get-Process $name -ErrorAction SilentlyContinue | Stop-Process -Force
  $uninstaller = Join-Path $env:LOCALAPPDATA "$name\uninstall.exe"
  if (Test-Path $uninstaller) { Start-Process $uninstaller -ArgumentList "/S" -Wait }
  Remove-Item (Join-Path $env:APPDATA $name.ToLower()) -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "Shotate is uninstalled. Your screenshots are still in Pictures\Screenshots."
