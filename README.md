# GitDocumentStorage

Общая папка с документами, которая на самом деле является GitHub-репозиторием.

Сохранил файл в Finder — через несколько секунд он лежит на GitHub, и его видят все, у кого подключена та же папка. Несколько папок, несколько аккаунтов GitHub. Папка есть, пока приложение запущено.

## Зачем

Общие документы обычно живут либо в мессенджере (файлы теряются, версии путаются), либо в git (ветки, коммиты, pull request — лишние для договора, сметы, заметки). Нужна обычная папка, которую открывают Word, Preview и Finder, а под ней — нормальное хранилище: история, права доступа, бэкап на GitHub.

GitDocumentStorage — это слой между ними. Для человека это сетевая папка. Для GitHub это обычный репозиторий: каждый сейв становится коммитом, старая версия остаётся в истории, доступ раздаётся как к любому репо. Участнику не нужно ставить git, клонировать репозиторий и помнить, что надо закоммитить.

Локального `.git` нет. Приложение говорит с GitHub только по HTTPS API. Закрыл приложение — папка в Finder пропадает, на GitHub ничего не меняется.

## Как этим пользуются

1. Войти в GitHub (Device Flow или personal access token).
2. Подключить репозиторий — в Finder появляется папка.
3. Создавать и править файлы любыми программами. Сохранение само уходит на GitHub.
4. Чужие правки приезжают в ту же папку.

Папка физически лежит в `~/Library/CloudStorage/GitDocumentStorage-<имя>/`. Содержимое скачивается при открытии файла.

## Что внутри

Нативное приложение для macOS 15+ (Swift 6, SwiftUI + AppKit). Finder-папку даёт File Provider (`NSFileProviderReplicatedExtension`), тот же механизм, что у Dropbox и iCloud. Запись в репозиторий — fast-forward коммит через GitHub API (`createCommitOnBranch` / Git Data API), без force-push.

Подробности: [план](docs/00-PLAN.md), [архитектура](docs/01-ARCHITECTURE.md), [решения](docs/06-DECISIONS.md).

## Быстрый старт

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # Team ID и OAuth Client ID — только локально
make test      # swift test в Packages/GitDocsKit
make build     # компиляция без подписи
make run       # сборка с подписью → ~/Applications → запуск
make logs      # логи расширения и fileproviderd
```

`Config/Local.xcconfig` в git не входит. Туда же не кладутся токены: они живут в Keychain.

Нужны macOS 15+, Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
