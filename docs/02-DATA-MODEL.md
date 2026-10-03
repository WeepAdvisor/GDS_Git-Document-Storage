# 02 — Модель данных

## 1. Конфигурация (App Group `UserDefaults` / `repos.json`)

```swift
struct Account: Codable, Identifiable, Sendable {
    let id: String            // "github.com:<login>"
    var login: String
    var displayName: String?
    var avatarURL: URL?
    var tokenKind: TokenKind  // .oauthDeviceFlow | .personalAccessToken
    var addedAt: Date
}

struct RepoConfig: Codable, Identifiable, Sendable {
    let id: UUID              // == NSFileProviderDomainIdentifier
    var owner: String
    var repo: String
    var branch: String        // default branch при добавлении
    var accountID: Account.ID
    var displayName: String   // имя папки в Finder
    var mode: AccessMode      // .readWrite | .readOnly
    var conflictPolicy: ConflictPolicy  // .lastWriterWins | .keepBoth
    var pollInterval: TimeInterval      // 5
    var isEnabled: Bool
    var lastCapabilityReport: CapabilityReport?
}
```

Токены — в Keychain: service `GitDocumentStorage`, account = `Account.id`, access group = `$(TeamID).<bundle>.shared`.

## 2. База домена `Domains/<repoID>/store.sqlite` (GRDB, WAL)

### `meta`
| col | type | описание |
|---|---|---|
| key | TEXT PK | `headSHA`, `headTreeSHA`, `headCommittedAt`, `schemaVersion`, `lastFullLoadAt`, `revision` |
| value | TEXT | |

`revision` — монотонный счётчик; инкрементируется при любой записи в `change_log`.

### `items`
| col | type | описание |
|---|---|---|
| id | TEXT PK | UUID, = `NSFileProviderItemIdentifier.rawValue` |
| parent_id | TEXT | UUID родителя, `NSFileProviderItemIdentifier.rootContainer.rawValue` для верхнего уровня |
| name | TEXT | имя файла (NFC) |
| path | TEXT UNIQUE | полный путь в репо, NFC, без ведущего `/` |
| kind | INTEGER | 0 file, 1 directory |
| blob_sha | TEXT NULL | SHA blob'а на сервере (для файлов) |
| size | INTEGER | байты |
| mode | TEXT | `100644`/`100755` |
| content_mtime | REAL | дата последнего изменения содержимого (из коммита либо локальная) |
| meta_rev | INTEGER | версия метаданных (инкремент при rename/move) |
| state | INTEGER | 0 synced, 1 uploading, 2 upload_failed, 3 conflict, 4 deleted_pending |
| local_sha | TEXT NULL | SHA содержимого в staging (git blob sha1 «blob <len>\0…»), пока не выгружено |
| is_ignored | INTEGER | 1 для файлов из ignore-list (хранятся локально, не выгружаются) |
| created_at / updated_at | REAL | |

Индексы: `(parent_id, name)`, `(path)`, `(state)`.

Папки: `blob_sha = NULL`, `mode = '040000'`. `.gitkeep` хранится как обычный скрытый файл.

### `change_log`
| col | type | описание |
|---|---|---|
| rev | INTEGER PK | значение `meta.revision` на момент записи |
| item_id | TEXT | |
| kind | INTEGER | 0 upsert (metadata/content changed), 1 delete |
| at | REAL | |

Используется `enumerateChanges(from: anchor)`: anchor = `rev` в виде `Data`. Храним последние 10 000 записей; anchor < min(rev) → `syncAnchorExpired`.

### `pending_ops`
| col | type | описание |
|---|---|---|
| op_id | TEXT PK | UUID |
| item_id | TEXT | |
| op | INTEGER | 0 create, 1 modifyContent, 2 rename/move, 3 delete, 4 mkdir |
| path_before | TEXT NULL | |
| path_after | TEXT NULL | |
| staging_file | TEXT NULL | относительный путь в `staging/` |
| base_blob_sha | TEXT NULL | версия, на которой основана правка (для детекта конфликта) |
| attempts | INTEGER | |
| last_error | TEXT NULL | |
| created_at | REAL | |
| batch_id | TEXT NULL | назначается, когда операция попала в формируемый коммит |

Правила свёртки (`PendingOpsCoalescer`) при сборке батча:
- create + modify… → один addition с последним содержимым;
- modify + delete → delete;
- create + delete → ничего;
- rename A→B + modify B → addition B с новым содержимым + deletion A;
- rename A→B + rename B→C → rename A→C.

### `etag_cache`
| url | TEXT PK | | etag | TEXT | | body | BLOB NULL | | fetched_at | REAL |

Для `git/ref`, `repos/{o}/{r}`, `compare`.

## 3. Версии элементов

```swift
NSFileProviderItemVersion(
    contentVersion: Data((item.blob_sha ?? item.local_sha ?? "").utf8),
    metadataVersion: Data("\(item.meta_rev)".utf8)
)
```

- При удалённом изменении файла меняется `blob_sha` → `contentVersion` → система перекачивает материализованный файл.
- При локальной записи `local_sha` ставится немедленно (чтобы версия отличалась от серверной), после коммита `blob_sha = local_sha`, `local_sha = NULL`. Git blob SHA содержимого считается локально (`sha1("blob \(size)\0" + bytes)`) — он совпадёт с серверным, что позволяет не менять версию после выгрузки и не вызывать лишнюю перекачку.

## 4. Идентичность при переименованиях

- Локальное переименование/перемещение: `items.path/name/parent_id` обновляются, `id` сохраняется, `meta_rev += 1`.
- Удалённое: `compare` отдаёт `status: renamed, previous_filename` → находим item по старому пути, обновляем путь. Иначе (при полной переэнумерации) rename = delete + create (новый UUID). Приемлемо.

## 5. Нормализация путей (`PathNormalizer`)

- В git пишем NFC. Имена, пришедшие от Finder, нормализуем `precomposedStringWithCanonicalMapping`.
- Коллизии регистра (`Readme.md` и `README.md` в одном каталоге, APFS по умолчанию case-insensitive): второй и последующие элементы получают локальный суффикс ` (case conflict N)` в `name`, `path` сохраняет серверное значение; элемент помечается read-only до устранения коллизии на сервере.
- Запрещённые в git/GitHub компоненты: `.`, `..`, пустые, содержащие `\0`; `.git` как компонент. Такие создания отвергаем ошибкой `NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInvalidFileNameError)` — Finder покажет «недопустимое имя».

## 6. Содержимое и кэш

- `staging/<op_id>` — файл содержимого до выгрузки; удаляется после успешного коммита.
- `blobcache/<sha>` — опциональный LRU (по умолчанию 2 GB) для повторного открытия после эвикции системой; система и сама держит материализованные файлы, поэтому кэш — фаза 7.
