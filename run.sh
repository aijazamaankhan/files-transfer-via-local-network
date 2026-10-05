#!/usr/bin/env bash
# LanBeam one-click launcher for macOS and Linux (Windows: use run.bat).
#
#   ./run.sh               interactive menu
#   ./run.sh desktop       update + run on this computer (macOS or Linux)
#   ./run.sh android       update + run on the USB-connected Android phone
#   ./run.sh ios           update + run on a connected iPhone / simulator (macOS)
#   ./run.sh build         build the desktop app into dist/
#   ./run.sh build-apk     build dist/LanBeam.apk (installs if a phone is connected)
#   ./run.sh test          run the automated tests
#   ./run.sh doctor        check the toolchain
# Set NO_UPDATE=1 to skip "git pull".
set -euo pipefail

MIN_FLUTTER="3.47.0"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

info() { printf '\033[36m==> %s\033[0m\n' "$*"; }
ok() { printf '\033[32m  OK  %s\033[0m\n' "$*"; }
warn() { printf '\033[33m  !!  %s\033[0m\n' "$*"; }
fail() { printf '\033[31m  XX  %s\033[0m\n' "$*"; exit 1; }

case "$(uname -s)" in
  Darwin) DESKTOP=macos ;;
  *) DESKTOP=linux ;;
esac

json_part() { sed -n '/^[[{]/,$p'; }

version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

check_toolchain() {
  info "Checking tools"
  command -v flutter >/dev/null || fail "Flutter not found. Install it from https://docs.flutter.dev/get-started/install"
  local v
  v="$(flutter --version --machine 2>/dev/null | json_part | grep '"frameworkVersion"' | sed -E 's/.*: "([0-9.]+).*/\1/')"
  [ -n "$v" ] || fail "Could not read the Flutter version."
  if ! version_ge "$v" "$MIN_FLUTTER"; then
    warn "Flutter $v is too old; LanBeam needs $MIN_FLUTTER or newer."
    read -r -p "  Upgrade Flutter now? (Y/n) " a
    if [[ -z "$a" || "$a" =~ ^[Yy] ]]; then flutter channel stable && flutter upgrade; else fail "Run 'flutter upgrade' and try again."; fi
  else
    ok "Flutter $v"
  fi
}

update_code() {
  if [ "${NO_UPDATE:-0}" = "1" ]; then warn "Skipping update (NO_UPDATE=1)."; return; fi
  if ! command -v git >/dev/null || [ ! -d .git ]; then warn "Not a git checkout; skipping update."; return; fi
  for junk in package-lock.json node_modules; do
    if [ -e "$junk" ] && [ -z "$(git ls-files "$junk")" ]; then rm -rf "$junk"; ok "Removed stray $junk (npm is not used)"; fi
  done
  info "Getting the latest version"
  if [ -n "$(git status --porcelain)" ]; then
    warn "You have local changes:"
    git status --short | head -n 15 | sed 's/^/      /'
    read -r -p "  Discard them and update to the latest version? (y/N) " a
    if [[ "$a" =~ ^[Yy] ]]; then git reset --hard HEAD >/dev/null; git clean -fd -e build -e .dart_tool >/dev/null; else warn "Keeping your changes; not updating."; return; fi
  fi
  if git pull --ff-only; then ok "At $(git log -1 --format='%h %s')"; else warn "Could not fast-forward; continuing with the current code."; fi
}

prepare_deps() {
  info "Preparing dependencies"
  local stamp=.dart_tool/lanbeam-launcher.stamp hash prev=""
  hash="$( (cat pubspec.lock pubspec.yaml) | shasum -a 256 2>/dev/null || (cat pubspec.lock pubspec.yaml) | sha256sum)"
  [ -f "$stamp" ] && prev="$(cat "$stamp")"
  if [ "$prev" != "$hash" ] && [ -d build ]; then
    warn "Dependencies changed since the last build; cleaning old build files."
    flutter clean
  fi
  flutter pub get
  mkdir -p .dart_tool && printf '%s' "$hash" > "$stamp"
  ok "Dependencies ready"
}

device_id() { # $1 = platform prefix (android / ios)
  flutter devices --machine 2>/dev/null | json_part | tr -d '\n ' |
    grep -o "\"id\":\"[^\"]*\",\"isSupported\":true,\"targetPlatform\":\"$1[^\"]*\"" |
    head -n1 | sed -E 's/"id":"([^"]*)".*/\1/'
}

phone_help() {
  warn "No Android phone found."
  echo "      1. 'flutter doctor' must show a green Android toolchain (install Android Studio)."
  echo "      2. Phone: Settings > About phone > tap 'Build number' 7 times."
  echo "      3. Phone: Developer options > USB debugging = On, plug in, tap 'Allow'."
}

build_apk() {
  info "Building the Android app (release APK)"
  flutter build apk --release
  mkdir -p dist && cp build/app/outputs/flutter-apk/app-release.apk dist/LanBeam.apk
  ok "Android app: dist/LanBeam.apk"
  local id; id="$(device_id android)"
  if [ -n "$id" ]; then info "Installing on $id"; flutter install -d "$id" --release; ok "Installed."; fi
}

build_desktop() {
  info "Building the $DESKTOP app (release)"
  flutter build "$DESKTOP" --release
  mkdir -p dist
  if [ "$DESKTOP" = macos ]; then
    rm -rf dist/LanBeam.app && cp -R build/macos/Build/Products/Release/lanbeam.app dist/LanBeam.app
    ok "macOS app: dist/LanBeam.app"
  else
    rm -rf dist/LanBeam-linux && cp -R build/linux/x64/release/bundle dist/LanBeam-linux
    ok "Linux app: dist/LanBeam-linux/lanbeam"
  fi
}

action="${1:-}"
if [ -z "$action" ]; then
  echo
  echo "  LanBeam"
  echo "  -------"
  echo "  1  Run on this computer ($DESKTOP)"
  echo "  2  Run on my Android phone (USB)"
  echo "  3  Run on iPhone / iOS simulator (macOS only)"
  echo "  4  Build the $DESKTOP app   -> dist/"
  echo "  5  Build Android APK        -> dist/LanBeam.apk"
  echo "  6  Run tests"
  echo "  7  Check my setup (flutter doctor)"
  read -r -p "  Choose 1-7 (Enter = 1) " c
  case "$c" in
    ""|1) action=desktop ;; 2) action=android ;; 3) action=ios ;; 4) action=build ;;
    5) action=build-apk ;; 6) action=test ;; 7) action=doctor ;; *) fail "Unknown choice '$c'." ;;
  esac
fi

check_toolchain
if [ "$action" = doctor ]; then flutter doctor -v; exit 0; fi
update_code
prepare_deps

case "$action" in
  desktop) info "Starting LanBeam on this computer"; flutter run -d "$DESKTOP" ;;
  android) id="$(device_id android)"; [ -n "$id" ] || { phone_help; exit 1; }; flutter run -d "$id" ;;
  ios) id="$(device_id ios)"; [ -n "$id" ] || fail "No iPhone or simulator found (open Simulator or connect an iPhone)."; flutter run -d "$id" ;;
  build) build_desktop ;;
  build-apk) build_apk ;;
  test) flutter test test/core ;;
  *) fail "Unknown action '$action'." ;;
esac
ok "Done."
