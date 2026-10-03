# 03 — Синхронизация и конфликты

## 1. Инварианты

1. `meta.headSHA` — коммит, которому соответствует состояние `items` (за вычетом pending-операций).
2. Любой наш коммит имеет родителем ровно `headSHA` (fast-forward). Если сервер ушёл вперёд — сначала pull, потом повтор.
3. Pending-операции применяются поверх любого нового удалённого состояния (rebase локальных правок).
4. Файлы из ignore-list существуют только локально.

## 2. Initial load

```
headSHA = GET git/ref/heads/{branch}            (object.sha)
commit  = GET git/commits/{headSHA}             (tree.sha, committer.date)
tree    = GET git/trees/{tree.sha}?recursive=1  (truncated? → fallback: обход по каталогам, см. 04)
```
Для каждого entry: `blob` → item(file); `tree` → item(dir); `commit` (submodule) и mode `120000` (symlink) → пропускаем.
Пустые каталоги в дереве не встречаются; каталоги создаются по префиксам путей. `content_mtime = committer.date`.
Записывается один `change_log` upsert на корень? Нет — initial load происходит до первой энумерации, change_log пуст, anchor = текущая `revision`.

## 3. Pull удалённых изменений (`RemoteDiffApplier.pull()`)

Триггер: `signalEnumerator(.workingSet)` от приложения, а также собственная проверка расширения перед каждым коммитом (не чаще раза в 2 с) и после ошибок not-fast-forward.

```
newHead = GET git/ref/heads/{branch} (ETag)
if newHead == headSHA → return
diff = GET compare/{headSHA}...{newHead}   // files[] со status: added|modified|removed|renamed|changed
if diff.files.count >= 300 || diff.truncated → полное дерево newHead и diff с items
apply(diff) в одной транзакции:
  added     → upsert item (или если путь занят локальным pending create → конфликт C1)
  modified  → если item.state == synced → blob_sha, mtime = commit.date, change_log upsert
              если item.state == uploading/pending → конфликт C2
  removed   → если synced → delete item + change_log delete (+ рекурсивно пустые родители без .gitkeep)
              если pending modify → конфликт C3
  renamed   → переместить item (сохранить id), meta_rev += 1
headSHA = newHead; revision++
```

После применения — `signalEnumerator(.workingSet)`, чтобы Finder вызвал `enumerateChanges`.

### Дата коммита для mtime
`compare` возвращает список коммитов; для простоты всем изменённым файлам ставим `committer.date` последнего коммита диапазона. Точность per-file — опциональное улучшение.

## 4. Локальные изменения → коммит

### 4.1 Приём операции (в обработчике File Provider)
```
createItem(file)     → staging copy, local_sha, items.insert(state: uploading), pending_ops(create)
createItem(dir)      → items.insert(dir) + pending_ops(mkdir)  → коммитится как <dir>/.gitkeep
modifyItem(contents) → staging copy, local_sha, state uploading, pending_ops(modifyContent, base_blob_sha = items.blob_sha)
modifyItem(rename/move) → items.path update, pending_ops(rename)
deleteItem           → items.state deleted_pending, pending_ops(delete)   (папка → рекурсивно)
```
Completion вызывается сразу после записи в БД. Для create/modify возвращаем item с `isUploading = true`, `isUploaded = false`.

### 4.2 Debounce и батч (`UploadQueue`)
- Таймер: 2 с после последней операции, но не позже 10 с после первой необработанной.
- Батч = все `pending_ops` без `batch_id`, свёрнутые `PendingOpsCoalescer`.
- Перед коммитом: `pull()` (чтобы иметь свежий `headSHA`), затем rebase батча: если удалённое состояние затронуло те же пути → `ConflictResolver`.

### 4.3 Коммит
Стратегия (подробно в `docs/04` §4):
- **GraphQL** `createCommitOnBranch(expectedHeadOid: headSHA, additions: [...base64], deletions: [...])` — когда в батче только новое содержимое/удаления, ≤ 200 файлов, ≤ 25 MB суммарно сырых байт, каждый файл ≤ 10 MB.
- **REST Git Data** иначе: `POST git/blobs` для нового содержимого (параллельно ≤ 4), `POST git/trees {base_tree: headTreeSHA, tree: [...]}` (удаление = entry с `sha: null`; rename/copy = entry с существующим `sha`), `POST git/commits {parents:[headSHA]}`, `PATCH git/refs/heads/{branch} {sha, force:false}`.

Сообщение коммита: автоматическое, человекочитаемое:
`Update Report.docx` / `Add 3 files` / `Rename Q3 → Q3 final` / `Delete old/` / `Update 2 files, delete 1` + тело со списком путей (≤ 50).

