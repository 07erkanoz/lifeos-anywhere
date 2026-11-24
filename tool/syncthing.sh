#!/usr/bin/env bash
# Puts Syncthing (the folder sync LifeOS uses too: lib/features/esitleme) where
# each build takes it from. Official release, checked against the sums pinned
# here (from the release's signed sha256sum.txt.asc); a mismatch stops the build.
#
#   tool/syncthing.sh android   android/app/src/main/jniLibs/<abi>/libsyncthing.so
#                               (a "library" so Android lets the app execute it;
#                               linux-arm64 and linux-arm: static Go binaries)
#   tool/syncthing.sh linux     build/linux/x64/release/bundle/lib/syncthing
#   tool/syncthing.sh windows   build/windows/x64/runner/Release/syncthing.exe
#
# Syncthing is MPL-2.0; its licence goes along (syncthing-LICENSE.txt).
set -euo pipefail

VERSION=v2.1.7   # keep in step with kSyncthingVersion (lib/features/esitleme/data/syncthing.dart)
declare -A SUM=(
  [linux-amd64]=2edc416e7ed136b7c858ed5f3f02a3b8316589605e54c380228ceea7acbf0142
  [linux-arm64]=48e456690cd2b97e7d26b02b5ac35f62a3b36172267b144cfeaf02c993ab955c
  [linux-arm]=d8b59029e25992bc0d280fccc5626e5dca743b285fca1a36db1148fcf871b639
  [windows-amd64]=3ce7da770f546a8d02b65b2e7ee31f2a3b8b7c3f990ede045590cca4172ecfe1
)

cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# fetch PLATFORM → $work/PLATFORM/{syncthing[.exe],LICENSE.txt}
fetch() {
  local platform=$1 ext=tar.gz
  [[ $platform == windows-* ]] && ext=zip
  local name="syncthing-$platform-$VERSION"
  curl -fsSL --retry 3 -o "$work/$name.$ext" \
    "https://github.com/syncthing/syncthing/releases/download/$VERSION/$name.$ext"
  echo "${SUM[$platform]}  $work/$name.$ext" | sha256sum -c --quiet - \
    || { echo "Syncthing $platform: sağlama toplamı tutmuyor." >&2; exit 1; }
  mkdir -p "$work/$platform"
  if [[ $ext == zip ]]; then
    unzip -q -j "$work/$name.$ext" "$name/syncthing.exe" "$name/LICENSE.txt" -d "$work/$platform"
  else
    tar -xzf "$work/$name.$ext" -C "$work/$platform" --strip-components=1 "$name/syncthing" "$name/LICENSE.txt"
  fi
}

case "${1:-}" in
  android)
    for pair in arm64-v8a:linux-arm64 armeabi-v7a:linux-arm; do
      abi=${pair%%:*} platform=${pair#*:}
      fetch "$platform"
      mkdir -p "android/app/src/main/jniLibs/$abi"
      install -m 755 "$work/$platform/syncthing" "android/app/src/main/jniLibs/$abi/libsyncthing.so"
    done
    mkdir -p android/app/src/main/assets
    install -m 644 "$work/linux-arm64/LICENSE.txt" android/app/src/main/assets/syncthing-LICENSE.txt
    ;;
  linux)
    bundle=build/linux/x64/release/bundle
    test -d "$bundle/lib" || { echo "Önce: flutter build linux --release" >&2; exit 1; }
    fetch linux-amd64
    install -m 755 "$work/linux-amd64/syncthing" "$bundle/lib/syncthing"
    install -m 644 "$work/linux-amd64/LICENSE.txt" "$bundle/syncthing-LICENSE.txt"
    ;;
  windows)
    out=build/windows/x64/runner/Release
    test -d "$out" || { echo "Önce: flutter build windows --release" >&2; exit 1; }
    fetch windows-amd64
    cp "$work/windows-amd64/syncthing.exe" "$out/syncthing.exe"
    cp "$work/windows-amd64/LICENSE.txt" "$out/syncthing-LICENSE.txt"
    ;;
  *)
    echo "Kullanım: $0 android|linux|windows" >&2
    exit 2
    ;;
esac
echo "Syncthing $VERSION ($1) yerinde."
