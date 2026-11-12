#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Workaround: flutter_inappwebview_android 1.1.3 (transitive via flutter_3d_controller)
# calls getDefaultProguardFile('proguard-android.txt') in its android/build.gradle.
# Newer AGP (bundled with Flutter 3.47.9, Gradle 9.3.1) HARD-REJECTS that call
# at project-evaluation time, breaking `flutter build apk/aab` (the error fires
# regardless of --obfuscate). This rewrites it to the AGP-recommended
# 'proguard-android-optimize.txt' (safe for release; no behaviour change).
#
# The package lives in pub cache and is re-fetched on a fresh `flutter pub get`,
# so this must run AFTER `flutter pub get` and BEFORE `flutter build apk/aab`.
# Idempotent: only rewrites when the deprecated string is still present.
#
# CI calls this automatically. LOCALLY, run it once after `flutter pub get`:
#   bash tools/patch_inappwebview_proguard.sh
# before `flutter build apk --release ...`.
# ---------------------------------------------------------------------------
set -euo pipefail

patched=0
roots=()
[ -n "${PUB_CACHE:-}" ] && roots+=("${PUB_CACHE}")
roots+=("$HOME/.pub-cache")
roots+=("/c/Users/11827/AppData/Local/Pub/Cache")
[ -n "${LOCALAPPDATA:-}" ] && roots+=("$LOCALAPPDATA/Pub/Cache")

for root in "${roots[@]}"; do
  [ -n "$root" ] || continue
  [ -d "$root" ] || continue
  while IFS= read -r -d '' f; do
    if grep -q "proguard-android.txt" "$f"; then
      sed -i 's/proguard-android\.txt/proguard-android-optimize.txt/g' "$f"
      echo "patched: $f"
      patched=1
    fi
  done < <(find "$root" -type f -path '*flutter_inappwebview_android-*/android/build.gradle' -print0 2>/dev/null)
done

echo "inappwebview proguard patch done (patched=$patched)"
