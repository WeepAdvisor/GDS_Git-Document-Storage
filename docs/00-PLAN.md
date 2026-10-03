# 00 — План реализации GitDocumentStorage

Этот документ — пошаговая инструкция для исполнителя (Grok). Каждая фаза заканчивается **критериями приёмки**;
следующая фаза не начинается, пока они не выполнены и `make build && make test` зелёные.
Контекст и обоснования — в `docs/01…06`. Ручные сценарии проверки — в `docs/07-TESTING.md`.

Легенда: 🧱 код, 🧪 тесты, ✅ критерий приёмки, ⚠️ грабли.

---

## Фаза 0 — Каркас проекта и «Hello, Finder» (1–2 дня)

Цель: приложение + расширение File Provider собираются, подписываются, в Finder появляется папка с одним фиктивным файлом.

Состояние на старте: каркас уже написан и компилируется без подписи (`make build` ✅, `make test` ✅ — 23 теста).
Задача фазы — довести его до работающей папки в Finder с подписью.

### Задачи
1. 🧱 `Config/Local.xcconfig` (gitignored) с `GDS_DEVELOPMENT_TEAM = <TeamID>`, `GITHUB_OAUTH_CLIENT_ID = <id>`. Шаблон — `Config/Local.xcconfig.example`.
2. 🧱 `make run` → сборка с подписью, копия в `~/Applications`, запуск. Исправить всё, что всплывёт при подписи (App Groups с префиксом Team ID, provisioning).
3. 🧱 Проверить, что entitlements (`Config/*.entitlements`) после подписи содержат группу `<TEAMID>.group.com.nasonov.gitdocumentstorage` (`codesign -d --entitlements - <app>`). При необходимости добавить расширению `com.apple.developer.fileprovider.testing-mode` только в Debug (отдельный entitlements-файл для Debug-конфига через `project.yml`).
4. 🧱 Уже есть: `Sources/App/*` (MenuBarExtra, `DomainManager` с демо-доменом, heartbeat, disconnect на выходе), `Sources/FileProviderExtension/*` (`FileProviderExtension`, `FileProviderItem`, `DemoCatalog`, `DemoEnumerator` с `README.txt` в памяти). Проверить в Finder; исправить ошибки API, если система отвергнет элементы (смотреть `make logs`).
5. 🧱 Проверить `scripts/fp-reset.sh`: флаг `--reset-domains` приложения удаляет домены.
6. 🧪 `make test` проходит.

### ⚠️ Грабли
- Без `DEVELOPMENT_TEAM` App Groups не валидируются и расширение не запустится (`pluginkit -m -p com.apple.fileprovider-nonui -vv` должно показать наш bundle id).
- Группа на macOS должна начинаться с Team ID: `<TEAMID>.group…` **или** `group.<bundle>` с автопрефиксом — используем `$(TeamIdentifierPrefix)group.<bundle>`; одна и та же строка в обоих entitlements и в коде (`SharedPaths.appGroupID`).
- Расширение регистрируется LaunchServices при первом запуске приложения; после пересборки — перезапускать приложение. Если Finder держит старую версию — `scripts/fp-reset.sh`.
- Запуск из DerivedData работает; для надёжности `make run` копирует `.app` в `~/Applications`.

### ✅ Приёмка
- `make build` и `make test` зелёные.
- В Finder → Locations появляется «GitDocumentStorage» → «Demo» с `README.txt`, файл открывается в TextEdit.
- `scripts/fp-logs.sh` показывает логи расширения (категория `ext`).

---

## Фаза 1 — GitHubKit: клиент, авторизация, проверка возможностей (2–3 дня)

Цель: модуль без UI, покрытый тестами, умеет всё из `docs/04` и `docs/05`.

