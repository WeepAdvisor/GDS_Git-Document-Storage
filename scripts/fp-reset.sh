#!/bin/zsh
# Удаляет все домены провайдера (через скрытый флаг приложения) и перезапускает Finder-кэш провайдеров.
# Использовать, когда Finder «завис» на старом состоянии расширения.
set -euo pipefail
APP="${1:-$HOME/Applications/GitDocumentStorage.app}"

echo "→ pluginkit sees:"
pluginkit -m -p com.apple.fileprovider-nonui -vv 2>/dev/null | grep -i gitdocument || echo "  (extension not registered yet)"

if [[ -d "$APP" ]]; then
  echo "→ removing all domains via $APP --reset-domains"
  open -W "$APP" --args --reset-domains || true
else
  echo "⚠ app not found at $APP — pass path as first argument"
fi

echo "→ killing stale extension/daemon processes"
killall GitDocumentStorageFileProvider 2>/dev/null || true
killall fileproviderd 2>/dev/null || true
echo "→ fileproviderctl domain list:"
fileproviderctl domain list 2>/dev/null || true
echo "done"
