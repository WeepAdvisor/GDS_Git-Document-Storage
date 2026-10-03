# GitDocumentStorage

GitHub-репозиторий как обычная папка в Finder. Без коммитов, веток и терминов git для пользователя:
сохранил файл — он на GitHub и у всех, кто подключил эту папку. Несколько папок, несколько аккаунтов,
доступно только пока приложение запущено.

- План реализации: [`docs/00-PLAN.md`](docs/00-PLAN.md)
- Архитектура: [`docs/01-ARCHITECTURE.md`](docs/01-ARCHITECTURE.md)
- Решения (ADR): [`docs/06-DECISIONS.md`](docs/06-DECISIONS.md)
- Открытые вопросы: [`docs/08-OPEN-QUESTIONS.md`](docs/08-OPEN-QUESTIONS.md)
- Промпт для исполнителя: [`docs/09-HANDOFF-PROMPT.md`](docs/09-HANDOFF-PROMPT.md)

## Быстрый старт

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # вписать Team ID и OAuth Client ID
make test      # swift test в Packages/GitDocsKit
make build     # компиляция без подписи
make run       # сборка с подписью → ~/Applications → запуск; папка «Demo» появится в Finder
make logs      # логи расширения и fileproviderd
```

Требования: macOS 15+, Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