### Задачи
1. 🧱 `GitHubClient` (actor): `request<T: Decodable>(_ endpoint: Endpoint) async throws -> Response<T>`, `download(_:to:)`, `graphQL(_:variables:)`. Общие заголовки, декодирование ошибок (`GitHubError.http(status, message, documentationURL)`, `.rateLimited(retryAfter)`, `.notFastForward`, `.emptyRepository`, `.ssoRequired(url)`, `.unauthorized`, `.network`).
2. 🧱 `RateLimiter` (actor): учёт заголовков, очередь ожидания, параллелизм по категориям (`read`, `blobDownload`, `blobUpload`, `mutation`). API: `await limiter.acquire(.mutation)` / `release`, `handle(response:)`.
3. 🧱 `ETagCache` (протокол + in-memory + GRDB-реализация позже в Persistence): `conditionalGET`.
4. 🧱 Эндпоинты (`Endpoints.swift`): все из `docs/04` §1–2 как статические конструкторы. Модели: `GHRepository`, `GHBranch`, `GHRef`, `GHCommit`, `GHTree`, `GHTreeEntry`, `GHCompare`, `GHCompareFile`, `GHUser`, `GHBlobCreated`, `GHTreeCreated`, `GHCommitCreated`.
5. 🧱 `DeviceFlowAuthenticator`: `start() -> DeviceCodeSession`, `poll(session) -> AsyncThrowingStream<DeviceFlowEvent, Error>` (`.pending`, `.slowDown`, `.authorized(token, scope)`), обработка `expired_token`/`access_denied`.
6. 🧱 `CapabilityChecker.check(owner:repo:accounts:) -> [CapabilityReport]` строго по `docs/04` §5.
7. 🧱 `GitHubRemoteRepository: RemoteRepository` (в `SyncCore`) — реализация протокола из `Packages/GitDocsKit/Sources/SyncCore/RemoteRepository.swift` поверх `GitHubClient`: `head()`, `tree(sha)`, `blob(sha,to:)`, `compare(base,head)`, `commit(changes, expectedHead, message)` с `CommitStrategySelector`, `createFirstFile` (пустой репо).
8. 🧪 `MockURLProtocol` + фикстуры JSON (реальные ответы GitHub, обезличенные): тесты на декодирование всех моделей, на `RateLimiter` (429 + retry-after, 403 + reset), на Device Flow state machine, на `CapabilityChecker` (все исходы таблицы), на `CommitStrategySelector` (границы 200 файлов / 10 MB / 25 MB / наличие rename), на сборку REST-дерева (удаление = `sha: null`, rename без blob upload).
9. 🧪 Опциональный интеграционный тест с реальным токеном из env `GDS_TEST_TOKEN` и репо `GDS_TEST_REPO` (пропускается, если переменных нет): создать файл, изменить, переименовать, удалить; проверить fast-forward отказ при подмене `expectedHead`.

### ✅ Приёмка
- `swift test` ≥ 60 тестов зелёные без сети.
- Интеграционный тест (при наличии токена) проходит и оставляет репозиторий в исходном состоянии.
- `CapabilityChecker` на реальном приватном репо даёт `readWrite`, на чужом публичном — `readOnly(noPush)`, на несуществующем — `unavailable`.

---

## Фаза 2 — Persistence: схема домена, ItemStore, change log, pending ops (1–2 дня)

### Задачи
1. 🧱 GRDB `DatabaseMigrator` v1 по `docs/02` §2. `DomainStore.open(at url:)` (WAL, busyTimeout 5 с — второй процесс).
2. 🧱 `ItemStore`: `item(id)`, `item(path)`, `children(parentID)`, `upsert`, `move(id, newParent, newName)`, `delete(id, recursive:)`, `setState`, `applyRemoteTree([RemoteTreeEntry], headSHA, committedAt)` (initial load в одной транзакции), `diffAgainst([RemoteTreeEntry])` для fullResync.
3. 🧱 `ChangeLog`: `append(itemID, kind)` (инкремент `meta.revision` в той же транзакции), `changes(since rev) -> (upserts, deletes, newRev)`, `prune(keep: 10_000)`, `isExpired(rev)`.
4. 🧱 `PendingOpsStore`: `enqueue`, `nextBatch(coalesced:)`, `markBatch(batchID)`, `complete(batchID)`, `fail(batchID, error)`, `releaseBatch(batchID)` (после краша — вернуть ops в очередь), `PendingOpsCoalescer` по правилам `docs/02`.
5. 🧱 `SharedPaths`: контейнер App Group, `domainDirectory(id)`, `stagingURL(domainID, opID)`.
6. 🧪 Тесты на миграции, на каждую операцию `ItemStore` (включая move каталога с 1000 потомков < 100 мс), на `ChangeLog.expired`, на все правила коалесцирования, на одновременную запись из двух `DatabaseQueue` (эмуляция двух процессов).

