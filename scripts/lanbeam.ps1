<#
  LanBeam one-click launcher for Windows.

  Double-click run.bat in the project root, or run:
    .\run.bat                 interactive menu
    .\run.bat windows         update + run the desktop app on this PC
    .\run.bat android         update + run on the USB-connected Android phone
    .\run.bat emulator        update + start the Android emulator and run there
    .\run.bat install-apk     build the APK and install it on the running emulator/phone
    .\run.bat build-windows   build the Windows app into dist\LanBeam-windows
    .\run.bat build-apk       build dist\LanBeam.apk (and install it if a phone is connected)
    .\run.bat all             build both
    .\run.bat test            run the automated tests
    .\run.bat doctor          check the toolchain
  Add -NoUpdate to skip "git pull".

  Every action first: pulls the latest code (only if you have no local
  edits), checks the Flutter version, cleans stale build files when the
  dependencies changed, and runs "flutter pub get".

  Written for Windows PowerShell 5.1 (built into Windows 10/11).
#>
param(
  [Parameter(Position = 0)][string]$Action = '',
  [switch]$NoUpdate
)

$ErrorActionPreference = 'Stop'
$MinFlutter = [version]'3.47.0'
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

function Info($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok($msg) { Write-Host "  OK  $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  !!  $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "  XX  $msg" -ForegroundColor Red; exit 1 }

function Invoke-Flutter {
  # Runs flutter with live output; stops the script if it fails.
  & flutter @args
  if ($LASTEXITCODE -ne 0) { Fail "flutter $($args -join ' ') failed (exit code $LASTEXITCODE)." }
}

function Get-FlutterJson([string[]]$FlutterArgs) {
  # flutter may print banners before the JSON; keep only the JSON part.
  $raw = (& flutter @FlutterArgs 2>$null) -join "`n"
  $start = $raw.IndexOfAny([char[]]'[{')
  if ($start -lt 0) { return $null }
  return ($raw.Substring($start) | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------
# 1. Toolchain checks

function Test-Toolchain {
  Info 'Checking tools'
  if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    Fail 'Flutter was not found. Install it from https://docs.flutter.dev/get-started/install and reopen this window.'
  }
  $ver = Get-FlutterJson @('--version', '--machine')
  if ($null -eq $ver) { Fail 'Could not read the Flutter version.' }
  $current = [version]($ver.frameworkVersion -replace '[^0-9.].*$', '')
  if ($current -lt $MinFlutter) {
    Warn "Flutter $current is too old; LanBeam needs $MinFlutter or newer."
    $answer = Read-Host '  Upgrade Flutter now? (Y/n)'
    if ($answer -eq '' -or $answer -match '^[Yy]') {
      Invoke-Flutter channel stable
      Invoke-Flutter upgrade
    } else {
      Fail 'Please run "flutter upgrade" and try again.'
    }
  } else {
    Ok "Flutter $current (Dart $($ver.dartSdkVersion))"
  }
}

# ---------------------------------------------------------------------------
# 2. Get the latest code

function Update-Code {
  if ($NoUpdate) { Warn 'Skipping update (-NoUpdate).'; return }
  if (-not (Get-Command git -ErrorAction SilentlyContinue) -or -not (Test-Path (Join-Path $Root '.git'))) {
    Warn 'Not a git checkout; skipping update.'
    return
  }
  # Leftovers from running npm in this folder (this is not a Node project).
  foreach ($junk in @('package-lock.json', 'node_modules')) {
    $path = Join-Path $Root $junk
    if ((Test-Path $path) -and -not (git ls-files $junk)) {
      Remove-Item -Recurse -Force $path
      Ok "Removed stray $junk (npm is not used by this project)"
    }
  }
  Info 'Getting the latest version'
  $dirty = git status --porcelain
  if ($dirty) {
    Warn 'You have local changes:'
    $dirty | Select-Object -First 15 | ForEach-Object { Write-Host "      $_" }
    $answer = Read-Host '  Discard them and update to the latest version? (y/N)'
    if ($answer -match '^[Yy]') {
      git reset --hard HEAD | Out-Null
      git clean -fd -e build -e .dart_tool | Out-Null
    } else {
      Warn 'Keeping your changes; not updating.'
      return
    }
  }
  git pull --ff-only
  if ($LASTEXITCODE -ne 0) {
    Warn 'Could not fast-forward (your branch has its own commits). Continuing with the current code.'
  } else {
    Ok "At $(git log -1 --format='%h %s')"
  }
}

# ---------------------------------------------------------------------------
# 3. Dependencies (cleans stale native build files when plugins change)

function Update-Dependencies {
  Info 'Preparing dependencies'
  $lock = Join-Path $Root 'pubspec.lock'
  $stampDir = Join-Path $Root '.dart_tool'
  $stamp = Join-Path $stampDir 'lanbeam-launcher.stamp'
  $hash = (Get-FileHash $lock -Algorithm SHA256).Hash + '|' + (Get-FileHash (Join-Path $Root 'pubspec.yaml') -Algorithm SHA256).Hash
  $previous = if (Test-Path $stamp) { Get-Content $stamp -Raw } else { '' }
  if ($previous.Trim() -ne $hash -and (Test-Path (Join-Path $Root 'build'))) {
    Warn 'Dependencies changed since the last build; cleaning old build files.'
    Invoke-Flutter clean
  }
  Invoke-Flutter pub get
  New-Item -ItemType Directory -Force $stampDir | Out-Null
  Set-Content -Path $stamp -Value $hash -NoNewline
  Ok 'Dependencies ready'
}

# ---------------------------------------------------------------------------
# Actions

function Get-AndroidDevice {
  $devices = Get-FlutterJson @('devices', '--machine')
  if ($null -eq $devices) { return $null }
  return @($devices | Where-Object { $_.targetPlatform -like 'android*' -and $_.isSupported }) | Select-Object -First 1
}

function Get-EmulatorIds {
  # "flutter emulators" prints lines like: Pixel_8_API_35 • Pixel 8 API 35 • Google • android
  $lines = & flutter emulators 2>$null
  $ids = @()
  foreach ($line in $lines) {
    $parts = $line -split '\s[\u2022|]\s'
    if ($parts.Count -ge 4 -and $parts[3].Trim() -eq 'android') { $ids += $parts[0].Trim() }
  }
  return $ids
}

function Wait-AndroidDevice([int]$Seconds) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    $d = Get-AndroidDevice
    if ($null -ne $d) { return $d }
    Start-Sleep -Seconds 3
    Write-Host '.' -NoNewline
  }
  Write-Host ''
  return $null
}

function Start-AndroidEmulator {
  # Reuse a running emulator or connected phone.
  $device = Get-AndroidDevice
  if ($null -ne $device) { Ok "Using $($device.name)"; return $device }

  $ids = @(Get-EmulatorIds)
  if ($ids.Count -eq 0) {
    Warn 'No Android emulator exists yet; trying to create one.'
    & flutter emulators --create --name LanBeam_Emulator | Out-Host
    $ids = @(Get-EmulatorIds)
  }
  if ($ids.Count -eq 0) {
    Warn 'Could not create an emulator automatically.'
    Write-Host '      Open Android Studio > More Actions > Virtual Device Manager > Create device,'
    Write-Host '      pick any phone (e.g. Pixel 8), download a system image, Finish. Then run this again.'
    exit 1
  }
  Info "Starting emulator $($ids[0]) (the first boot can take a few minutes)"
  & flutter emulators --launch $ids[0] | Out-Host
  $device = Wait-AndroidDevice 300
  if ($null -eq $device) { Fail 'The emulator did not finish booting. Start it from Android Studio and try again.' }
  Ok "Emulator ready: $($device.name)"
  return $device
}

function Start-Emulator {
  $device = Start-AndroidEmulator
  Info "Starting LanBeam on $($device.name)"
  Invoke-Flutter run -d $device.id
}

function Install-Apk {
  Start-AndroidEmulator | Out-Null
  Build-Apk
}

function Show-PhoneHelp {
  Warn 'No Android phone found.'
  Write-Host '      1. Run "flutter doctor" - "Android toolchain" must be green (install Android Studio).'
  Write-Host '      2. Phone: Settings > About phone > tap "Build number" 7 times.'
  Write-Host '      3. Phone: Developer options > USB debugging = On.'
  Write-Host '      4. Plug in the USB cable and tap "Allow" on the phone.'
}

function Start-Windows {
  Info 'Starting LanBeam on this PC (close the app window or press q here to stop)'
  Write-Host '      If Windows Firewall asks, allow LanBeam on Private networks.' -ForegroundColor DarkGray
  Invoke-Flutter run -d windows
}

function Start-Android {
  $device = Get-AndroidDevice
  if ($null -eq $device) { Show-PhoneHelp; exit 1 }
  Info "Starting LanBeam on $($device.name)"
  Invoke-Flutter run -d $device.id
}

function Build-Windows {
  Info 'Building the Windows app (release)'
  Invoke-Flutter build windows --release
  $out = Join-Path $Root 'dist\LanBeam-windows'
  if (Test-Path $out) { Remove-Item -Recurse -Force $out }
  New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
  Copy-Item -Recurse (Join-Path $Root 'build\windows\x64\runner\Release') $out
  Ok "Windows app: $out\lanbeam.exe"
}

function Build-Apk {
  Info 'Building the Android app (release APK)'
  Invoke-Flutter build apk --release
  $dist = Join-Path $Root 'dist'
  New-Item -ItemType Directory -Force $dist | Out-Null
  $apk = Join-Path $dist 'LanBeam.apk'
  Copy-Item -Force (Join-Path $Root 'build\app\outputs\flutter-apk\app-release.apk') $apk
  Ok "Android app: $apk"
  $device = Get-AndroidDevice
  if ($null -ne $device) {
    Info "Installing on $($device.name)"
    Invoke-Flutter install -d $device.id --release
    Ok 'Installed - open LanBeam on the phone.'
  } else {
    Write-Host '      Copy dist\LanBeam.apk to your phone and open it to install, drag it onto a running'
    Write-Host '      emulator window, or use option 6 to start the emulator and install automatically.'
  }
}

function Invoke-Tests {
  Info 'Running tests'
  Invoke-Flutter test test/core
}

function Show-Menu {
  Write-Host ''
  Write-Host '  LanBeam' -ForegroundColor White
  Write-Host '  -------'
  Write-Host '  1  Run on this PC (Windows)'
  Write-Host '  2  Run on my Android phone (USB)'
  Write-Host '  3  Run on Android emulator (starts it if needed)'
  Write-Host '  4  Build Windows app       -> dist\LanBeam-windows'
  Write-Host '  5  Build Android APK       -> dist\LanBeam.apk (installs if phone/emulator running)'
  Write-Host '  6  Install APK on emulator (starts it, builds, installs)'
  Write-Host '  7  Build both'
  Write-Host '  8  Run tests'
  Write-Host '  9  Check my setup (flutter doctor)'
  Write-Host ''
  $choice = Read-Host '  Choose 1-9 (Enter = 1)'
  switch ($choice) {
    '' { return 'windows' }
    '1' { return 'windows' }
    '2' { return 'android' }
    '3' { return 'emulator' }
    '4' { return 'build-windows' }
    '5' { return 'build-apk' }
    '6' { return 'install-apk' }
    '7' { return 'all' }
    '8' { return 'test' }
    '9' { return 'doctor' }
    default { Fail "Unknown choice '$choice'." }
  }
}

# ---------------------------------------------------------------------------

if ($Action -eq '') { $Action = Show-Menu }
$Action = $Action.ToLowerInvariant()
$known = @('windows', 'android', 'emulator', 'build-windows', 'build-apk', 'install-apk', 'all', 'test', 'doctor')
if ($known -notcontains $Action) { Fail "Unknown action '$Action'. Use one of: $($known -join ', ')" }

Test-Toolchain
if ($Action -eq 'doctor') { Invoke-Flutter doctor -v; exit 0 }
Update-Code
Update-Dependencies

switch ($Action) {
  'windows' { Start-Windows }
  'android' { Start-Android }
  'emulator' { Start-Emulator }
  'install-apk' { Install-Apk }
  'build-windows' { Build-Windows }
  'build-apk' { Build-Apk }
  'all' { Build-Windows; Build-Apk }
  'test' { Invoke-Tests }
}
Ok 'Done.'