### 4.4 Результат
- Успех: `headSHA = newCommit`, для каждого пути `blob_sha = local_sha`, `local_sha = NULL`, `state = synced`, удалить staging, закрыть ops, `change_log upsert`, `signalEnumerator`.
- `expectedHeadOid` mismatch / 422 not fast-forward: `pull()` → повторить (до 5 раз, затем backoff 30 с → 5 мин, `state = upload_failed`, в меню — ошибка «Can't sync X: …»).
- 401/403 (нет прав): домен в `readOnly`, все pending → `upload_failed`, уведомление пользователю, файлы остаются локально.
- 422 «path too long / invalid» → `state = upload_failed`, уведомление с именем файла.
- Сеть недоступна: оставить pending, ретрай с backoff; Finder показывает «ожидает».

## 5. Матрица конфликтов

Обозначения: L — локальная незафиксированная операция, R — удалённое изменение, пришедшее до её коммита.

| # | L | R | `lastWriterWins` (по умолчанию) | `keepBoth` |
|---|---|---|---|---|
| C1 | create `a` | added `a` | наш `a` перезапишет (addition поверх нового head). Чужая версия — в истории | наш сохраняется как `a (conflicted copy <login> <yyyy-mm-dd HH.mm>).ext`, `a` = удалённая |
| C2 | modify `a` (base = v1) | modified `a` (v2) | наш коммит поверх v2 (содержимое наше) | наш → conflicted copy, `a` = v2 (система перекачает) |
| C3 | modify `a` | removed `a` | `a` воскресает с нашим содержимым | то же |
| C4 | delete `a` | modified `a` | удаление **отменяется**: `a` возвращается с v2 (не теряем чужую правку) | то же |
| C5 | delete `a` | removed `a` | ничего (op закрывается) | то же |
| C6 | rename `a→b` | modified `a` | `b` получает v2-содержимое? Нет: rename применяется к v2 (blob v2 под именем `b`), наш local content отсутствует | то же |
| C7 | rename `a→b` | removed `a` | `b` создаётся из последнего известного blob (воскрешение под новым именем) | то же |
| C8 | rename `a→b` | renamed `a→c` | побеждает удалённое (`c`); наша операция отбрасывается, Finder покажет `c` | то же |
| C9 | create dir `d/` | removed всё из `d/` | `d/.gitkeep` коммитится | то же |
| C10 | modify `a` | `a` стал каталогом / каталог стал файлом | наш → conflicted copy всегда (нельзя разрешить тихо) | то же |

«Conflicted copy» — всегда рядом с оригиналом, уходит в коммит как обычный addition, в меню — уведомление.
Пользователь-«проигравший» в `lastWriterWins` получает уведомление «Report.docx was overwritten by @anna; previous version is in history» с кнопкой «Open history on GitHub». Это компромисс между SMB-поведением и сохранностью данных.

Правило C4 (отмена удаления при чужой правке) — осознанное отступление от SMB: сетевая папка бы удалила; мы предпочитаем не терять чужую работу.

## 6. Ignore-list (`IgnoreRules`)

Никогда не выгружаются (хранятся локально, `is_ignored = 1`, не показываются в `change_log`):
```
.DS_Store, ._*, .Spotlight-V100, .Trashes, .TemporaryItems, .fseventsd, .apdisk, Icon\r
~$*            (Office lock files)
.~lock.*#      (LibreOffice lock)
*.sb-*         (Finder save-box temp)
.#*            (Emacs lock)
*.tmp, *.crdownload, *.part, *.download
.git/** , .git (как имя файла)
```
Пользовательские правила — из `.gitignore` в корне репо **не** применяем (иначе пользователь не поймёт, почему файл «не сохраняется»). Опция «Respect .gitignore» — не в v1.

Файлы, которые не выгружаются из-за ограничений (> 100 MB), получают `state = upload_failed` и значок ошибки + уведомление.

## 7. Атомарные сохранения приложений

Word/Pages/TextEdit сохраняют через temp-файл + rename + delete. За 2-секундный debounce это сворачивается в один `modifyContent` (см. правила `PendingOpsCoalescer`). Если temp-файл попал в ignore-list (`*.sb-*`), rename ignored→visible трактуется как `create` с содержимым.

## 8. Переименование каталогов

Локально: обновить `path` у всех потомков (одна транзакция), операция `rename` на каталог. В коммите: REST Git Data — новое дерево с теми же blob SHA под новыми путями + удаления старых (без перезаливки содержимого). GraphQL здесь не используется.

## 9. Поллинг

`RemotePoller` (в приложении): интервал 5 с при активности (были операции/энумерации за последние 10 мин — расширение пишет `lastActivityAt` в App Group), иначе 30 с, после 2 ч простоя — 60 с. Условные запросы с ETag → 304 бесплатны по primary limit, но считаются в secondary (1 point) — при 10 репо × 12 req/мин = 120 points/мин, запас есть.

После собственного коммита — поллинг не нужен (headSHA уже обновлён), но ETag сбрасывается.

## 10. Полная ресинхронизация (`fullResync`)

Когда: `syncAnchorExpired`, `compare` truncated, ошибки целостности, кнопка «Resync» в меню.
Алгоритм: загрузить полное дерево head; построить map path→(sha, mode); сравнить с `items` (кроме pending/ignored); сгенерировать upsert/delete в `change_log`; `signalEnumerator`.
