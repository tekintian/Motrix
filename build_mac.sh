#!/bin/bash
# build_mac.sh — Build and package Motrix as a macOS DMG for the current system
#
# Usage:
#   ./build_mac.sh              # auto-detect arch (arm64 or x64)
#   ./build_mac.sh --arch arm64 # force arm64
#   ./build_mac.sh --arch x64   # force x64 (Intel)
#   ./build_mac.sh --skip-sign  # skip codesign entirely
#   ./build_mac.sh --sign-identity "Developer ID Application: ..."  # use specific identity
#
# Prerequisites:
#   - Node.js 24+, pnpm 12.5.1+, Rust toolchain (for native-host & finalize-fs)
#   - macOS 13+ (Ventura)
#   - Xcode Command Line Tools (for codesign)
#
# Output:
#   release/mac-{arch}/Motrix.app
#   release/mac-{arch}/Motrix-{version}-{arch}.dmg
#   release/mac-{arch}/Motrix-{version}-{arch}.zip

set -euo pipefail

# ─── Color helpers ───────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
fail()  { echo -e "${RED}[FAIL]${RESET}  $*" >&2; exit 1; }
step()  { echo -e "\n${BOLD}━━━ $* ━━━${RESET}"; }

# ─── Resolve project root ────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}"
cd "${PROJECT_ROOT}"

# ─── Parse arguments ─────────────────────────────────────────────
ARCH=""
SKIP_SIGN=false
SIGN_IDENTITY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      ARCH="$2"
      shift 2
      ;;
    --skip-sign)
      SKIP_SIGN=true
      shift
      ;;
    --sign-identity)
      SIGN_IDENTITY="$2"
      shift 2
      ;;
    -h|--help)
      head -n 15 "$0" | tail -n 13
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

# ─── Detect platform & architecture ──────────────────────────────
if [[ "$(uname -s)" != "Darwin" ]]; then
  fail "This script must be run on macOS"
fi

if [[ -z "${ARCH}" ]]; then
  CPU_ARCH="$(uname -m)"
  case "${CPU_ARCH}" in
    arm64)  ARCH="arm64" ;;
    x86_64) ARCH="x64"   ;;
    *)      fail "Unsupported CPU architecture: ${CPU_ARCH}" ;;
  esac
fi

info "Target: darwin-${ARCH}"

# ─── Map arch to Rust target and Electron Builder arch ───────────
case "${ARCH}" in
  arm64)
    RUST_TARGET="aarch64-apple-darwin"
    EB_ARCH="arm64"
    ;;
  x64)
    RUST_TARGET="x86_64-apple-darwin"
    EB_ARCH="x64"
    ;;
  *)
    fail "Unsupported arch: ${ARCH} (use arm64 or x64)"
    ;;
esac

PLATFORM_DIR="mac-${EB_ARCH}"
APP_PATH="release/${PLATFORM_DIR}/Motrix.app"

# ─── Read version from package.json ──────────────────────────────
VERSION="$(node -e "console.log(require('./package.json').version)")"
info "Version: ${VERSION}"

# ─── Check prerequisites ─────────────────────────────────────────
step "Checking prerequisites"

command -v node >/dev/null 2>&1  || fail "node not found (need Node.js 24+)"
command -v pnpm >/dev/null 2>&1 || fail "pnpm not found (need pnpm 12.5.1+)"
command -v cargo >/dev/null 2>&1 || fail "cargo not found (need Rust toolchain)"
command -v codesign >/dev/null 2>&1 || fail "codesign not found (need Xcode CLT)"

NODE_MAJOR="$(node -e "console.log(process.versions.node.split('.')[0])")"
if [[ "${NODE_MAJOR}" -lt 20 ]]; then
  fail "Node.js ${NODE_MAJOR} is too old (need 20+)"
fi

MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [[ "${MACOS_MAJOR}" -lt 12 ]]; then
  fail "macOS $(sw_vers -productVersion) is below the minimum (12.0 Monterey). \
Electron 43 requires macOS 12+. Upgrade macOS to continue."
fi

ok "Node.js $(node --version), pnpm $(pnpm --version), Rust $(rustc --version | awk '{print $2}')"

# ─── Install dependencies ────────────────────────────────────────
step "Installing dependencies"

if [[ ! -d "node_modules" ]]; then
  info "Running pnpm install..."
  pnpm install --frozen-lockfile
else
  info "node_modules exists, skipping install"
fi

# ─── Step 1: Fetch builtins ──────────────────────────────────────
step "Fetching builtins (plugin seeds)"

pnpm run build:builtin
ok "Builtins fetched"

# ─── Step 2: Build Rust native-host ──────────────────────────────
step "Building native-host (Rust → ${RUST_TARGET})"

pnpm run build:native-host -- --platform darwin --arch "${ARCH}"
ok "native-host built for darwin-${ARCH}"

# ─── Step 3: Build Rust finalize-fs ──────────────────────────────
step "Building finalize-fs (Rust → ${RUST_TARGET})"

