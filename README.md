# LanBeam

Private, serverless file transfer between your phone and computer over the
local network — like AirDrop or LocalSend. Files go directly between devices
over an encrypted connection; nothing is uploaded anywhere and no Internet
connection is needed.

## Quick start (one click)

1. Install [Flutter](https://docs.flutter.dev/get-started/install) **3.47 or newer**.
   - Windows desktop app: Visual Studio 2022 with **Desktop development with C++**.
   - Android phone/emulator: Android Studio (then `flutter doctor --android-licenses`).
2. Get the code (or `git pull` to update).
3. Start the launcher:
   - **Windows:** double-click **`run.bat`**
   - **macOS / Linux:** run **`./run.sh`**

The launcher updates to the latest code, checks Flutter, cleans stale build
files when dependencies changed, downloads packages, and shows a menu:

| # | Windows menu | What it does |
|---|--------------|--------------|
| 1 | Run on this PC | Starts the desktop app |
| 2 | Run on my Android phone | Runs on a USB-connected phone (USB debugging on) |
| 3 | Run on Android emulator | Starts an emulator (creates one if possible) and runs there |
| 4 | Build Windows app | Installable app in `dist\LanBeam-windows\lanbeam.exe` |
| 5 | Build Android APK | `dist\LanBeam.apk`; installs it if a phone/emulator is running |
| 6 | Install APK on emulator | Starts the emulator, builds the APK and installs it |
| 7 | Build both | Windows app + APK |
| 8 | Run tests | Automated protocol and transfer tests |
| 9 | Check my setup | `flutter doctor -v` |

You can skip the menu: `run.bat emulator`, `run.bat install-apk`,
`run.bat build-windows`, … (`./run.sh emulator`, `./run.sh build`, … on macOS/Linux).
Add `-NoUpdate` (or `NO_UPDATE=1 ./run.sh`) to skip `git pull`.

**VS Code:** *Terminal → Run Task…* lists the same actions ("LanBeam: …"),
and **F5** runs the app on the device selected in the status bar.

### Android emulator

* Create one once in Android Studio: **More Actions → Virtual Device Manager →
  Create device** → pick a phone → download a system image → Finish.
* Then use menu **3** (run with hot reload) or **6** (install the release APK).
* You can also drag `dist\LanBeam.apk` onto a running emulator window to install it.
* Pairing the emulator with the PC on the same machine: the emulator sits behind
  its own NAT, so discovery and QR scanning don't work there. Instead, on the
  emulator tap **Connect by IP**, enter `10.0.2.2:45872` (the emulator's alias
  for your PC) and type the PIN the PC shows. Sending from the emulator to the
  PC then works; sending from the PC *into* the emulator is blocked by the
  emulator's NAT, so test that direction with a real phone.
* Real phones on your Wi-Fi don't need any of this.

### First use

1. Open LanBeam on both devices (same Wi-Fi).
2. On the computer click **Pair device**; on the phone tap **Scan QR code** and
   approve on the computer. (Or pair a device from *Nearby devices* with a PIN,
   or use **Connect by IP**.)
3. Send files or folders — or drag them onto the desktop window.

If Windows Firewall asks, allow LanBeam on **Private networks**.

## Documentation

* [Architecture](docs/ARCHITECTURE.md) — design, components, decisions, milestones
* [Protocol](docs/PROTOCOL.md) — discovery, pairing, authentication, transfer API

## Project layout

```
lib/core/       pure-Dart engine: protocol, security, transfer, discovery, storage
lib/platform/   platform adapters (Android SAF bridge, notifications, Bonjour, …)
lib/features/   UI screens
android/ ios/ macos/ windows/ linux/   platform runners and permissions
test/core/      unit + loopback end-to-end tests
tool/           headless CLI peer (tool/lanbeam_cli.dart) and benchmark
scripts/        launcher implementation (run.bat → scripts/lanbeam.ps1)
```
