#!/bin/bash
set -e

# =============================================================================
# Happy — TestFlight Deployment Script
# Builds and uploads to TestFlight using local Xcode signing
# Requires: Apple Distribution certificate in Keychain
# =============================================================================

# Load environment variables from shell profile
if [ -f "$HOME/.zshrc" ]; then
    eval "$(grep '^export ' "$HOME/.zshrc" 2>/dev/null)" || true
fi

export PATH="/opt/homebrew/opt/node@22/bin:/opt/homebrew/bin:$PATH"
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
export APP_ENV=production

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# NOTE: workspace/scheme names are derived from app name after expo prebuild.
# Production app name is "Happy" → workspace is Happy.xcworkspace, scheme is Happy.
# If this is wrong after first prebuild, update these two values.
SCHEME="Happy"
WORKSPACE="$PROJECT_DIR/ios/Happy.xcworkspace"
EXPORT_OPTIONS="$PROJECT_DIR/ios/ExportOptions.plist"
BUILD_DIR="$PROJECT_DIR/ios/build"
ARCHIVE_PATH="$BUILD_DIR/Happy.xcarchive"
IPA_DIR="$BUILD_DIR/ipa"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; }
warn()  { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARNING:${NC} $1"; }
error() { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $1"; exit 1; }

log "Starting Happy TestFlight deployment (bundle: com.alannascott.happy)..."

# Keychain unlock (optional — only used if .keychain-password exists)
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
KEYCHAIN_PASSWORD_FILE="$PROJECT_DIR/.keychain-password"
if [ -f "$KEYCHAIN_PASSWORD_FILE" ]; then
    log "Unlocking keychain..."
    security unlock-keychain -p "$(cat "$KEYCHAIN_PASSWORD_FILE")" "$LOGIN_KEYCHAIN"
    security set-keychain-settings -t 3600 -l "$LOGIN_KEYCHAIN"
    log "✓ Keychain unlocked"
fi

# Step 1: Install JS dependencies
log "Step 1/5: Installing dependencies..."
cd "$PROJECT_DIR"
npm install --legacy-peer-deps --silent

# Step 2: Expo prebuild (regenerates ios/ from app.config.js)
log "Step 2/5: Running Expo prebuild (APP_ENV=production)..."

# Back up ExportOptions.plist — expo prebuild wipes ios/ entirely
EXPORT_OPTIONS_BACKUP=""
if [ -f "$EXPORT_OPTIONS" ]; then
    EXPORT_OPTIONS_BACKUP=$(mktemp)
    cp "$EXPORT_OPTIONS" "$EXPORT_OPTIONS_BACKUP"
fi

APP_ENV=production npx expo prebuild --clean --platform ios --no-install

# Restore ExportOptions.plist
if [ -n "$EXPORT_OPTIONS_BACKUP" ]; then
    cp "$EXPORT_OPTIONS_BACKUP" "$EXPORT_OPTIONS"
    rm "$EXPORT_OPTIONS_BACKUP"
fi

if [ ! -f "$EXPORT_OPTIONS" ]; then
    error "ExportOptions.plist missing after prebuild"
fi

log "✓ Expo prebuild complete"

# Step 3: CocoaPods (generates .xcworkspace)
log "Step 3/5: Installing CocoaPods..."
cd "$PROJECT_DIR/ios"
pod install --silent
log "✓ CocoaPods installed"

# Verify the workspace was generated with expected name (after pod install)
if [ ! -d "$WORKSPACE" ]; then
    ACTUAL_WS=$(ls "$PROJECT_DIR/ios/"*.xcworkspace 2>/dev/null | head -1)
    if [ -n "$ACTUAL_WS" ]; then
        warn "Expected workspace at $WORKSPACE but found $ACTUAL_WS"
        WORKSPACE="$ACTUAL_WS"
        SCHEME=$(basename "$ACTUAL_WS" .xcworkspace)
        warn "Auto-detected: SCHEME=$SCHEME WORKSPACE=$WORKSPACE"
    else
        error "No .xcworkspace found after pod install"
    fi
fi

# Step 4: Archive
log "Step 4/5: Building archive (this takes a few minutes)..."
mkdir -p "$BUILD_DIR"
cd "$PROJECT_DIR"

xcodebuild archive \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=iOS" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="TC86U5ZRJT" \
    -quiet 2>&1 | grep -E "(error:|warning:|\*\*)" || true

if [ ! -d "$ARCHIVE_PATH" ]; then
    error "Archive failed — re-run without -quiet for details"
fi
log "✓ Archive complete: $ARCHIVE_PATH"

# Step 5: Export and upload to TestFlight
log "Step 5/5: Exporting and uploading to TestFlight..."
rm -rf "$IPA_DIR"
mkdir -p "$IPA_DIR"

# App Store Connect API key (same as Bandcramp — tied to Apple Developer account)
ASC_KEY_ID="UF6Z5FCQTP"
ASC_ISSUER_ID="5ebdffdb-b01e-40a0-ba15-63eefce0166c"
ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"

EXPORT_ARGS=(
    -archivePath "$ARCHIVE_PATH"
    -exportPath "$IPA_DIR"
    -exportOptionsPlist "$EXPORT_OPTIONS"
    -allowProvisioningUpdates
)

if [ -f "$ASC_KEY_PATH" ]; then
    log "Using App Store Connect API key for upload auth"
    EXPORT_ARGS+=(
        -authenticationKeyPath "$ASC_KEY_PATH"
        -authenticationKeyID "$ASC_KEY_ID"
        -authenticationKeyIssuerID "$ASC_ISSUER_ID"
    )
else
    warn "No ASC API key at $ASC_KEY_PATH — falling back to Xcode account credentials"
fi

EXPORT_OUTPUT=$(xcodebuild -exportArchive "${EXPORT_ARGS[@]}" 2>&1)
echo "$EXPORT_OUTPUT" | grep -E "(error:|warning:|Upload|EXPORT)" || true

if echo "$EXPORT_OUTPUT" | grep -qE "EXPORT SUCCEEDED|exportArchive succeeded"; then
    log "========================================="
    log "SUCCESS! Happy uploaded to TestFlight"
    log "========================================="
    log "Check App Store Connect for processing status."
else
    echo "$EXPORT_OUTPUT" | tail -30
    error "Export/upload failed — check output above"
fi
