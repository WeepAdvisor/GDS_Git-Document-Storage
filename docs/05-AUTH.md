# 05 — Аутентификация и аккаунты

## 1. Цель UX

Пользователь не знает слов «токен» и «scope». Сценарий: «Add folder» → вставил ссылку на репозиторий → если нужно,
нажал «Sign in with GitHub», увидел код `ABCD-1234`, браузер открылся сам, нажал Authorize → папка появилась.
Второй аккаунт — тот же сценарий, когда первый не имеет доступа к нужному репозиторию. Больше о аккаунтах думать не надо.

## 2. OAuth App + Device Flow

### Одноразовая подготовка (делает владелец проекта, не пользователь)
1. GitHub → Settings → Developer settings → OAuth Apps → New OAuth App.
   - Application name: `GitDocumentStorage`
   - Homepage URL: любой (репозиторий проекта)
   - Authorization callback URL: `http://127.0.0.1/unused` (Device Flow его не использует, но поле обязательное)
   - ✅ **Enable Device Flow**
2. Скопировать **Client ID** → `Config/Secrets.xcconfig` как `GITHUB_OAUTH_CLIENT_ID` (это публичное значение, секрет НЕ нужен и в приложении не хранится).

### Поток в приложении (`DeviceFlowAuthenticator`)
```
1. POST https://github.com/login/device/code
   body: client_id=<id>&scope=repo        Accept: application/json
   ← { device_code, user_code, verification_uri, expires_in (900), interval (5) }
2. UI: показать user_code крупно, кнопка «Copy & open GitHub» → NSWorkspace.open(verification_uri);
   user_code также кладём в буфер обмена автоматически.
3. Поллинг каждые `interval` с:
   POST https://github.com/login/oauth/access_token
   body: client_id, device_code, grant_type=urn:ietf:params:oauth:grant-type:device_code
   ← error: authorization_pending → ждать; slow_down → interval += 5; expired_token → начать заново; access_denied → отмена
   ← access_token, token_type=bearer, scope
4. GET /user → login, id, name, avatar → Account(id: "github.com:<login>")
5. Токен → Keychain (access group), Account → repos.json
```
Scope `repo` — единственный classic-scope, дающий запись в приватные репозитории. В UI честно пишем:
«GitDocumentStorage will be able to read and write repositories you have access to. You can revoke this anytime at github.com/settings/applications».

### Fallback: «Use a token instead»
Поле для вставки PAT. Поддерживаем classic (`repo`) и fine-grained (Repository permissions → Contents: Read and write, Metadata: Read). После вставки — `GET /user` для идентификации аккаунта; для fine-grained токенов проверка возможностей делается по факту (`permissions` в `GET /repos`).

## 3. Хранение

- Keychain item: `kSecClassGenericPassword`, `service = "GitDocumentStorage.github"`, `account = Account.id`,
  `kSecAttrAccessGroup = "$(AppIdentifierPrefix)<bundle>.shared"`, `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlock`.
- Один `TokenStore` (протокол) с реализациями `KeychainTokenStore` и `InMemoryTokenStore` (тесты).
- Оба процесса (приложение и расширение) имеют entitlement `keychain-access-groups` с этой группой.

## 4. Мультиаккаунт

- `Account` — список в настройках с аватаром/логином, кнопки «Sign out» (удаляет токен, домены этого аккаунта → `disconnect(reason: "Account signed out")`, папки остаются в списке с пометкой).
- `RepoConfig.accountID` — фиксированная привязка. Смена аккаунта для папки — в настройках папки («Use account…») с повторной проверкой возможностей.
- При добавлении папки `CapabilityChecker` перебирает все аккаунты и выбирает лучший (см. `docs/04` §5). Если несколько дают `readWrite` — берём первый добавленный, но показываем селектор.
- Один и тот же GitHub-пользователь не может быть добавлен дважды (ключ `login`).

## 5. Отзыв и ошибки

- 401 от API → `Account.state = .needsReauth`; меню показывает «⚠️ Sign in again as @login»; домены этого аккаунта отключены до повторного входа.
- SAML SSO (`X-GitHub-SSO: required; url=…`) → показать кнопку «Authorize for <org>» с открытием URL; после — «Check again».
- Пользователь отозвал OAuth App на GitHub — ловится тем же 401.

## 6. Безопасность

- Токен никогда не пишется в логи и UserDefaults.
- `NSAppTransportSecurity` — по умолчанию (только HTTPS).
- Device Flow не требует client secret, поэтому в бандле нет ничего секретного.
