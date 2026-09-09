#!/bin/zsh
set -euo pipefail

OLD_REPO="$HOME/programming/self/docer"
NEW_REPO="$HOME/programming/self/docean"
OLD_CTR="$HOME/Library/Containers/dev.docer.docer/Data"
NEW_CTR="$HOME/Library/Containers/dev.docean.docean/Data"
APP_BUNDLE="$NEW_REPO/app/build/macos/Build/Products/Debug/docean.app"
OLD_LIB="$HOME/Documents/docer"
NEW_LIB="$HOME/Documents/docean"

say() { print -r -- "==> $*" }

if command -v fvm >/dev/null 2>&1; then
  FLUTTER=(fvm flutter)
else
  FLUTTER=(flutter)
fi

if [[ -d "$OLD_REPO" && ! -d "$NEW_REPO" ]]; then
  say "renaming workspace directory"
  mv "$OLD_REPO" "$NEW_REPO"
elif [[ -d "$NEW_REPO" ]]; then
  say "workspace already at $NEW_REPO"
else
  print -r -- "!! neither $OLD_REPO nor $NEW_REPO exists" >&2
  exit 1
fi

XCCONFIG="$NEW_REPO/app/macos/Flutter/ephemeral/Flutter-Generated.xcconfig"
if [[ -f "$XCCONFIG" ]] && grep -q "$OLD_REPO" "$XCCONFIG"; then
  say "refreshing build-time absolute paths for the new directory"
  (cd "$NEW_REPO/app" && "${FLUTTER[@]}" pub get) ||
    print -r -- "   pub get failed - run it yourself: cd $NEW_REPO/app && flutter pub get" >&2
fi

if [[ ! -d "$NEW_CTR" ]]; then
  if [[ ! -d "$APP_BUNDLE" ]]; then
    say "building the macOS app once"
    (cd "$NEW_REPO/app" && "${FLUTTER[@]}" build macos --debug) || true
  fi
  if [[ -d "$APP_BUNDLE" ]]; then
    say "launching docean once to create its sandbox container"
    open "$APP_BUNDLE"
    waited=0
    while [[ ! -d "$NEW_CTR" && $waited -lt 60 ]]; do
      sleep 1
      waited=$((waited + 1))
    done
    pkill -f 'docean.app/Contents/MacOS/docean' || true
    sleep 2
  fi
fi

if [[ ! -d "$NEW_CTR" ]]; then
  print -r -- "!! container $NEW_CTR still missing." >&2
  print -r -- "   start the app once (cd $NEW_REPO/app && flutter run -d macos)," >&2
  print -r -- "   quit it, then re-run this script - every step is idempotent." >&2
  exit 1
fi

OLD_REPO_DIR="$OLD_CTR/Documents/docer"
NEW_REPO_DIR="$NEW_CTR/Documents/docean"

if [[ -d "$OLD_REPO_DIR" && ! -d "$NEW_REPO_DIR" ]]; then
  say "moving the repository (database + blobs + library_dir.txt) into the new container"
  mkdir -p "$NEW_CTR/Documents"
  cp -R "$OLD_REPO_DIR" "$NEW_REPO_DIR"
  for ext in "" "-wal" "-shm"; do
    if [[ -f "$NEW_REPO_DIR/docer.db$ext" ]]; then
      mv "$NEW_REPO_DIR/docer.db$ext" "$NEW_REPO_DIR/docean.db$ext"
    fi
  done
  if [[ -f "$NEW_REPO_DIR/library_dir.txt" ]]; then
    sed -i '' 's/docer/docean/g' "$NEW_REPO_DIR/library_dir.txt"
    print -r -- "    library_dir.txt -> $(cat "$NEW_REPO_DIR/library_dir.txt")"
  fi
elif [[ -d "$NEW_REPO_DIR" ]]; then
  say "repository already present in the new container, skipping"
else
  say "no repository at $OLD_REPO_DIR, nothing to migrate"
fi

if [[ -d "$OLD_LIB" && ! -d "$NEW_LIB" ]]; then
  say "renaming the mirrored library folder"
  mv "$OLD_LIB" "$NEW_LIB"
elif [[ -d "$NEW_LIB" ]]; then
  say "library folder already named docean, skipping"
fi

OLD_AI="$OLD_CTR/.config/docer/ai"
NEW_AI="$NEW_CTR/.config/docean/ai"

if [[ -d "$OLD_AI" && ! -d "$NEW_AI" ]]; then
  say "migrating AI provider config and built-in model cache"
  mkdir -p "$(dirname "$NEW_AI")"
  cp -R "$OLD_AI" "$NEW_AI"
  if [[ -f "$NEW_AI/ai.json" ]]; then
    sed -i '' -e 's/docer/docean/g' -e 's/Docer/Docean/g' "$NEW_AI/ai.json"
  fi
  if [[ -f "$NEW_AI/models/docer-tiny.bin" ]]; then
    mv "$NEW_AI/models/docer-tiny.bin" "$NEW_AI/models/docean-tiny.bin"
  fi
elif [[ -d "$NEW_AI" ]]; then
  say "AI config already migrated, skipping"
fi

if [[ -f "$NEW_AI/ai.json" ]] && command -v jq >/dev/null 2>&1; then
  say "copying keychain API keys from service docer.ai to docean.ai"
  for pid in $(jq -r '.providers | keys[]' "$NEW_AI/ai.json"); do
    if secret=$(security find-generic-password -s docer.ai -a "$pid" -w 2>/dev/null); then
      security add-generic-password -s docean.ai -a "$pid" -w "$secret" -U
      print -r -- "    copied key for provider: $pid"
    fi
  done
fi

say "done"
print -r -- "    old container kept as backup: $HOME/Library/Containers/dev.docer.docer"
print -r -- "    delete it only once docean shows your documents, tags and paths"
print -r -- "    if the app cannot read the library folder, re-pick $NEW_LIB once"
print -r -- "    in the library-folder dialog (sandbox file grants are per bundle id)"
