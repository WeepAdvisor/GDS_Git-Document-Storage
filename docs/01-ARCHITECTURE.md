# 01 — Архитектура

## 1. Ключевая идея

Finder-папка реализуется через **File Provider** (`NSFileProviderReplicatedExtension`) — тот же механизм, которым пользуются
Dropbox, OneDrive, Box, Google Drive и Transmit. Папки появляются в сайдбаре Finder в разделе «Locations», физически —
в `~/Library/CloudStorage/GitDocumentStorage-<Имя папки>/`. Файлы отображаются сразу (метаданные), содержимое скачивается
при первом открытии (dataless-файлы с иконкой облака), значки состояния синхронизации Finder рисует сам.

GitHub-репозиторий хранится **не как локальный git-клон**, а как «удалённая файловая система»: дерево и blob'ы читаются
через REST API, записи делаются одним коммитом через GraphQL `createCommitOnBranch` (или REST Git Data API).
Это убирает libgit2/бинарник git, merge-движок и локальный `.git`, а оптимистическая блокировка (`expectedHeadOid`)
даёт ровно ту семантику, которая нужна «сетевой папке» (см. ADR-002).

## 2. Процессы

```
┌──────────────────────────────┐          ┌──────────────────────────────────────┐
│  GitDocumentStorage.app      │          │  GitDocumentStorageFileProvider.appex │
│  (menu bar, LSUIElement)     │          │  (один процесс, N экземпляров/домены) │
│                              │          │                                       │
│  • Settings UI (SwiftUI)     │  signal  │  • FileProviderExtension (per domain) │
│  • AccountManager (OAuth)    │ ───────▶ │  • SyncEngine (per domain, actor)     │
│  • DomainManager (add/remove │ enumerat.│  • ItemStore (SQLite, GRDB)           │
│    reconnect/disconnect)     │          │  • UploadQueue / CommitBuilder        │
│  • RemotePoller (ETag poll)  │          │  • RemoteDiffApplier                  │
│  • Heartbeat (liveness)      │          │  • GitHubClient                       │
│  • LoginItem (SMAppService)  │          │                                       │
└──────────────┬───────────────┘          └───────────────────┬───────────────────┘
               │  App Group container (UserDefaults + SQLite + staging)            │
               │  Keychain access group (tokens)                                   │
               └───────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼  HTTPS
                            api.github.com
```

### Почему движок синхронизации — в расширении, а не в приложении

- Finder вызывает `createItem/modifyItem/fetchContents` именно у расширения; ответить он должен сам. Пробрасывать каждый
  вызов по XPC в приложение — лишняя сложность и точка отказа.
- Расширение переживает краш/выход приложения: начатая выгрузка завершится.
- Приложение делает то, что требует «присутствия»: авторизация, UI, **поллинг удалённых изменений** и признак «я жив».

### Семантика «приложение не запущено → папки недоступны»

1. При старте приложение вызывает `NSFileProviderManager(for: domain).reconnect()` для всех доменов и начинает поллинг.
2. При штатном выходе приложение: ждёт опустошения очереди выгрузки (окно «Finishing upload…», максимум 30 с), затем
   `disconnect(reason: "GitDocumentStorage is not running", options: [.temporary])` для каждого домена. Finder показывает
   баннер и серые значки.
3. Backstop на случай краша: расширение перед любой сетевой операцией проверяет `AppLiveness.isAlive`
   (`NSRunningApplication` по bundle id + heartbeat-метка в App Group UserDefaults, свежее 30 с). Если нет —
   `NSFileProviderError(.serverUnreachable)`. Finder показывает «не удалось выполнить».
4. Строгий режим (папка исчезает полностью: `remove(domain)` на выходе, `add(domain)` на старте) — опция в настройках,
   выключена по умолчанию (теряется локальный кэш; см. `docs/08`, вопрос Q3).

## 3. Модули (SPM-пакет `Packages/GitDocsKit`)

| Модуль | Назначение | Зависимости |
|---|---|---|
| `GitHubKit` | `GitHubClient` (actor), `RateLimiter`, `ETagCache`, `DeviceFlowAuthenticator`, модели API, `CapabilityChecker` | Foundation |
| `Persistence` | GRDB-схема, `ItemStore`, `ChangeLog`, `PendingOpsStore`, миграции | GRDB |
| `SyncCore` | `RemoteRepository` (протокол поверх GitHubKit), `SyncEngine`, `CommitBuilder`, `CommitStrategySelector`, `RemoteDiffApplier`, `ConflictResolver`, `IgnoreRules`, `PathNormalizer`, `AppLiveness`, `SharedPaths`, `RepoConfigStore`, `TokenStore` | GitHubKit, Persistence |

Приложение и расширение линкуют `SyncCore`. Весь нетривиальный код живёт в пакете и покрыт тестами без Finder.

## 4. Данные, разделяемые между процессами

