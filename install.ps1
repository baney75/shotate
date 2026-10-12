# Installs Shotate on Windows from the latest release, for the current user (no admin needed):
#   irm https://raw.githubusercontent.com/baney75/shotate/main/install.ps1 | iex
$ErrorActionPreference = "Stop"
$repo = "baney75/shotate"
Write-Host "==> Finding the latest Shotate release"
$release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -Headers @{ "User-Agent" = "shotate-installer" }
$asset = $release.assets | Where-Object { $_.name -match "_x64-setup\.exe$" } | Select-Object -First 1
if (-not $asset) { throw "No Windows installer in release $($release.tag_name)." }
$setup = Join-Path $env:TEMP $asset.name
Write-Host "==> Downloading $($asset.name)"
Invoke-WebRequest $asset.browser_download_url -OutFile $setup -UseBasicParsing
Write-Host "==> Installing"
# Shotate was called Snapmark; remove the old app first so only one copy runs.
$legacy = Join-Path $env:LOCALAPPDATA "Snapmark\uninstall.exe"
if (Test-Path $legacy) {
  Get-Process snapmark -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Process $legacy -ArgumentList "/S" -Wait
}
Start-Process $setup -ArgumentList "/S" -Wait
Remove-Item $setup -ErrorAction SilentlyContinue
$exe = Join-Path $env:LOCALAPPDATA "Shotate\shotate.exe"
if (Test-Path $exe) { Start-Process $exe }
Write-Host ""
Write-Host "Shotate is installed. It lives in your system tray; press Ctrl+Shift+S to capture an area."
Write-Host "Windows may show a SmartScreen notice the first time, because Shotate isn't code-signed yet."