### ✅ Приёмка
- Тесты зелёные; `applyRemoteTree` на дереве из 50 000 записей < 2 с (тест с генерацией).

---

## Фаза 3 — Чтение: initial load, энумерация, скачивание, удалённые изменения (3–4 дня)

Цель: репозиторий виден и читается в Finder; чужие коммиты появляются ≤ 10 с.

### Задачи
1. 🧱 `RepoConfigStore` (App Group UserDefaults, `repos.json`, атомарная запись) и `KeychainTokenStore`.
2. 🧱 `SyncEngine` (actor на домен): `init(config, store, remote)`, `ensureInitialLoad()`, `pullRemote()` (по `docs/03` §3 без конфликтов — они в фазе 5), `fetchBlob(item) -> URL`.
3. 🧱 Расширение:
   - `FileProviderExtension.init(domain:)` → найти `RepoConfig` по `domain.identifier`, открыть `DomainStore`, собрать `SyncEngine`. Нет конфига → все вызовы возвращают `NSFileProviderError(.noSuchItem)` с логом уровня error (домен-сирота; приложение удалит его при следующем старте).
   - `item(for:)` из `ItemStore`; `FileProviderItem` маппит строку БД → `NSFileProviderItemProtocol` (`capabilities` зависят от `mode`, `isUploading/isUploaded/isDownloaded`, `contentModificationDate`, `documentSize`, `itemVersion`, `contentType` по расширению через `UTType`).
   - `fetchContents(for:version:)` → `SyncEngine.fetchBlob` (временный файл в `NSFileProviderManager.temporaryDirectoryURL()`), если `version.contentVersion` ≠ текущей — вернуть текущую с item (система справится).
   - `enumerator(for:)`: контейнер → `ContainerEnumerator` (страницы по 500 из `children`), `.workingSet` → `WorkingSetEnumerator` (`enumerateItems` — все элементы постранично; `enumerateChanges(from:)` — `ChangeLog.changes(since:)`, перед этим `await engine.pullRemote()`; `currentSyncAnchor` = `revision`).
   - `AppLiveness.isAlive` проверка перед сетевыми вызовами → `.serverUnreachable`.
4. 🧱 Приложение: `DomainManager` (`add/remove/reconnect/disconnect`, синхронизация списка доменов с `repos.json` при старте), `RemotePoller` (по `docs/03` §9), `Heartbeat` (пишет `heartbeatAt` каждые 10 с), на выходе — `disconnect(.temporary)` всех доменов.
5. 🧱 Временный UI в Settings: таблица репо + кнопка «Add (owner/repo, token)» (без Device Flow — PAT в поле) для ручной проверки. Полноценный UI — фаза 6.
6. 🧪 Тесты `SyncEngine.pullRemote` с `MockRemoteRepository`: added/modified/removed/renamed, compare > 300 → полное дерево, truncated tree → поуровневый обход. Тесты `WorkingSetEnumerator` на anchor (expired → ошибка).

### ⚠️ Грабли
- `enumerateItems` для `.workingSet` должен отдавать **все** элементы, иначе Finder не узнает об элементах при первом подключении после `syncAnchorExpired`.
- `NSFileProviderItemProtocol.filename` — просто имя, не путь. `parentItemIdentifier` корня верхнего уровня = `.rootContainer`.
- `contentType` для папок — `.folder`; без него Finder не раскрывает каталоги.
- Finder кэширует агрессивно: проверять изменения не глазами, а `ls ~/Library/CloudStorage/...`.

