# Installs the Shotate preview for Windows (the nightly build), for the current user (no admin needed):
#   irm https://raw.githubusercontent.com/baney75/shotate/main/install.ps1 | iex
# Running it again updates in place; Shotate can also update itself from its tray menu.
$ErrorActionPreference = "Stop"
$repo = "baney75/shotate"
# Stable releases are macOS only for now, so Windows always gets the nightly preview.
if ($env:SHOTATE_CHANNEL -and $env:SHOTATE_CHANNEL -ne "nightly") {
  Write-Host "Stable releases are macOS only for now, so this installs the Windows preview (nightly)."
}
$path = "tags/nightly"
Write-Host "==> Finding the newest Shotate preview for Windows (nightly)"
$release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/$path" -Headers @{ "User-Agent" = "shotate-installer" }
$asset = $release.assets | Where-Object { $_.name -match "_x64-setup\.exe$" } | Select-Object -First 1
if (-not $asset) { throw "No Windows installer in release $($release.tag_name)." }
$setup = Join-Path $env:TEMP $asset.name
Write-Host "==> Downloading $($asset.name)"
Invoke-WebRequest $asset.browser_download_url -OutFile $setup -UseBasicParsing
Write-Host "==> Installing"
# The setup removes Snapmark (the old name) itself and keeps Open at login.
Start-Process $setup -ArgumentList "/S" -Wait
Remove-Item $setup -ErrorAction SilentlyContinue
$exe = Join-Path $env:LOCALAPPDATA "Shotate\shotate.exe"
if (Test-Path $exe) { Start-Process $exe }
Write-Host ""
Write-Host "Shotate is installed. It lives in your system tray; press Ctrl+Shift+S to capture an area."
Write-Host "Windows may show a SmartScreen notice the first time, because Shotate isn't code-signed yet."
