# Installs the Yapshot preview for Windows (the nightly build), for the current user (no admin needed):
#   irm https://raw.githubusercontent.com/baney75/yapshot/main/install.ps1 | iex
# Running it again updates in place; Yapshot can also update itself from its tray menu.
$ErrorActionPreference = "Stop"
$repo = "baney75/yapshot"
# Stable releases are macOS only for now, so Windows always gets the nightly preview.
$channel = if ($env:YAPSHOT_CHANNEL) { $env:YAPSHOT_CHANNEL } else { $env:SHOTATE_CHANNEL }  # SHOTATE_: the old name
if ($channel -and $channel -ne "nightly") {
  Write-Host "Stable releases are macOS only for now, so this installs the Windows preview (nightly)."
}
$path = "tags/nightly"
Write-Host "==> Finding the newest Yapshot preview for Windows (nightly)"
$release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/$path" -Headers @{ "User-Agent" = "yapshot-installer" }
$asset = $release.assets | Where-Object { $_.name -match "_x64-setup\.exe$" } | Select-Object -First 1
if (-not $asset) { throw "No Windows installer in release $($release.tag_name)." }
$setup = Join-Path $env:TEMP $asset.name
Write-Host "==> Downloading $($asset.name)"
Invoke-WebRequest $asset.browser_download_url -OutFile $setup -UseBasicParsing
Write-Host "==> Installing"
# The setup removes Shotate and Snapmark (the old names) itself, keeps Open at login, and starts
# Yapshot when it replaced Shotate.
Start-Process $setup -ArgumentList "/S" -Wait
Remove-Item $setup -ErrorAction SilentlyContinue
$exe = Join-Path $env:LOCALAPPDATA "Yapshot\yapshot.exe"
if ((Test-Path $exe) -and -not (Get-Process yapshot -ErrorAction SilentlyContinue)) { Start-Process $exe }
Write-Host ""
Write-Host "Yapshot is installed. It lives in your system tray; press Ctrl+Shift+S to capture an area."
Write-Host "Windows may show a SmartScreen notice the first time, because Yapshot isn't code-signed yet."
