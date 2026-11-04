#!/bin/zsh
# Builds the app, then writes dist/JadyxDrop-<version>.zip and .dmg for a GitHub release.
set -euo pipefail
cd "${0:A:h}/.."
./scripts/build.sh
VERSION=$(<VERSION)
rm -rf dist && mkdir -p dist/dmg
ditto -c -k --keepParent build/JadyxDrop.app "dist/JadyxDrop-$VERSION.zip"
cp -R build/JadyxDrop.app dist/dmg/
ln -s /Applications dist/dmg/Applications
hdiutil create -quiet -volname "JadyxDrop $VERSION" -srcfolder dist/dmg -ov -format UDZO "dist/JadyxDrop-$VERSION.dmg"
rm -rf dist/dmg
(cd dist && shasum -a 256 JadyxDrop-$VERSION.* > SHA256SUMS.txt)
ls -lh dist
