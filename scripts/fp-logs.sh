#!/bin/zsh
# Поток логов приложения, расширения и fileproviderd.
# Использование: scripts/fp-logs.sh [bundle-id-prefix]
set -euo pipefail
PREFIX="${1:-com.nasonov.gitdocumentstorage}"
exec log stream --style compact --level debug --predicate \
  "subsystem BEGINSWITH \"${PREFIX}\" OR process == \"fileproviderd\" OR process CONTAINS \"GitDocumentStorage\""