### ✅ Приёмка (ручной сценарий T3 из `docs/07`)
- Добавил приватный репо → папка в Finder со всем деревом за ≤ 5 с (для 1000 файлов).
- Открыл `.docx`/`.png`/`.pdf` — скачивается и открывается; Quick Look работает.
- Сделал коммит на GitHub через веб (новый файл, правка, удаление, переименование) — Finder отразил всё ≤ 10 с без перезахода в папку.
- Закрыл приложение → Finder показывает баннер; попытка открыть нескачанный файл → ошибка; запустил снова → работает.

---

## Фаза 4 — Запись: create/modify/delete → коммит (3–4 дня)

### Задачи
1. 🧱 В расширении `createItem`, `modifyItem` (и `changedFields: .contents/.filename/.parentItemIdentifier/.contentModificationDate`), `deleteItem` по `docs/03` §4.1. Поддержать `NSFileProviderCreateItemOptions.mayAlreadyExist` (идемпотентность: если путь уже есть с тем же SHA — вернуть существующий). Сохранять `100755`, если был.
2. 🧱 `UploadQueue` (actor): debounce 2/10 с, батч, `CommitBuilder`, вызов `remote.commit`, применение результата, `signalEnumerator`. Персистентность: при `init` расширения — `releaseBatch` всех незавершённых батчей и запуск очереди.
3. 🧱 `CommitMessageComposer` (`docs/03` §4.3).
4. 🧱 `IgnoreRules` (`docs/03` §6): такие элементы создаются локально (`is_ignored`), возвращаются Finder как обычные, но в `pending_ops` не попадают.
5. 🧱 Пустые папки → `.gitkeep` (ADR-008). `.gitkeep` показывать как скрытый файл (`isHidden` нет в протоколе — просто dotfile).
6. 🧱 Read-only домен: `capabilities` без записи; Finder сам не даст писать. На всякий случай `createItem`/`modifyItem`/`deleteItem` возвращают `NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)`.
7. 🧱 Пустой репозиторий: первая запись через Contents API.
8. 🧪 Тесты `UploadQueue` с `MockRemoteRepository`: debounce, батч из create+modify+delete, выбор стратегии, not-fast-forward → pull → retry, краш между commit и apply (повторный запуск с тем же batch — идемпотентно через `mayAlreadyExist`-подобную проверку SHA на сервере: если `headSHA` на сервере уже содержит наш blob по пути — считать успехом).
9. 🧪 Интеграционный тест (env-токен): записать 50 файлов за один батч → 1 коммит GraphQL; переименовать папку из 20 файлов → 1 коммит REST без загрузки blob (проверить по количеству запросов в `MockURLProtocol`-обёртке/счётчику клиента).

### ⚠️ Грабли
- `contents` URL от системы валиден только в вызове — сразу `FileManager.moveItem` в staging (это другой volume? нет, тот же — move дёшев; если ошибка `EXDEV`, копировать).
- Системе нужно вернуть item, у которого `itemVersion.contentVersion` **уже** соответствует новому содержимому (local_sha), иначе она сочтёт, что загрузка не отражена, и повторит `modifyItem`.
- Finder при копировании папки вызывает `createItem` для папки, затем для файлов — порядок не гарантирован; `parentItemIdentifier` может ссылаться на ещё не созданный каталог → в `ItemStore` родитель всегда уже есть (система ждёт completion родителя), но защититься проверкой.
- Office/Pages: 5–10 операций на одно сохранение → убедиться в коалесцировании (тест T4.5).

