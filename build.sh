#!/bin/bash
set -e

# ============================================================
# Audium Build Script
# ============================================================
# Unlike MXFixer/QCheck, this target depends on an SPM package (WhisperKit),
# so plain `swiftc <files>` can't resolve/compile it. `swift build` (part of
# the Swift toolchain, not Xcode) does dependency resolution + compilation;
# everything after that — bundling, signing, DMG — follows the same pattern
# as the other apps.

APP_NAME="Audium"
BUNDLE_ID="com.postproduction.Audium"
VERSION="0.1"
MIN_MACOS="14.0"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"
BIN_DIR="$RES_DIR/bin"

sign_item() {
    xattr -cr "$1" 2>/dev/null || true
    codesign --force --sign "$SIGN_IDENTITY" "$1"
}

echo ""
echo "╔════════════════════════════════════╗"
echo "║        Audium Build Script          ║"
echo "╚════════════════════════════════════╝"
echo ""

# ── 1. Clean ────────────────────────────────────────────────
echo "▶ Cleaning build directory…"
rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR" "$BIN_DIR"

# ── 2. Build via SwiftPM (resolves WhisperKit) ──────────────
echo "▶ Building via swift build (release)…"
swift build -c release --package-path "$SCRIPT_DIR"
BIN_PATH="$(swift build -c release --package-path "$SCRIPT_DIR" --show-bin-path)/$APP_NAME"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
echo "   ✅ Build done"

# ── 3. Bundle yt-dlp (YouTube URL transcription, spec §2) ───
echo "▶ Bundling yt-dlp…"
YTDLP_SRC="$SCRIPT_DIR/Resources/bin/yt-dlp"
if [ -f "$YTDLP_SRC" ]; then
    cp "$YTDLP_SRC" "$BIN_DIR/yt-dlp"
    chmod +x "$BIN_DIR/yt-dlp"
    echo "   ✅ yt-dlp bundled"
else
    echo "   ⚠️  yt-dlp not found in Resources/bin/"
fi

# ── 3b. Bundle ffmpeg (yt-dlp's audio-extraction dependency) ─
# Same evermeet.cx-sourced static binary QCheck already bundles, same steps
# (see QCheck/README.md for the source/update process) — x86_64-only (evermeet.cx
# doesn't build arm64), runs on Apple Silicon via Rosetta 2.
echo "▶ Bundling ffmpeg…"
FFMPEG_SRC="$SCRIPT_DIR/Resources/bin/ffmpeg"
if [ -f "$FFMPEG_SRC" ]; then
    cp "$FFMPEG_SRC" "$BIN_DIR/ffmpeg"
    chmod +x "$BIN_DIR/ffmpeg"
    echo "   ✅ ffmpeg bundled"
else
    echo "   ⚠️  ffmpeg not found in Resources/bin/"
fi

# ── 3c. Bundle Skills (AI Chat role presets, spec §8) ────────
echo "▶ Bundling Skills…"
SKILLS_SRC="$SCRIPT_DIR/Skills"
if [ -d "$SKILLS_SRC" ]; then
    cp -R "$SKILLS_SRC" "$RES_DIR/Skills"
    echo "   ✅ Skills bundled"
else
    echo "   ⚠️  Skills/ not found at repo root"
fi

# ── 4. Bundle app icon ───────────────────────────────────────
echo "▶ Bundling app icon…"
ICON_SRC="$SCRIPT_DIR/Resources/AppIcon.png"
if [ -f "$ICON_SRC" ]; then
    ICONSET="$BUILD_DIR/AppIcon.iconset"
    mkdir -p "$ICONSET"
    sips -z 16 16     "$ICON_SRC" --out "$ICONSET/icon_16x16.png"      2>/dev/null
    sips -z 32 32     "$ICON_SRC" --out "$ICONSET/icon_16x16@2x.png"   2>/dev/null
    sips -z 32 32     "$ICON_SRC" --out "$ICONSET/icon_32x32.png"       2>/dev/null
    sips -z 64 64     "$ICON_SRC" --out "$ICONSET/icon_32x32@2x.png"    2>/dev/null
    sips -z 128 128   "$ICON_SRC" --out "$ICONSET/icon_128x128.png"     2>/dev/null
    sips -z 256 256   "$ICON_SRC" --out "$ICONSET/icon_128x128@2x.png"  2>/dev/null
    sips -z 256 256   "$ICON_SRC" --out "$ICONSET/icon_256x256.png"     2>/dev/null
    sips -z 512 512   "$ICON_SRC" --out "$ICONSET/icon_256x256@2x.png"  2>/dev/null
    sips -z 512 512   "$ICON_SRC" --out "$ICONSET/icon_512x512.png"     2>/dev/null
    sips -z 1024 1024 "$ICON_SRC" --out "$ICONSET/icon_512x512@2x.png"  2>/dev/null
    iconutil -c icns "$ICONSET" -o "$RES_DIR/AppIcon.icns" 2>/dev/null
    echo "   ✅ App icon bundled"
else
    echo "   ⚠️  No AppIcon.png found in Resources/ (placeholder — add before shipping)"
fi

# ── 5. Write Info.plist ──────────────────────────────────────
echo "▶ Writing Info.plist…"
cat > "$CONTENTS/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_MACOS</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
</dict>
</plist>
EOF
echo "   ✅ Info.plist written"

