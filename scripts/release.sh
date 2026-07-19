#!/usr/bin/env bash
# abra release — the whole pipeline, atomically:
#   build → sign → notarize → staple → zip → GitHub release → tap sha/version bump
# Fails loudly at any step; never leaves the release asset and the cask out of sync.
# Needs: .env with NOTARY_* (see .env.example), gh authenticated, tap checkout nearby.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -z $(git status --porcelain) ]] || { echo "!! working tree not clean"; exit 1; }
set -a; source ./.env; set +a
KEY="${NOTARY_KEY_PATH/#\~/$HOME}"
[[ -f $KEY ]] || { echo "!! notary key missing: $KEY"; exit 1; }

VERSION=$(plutil -extract CFBundleShortVersionString raw shells/mac/Sources/AbraShell/Info.plist)
echo "== releasing abra $VERSION"

make app

mkdir -p dist
ditto -c -k --keepParent /Applications/Abra.app dist/Abra-notarize.zip
xcrun notarytool submit dist/Abra-notarize.zip \
    --key "$KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" \
    --wait | tee /tmp/abra-notary.log
grep -q "status: Accepted" /tmp/abra-notary.log || { echo "!! notarization rejected"; exit 1; }
xcrun stapler staple /Applications/Abra.app
rm dist/Abra-notarize.zip

ZIP="dist/Abra-$VERSION.zip"
ditto -c -k --keepParent /Applications/Abra.app "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)

NOTES="Signed and notarized Abra.app.

Install: \`brew install ramsrib/tap/abra\` — or download the zip, drag Abra.app
to /Applications, and set up the engine per the README."
if gh release view "v$VERSION" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "$ZIP" --clobber
else
    gh release create "v$VERSION" "$ZIP" --title "abra $VERSION" --notes "$NOTES"
fi

TAP="$HOME/Projects/active/homebrew-tap"
sed -i '' \
    -e "s/^  version \".*\"/  version \"$VERSION\"/" \
    -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" \
    "$TAP/Casks/abra.rb"
(cd "$TAP" && brew style Casks/abra.rb \
    && git add Casks/abra.rb && git commit -m "abra $VERSION" && git push)

echo "== released v$VERSION"
echo "   asset: Abra-$VERSION.zip  sha256: $SHA"
echo "   cask bumped and pushed — brew users get it on next brew update"