pnpm run build:finalize-fs -- --platform darwin --arch "${ARCH}"
ok "finalize-fs built for darwin-${ARCH}"

# ─── Step 4: Build Electron app (Vite) ───────────────────────────
step "Building Electron app (Vite)"

pnpm run build:electron

ok "Electron app built"

# ─── Step 5: Stage Electron app ──────────────────────────────────
step "Staging Electron app"

pnpm run stage:electron -- --platform darwin --arch "${EB_ARCH}"
ok "Electron app staged"

# ─── Step 6: Package with electron-builder ───────────────────────
step "Packaging with electron-builder (darwin-${EB_ARCH})"

CSC_IDENTITY_AUTO_DISCOVERY=false \
  pnpm exec electron-builder \
    --mac \
    --"${EB_ARCH}" \
    --config electron-builder.json \
    --publish never

ok "electron-builder package created"

# ─── Step 7: Codesign ────────────────────────────────────────────
step "Codesigning"

if [[ "${SKIP_SIGN}" == "true" ]]; then
  warn "Skipping codesign (--skip-sign)"
elif [[ -d "${APP_PATH}" ]]; then
  NATIVE_HOST="${APP_PATH}/Contents/Resources/bin/motrix-native-host"
  FINALIZE_FS="${APP_PATH}/Contents/Resources/bin/motrix-finalize-fs"

  if [[ -n "${SIGN_IDENTITY}" ]]; then
    SIGN_ARGS=(--force --sign "${SIGN_IDENTITY}" --options runtime --entitlements build/entitlements.mac.plist)
    info "Signing with identity: ${SIGN_IDENTITY}"
  else
    SIGN_ARGS=(--force --sign -)
    info "Ad-hoc signing (no Developer ID certificate)"
  fi

  info "Step 1: Deep-sign the app bundle (frameworks + helpers)"
  codesign "${SIGN_ARGS[@]}" --deep "${APP_PATH}"

  info "Step 2: Explicitly sign nested Mach-O executables in Resources/bin/"
  for bin in "${NATIVE_HOST}" "${FINALIZE_FS}"; do
    if [[ -f "$bin" ]]; then
      codesign "${SIGN_ARGS[@]}" "$bin"
    else
      warn "$bin not found, skipping"
    fi
  done

  info "Step 3: Re-sign the outer bundle (without --deep) to fix the resource seal"
  codesign "${SIGN_ARGS[@]}" "${APP_PATH}"

  ok "Codesigned"
else
  warn "App bundle not found at ${APP_PATH}, skipping codesign"
fi

# ─── Step 8: Verify signatures ───────────────────────────────────
step "Verifying signatures"

if [[ -d "${APP_PATH}" ]]; then
  if [[ "${SKIP_SIGN}" == "true" ]]; then
    warn "Skipping signature verification (--skip-sign)"
  else
    codesign --verify --deep --verbose=2 "${APP_PATH}" && ok "App signature valid" || warn "App signature verification failed (may be ad-hoc)"

    NATIVE_HOST="${APP_PATH}/Contents/Resources/bin/motrix-native-host"
    FINALIZE_FS="${APP_PATH}/Contents/Resources/bin/motrix-finalize-fs"
    for bin in "${NATIVE_HOST}" "${FINALIZE_FS}"; do
      if [[ -f "$bin" ]]; then
        codesign --verify --verbose=2 "$bin" && ok "$(basename "$bin") signature valid" || warn "$(basename "$bin") signature verification failed"
      fi
    done
  fi
else
  warn "App bundle not found, skipping verification"
fi

# ─── Step 9: Summary ─────────────────────────────────────────────
step "Build complete"

echo ""
info "Platform:     darwin-${ARCH}"
info "Version:      ${VERSION}"
info "App:          ${APP_PATH}"
echo ""

if [[ -d "${APP_PATH}" ]]; then
  APP_SIZE="$(du -sh "${APP_PATH}" 2>/dev/null | awk '{print $1}')"
  info "App size:     ${APP_SIZE:-unknown}"
fi

DMG_FILE="release/${PLATFORM_DIR}/Motrix-${VERSION}-${EB_ARCH}.dmg"
ZIP_FILE="release/${PLATFORM_DIR}/Motrix-${VERSION}-${EB_ARCH}.zip"

if [[ -f "${DMG_FILE}" ]]; then
  DMG_SIZE="$(du -sh "${DMG_FILE}" 2>/dev/null | awk '{print $1}')"
  ok "DMG: ${DMG_FILE} (${DMG_SIZE:-unknown})"
else
  warn "DMG not found at ${DMG_FILE}"
fi

if [[ -f "${ZIP_FILE}" ]]; then
  ZIP_SIZE="$(du -sh "${ZIP_FILE}" 2>/dev/null | awk '{print $1}')"
  ok "ZIP: ${ZIP_FILE} (${ZIP_SIZE:-unknown})"
else
  warn "ZIP not found at ${ZIP_FILE}"
fi

echo ""
ok "Done! 🎉"