# ── 6. Code sign ─────────────────────────────────────────────
# IMPORTANT — read before changing this back to ad-hoc (`--sign -`):
# Pure ad-hoc signing gives every rebuild a *different* cdhash, because the
# signature is derived from the binary's own content hash with no stable
# identity behind it. That's fine for Gatekeeper (not notarized either way,
# same as MXFixer/QCheck), but it breaks KeychainStore's dedicated-keychain
# fix: the self-only SecAccess ACL on the saved API-key item is bound to one
# specific code identity (cdhash), so *any* rebuild — even of the exact same
# source — invalidates it and macOS falls back to an interactive SecurityAgent
# "Allow" prompt, i.e. the same class of bug the dedicated keychain was
# supposed to eliminate. Confirmed directly via securityd logs (repeated
# "user did not approve 'allow'" ACL rejections across rebuilds) — this
# wasn't a hypothesis.
#
# Fix: sign with a stable local self-signed "Audium Local Dev" codesigning
# identity instead, so the cdhash — and thus the ACL trust — survives
# rebuilds. Ad-hoc is kept below as an automatic fallback only, in case that
# identity is ever missing (e.g. a fresh dev machine). If it's missing and
# you want it back, recreate it with:
#   openssl req -x509 -newkey rsa:2048 -keyout audium.key -out audium.crt \
#     -days 3650 -nodes -subj "/CN=Audium Local Dev" \
#     -addext "keyUsage=critical,digitalSignature" \
#     -addext "extendedKeyUsage=critical,codeSigning"
#   openssl pkcs12 -export -legacy -out audium.p12 \
#     -inkey audium.key -in audium.crt -passout pass:x
#     (the -legacy flag matters: OpenSSL 3.x's default PKCS12 cipher fails
#     "MAC verification failed" against macOS's older `security import` parser)
#   security create-keychain -p "$(swift Scripts/derive-signing-password.swift "$SIGNING_SALT_PATH")" \
#     ~/Library/Keychains/AudiumSigning.keychain-db
#     (NOT a hand-chosen password — see the derivedPassword() note below. A hand-chosen
#     password that's never written down is exactly how this keychain's password got lost
#     the first time; see spec.md §5 "AudiumSigning password-loss" for the postmortem.)
#   security import audium.p12 -k ~/Library/Keychains/AudiumSigning.keychain-db \
#     -P x -T /usr/bin/codesign
#   security find-certificate -c "Audium Local Dev" -p \
#     ~/Library/Keychains/AudiumSigning.keychain-db > audium-pub.pem
#   security add-trusted-cert -p codeSign \
#     -k ~/Library/Keychains/AudiumSigning.keychain-db audium-pub.pem
#     (self-signed certs aren't trusted for *any* policy until this step —
#     without it, `security find-identity -v -p codesigning` reports 0 valid
#     identities even though the import itself succeeded. This step needs a live human:
#     macOS gates Certificate Trust Settings changes behind Authorization Services —
#     your actual account password/Touch ID, once, at creation time — no keychain
#     password or script can bypass that, by design. One-time cost; every build after
#     this doesn't need it again.)
#   security list-keychains -d user -s $(security list-keychains -d user | \
#     sed 's/"//g') ~/Library/Keychains/AudiumSigning.keychain-db
#
# The keychain's own unlock password is never hand-chosen or written down (that's what
# got the previous one lost — see spec.md). Same fix as KeychainStore.swift already uses
# for Audium.keychain-db: HKDF-SHA256(pepper=fixed public app-id string, salt=32 random
# bytes, info="Audium.signing-keychain") via Scripts/derive-signing-password.swift,
# re-computed fresh every build rather than stored anywhere as a password. The one
# ingredient that persists is the salt (not a secret by itself — see that script's
# comments) at $SIGNING_SALT_PATH, generated once on first use.
SIGNING_SALT_PATH="$HOME/Library/Application Support/Audium/signing-salt.b64"
SIGNING_KEYCHAIN="$HOME/Library/Keychains/AudiumSigning.keychain-db"

SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 '"Audium' | sed -E 's/.*"(.*)"/\1/')"
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="-"
    echo "▶ Code signing (ad-hoc — no stable \"Audium Local Dev\" identity found)…"
else
    echo "▶ Code signing (stable identity: $SIGN_IDENTITY)…"
    if [ -f "$SIGNING_KEYCHAIN" ]; then
        # Unlock + authorize codesign/security to use the key without a per-build GUI
        # prompt. Password lives only in this variable for the few lines below.
        SIGNING_PW="$(swift Scripts/derive-signing-password.swift "$SIGNING_SALT_PATH")"
        security unlock-keychain -p "$SIGNING_PW" "$SIGNING_KEYCHAIN"
        security set-key-partition-list -S apple-tool:,apple: -s -k "$SIGNING_PW" "$SIGNING_KEYCHAIN" >/dev/null
        unset SIGNING_PW
    fi
fi
[ -f "$BIN_DIR/yt-dlp" ] && sign_item "$BIN_DIR/yt-dlp" && echo "   Signed: yt-dlp"
[ -f "$BIN_DIR/ffmpeg" ] && sign_item "$BIN_DIR/ffmpeg" && echo "   Signed: ffmpeg"
sign_item "$MACOS_DIR/$APP_NAME"
echo "   Signed: $APP_NAME binary"
xattr -cr "$APP_DIR" 2>/dev/null || true
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"
echo "   ✅ App bundle signed"

# ── 7. Package DMG ───────────────────────────────────────────
# ponytail: placeholder — no distributable to package yet, fill in once
# there's a real build worth shipping (staging dir + Applications symlink +
# hdiutil, same as MXFixer/QCheck's build.sh).
echo "▶ DMG packaging: skipped (placeholder, nothing to distribute yet)"

echo ""
echo "╔════════════════════════════════════╗"
echo "║            Build Complete           ║"
echo "╚════════════════════════════════════╝"
echo ""
echo "  App: $APP_DIR"
echo ""
echo "  Run: open \"$APP_DIR\""
echo ""