### ✅ Приёмка
- Сохранил файл в Finder → коммит на GitHub ≤ 5 с с человекочитаемым сообщением, автор — я.
- На втором Mac (или в веб-интерфейсе) файл виден ≤ 10 с; на втором Mac с приложением — появился в Finder.
- Копирование папки из 300 файлов (суммарно 20 MB) → завершается ≤ 60 с, ≤ 3 коммита, значки синхронизации корректны.
- Переименование/перемещение/дублирование — без перезаливки содержимого (по логам: 0 `POST git/blobs`).
- Удаление папки → один коммит.

---

## Фаза 5 — Конфликты и крайние случаи (2–3 дня)

### Задачи
1. 🧱 `ConflictResolver` — матрица `docs/03` §5 для обеих политик. Conflicted copy: `"\(stem) (conflicted copy \(login) \(yyyy-MM-dd HH.mm)).\(ext)"`.
2. 🧱 Детект конфликта в `modifyItem` по `baseVersion` **и** в `UploadQueue` перед коммитом (удалённое изменение могло прийти после приёма операции).
3. 🧱 Уведомления (`UserNotifications`, из приложения; расширение пишет события в таблицу `events`/App Group, приложение показывает): «overwritten by @x», «conflicted copy created», «can't upload (too large)».
4. 🧱 `PathNormalizer`: NFC, коллизии регистра, недопустимые имена.
5. 🧱 Symlink/submodule — пропуск с логом. Файлы > 100 MB — `upload_failed` + уведомление.
6. 🧱 `fullResync()` + пункт меню «Resync folder».
7. 🧪 Тесты на каждую строку матрицы × обе политики (минимум 20 тестов), на NFC/регистр, на conflicted-copy имена (уникальность при повторе в ту же минуту → суффикс ` 2`).

### ✅ Приёмка (сценарии T5.x)
- Два Mac правят один файл одновременно: в `lastWriterWins` остаётся последняя версия, проигравший получает уведомление, прежняя версия видна в истории GitHub; в `keepBoth` появляется conflicted copy у обоих.
- Удалил файл, пока другой его правил → файл вернулся с правкой.
- Папка с `Readme.md`+`README.md` на сервере не роняет расширение; второй файл помечен суффиксом.

---

## Фаза 6 — Продуктовый UI приложения (3–4 дня)

### Задачи
1. 🧱 Меню-бар (`MenuBarExtra` или `NSStatusItem`): общий статус (✓ / ↑ N / ⚠), список папок с состоянием и «Open in Finder», «Open on GitHub», «Pause sync», «Recent activity» (последние 10 коммитов из `compare`/`commits`), «Settings…», «Quit».
2. 🧱 Settings (SwiftUI, `Settings` scene): вкладки **Folders**, **Accounts**, **General**.
   - Folders: список, «Add Folder…» мастер: шаг 1 — ввод URL/`owner/repo` или выбор из `GET /user/repos` (поиск); шаг 2 — «Checking access…» с прогрессом по аккаунтам → отчёт `CapabilityReport` (значок, причины, предупреждения), выбор ветки (по умолчанию default), имя папки, политика конфликтов; шаг 3 — «Done, open in Finder».
     Если доступа нет ни у одного аккаунта — кнопка «Sign in with another GitHub account» прямо в шаге 2, после входа повторная проверка.
   - Папка: «Remove» (с вопросом «удалить локальный кэш?»), «Check access again», «Change account», «Rename folder» (= remove+add домена с сохранением БД).
   - Accounts: аватар, логин, «Sign in with GitHub» (Device Flow экран с кодом), «Use a token instead», «Sign out».
   - General: «Launch at login» (`SMAppService.mainApp`), «Strict mode: hide folders when app is not running» (ADR-005), интервал поллинга, лимит кэша, «Show notifications».
3. 🧱 `LoginItem` регистрация при первом запуске (спросить).
4. 🧱 Graceful quit: «Finishing upload… (N files)» с кнопкой «Quit anyway» (таймаут 30 с).
5. 🧱 Onboarding при первом запуске: «Add your first folder».
6. 🧪 Unit-тесты view-model'ей мастера (состояния, выбор аккаунта); UI-тесты не требуются.

