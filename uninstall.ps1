# Removes Snapmark for the current user, and its settings. Screenshots are left alone.
#   irm https://raw.githubusercontent.com/baney75/snapmark/main/uninstall.ps1 | iex
$ErrorActionPreference = "Stop"
Get-Process snapmark -ErrorAction SilentlyContinue | Stop-Process -Force
$uninstaller = Join-Path $env:LOCALAPPDATA "Snapmark\uninstall.exe"
if (Test-Path $uninstaller) { Start-Process $uninstaller -ArgumentList "/S" -Wait }
Remove-Item (Join-Path $env:APPDATA "snapmark") -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Snapmark is uninstalled. Your screenshots are still in Pictures\Screenshots."
