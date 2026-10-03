# 04 — GitHub API: эндпоинты, лимиты, проверка возможностей

Базовый URL `https://api.github.com`. Заголовки на всех запросах:
```
Authorization: Bearer <token>
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2022-11-28
User-Agent: GitDocumentStorage/<version> (macOS)
```
GitHub Enterprise Server — не в v1 (но `GitHubClient` принимает `baseURL`).

## 1. Чтение

| Назначение | Запрос | Примечания |
|---|---|---|
| Текущий пользователь | `GET /user` | `login`, `id`, `name`, `avatar_url`; заголовок `X-OAuth-Scopes` (classic) |
| Репозиторий | `GET /repos/{o}/{r}` | `default_branch`, `permissions{pull,push,admin}`, `archived`, `disabled`, `size` (KB), `visibility` |
| Ветка | `GET /repos/{o}/{r}/branches/{b}` | `protected`, `commit.sha` |
| Защита ветки | `GET /repos/{o}/{r}/branches/{b}/protection` | 404 = не защищена; 403 без admin — считать «неизвестно» |
| HEAD ветки (поллинг) | `GET /repos/{o}/{r}/git/ref/heads/{b}` | `object.sha`; использовать `If-None-Match` |
| Коммит | `GET /repos/{o}/{r}/git/commits/{sha}` | `tree.sha`, `committer.date` |
| Дерево | `GET /repos/{o}/{r}/git/trees/{sha}?recursive=1` | `tree[]{path,mode,type,sha,size}`, `truncated` (лимит 100 000 записей / 7 MB) |
| Поддерево (fallback) | `GET /repos/{o}/{r}/git/trees/{sha}` | без `recursive` — поуровневый обход при `truncated` |
| Blob raw | `GET /repos/{o}/{r}/git/blobs/{sha}` с `Accept: application/vnd.github.raw+json` | до 100 MB, стримить в файл (`URLSession.download`) |
| Дифф | `GET /repos/{o}/{r}/compare/{base}...{head}` | `files[]{filename,status,previous_filename,sha}` ≤ 300 файлов; `commits[]`; постранично `per_page=250&page=N` для commits |
| Содержимое `.gitattributes` | `GET /repos/{o}/{r}/contents/.gitattributes` | детект LFS (`filter=lfs`) |
| Лимиты | `GET /rate_limit` | не тратит primary |
| Список репо пользователя | `GET /user/repos?per_page=100&sort=pushed&affiliation=owner,collaborator,organization_member` | для пикера при добавлении папки |

## 2. Запись

### 2.1 GraphQL `createCommitOnBranch` (основной путь для нового содержимого)
`POST https://api.github.com/graphql`
```graphql
mutation($input: CreateCommitOnBranchInput!) {
  createCommitOnBranch(input: $input) { commit { oid committedDate } }
}
```
```json
{ "input": {
    "branch": { "repositoryNameWithOwner": "o/r", "branchName": "main" },
    "expectedHeadOid": "<headSHA>",
    "message": { "headline": "Update Report.docx", "body": "…" },
    "fileChanges": {
      "additions": [ { "path": "docs/Report.docx", "contents": "<base64>" } ],
      "deletions": [ { "path": "old.txt" } ] } } }
```
- Ошибка `expectedHeadOid` mismatch приходит в `errors[]` с текстом вида «Expected branch to point to … but it did not» → трактовать как not-fast-forward.
- Удаление несуществующего пути → ошибка валидации всего коммита → перед отправкой сверять с `items`.
- **Лимиты размера тела официально не документированы.** Рабочие пороги (настраиваемые константы `CommitLimits`): ≤ 200 файлов, ≤ 10 MB на файл, ≤ 25 MB сырых байт на мутацию. Превышение → REST путь. Пороги уточняются в фазе 7 экспериментально.
- Коммит получает подпись GitHub (Verified), автор = пользователь токена.
- Создаёт ветку? Нет — ветка должна существовать. Пустой репозиторий → см. 2.3.

### 2.2 REST Git Data (большие файлы, rename/copy, удаления каталогов)
```
POST  /repos/{o}/{r}/git/blobs            { "content": "<base64>", "encoding": "base64" }      → sha   (≤ 100 MB)
POST  /repos/{o}/{r}/git/trees            { "base_tree": "<headTreeSHA>",
                                            "tree": [ {"path":"a/b.txt","mode":"100644","type":"blob","sha":"<sha>"},
                                                      {"path":"old.txt","mode":"100644","type":"blob","sha": null} ] }
POST  /repos/{o}/{r}/git/commits          { "message": "...", "tree": "<newTree>", "parents": ["<headSHA>"] }
PATCH /repos/{o}/{r}/git/refs/heads/{b}   { "sha": "<newCommit>", "force": false }   → 422 если не fast-forward
```
- `sha: null` в tree-entry удаляет путь. Для удаления каталога — перечислить все файлы внутри (есть в `items`).
- Для rename/copy — entry с существующим `sha`, содержимое не заливается.
- Вложенные пути в `tree[].path` допустимы с `base_tree` (GitHub сам создаёт промежуточные деревья).
- Автор/коммиттер по умолчанию — пользователь токена (`author` можно не передавать).