### ✅ Приёмка
- Новый пользователь без подготовки: запуск → Add Folder → ссылка → Sign in → код → Authorize → папка в Finder. ≤ 2 минут, ни одного git-термина на экране (кроме «GitHub»).
- Второй репозиторий от другого аккаунта добавляется тем же путём; в списке папок обе, аккаунты разные.
- Read-only репо отображается с замком и объяснением.

---

## Фаза 7 — Надёжность и производительность (2–3 дня)

### Задачи
1. 🧱 Экспериментально уточнить пороги `CommitLimits` (GraphQL размер тела): бинарный поиск на тестовом репо, зафиксировать в коде и в `docs/04` §2.1.
2. 🧱 `blobcache` LRU (ADR, `docs/02` §6) — только если наблюдается повторная перекачка после эвикции.
3. 🧱 Поведение при сети «нет/плохая»: `NWPathMonitor` в приложении → статус «Offline», пауза поллинга; в расширении — pending остаются.
4. 🧱 Сон/пробуждение Mac: немедленный поллинг после `didWakeNotification`.
5. 🧱 Стресс: репо 20 000 файлов — initial load, энумерация, память расширения < 200 MB. Профилировать `applyRemoteTree` и энумерацию (страницы).
6. 🧱 Проверка secondary rate limit: заливка 1000 файлов по 10 KB — ожидаемо ≤ 5 коммитов GraphQL; заливка 50 файлов по 20 MB — REST, ≤ 180 мутаций/мин соблюдается.
7. 🧱 Краш-тесты расширения: `kill -9` во время батча → после перезапуска батч доезжает, дублей коммитов нет.
8. 🧱 Телеметрия в логи: длительности, размеры батчей, количество запросов за сессию (в меню «Diagnostics → Export logs» через `log collect`).

### ✅ Приёмка
- Все стресс-сценарии `docs/07` T7.x проходят; нет утечек (Instruments Leaks на 30-минутной сессии).

---

## Фаза 8 — Дистрибуция (1–2 дня)

1. 🧱 Developer ID сертификат, hardened runtime, notarization (`xcrun notarytool`), DMG (`create-dmg` или `hdiutil`). Скрипт `scripts/release.sh`.
2. 🧱 Версионирование: `MARKETING_VERSION` в `project.yml`, `CHANGELOG.md`.
3. 🧱 Опционально: Sparkle для автообновлений (отдельный ADR, т.к. новая зависимость).
4. ✅ DMG устанавливается на чистый Mac без Xcode; Gatekeeper не ругается; папки работают.

---

## Фаза 9 — Приятности (опционально)

- FileProviderUI action extension: контекстное меню Finder «Open on GitHub», «Copy GitHub link», «Show history».
- `NSFileProviderThumbnailing` — превью для изображений без скачивания (через `contents` API? нет — скачиваем blob; смысла мало).
- Уведомление «@anna changed Report.docx» (из `compare.commits`).
- Поддержка GitHub Enterprise Server (`baseURL`).
- Реализация `RemoteRepository` поверх libgit2 для произвольных git-хостов.

---

## Правила работы исполнителя

1. Перед началом фазы прочитать соответствующие разделы `docs/01–05`. При расхождении плана и документа — исправить документ и зафиксировать в коммите.
2. Каждая задача — отдельный коммит с префиксом фазы: `P3: WorkingSetEnumerator with change log anchors`.
3. Не добавлять зависимости и не менять `project.yml`/entitlements без записи в `docs/06-DECISIONS.md`.
4. Любой публичный тип в `SyncCore`/`GitHubKit` — с doc-комментарием и тестом.
5. Если что-то в File Provider ведёт себя не так, как описано — сначала `scripts/fp-logs.sh`, потом `fp-reset.sh`, потом фиксировать наблюдение в `docs/08-OPEN-QUESTIONS.md` раздел «Наблюдения».
6. Оценки времени ориентировочные; качество важнее.
