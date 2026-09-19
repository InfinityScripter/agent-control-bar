#!/bin/bash
# Builds the menu bar app (and optionally a .dmg with: ./build.sh --dmg).
set -euo pipefail
cd "$(dirname "$0")"
# Identity lives in one file so a rename can never half-apply (see identity.env).
# ./ and not "$(dirname "$0")" again: the cd above already happened, and applying a relative
# dirname twice resolved to <repo>/<repo>/identity.env when invoked from the parent directory.
# shellcheck source=identity.env
. ./identity.env

# Version has exactly one source: the plugin manifest. It used to be typed into the Info.plist
# heredoc as well, which is how a build ships announcing a version nobody released.
VERSION=$(/usr/bin/python3 -c "import json;print(json.load(open('.claude-plugin/plugin.json'))['version'])")

APP="${CONTROL_BAR_APP:-build/$APP_NAME.app}"

# Everything is built and signed in a staging bundle, and the installed app is replaced only
# once the new one is complete. The old order — rm -rf first, compile after — meant a failed
# compile (half-installed CLT, full disk, an SDK quirk) destroyed the user's last working copy
# and left nothing but a log; the plugin channel runs this unattended on session start, where
# that is the difference between "update failed" and "app gone".
#
# The staging bundle lives in a private temp directory, not beside the target. It used to be
# "$APP.staging.$$" — a plain folder next to the installed app for the minute the compile
# takes. The Dock keeps a live model of any folder whose stack has been opened even once, and
# in that model the staging folder stayed a folder after the rename: clicking the freshly
# updated app in the Applications stack browsed into "Contents" instead of launching it.
# Nothing is built inside the target directory any more; what arrives there is a finished
# bundle under its final name. The rename stays atomic because the temp directory sits on the
# same volume as /Applications and ~/Applications on a stock install; any other layout gets
# mv's copy, which is no worse than what a DMG drag does.
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/$CASK_TOKEN-build.XXXXXX")"
STAGE_APP="$STAGE_DIR/$APP_NAME.app"
BIN="$STAGE_APP/Contents/MacOS/$EXEC"
trap 'rm -rf "$STAGE_DIR"' EXIT

mkdir -p "$STAGE_APP/Contents/MacOS"