### 2.3 Пустой репозиторий
`GET git/ref/heads/{b}` → 409 `Git Repository is empty`. Первый файл: `PUT /repos/{o}/{r}/contents/{path}` `{ "message": "...", "content": "<base64>", "branch": "<b>" }` (создаст ветку). Если пользователь ещё ничего не положил, а папку открыл — показываем пустую папку; при первой записи используем Contents API, затем переключаемся на обычный путь.

### 2.4 Device Flow (см. `docs/05`)
```
POST https://github.com/login/device/code            client_id, scope=repo  (Accept: application/json)
POST https://github.com/login/oauth/access_token     client_id, device_code, grant_type=urn:ietf:params:oauth:grant-type:device_code
```

## 3. Лимиты и поведение `RateLimiter`

- Primary: 5000 req/ч на токен (GraphQL — отдельные 5000 points/ч). Условные GET с 304 **не** тратят primary.
- Secondary: ≤ 900 points/мин на REST-эндпоинт (GET = 1, мутация = 5 ⇒ ≤ 180 мутаций/мин); ≤ 2000 points/мин GraphQL; «≤ 80 content-generating запросов/мин и ≤ 500/ч» (формулировка GitHub размыта; считаем, что `createCommitOnBranch`/`git/commits` под неё попадают — это ещё один довод батчить коммиты).
- Реакция на 403/429: `retry-after` → ждать ровно столько; `x-ratelimit-remaining: 0` → ждать до `x-ratelimit-reset`; иначе ≥ 60 с с экспонентой (60, 120, 240… до 15 мин). Параллельно показывать в меню «GitHub rate limit — resuming in N min».
- Параллелизм: чтение blob — 6 на домен; загрузка blob — 4 на домен; мутации — строго последовательно на домен (иначе `expectedHeadOid` конфликтует сам с собой).
- Прогнозная оценка для UI: батч из N новых файлов по REST ≈ N/3 с; по GraphQL ≈ 1–3 с на мутацию.

## 4. Выбор стратегии коммита (`CommitStrategySelector`)

```
если батч содержит только additions с новым содержимым и/или deletions,
   и файлов ≤ 200, и каждый ≤ 10 MB, и сумма ≤ 25 MB         → GraphQL
иначе (есть rename/copy, файлы крупнее, батч больше)           → REST Git Data
если репозиторий пуст                                          → Contents API для первого файла
```
Батч больше лимитов GraphQL, но без rename → можно разбить на несколько GraphQL-мутаций подряд (каждая с обновлённым `expectedHeadOid`); это даёт несколько коммитов, что допустимо.

## 5. Проверка возможностей репозитория («пинг» при добавлении) — `CapabilityChecker`

Для каждого кандидата-аккаунта последовательно:

| Шаг | Запрос | Исход |
|---|---|---|
| 1 | `GET /repos/{o}/{r}` | 404/401 → `unavailable(noAccess)`; `archived`/`disabled` → `readOnly(archived)`; `permissions.push == false` → `readOnly(noPush)` |
| 2 | `GET /repos/{o}/{r}/branches/{default_branch}` | 404 (пустой репо) → `readWrite(emptyRepo)`; `protected == true` → шаг 3 |
| 3 | `GET …/branches/{b}/protection` | `required_pull_request_reviews` или `required_status_checks` или `enforce_admins` без обхода → `readOnly(protectedBranch)`; 403 → `readWrite(warning: unknownProtection)` |
| 4 | `GET …/contents/.gitattributes` | содержит `filter=lfs` → warning `lfsDetected` |
| 5 | `GET git/trees/{sha}?recursive=1` (только `truncated` и count) | `truncated` → warning `hugeTree`; count > 20 000 → warning `largeTree`; `size` > 2 GB → warning `largeRepo` |
| 6 | `GET /user` заголовок `X-OAuth-Scopes` (classic токены) | нет `repo` → `readOnly(tokenScope)` |
| 7 | заголовок `X-GitHub-SSO: required; …` на любом ответе | `unavailable(ssoRequired(url))` с кнопкой «Authorize SSO» |

Итог — `CapabilityReport { mode, reasons[], warnings[], account, defaultBranch, rateLimitRemaining }`.
UI показывает: «✅ Live sync (read & write)», «👁 Read-only: branch `main` is protected», «❌ No access with any of your accounts — sign in with another account». Приоритет выбора аккаунта: readWrite > readOnly > unavailable; при равенстве — тот, что добавлен раньше.

Повторная проверка выполняется: раз в сутки в фоне, при ошибке 401/403 во время работы, по кнопке «Check again».

## 6. Коды ошибок → поведение

| Ответ | Действие |
|---|---|
| 401 | Токен отозван → аккаунт `needsReauth`, все его домены `disconnect(reason: "Sign in again")`, уведомление |
| 403 + `X-GitHub-SSO` | показать SSO-подсказку |
| 403/429 rate limit | `RateLimiter` пауза |
| 404 на репо | домен `unavailable`, уведомление «Repository not found or access removed» |
| 409 empty repo | путь 2.3 |
| 422 not fast-forward | pull + retry |
| 422 validation (имя/путь/размер) | `upload_failed` на конкретных элементах с текстом ошибки |
| 5xx / сеть | backoff, pending остаются |