- **App Group** `group.<bundle-prefix>.gitdocumentstorage` (с префиксом Team ID на macOS):
  - `Library/Application Support/Domains/<domainID>/store.sqlite` — состояние домена (WAL, доступ из обоих процессов безопасен; пишет в основном расширение, приложение читает статусы).
  - `Library/Application Support/Domains/<domainID>/staging/` — содержимое файлов, ожидающих выгрузки.
  - `Library/Application Support/Domains/<domainID>/blobcache/` — опционально: кэш скачанных blob по SHA (LRU, лимит из настроек).
  - `UserDefaults(suiteName:)` — `repos.json` (конфиг папок), heartbeat, последняя известная `headSHA` на домен, флаги.
- **Keychain access group** — токены GitHub, ключ = `accountID` (login + host).

## 5. Основные потоки

### 5.1 Добавление папки
1. Пользователь вводит URL/`owner/repo` (или выбирает из списка своих репо).
2. `CapabilityChecker` перебирает существующие аккаунты → для каждого `GET /repos/{o}/{r}` → выбирает лучший по правам.
   Если ни один не подходит → предлагает «Sign in with another GitHub account» (Device Flow) → повтор.
3. Показывается отчёт: режим `readWrite` / `readOnly` / `unavailable` + предупреждения (LFS, protected branch, размер, пустой репо).
4. Сохраняется `RepoConfig` (domainID = UUID, owner, repo, branch, accountID, displayName, mode).
5. `NSFileProviderManager.add(NSFileProviderDomain(identifier: domainID, displayName: displayName))`.
6. Расширение при первом `enumerator(for: .rootContainer)` делает **initial load**: `GET git/trees/{headSHA}?recursive=1` → заполняет `items`.

### 5.2 Чтение файла
`fetchContents(for:version:)` → `ItemStore` даёт blobSHA → `GET git/blobs/{sha}` (`Accept: application/vnd.github.raw+json`) потоково во временный файл → вернуть URL. Параллелизм — 6 на домен.

### 5.3 Запись файла (Finder / любое приложение сохранило файл)
1. `modifyItem(contents:)` → содержимое перемещается в `staging/<opID>`; в `pending_ops` пишется операция; в `items` статус `uploading`; completion с item (`isUploading = true`).
2. `UploadQueue` (actor на домен) ждёт debounce (2 с с момента последней операции, максимум 10 с от первой) и собирает **батч**.
3. `CommitBuilder` формирует коммит: additions (новое содержимое), deletions, renames/copies (переиспользование SHA).
4. `CommitStrategySelector` выбирает GraphQL `createCommitOnBranch` или REST Git Data (см. `docs/04`).
5. Успех → `items` получают новый blobSHA/версию, `pending_ops` закрываются, `headSHA` обновляется, `signalEnumerator(.workingSet)`.
6. Отказ «not fast-forward» → `RemoteDiffApplier` подтягивает удалённые изменения, `ConflictResolver` решает коллизии, повтор (до 5 раз, затем ошибка + ретрай по таймеру).

### 5.4 Удалённые изменения
1. `RemotePoller` в приложении каждые 5 с (адаптивно до 60 с при простое) делает условный `GET git/ref/heads/{branch}`.
2. Новый SHA → приложение пишет `knownRemoteHead[domainID]` и вызывает `signalEnumerator(.workingSet)`.
3. Система вызывает `enumerateChanges(from: anchor)` у расширения → перед ответом `SyncEngine.pullRemote()`:
   `GET compare/{lastSHA}...{newSHA}` (≤ 300 файлов) либо полный `git/trees?recursive=1` + diff с БД.
4. Для каждого изменения — обновление `items` + запись в `change_log`; материализованные файлы система перекачает сама по смене `contentVersion`.
5. Элемент с незавершённой локальной правкой + удалённое изменение → конфликт (см. `docs/03`).

## 6. Состояние и надёжность

- Все операции идемпотентны: `pending_ops` хранят `opID`, повтор после краша безопасен.
- `headSHA` в БД домена — единственный источник «что мы считаем текущим состоянием сервера».
- При рассинхроне (например, `syncAnchorExpired`) — полная переэнумерация: дерево с сервера, diff с БД, change_log.
- Логи: `os.Logger(subsystem: "<bundle>", category: ...)`; `scripts/fp-logs.sh`.

## 7. Что сознательно НЕ делаем в v1

- Git LFS (файлы-указатели показываются как есть; при обнаружении — предупреждение в «пинге»).
- Submodules и symlink'и (не показываем).
- Ветки/история в UI (только «последняя активность» в меню — опционально, фаза 9).
- Оффлайн-правки с отложенной выгрузкой «на потом» дольше сессии (очередь живёт, но UX не обещаем).
- Другие хостинги (GitLab/Gitea) — только через новую реализацию `RemoteRepository`.