echo "Compiling universal binary (arm64 + x86_64)…"
# Universal binary so it runs natively on both Apple Silicon and Intel (each Mac uses its own
# slice, so Rosetta is never involved). swiftc emits one arch per -target, so this is two
# compiles joined by lipo. Keep the deployment target pinned, else swiftc stamps the binary
# with the build machine's OS and it refuses to launch on older systems despite LSMinimumSystemVersion.
# Sources/Model/ is the UI-free half (parsers, state machines, frame data) that CI also compiles
# on its own against tests/model/main.swift; Sources/ proper is the app.
swiftc -O -target arm64-apple-macos13.0  Sources/*.swift Sources/Model/*.swift -o "$BIN.arm64"  -framework Cocoa -framework SwiftUI
swiftc -O -target x86_64-apple-macos13.0 Sources/*.swift Sources/Model/*.swift -o "$BIN.x86_64" -framework Cocoa -framework SwiftUI
lipo -create "$BIN.arm64" "$BIN.x86_64" -output "$BIN"
rm -f "$BIN.arm64" "$BIN.x86_64"

cat > "$STAGE_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$EXEC</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSAppleEventsUsageDescription</key><string>$APP_NAME focuses the terminal window and tab a session runs in when you click it in the panel. It is used for nothing else, and only while "Exact terminal focus" is switched on.</string>
</dict>
</plist>
PLIST

# Bundle the hook scripts (so first-launch self-install works) and the app icon.
mkdir -p "$STAGE_APP/Contents/Resources"
cp hooks/update.js hooks/lifecycle.js hooks/install.js hooks/uninstall.js hooks/statusline.sh hooks/statusline.py "$STAGE_APP/Contents/Resources/"
# The MCP half runs out of the bundle in the brew/DMG channel — the plugin directory that
# normally holds it does not exist there.
mkdir -p "$STAGE_APP/Contents/Resources/scripts"
cp scripts/mcpbar.py "$STAGE_APP/Contents/Resources/scripts/"
cp assets/AppIcon.icns "$STAGE_APP/Contents/Resources/AppIcon.icns"
cp CHANGELOG.md "$STAGE_APP/Contents/Resources/CHANGELOG.md"  # the menu's "What's new" reads it
cp assets/completion.mp3 "$STAGE_APP/Contents/Resources/completion.mp3"
# The pets the app ships with, in the same folder shape Codex uses for the ones a user installs
# (pet.json beside its atlas), so one reader serves both sources.
cp -R assets/pets "$STAGE_APP/Contents/Resources/pets"

# --- Signing / notarization ---
# For a clean (no Gatekeeper warning) release you need, set up once on this Mac:
#   1. A "Developer ID Application" certificate in your keychain (Xcode > Settings > Accounts).
#   2. A notarytool credential profile named the same as NOTARY_PROFILE below — the name in
#      this line used to be upstream's, so anyone following it stored a profile this script
#      then failed to find, and the build fell through to an unnotarized DMG:
#        xcrun notarytool store-credentials "claude-control-bar" \
#          --apple-id you@example.com --team-id <YOUR TEAM ID> --password <app-specific-password>
# Then `./build.sh --dmg` auto-signs + notarizes. Without a cert it falls back to an
# ad-hoc dev build (runnable locally; users would need right-click > Open once).
# Was hardcoded to upstream's Apple Team ID, which is nobody's cert here: the grep never
# matched, the script fell through to ad-hoc signing AND skipped notarization entirely, and
# said so only in a line nobody reads. Unset now means "any Developer ID in the keychain",
# and REQUIRE_NOTARIZE=1 makes a release build fail loudly instead of shipping unnotarized.
TEAM_ID="${APPLE_TEAM_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-claude-control-bar}"

# `|| true` so a missing Developer ID cert (grep matches nothing → nonzero, which `set -eo pipefail`
# would otherwise treat as a fatal error) falls through to the ad-hoc dev build below instead of
# aborting the whole script.
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | grep "$TEAM_ID" | head -1 | sed -E 's/.*"(.*)"/\1/')" || true
if [[ -z "$SIGN_ID" && "${REQUIRE_NOTARIZE:-}" == "1" ]]; then
  echo "REQUIRE_NOTARIZE=1 but no Developer ID Application certificate found." >&2
  exit 1
fi

# Strip extended attributes (Finder info, quarantine, etc.) that bundled resources can
# carry — codesign rejects them ("resource fork, Finder information, ... not allowed").
xattr -cr "$STAGE_APP"

# Signed into BOTH paths. The entitlement is what lets "Exact terminal focus" reach the macOS
# Automation prompt at all under the hardened runtime (see app.entitlements) — and a local dev
# build that silently could not do the one thing being worked on is how that gets debugged for an
# afternoon in the wrong place.
ENTITLEMENTS="app.entitlements"
test -f "$ENTITLEMENTS"
if [[ -n "$SIGN_ID" ]]; then
  echo "Signing with Developer ID: $SIGN_ID"
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$STAGE_APP"
else
  echo "No Developer ID certificate found — ad-hoc signing. The result is NOT notarized:"
  echo "  macOS will block the first launch. See README, section \"Gatekeeper\"."
  # || warns instead of swallowing: macOS kills an unsigned arm64 binary at launch, so a
  # silently failed ad-hoc codesign shipped a complete-looking .app that never starts.
  codesign --force --entitlements "$ENTITLEMENTS" --sign - "$STAGE_APP" >/dev/null 2>&1 \
    || echo "WARNING: ad-hoc codesign failed — Apple Silicon Macs will refuse to launch this build" >&2
fi
# The swap happens only past this line: binary present and executable, plist well-formed.
test -x "$BIN"
/usr/bin/plutil -lint "$STAGE_APP/Contents/Info.plist" >/dev/null
# The outgoing bundle is deleted, not kept as "$APP.previous". That rollback copy sat next to
# the app after every update — a folder in Finder and in the Dock's Applications stack — and
# nothing in the code ever read it; users just trashed it by hand. Leftovers of older builds
# go with it.
rm -rf "$APP" "$APP.previous"
# build/ is gitignored, so on a fresh checkout — the Release workflow's DMG job — the default
# destination's parent does not exist and mv fails after a full compile. The CI check job never
# saw it: it points CONTROL_BAR_APP at RUNNER_TEMP, which exists.
mkdir -p "$(dirname "$APP")"
mv "$STAGE_APP" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--dmg" ]]; then
  # Notarize + staple the APP first, so a copied-out .app is independently notarized.
  # The DMG itself is notarized + stapled later (below) — that's the check a downloader
  # actually hits, so the image must carry its own ticket to open without a warning.
  if [[ "${SKIP_NOTARIZE:-}" != "1" && -n "$SIGN_ID" ]]; then
    echo "Notarizing the app via profile '$NOTARY_PROFILE' (can take a minute)…"
    rm -f build/app-notarize.zip
    ditto -c -k --keepParent "$APP" build/app-notarize.zip
    xcrun notarytool submit build/app-notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f build/app-notarize.zip
    echo "App notarized + stapled."
  fi

  echo "Packaging DMG…"
  DMG="build/$CASK_TOKEN.dmg"
  STAGE="build/dmg-stage"
  rm -rf "$STAGE" "$DMG" build/rw.dmg
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"

  # Eject any stale "$APP_NAME" volumes from earlier builds first. Otherwise a name
  # collision mounts this one as "$APP_NAME 2", the hardcoded /Volumes path below points
  # at the wrong volume (layout capture silently fails), and the stale mounts pile up in Finder.
  for d in $(hdiutil info | awk -v name="$APP_NAME" 'index($0, name) {print $1}'); do hdiutil detach "$d" >/dev/null 2>&1 || true; done

  # Lay out the window on a read-write image to capture its .DS_Store, then build the final
  # image from the folder (see below).
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDRW build/rw.dmg >/dev/null
  device="$(hdiutil attach -readwrite -noverify -noautoopen build/rw.dmg | grep -E '^/dev/' | head -1 | awk '{print $1}')"
  sleep 1
  # Passed as an argument, not interpolated: this heredoc is quoted (AppleScript is full of $
  # and backticks), so a shell variable written inside it would reach Finder as the literal
  # text "$APP_NAME" and the layout step would silently do nothing.
  osascript - "$APP_NAME" <<'OSA' || echo "(Finder layout skipped — DMG still has the app + Applications shortcut)"
on run argv
set volName to item 1 of argv
tell application "Finder"
  tell disk volName
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {400, 200, 880, 540}
    set vo to the icon view options of container window
    set arrangement of vo to not arranged
    set icon size of vo to 100
    set text size of vo to 12
    set position of item (volName & ".app") of container window to {130, 150}
    set position of item "Applications" of container window to {350, 150}
    update without registering applications
    delay 1
    close
  end tell
end tell
end run
OSA
  # Capture the layout Finder just wrote (.DS_Store), then discard the writable image and build
  # the final compressed image straight from the folder. Building from a folder never mounts a
  # writable volume, so macOS's fseventsd never creates a hidden .fseventsd in the shipped DMG.
  # (Removing .fseventsd from a mounted volume does not stick: the removal is itself an event
  # fseventsd logs, which recreates the folder.)
  cp "/Volumes/$APP_NAME/.DS_Store" "$STAGE/.DS_Store" 2>/dev/null || true
  hdiutil detach "$device" >/dev/null || true
  rm -f build/rw.dmg
  # Scrub any hidden folder that may have accrued (.fseventsd, .Trashes, .Spotlight-V100, …),
  # keeping only the intentional .DS_Store that carries the window layout.
  find "$STAGE" -maxdepth 1 -name ".*" ! -name ".DS_Store" -exec rm -rf {} + 2>/dev/null || true
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"

  # Guard: the shipped image must hold nothing but the app, the Applications symlink, and the
  # .DS_Store layout file. Mount read-only and abort before notarizing if any stray hidden entry
  # slipped in (the recurring .fseventsd/.Trashes problem).
  # Mount point taken from hdiutil's own answer, not assembled from the volume name: a leftover
  # mount of the same name (a failed detach on the previous run) makes macOS mount this one as
  # "…  1", and the guard would then inspect the OLD image and pass an image it never looked at.
  # The line taken is the last one that actually NAMES a mount point, not simply the last
  # /dev/ line: an APFS-formatted image answers with four of them — the synthesized volume,
  # which is the mounted one, comes first, and the physical store comes last with an empty
  # mount column. `tail -1` therefore read "no mount point" and aborted a clean image.
  attached="$(hdiutil attach -nobrowse -noautoopen -readonly "$DMG" \
    | awk -F'\t' '$1 ~ /^\/dev\// && $3 != "" { last = $0 } END { print last }')"
  vdev="$(printf '%s' "$attached" | awk '{print $1}')"
  vmount="$(printf '%s' "$attached" | awk '{ $1=""; $2=""; sub(/^[ \t]+/, ""); print }')"
  stray=""
  if [[ -n "$vmount" ]]; then
    stray="$(find "$vmount" -maxdepth 1 -name ".*" ! -name ".DS_Store" 2>/dev/null || true)"
  fi
  hdiutil detach "$vdev" >/dev/null 2>&1 || true
  if [[ -z "$vmount" ]]; then
    echo "ERROR: could not tell where the DMG mounted, refusing to ship it unchecked"; exit 1
  fi
  if [[ -n "$stray" ]]; then
    echo "ERROR: DMG has stray hidden entries, aborting before notarize:"; echo "$stray"; exit 1
  fi
  echo "DMG verified clean (no stray hidden folders)."

  # Sign, then notarize + staple the DMG so the downloaded image opens with no Gatekeeper
  # warning. Stapling writes the ticket into the read-only image's metadata; it does not
  # mount-and-write the inner filesystem, so .fseventsd does not come back.
  if [[ -n "$SIGN_ID" ]]; then
    codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
    if [[ "${SKIP_NOTARIZE:-}" != "1" ]]; then
      echo "Notarizing the DMG via profile '$NOTARY_PROFILE' (can take a minute)…"
      xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
      xcrun stapler staple "$DMG"
      echo "DMG notarized + stapled."
    else
      echo "SKIP_NOTARIZE=1 — DMG signed but NOT notarized (layout test only)."
    fi
  fi
  echo "Built $DMG"
fi
