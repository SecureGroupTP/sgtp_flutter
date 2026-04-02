#!/usr/bin/env bash
set -euo pipefail

# SGTP local data reset helper.
# Removes app data from Documents and SharedPreferences caches.
# Usage:
#   ./scripts/clean.sh        # interactive confirm
#   ./scripts/clean.sh --yes  # non-interactive

ASSUME_YES=0
if [[ "${1:-}" == "--yes" ]]; then
  ASSUME_YES=1
fi

DOCS_DIR="${HOME}/Documents"
TARGETS=(
  "${DOCS_DIR}/sgtp"
  "${DOCS_DIR}/sgtp_accounts"
  "${DOCS_DIR}/sgtp_chats"
)

PREF_CANDIDATES=(
  "${HOME}/.config/sgtp_flutter/shared_preferences.json"
  "${HOME}/.local/share/sgtp_flutter/shared_preferences.json"
  "${HOME}/Library/Application Support/sgtp_flutter/shared_preferences.json"
  "${HOME}/Library/Preferences/sgtp_flutter.plist"
)

FOUND=()
for p in "${TARGETS[@]}"; do
  if [[ -e "$p" ]]; then
    FOUND+=("$p")
  fi
done

for p in "${PREF_CANDIDATES[@]}"; do
  if [[ -f "$p" ]]; then
    FOUND+=("$p")
  fi
done

# Best-effort scan for extra shared_preferences files that contain SGTP keys.
for root in "${HOME}/.config" "${HOME}/.local/share" "${HOME}/Library/Application Support"; do
  [[ -d "$root" ]] || continue
  while IFS= read -r -d '' f; do
    if grep -q '"sgtp_' "$f" 2>/dev/null; then
      FOUND+=("$f")
    fi
  done < <(find "$root" -type f -name 'shared_preferences.json' -print0 2>/dev/null)
done

# Deduplicate
if [[ ${#FOUND[@]} -gt 0 ]]; then
  mapfile -t FOUND < <(printf '%s\n' "${FOUND[@]}" | awk '!seen[$0]++')
fi

if [[ ${#FOUND[@]} -eq 0 ]]; then
  echo "Nothing to clean."
  exit 0
fi

echo "Will remove ${#FOUND[@]} path(s):"
printf '  %s\n' "${FOUND[@]}"

if [[ $ASSUME_YES -ne 1 ]]; then
  read -r -p "Proceed? [y/N] " ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *)
      echo "Cancelled."
      exit 0
      ;;
  esac
fi

REMOVED=0
for p in "${FOUND[@]}"; do
  if [[ -d "$p" ]]; then
    rm -rf -- "$p"
    ((REMOVED+=1))
  elif [[ -e "$p" ]]; then
    rm -f -- "$p"
    ((REMOVED+=1))
  fi
done

echo "Done. Removed ${REMOVED} path(s)."
