# План: поддержка OpenAI Codex CLI в Control Bar

Цель — тот же набор функций, что уже есть для Claude Code, но для Codex: живые сессии
с состоянием (думает / инструмент / ждёт разрешения / idle), таймер хода и заполненность
контекста, клик по строке фокусирует терминал, «нужен ты» со звуком и жёлтой точкой,
лимиты аккаунта (5 часов / неделя) с временем сброса, уведомление о сбросе, и MCP-серверы
Codex с переключателями серверов и отдельных инструментов.

**Дизайн-макет** (панель: Sessions, MCP, Settings и три варианта полоски лимитов):
https://claude.ai/code/artifact/d6343b03-5742-40ae-b758-9e1588111b37

**Решение по шагу «Д» (2026-09-11).** Вариант полоски не выбирается за пользователя: в
Settings → Appearance → *Limits strip* стоит выбор **Two rows** (вариант A, по умолчанию) и
**Switcher** (вариант B). Вариант C (четыре ячейки в один ряд) отброшен — в него не помещаются
ни окно Fable, ни второе окно Codex. Почему именно так, и что взято у конкурентов, —
`docs/codex-landscape.md`, раздел «Что взято в код».

**Фаза 0 пройдена на живой машине (2026-09-13, codex-cli 0.154.0).** Что подтвердилось и что
в плане ниже оказалось неверным:

- **Подтверждено.** Хуки Codex срабатывают и отдают `session_id`, `cwd`, `transcript_path`,
  `model`, `permission_mode` (плюс `source` у `SessionStart`, `turn_id` и `prompt` у
  `UserPromptSubmit`, `reason` у `SessionEnd`). `process.ppid` в хуке — это **сам процесс
  `codex`** (`ps -o comm= -p $PPID` → `codex`), так что риск «родителем остаётся login shell»
  снят, и живость сессии считается так же, как у Claude. `codex mcp list --json` перечисляет
  и **выключенные** серверы (в отличие от `claude mcp list`), поэтому досинтезировать их из
  прошлого состояния не нужно; `codex mcp get --json` отдаёт `enabled_tools`/`disabled_tools`.
  `mcpServerStatus/list` у app-server отдаёт полные схемы инструментов и `pluginId`.
- **Неверно в §0.3b:** у `config/batchWrite` параметр называется `edits` (не `items`), а внутри
  — `keyPath`, `value` и **обязательный** `mergeStrategy`, всё в camelCase. Запрос со
  snake_case отвергается с `missing field 'mergeStrategy'`. Проверено записью в копию конфига:
  комментарии и чужие таблицы остаются на месте.
- **Неверно в §0.3a:** в таблице `threads` файла `state_5.sqlite` **нет** колонки `originator`.
  Есть `source`, `thread_source` (`user` / `subagent` / `guardian_review`), `cli_version`,
  `name`, `title`. Surface берётся из `originator` в **первой строке rollout**, а не из индекса;
  живые значения — `codex_cli_rs`, `codex_vscode`, `codex_work_desktop` / `Codex Desktop`,
  `codex_exec`.
- **Неверно в §0.2 (и это дало бы врущую цифру):** контекст сессии считается по
  `last_token_usage`, а **не** по `total_token_usage`. Второе — накопительный счёт за всё, что
  было оплачено: на живой 110-ходовой сессии он дошёл до 25 374 147 при окне 828 400, то есть
  любая сессия после нескольких ходов показывала бы 100 %. `last_token_usage.total_tokens` на
  той же сессии вырос с 60 тыс. до 323 тыс. и окна ни разу не превысил.
- **Реальные имена инструментов** в rollout'ах этой машины: `exec`, `js`, `spawn_agent`,
  `wait_agent`, `list_agents`, `followup_task`, `send_message`, `wait` — список `TOOL_LABELS`
  собран из них плюс реестра инструментов `openai/codex`.

**Отклонения от плана, сделанные сознательно:**

- **Второго писателя `codex/limits.json` не появилось.** План (§2.1, §2.2) предлагал писать его
  ещё и из хука; но лимиты и так лежат в свежем rollout, который `codex-limits` читает раз в
  пять минут, — второй писатель добавил бы согласование форматов и ни одного нового факта.
  Правило `.claude/rules/architecture.md` про единственного писателя осталось верным.
- **Отдельных `hooks/codex-install.js` и `codex/owner.json` тоже нет.** Установка живёт ветвью в
  `install.js` (как и предлагает §2.2 в качестве варианта), а аренда хуков одна на оба агента:
  `~/.codex/hooks.json` — единственный канал Codex, поэтому он ставится в обоих каналах, и
  предикат владения существует в одной копии, а не в четырёх.
- **События не переименовываются в коде.** Наш `hooks.json` для Codex сразу зовёт
  `update.js pre --provider codex`, поэтому карта «событие Codex → внутреннее слово» не нужна:
  `Interrupt` просто указывает на то же слово `stop`.

**Что уже в ветке** (шаг 5, частично; остальное по плану ниже):

- `scripts/mcpbar.py codex-limits` — лимиты Codex из свежего `rollout-*.jsonl` в
  `codex/limits.json`. Без токена, без сети, без запуска Codex. Эндпоинт `wham/usage` и
  app-server из §0.3 не тронуты: они нужны, когда сессий Codex не было совсем, и требуют
  живой проверки из фазы 0.
- Swift: `LimitsSet`/`NamedWindow` — провайдеро-независимые окна, полоска на два провайдера в
  двух раскладках, правило «снимок старше своего окна не показывается», фолбэк значка на Codex,
  когда у Claude цифр нет вовсе.
- **Сделано 2026-09-13 (шаги 1–3 и 6а–6б).** Сессии Codex: `--provider codex` у обоих хуков,
  установка хуков в `~/.codex/hooks.json` мержем, `codex/state.d/`, поля `provider`/`surface` в
  `Session`, ключ `"<provider>:<id>"` в карте сессий, жизненный цикл по двум процессам, глиф
  провайдера в строке. MCP Codex: `mcpbar.py codex-mcp refresh | toggle-server | toggle-tool`,
  `codex/mcp.json` в форме `mcp.json`, второй `MCPModel`, группы *Codex · config.toml* и
  *Codex · plugins* во вкладке MCP, маршрутизация переключателей по провайдеру, тумблер
  *Codex MCP servers*.
- Не сделано и остаётся по плану: опрос эндпоинта `wham/usage` (шаг 5 целиком — нужен, только
  когда сессий Codex не было совсем), уведомление о сбросе лимита (шаг 6), настройка «лимиты в
  значке» (сейчас значок падает на Codex сам, когда у Claude цифр нет), деградированный режим
  `notify` для старых сборок Codex.

Факты про Codex ниже сверены с исходниками `openai/codex` (коммит `9469737`, 2026-09-10,
crates `codex-rs/hooks`, `codex-rs/rollout`, `codex-rs/protocol`, `codex-rs/backend-client`,
`codex-rs/app-server-protocol`). Что не проверено на живой машине — помечено «проверить».

## 0. Что даёт Codex (источники данных)

### 0.1 Lifecycle-хуки — основной источник состояния сессии

Codex CLI имеет систему хуков, почти зеркальную Claude Code. Это главная удача: слой
Node-хуков переиспользуется почти целиком.

- **Где объявляются.** `~/.codex/hooks.json` (пользовательский слой),
  `<проект>/.codex/hooks.json` (проектный) и секция `[hooks]` в `~/.codex/config.toml`.
  Формат JSON тот же, что у Claude Code:
  `{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "…"}]}]}}`,
  с `matcher`, `timeout` (по умолчанию 600 с), `async`.
- **События.** `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
  `PermissionRequest`, `Stop`, `SubagentStart`, `SubagentStop`, `PreCompact`, `PostCompact`,
  `Interrupt`. Событие `Notification` **отсутствует** — «нужен ты» берём из
  `PermissionRequest`. Бонус, которого нет у Claude: `Interrupt` фиксирует Esc явно, значит
  «сеть по маркеру прерывания в транскрипте» для Codex не нужна.
- **Payload на stdin (JSON).** Общие поля: `session_id`, `cwd`, `hook_event_name`, `model`,
  `permission_mode`, `transcript_path` (nullable), `turn_id`. Инструментные события добавляют
  `tool_name`, `tool_input`, `tool_use_id`, `tool_response`, а также `agent_id` / `agent_type`
  (субагенты — их надо игнорировать при расчёте состояния корневой сессии).
  `SessionStart.source` ∈ `startup | resume | clear | compact | fork`, `SessionEnd.reason`,
  `Stop.last_assistant_message`, `Stop.stop_hook_active`. Хуки включены по умолчанию
  (`[features] hooks = true`). Официальная документация: https://learn.chatgpt.com/docs/hooks.
- **Таймауты.** По умолчанию 600 с, но `SessionEnd` и `Interrupt` — **1 с (максимум 3 с)**.
  Значит `lifecycle.js end` для Codex обязан быть мгновенным: никакого `pgrep`, никакого
  обхода `state.d` — только удалить свой файл; reap мёртвых сессий переносится на `start`
  и в приложение (оно и так чистит по pid).
- **Окружение хука.** Команда запускается через `$SHELL -lc` (login shell, PATH пользователя
  подхватывается сам — фикс с `/opt/homebrew/bin` в Claude-хуках здесь не критичен, но
  оставляем для симметрии), `cwd` = cwd сессии, env — **снимок env сессии на старте**, не живой
  env процесса. `TERM_PROGRAM` и `__CFBundleIdentifier` в снимке есть, значит фокус терминала
  по клику работает так же.
- **Доверие (trust) — ключевое отличие.** Хук из пользовательского/проектного слоя
  исполняется только со статусом `Trusted`: в `config.toml` должна лежать запись
  `[hooks.state."<key>"] trusted_hash = "<hash>"` с хэшем нормализованного описания хука.
  При первом запуске TUI показывает экран ревью незнакомых хуков (`startup_hooks_review.rs`),
  и пользователь подтверждает их один раз; хэш пишется через app-server `config/batchWrite`.
  Есть флаг `--dangerously-bypass-hook-trust` и `allow_managed_hooks_only` для админов.
  **Решение:** установщик не подделывает `trusted_hash` (это обход защитного механизма и
  зависимость от внутреннего алгоритма хэширования), а пишет `hooks.json` и документирует
  одноразовое подтверждение в Codex. Изменение команды хука (апгрейд плагина) = новый хэш =
  повторный вопрос — учесть в CHANGELOG/TROUBLESHOOTING.
- **Legacy `notify`.** Старая опция `notify = ["…"]` в `config.toml` жива
  (`legacy_notify.rs`), шлёт один JSON-аргумент `{"type":"agent-turn-complete",
  "thread-id","turn-id","cwd","input-messages","last-assistant-message"}` только по концу хода.
  Для версий Codex без хуков этого хватит на «idle/готово», но не на «думает» и «ждёт
  разрешения». Поддерживать как деградированный режим только если проверка (§1) покажет, что
  у пользователей массово старые версии; иначе — не тратить время.

### 0.2 Rollout-файл (транскрипт) — контекст, лимиты, «стриминг жив»

- Путь: `~/.codex/sessions/YYYY/MM/DD/rollout-<YYYY-MM-DDTHH-MM-SS>-<thread_id>.jsonl`;
  архив — `~/.codex/archived_sessions/`. Старые файлы могут быть сжаты в `.jsonl.zst`
  (`compression.rs`) — активный файл всегда plain JSONL, так что хвост читать можно, но
  «поиск по архиву» в план не входит.
- Строка: `{"timestamp": "<RFC3339>", "type": "<tag>", "payload": {…}}`; `type` ∈
  `session_meta | response_item | turn_context | event_msg | compacted | …`.
- Первая строка — `session_meta` (`id`, `session_id`, `timestamp`, `cwd`, `git` с
  `branch` и `commit_hash`, `originator`, `cli_version`, `source`, `model_provider`,
  `context_window`; у субагентов — `agent_nickname`/`agent_role`). `originator` различает
  surface: `codex_cli_rs` (CLI), `codex_vscode` (IDE-расширение), `codex_work_desktop`
  (desktop-приложение); `source` у IDE и desktop одинаково `vscode`, у `codex exec` — `exec`.
- `turn_context` несёт `model`, `approval_policy`, `sandbox_policy`, `cwd` текущего хода —
  модель сессии брать отсюда, а не из `session_meta`.
- Дальше `event_msg` записи; в rollout **сохраняются** `token_count`, `task_started`
  (wire-имя `TurnStarted`; несёт `turn_id`, `started_at`, `model_context_window`),
  `task_complete` (`last_agent_message`, `duration_ms`), `turn_aborted`, `user_message`,
  `agent_message` (`policy.rs::should_persist_event_msg`). **Не сохраняются**:
  `exec_command_begin/end`, `exec_approval_request`, `apply_patch_approval_request`,
  `request_permissions`. Вывод: «ждёт разрешения» из файла **не читается вообще** — только
  хук `PermissionRequest`. «Ход идёт» из файла читается: последний `task_started` без
  парного `task_complete`/`turn_aborted`.
- `token_count` несёт два нужных блока:
  - `info` (`TokenUsageInfo`): `total_token_usage` / `last_token_usage` (`input_tokens`,
    `cached_input_tokens`, `cache_write_input_tokens`, `output_tokens`,
    `reasoning_output_tokens`) и `model_context_window` → процент контекста сессии. Считать так же, как `contextOf()` в `hooks/update.js`: хвост файла, последняя
    запись, `clamp(round(used / window * 100))`. Окно модели даётся самим Codex — гадать по
    семейству модели, как для Claude, не придётся.
  - `rate_limits` (`RateLimitSnapshot`): `primary` и `secondary` окна
    (`used_percent: f64`, `window_minutes`, `resets_at` epoch-секунды), `credits`
    (`has_credits`, `unlimited`, `balance`), `plan_type`, `limit_id`/`limit_name`
    (в т.ч. отдельные квоты моделей), `spend_control_reached`, `rate_limit_reached_type`.
    Это аналог statusLine-перехвата у Claude, но **без установки statusLine**: любой живой
    rollout уже содержит свежие лимиты после каждого ответа модели.
- mtime файла = «модель стримит» — та же сеть проверки живости, что `turnFacts` в
  `Sessions.swift`, переносится один в один.

### 0.3 Лимиты без сессии — эндпоинт и app-server

Когда ни одна сессия Codex не открыта, rollout не обновляется. Два пути:

1. **Backend-эндпоинт** (`backend-client/src/client.rs::get_rate_limits_many`,
   `client/rate_limit_resets.rs`): `GET https://chatgpt.com/backend-api/wham/usage`
   (API-key-вариант `…/api/codex/usage`); сам Codex TUI опрашивает его примерно раз в минуту.
   Заголовки: `Authorization: Bearer <access_token>`, `ChatGPT-Account-Id: <account_id>`,
   `User-Agent: codex-cli`. Ответ `RateLimitStatusPayload`: `plan_type`,
   `rate_limit.primary_window/secondary_window` (`used_percent`, `limit_window_seconds`,
   `reset_after_seconds`, `reset_at`), `additional_rate_limits[]` (`limit_name`,
   `metered_feature`), `credits`, `spend_control`, `rate_limit_reached_type`. На Free-плане
   `secondary_window` может быть `null` — окно пропускать, не рисовать нулём.
   Токен — `~/.codex/auth.json`: `{"OPENAI_API_KEY", "tokens": {"id_token", "access_token",
   "refresh_token", "account_id"}, "last_refresh"}`; тип плана — claim `chatgpt_plan_type` в
   `id_token`. Refresh-токеном **не пользоваться** и в `auth.json` не писать: при 401 молчать,
   Codex обновит запись сам при следующем запуске (та же политика, что `oauth_token()` для
   Claude). Форму ответа всё равно **проверить** живым запросом (§1).
2. **`codex app-server`** (JSON-RPC по stdio): метод `account/rateLimits/read`, уведомление
   `account/rateLimits/updated`, `thread/list`. Не надо реализовывать auth и refresh
   токена — этим занимается сам Codex. Цена — запуск тяжёлого процесса на каждый опрос.

**Решение:** порядок источников для лимитов Codex — rollout-хвост (бесплатно, всегда) →
эндпоинт раз в 5 минут (опционально, отдельный тумблер в Settings, как `oauthLimits`) →
app-server как запасной путь, если эндпоинт окажется нестабильным или сменит форму.

### 0.3a Индекс потоков — дешёвый список сессий без разбора JSONL

`~/.codex/state_5.sqlite` (WAL, таблица `threads`: `id`, `rollout_path`, `cwd`, `git_branch`,
`title`, `name`, `model`, `originator`, `source`, `updated_at_ms`, `archived`, …) и
`~/.codex/session_index.jsonl` (`{"id", "thread_name", "updated_at"}` — имена потоков).
Для панели это источник **названия** сессии (у Claude такого нет) и ветки без чтения
`.git/HEAD`. Открывать только на чтение (`sqlite3` в системном Python есть); номер в имени
файла (`state_5`) — версия схемы, при переименовании молча деградировать до rollout.
Живость и состояние из индекса не берутся — только из хуков и pid.

### 0.3b MCP-серверы Codex

- **Где живут.** `~/.codex/config.toml`, таблица `[mcp_servers.<name>]`: транспорт
  (`command`/`args`/`env` для stdio, `url` для streamable HTTP), `enabled = true|false`,
  `enabled_tools = [...]` (allow-list), `disabled_tools = [...]` (deny-list, применяется после
  allow-list), `startup_timeout_sec`, per-tool политики. Плагины Codex добавляют свои серверы,
  а пользовательский `[plugins.<id>.mcp_servers.<name>]` несёт те же `enabled` /
  `enabled_tools` / `disabled_tools` поверх них. Проектный `.codex/config.toml` — второй слой.
- **Чтение.** `codex mcp list --json` (поля `name`, `enabled`, транспорт, `auth_status`) и
  `codex mcp get <name> --json` (`enabled`, `enabled_tools`, `disabled_tools`). Живой статус и
  список инструментов — app-server `mcpServerStatus/list` (`runtime_status`, `tools{}`,
  `tools_error`, `auth_status`, `plugin_id`). Это аналог `claude mcp list` + JSON-RPC-опроса
  `ask_server_for_tools` в `mcpbar.py`, только Codex сам поднимает серверы — нам их
  запускать не надо.
- **Запись.** Системный `/usr/bin/python3` на macOS — 3.9, `tomllib` в нём нет, а писать TOML
  руками (сохраняя комментарии и чужие таблицы) — ровно та ошибка, которую `mcpbar.py`
  избегает для `settings.json` бэкапами и локом. Поэтому переключатели пишут через сам Codex:
  app-server `config/batchWrite` (`key_path` = `mcp_servers.<name>.enabled` или
  `mcp_servers.<name>.disabled_tools`, `merge_strategy: upsert`) — тот же механизм, которым
  TUI сохраняет доверие хуков. Так формат файла остаётся за Codex. Запасной вариант —
  `config/value/write`.
- **Имена инструментов** в хуках и транскриптах: `mcp__<server>__<tool>` — тот же префикс,
  что у Claude, значит `tool_prefix()`/`TOOL_LABELS` работают без правок.
- **OAuth-серверы**: `auth_status` ≠ authorized → строка показывает `codex mcp login` вместо
  счётчика инструментов (макет, вкладка MCP).
- **Применение**: как и у Claude, набор серверов строится на старте сессии — заголовок группы
  честно говорит «applies next session».

### 0.4 Процесс и surface

- Бинарь называется `codex` (`[[bin]] name = "codex"`; npm-обёртка `codex.js` exec'ает
  нативный `@openai/codex-darwin-*`). Значит `RunningProcesses.exists(named: "codex")` и
  `pgrep -x codex` работают как для `claude`.
- Хук порождается процессом Codex; `process.ppid` в хуке = pid сессии (TUI держит app-server
  in-process, `AppServerClient::InProcess`). **Проверить** на macOS, что ppid — именно
  `codex`, а не промежуточный `sh -lc` (login shell может остаться родителем; тогда брать
  `ppid` родителя или читать `/proc`-аналог через `ps -o ppid=`).
- Surface: терминал (`TERM_PROGRAM`, `__CFBundleIdentifier`), IDE-расширение Codex,
  desktop-приложение Codex, `codex exec` (неинтерактивный режим — хуки те же, разрешений не
  спрашивает). Бейдж: `CLI` / `IDE` / `APP` / `EXEC` — по `originator` из `session_meta`
  (или по `source` хука `SessionStart` + `__CFBundleIdentifier`).
- **Desktop-приложение и IDE-расширение Codex** встраивают тот же app-server и пишут в тот же
  `~/.codex/` (rollout, `state_5.sqlite`, `auth.json`, `config.toml`, `hooks.json`). Значит
  одни хуки покрывают все три surface, отдельного хранилища вроде
  `~/Library/Application Support/Claude/claude-code-sessions` искать не нужно. Deep link для
  фокуса конкретного потока в desktop-приложении не найден — клик по строке `APP` просто
  активирует приложение (**проверить** в фазе 0, есть ли URL-схема).
- При установке через npm родитель `codex` — процесс `node` с `codex.js`; сам процесс сессии
  всё равно называется `codex`, `pgrep -x codex` не страдает.
- Дочерним процессам инструментов Codex выставляет `CODEX_SESSION_ID`, `CODEX_THREAD_ID`,
  `CODEX_SANDBOX`; в env хука их нет — id берётся из payload.

## 1. Фаза 0 — проверка на живой машине (≈1 день)

До кода — на Mac с установленным Codex:

1. `~/.codex/hooks.json` с одним `SessionStart`-хуком `cat > /tmp/codex-hook.json`;
   запустить `codex`, пройти экран доверия, убедиться, что файл записан. Снять реальные
   payload'ы всех событий (`UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `Stop`,
   `Interrupt`, `SessionEnd`) — они станут фикстурами тестов.
2. Проверить `process.ppid` из хука и имя процесса (`ps -o comm= -p $PPID`).
3. Открыть rollout сессии, подтвердить строки `token_count` с `rate_limits` и `info`,
   и первую строку `session_meta`. Зафиксировать реальные имена полей (snake_case,
   формат `timestamp`).
4. Один запрос к usage-эндпоинту с токеном из `auth.json` через `curl`: путь, заголовки,
   форма ответа. Один вызов `codex app-server` с `account/rateLimits/read`.
5. Проверить `codex --version` → минимальная поддерживаемая версия (та, где появились хуки).

Выход фазы: `tests/fixtures/codex/*.json` и уточнённый §0. Если что-то не сходится —
править план, не код.

## 2. Архитектура: один app, измерение «provider»

Вариант A (рекомендуется): в том же приложении добавить измерение провайдера. Один значок в
меню-баре, один жизненный цикл, одна панель. Вариант B — отдельный fork «Codex Control Bar» —
дублирует 10 тыс. строк ради другого бинаря и заставляет держать два значка.

Примечание: `.github/pull_request_template.md` сейчас объявляет Codex вне скоупа проекта.
Раз это меняется, шаблон и CONTRIBUTING.md обновить в той же серии PR, иначе внешние
контрибьюторы будут получать противоречивые сигналы.

### 2.1 Контракт файлов состояния (расширение `.claude/rules/` — слои и владельцы)

Корень остаётся `~/.claude/control-bar/` (единственный владелец путей — `main.swift`).
Codex получает подкаталог, чтобы не трогать существующие контракты с двумя писателями:

| Файл | Писатель | Аналог для Claude |
|---|---|---|
| `codex/state.d/<session_id>.json` | `hooks/update.js --provider codex` | `state.d/` |
| `codex/context.d/<session_id>.json` | не нужен: контекст берётся из rollout прямо в хуке | `context.d/` (statusline.py) |
| `codex/limits.json` | `hooks/update.js` (из `token_count.rate_limits`) и `scripts/mcpbar.py codex-limits` (эндпоинт) — двойной писатель, формат согласован | `limits.json` |
| `codex/owner.json` | `hooks/codex-install.js` | `owner.json` |

Форма `state.d/<id>.json` — та же, что у Claude, плюс `provider: "codex"`, `surface`
(`cli|ide|app|exec`), `permissionMode`. Значения `state` — те же строки
`idle|thinking|tool|permission|done`. Так `Session(json:)`, `SessionEngine`,
`PanelSession` и весь рендер получают Codex-сессии бесплатно.

Форма `codex/limits.json`:
```json
{
  "ts": 1789000000, "source": "rollout",
  "five_hour": {"used_percentage": 42, "resets_at": 1789012345, "window_minutes": 300},
  "seven_day": {"used_percentage": 84, "resets_at": 1789500000, "window_minutes": 10080},
  "plan": "pro", "credits": {"has": true, "unlimited": false, "balance": "9.99"},
  "reached": null
}
```
`primary` → `five_hour`, `secondary` → `seven_day` **по `window_minutes`, а не по позиции**
(окна приходят как «первичное/вторичное», их длительность — факт из payload; на планах с
другими окнами имя строки в панели тоже берётся из `window_minutes`: «5h», «1d», «7d»).
`used_percentage` — `int(round(...))`, как везде: Swift читает `as? Int`.
`additional_rate_limits` (квоты отдельных моделей) — в массив `extra: [{name, used_percentage,
resets_at}]`, панель рисует их как строку «Fable · 7d» у Claude.

### 2.2 Слой Node-хуков

- `hooks/update.js`: аргумент `--provider codex` (позиционный `event` остаётся). Различия
  внутри одного файла, не второй файл — иначе исправления в одном хуке перестанут попадать во
  второй, а копирование в `~/.claude/control-bar/` уже устроено под один `update.js`:
  - карта событий Codex → внутренние: `UserPromptSubmit→prompt`, `PreToolUse→pre`,
    `PostToolUse→post`, `PermissionRequest→permreq`, `Stop→stop`, `Interrupt→stop`
    (state `done`), `SubagentStart/Stop` — игнорировать; записи с `agent_id` не корневого
    агента — игнорировать (иначе субагент «думает» перекроет «ждёт разрешения» родителя);
  - `TOOL_LABELS` для имён инструментов Codex (по `core/src/tools`: `shell`,
    `shell_command`, `exec_command`, `write_stdin`, `unified_exec` → «Running command»;
    `apply_patch` → «Editing»; `read_file` → «Reading»; `web_search` → «Searching web»;
    `view_image`, `update_plan` → «Planning»; `spawn_agent` → «Delegating»; MCP-инструменты
    — по префиксу; итоговый список сверить с фикстурами фазы 0);
  - контекст: `contextOf()` получает второй парсер — последняя строка с `"token_count"`,
    `info.total_token_usage` и `info.model_context_window`. Окно известно точно →
    `assumed: false`;
  - лимиты: из той же записи `rate_limits` → `codex/limits.json` с правилом «не
    перезаписывать одинаковую запись чаще раза в минуту» (копия логики `capture_limits` из
    `hooks/statusline.py`);
  - self-heal: `pgrep -x ClaudeControlBar` + `open -b` — без изменений.
- `hooks/lifecycle.js --provider codex`: `start`/`end` пишут/чистят `codex/state.d/`,
  reap по pid тот же.
- `hooks/codex-install.js` / `codex-uninstall.js` (или ветка в `install.js` по флагу):
  мерж в `~/.codex/hooks.json` без затирания чужих хуков, владение по пути скрипта (тот же
  предикат `pointsAt`, что в `install.js`; держать три копии предиката в шаге — теперь
  четыре). Не трогать `config.toml` — trust пусть выдаёт сам Codex. `bootstrap.py`
  (SessionStart Claude) вызывает установку Codex-хуков только если `~/.codex/` существует —
  у пользователя без Codex ничего нового не появляется.
- Идемпотентность, `try/catch → null`, атомарная запись с `0o600` — по code-conventions без
  исключений.

### 2.3 Слой Python (`scripts/mcpbar.py`)

- Команда `codex-limits`: токен из `~/.codex/auth.json` (проверка `expires`/refresh не
  делать — при 401 молчать и не трогать файл, как `fetch_limits`), запрет редиректов
  (тот же `NoRedirect`), запись `codex/limits.json` с `source: "oauth"`. Маппер
  `codex_usage_record(payload)` — чистая функция для тестов, по образцу `usage_record`.
- Запасной путь `codex-limits --app-server`: `codex app-server` как подпроцесс,
  `initialize` → `account/rateLimits/read` → exit; таймаут 20 с.
- `report`/`doctor`: секция Codex (версия `codex`, наличие `hooks.json`, статус доверия по
  `hooks.state` в `config.toml` — только чтение, число живых сессий).
- Команда `codex-mcp refresh`: `codex mcp list --json` + `mcpServerStatus/list` через
  app-server → `codex/mcp.json` той же формы, что `mcp.json` (сервер: `state`, `tools[]` с
  `enabled`, `auth`, `plugin`), чтобы `MCPModel` читал оба файла одним парсером.
  `codex-mcp toggle-server <name> --off` и `toggle-tool --server <s> --tool <t> --off` —
  через `config/batchWrite` (§0.3b); после записи — `refresh`, не ручная правка `codex/mcp.json`.
  Лок и бэкап `config.toml` перед первой записью — как `backup_settings()`.

### 2.4 Слой Swift

- `Session`: поле `provider` (строка, `"claude"` по умолчанию для старых файлов), `surface`.
  `main.swift` сканирует два каталога `state.d/` и `codex/state.d/`; ключ словаря
  `sessions` — `"<provider>:<id>"`, чтобы одинаковые id не столкнулись.
- `Limits`: сегодня это три фиксированных окна. Делать `Limits` провайдеро-независимым:
  `struct LimitsSet { let provider: String; let windows: [LimitWindow]; plan; credits; ts;
  source }`, где `LimitWindow` получает `title` из `window_minutes`. Существующий парсер
  Claude превращается в первый адаптер, Codex — второй. Загрузка через тот же mtime-гейт
  (`loadLimits`).
- `PanelData.panelLimits`: две группы с заголовком-провайдером; провайдер без данных
  скрывается целиком, а не рисует пустые бары. Сброс: `resets` уже считается; добавить
  `resetSoon` (<15 мин) для подсветки.
- `Gauge` (иконка): сегодня две дуги 5h/7d Claude. Правило: показывать провайдер **ведущей
  сессии** (та, что даёт состояние иконке); когда сессий нет — тот, чьи данные свежее.
  Переключатель в Settings «Лимиты в значке: Claude / Codex / ведущей сессии».
- `SessionLabels.surfaceTag`: Codex-строка получает пилюлю провайдера (маленький глиф
  рядом с `CLI/IDE/APP/EXEC`), чтобы два `myrepo` из разных агентов различались.
- `Actions.openSession`: терминальные сессии — без изменений (по `term_bundle`). IDE и
  desktop-приложение Codex — по результатам фазы 0 (deep link, если есть; иначе просто
  активировать приложение).
- `checkLifecycle`: «нужен ли app» — если жив `claude` **или** `codex`; `claudeCodeRunning()`
  становится `agentRunning()` с двумя именами.
- «Нужен ты»: `NeedsYouSound.shouldCue` уже работает по `state == "permission"` и
  `termBundle` — переносится без правок. Уведомление о **сбросе лимита**: новое, для обоих
  провайдеров — когда окно, бывшее ≥ 90 %, обнуляется (или `resets_at` прошёл), одно
  `UNUserNotification` «Codex: 5-часовое окно сброшено». Тумблер в Settings, по умолчанию
  выключен.
- `CrabMood`: считает работающие сессии всех провайдеров вместе (краб один).
- Вкладка MCP: `MCPModel` получает второй путь (`codex/mcp.json`) и поле `provider` у
  сервера; `PanelData.panelServer` группирует «Claude · Local config / From plugins /
  connectors» и «Codex · config.toml / plugins». `PanelStore.setServer/setTool` маршрутизируют
  по провайдеру в `mcpbar.py toggle-*` или `codex-mcp toggle-*`. Иконка «открыть конфиг» в
  заголовке открывает `settings.json` или `config.toml` по последней раскрытой группе.
  Счётчик на вкладке и строка «N of M connected» — суммарные по обоим провайдерам.

### 2.5 Настройки

Settings → General, две новые секции (макет «Settings»): **Codex** — «Track Codex sessions»
(ставит/снимает хуки), «Poll Codex usage» (аналог `oauthLimits`), «Manage Codex MCP servers»;
**Limits** — «Windows in the menu bar icon: Claude / Codex / Lead», «Notify when a window
resets». Ключи UserDefaults: `codexEnabled`, `codexLimitsPoll`, `codexMCP`, `iconLimits`,
`limitResetNotify`.

## 3. Порядок работ и оценка

| # | Шаг | Результат | Оценка |
|---|---|---|---|
| Д | Утвердить дизайн по макету: вариант полоски лимитов (A/B/C), группировка сессий по провайдеру, группа Codex в MCP | решения зафиксированы в `docs/` рядом с `panel-design.html` | 0.5 д |
| 0 | Фаза 0: проверка на Mac | фикстуры, уточнённый §0, минимальная версия Codex; плюс `codex mcp list --json` и `config/batchWrite` на живом конфиге | 1.5 д |
| 1 | `update.js`/`lifecycle.js` с `--provider codex`, парсер `token_count`, `codex/limits.json` | Codex-сессии появляются в `codex/state.d/` | 2 д |
| 2 | Установщик/деинсталлятор хуков Codex, `owner.json`, вызов из `bootstrap.py` | `codex` показывает экран доверия один раз, хуки живут | 1 д |
| 3 | Swift: `provider` в `Session`, второй каталог, ключ `provider:id`, lifecycle по двум процессам, пилюля провайдера | строки Codex в панели, «нужен ты», таймер, контекст | 2 д |
| 4 | Swift: `LimitsSet`, панель лимитов на два провайдера, Gauge по правилу ведущей сессии | лимиты Codex со сбросами в панели и значке | 2 д |
| 5 | Python: `codex-limits` (эндпоинт + app-server), `report`/`doctor` | лимиты без открытой сессии | 1–2 д |
| 6 | Уведомление о сбросе лимита (оба провайдера), тумблеры в Settings | — | 1 д |
| 6а | Python: `codex-mcp refresh/toggle-*` через `codex mcp` и app-server, `codex/mcp.json` | серверы и инструменты Codex читаются и переключаются | 2 д |
| 6б | Swift: `provider` в `MCPModel`, группы Codex во вкладке MCP, маршрутизация переключателей, открытие `config.toml` | вкладка MCP из макета | 2 д |
| 7 | Тесты: node (фикстуры Codex, merge в `hooks.json`), python (маппер usage, tail rollout, `codex-mcp` на фикстурах JSON), Swift model-check (`provider`, `LimitsSet`, MCP-группы), CI-гварды | зелёный CI | 2.5 д |
| 8 | Документация: README/README.ru, PRIVACY (чтение `auth.json` и `sessions/`), TROUBLESHOOTING (экран доверия, «хуки не запускаются» = не подтверждены), CHANGELOG, версия в трёх местах, PR-шаблон/CONTRIBUTING | релиз 0.15.0 | 1 д |

Итого ≈ 18–19 рабочих дней одной парой рук; шаги 1–2, 3–4 и 6а–6б можно вести
параллельно, так как границей между ними является только формат файлов из §2.1.

Порядок релизов: 0.15.0 — сессии + «нужен ты» + контекст (Д, 0–3, 7, 8 частично);
0.16.0 — лимиты и сбросы (4–6); 0.17.0 — MCP Codex (6а–6б). Так первая польза приходит
раньше, а два самых рискованных куска (эндпоинт и запись `config.toml`) не держат остальное.

## 4. Риски и как их гасим

- **Экран доверия хуков.** Пользователь может нажать «не доверять» — тогда сессий не будет,
  а приложение будет молчать. `doctor` и панель должны говорить прямо: «хуки Codex не
  подтверждены — запусти `codex` и подтверди» (читаем `hooks.state` в `config.toml`).
- **Скорость изменений Codex.** Имена полей rollout и эндпоинта могут дрейфовать. Все парсеры
  — «неожиданная форма = нет данных», не исключение (правило 6 code-conventions); прошлые
  цифры в файле не затираются.
- **ppid не равен процессу `codex`** (если login shell остаётся родителем). Решение в фазе 0;
  запасной вариант — `session_id` + `ps` один раз на `SessionStart`, дальше pid хранится в
  файле.
- **Субагенты** (`agent_id`): их события не должны менять состояние корневой сессии.
- **`permission_mode` full-auto / `codex exec`**: `PermissionRequest` не придёт никогда —
  это нормально, состояние живёт на `prompt/pre/post/stop`.
- **Сжатые rollout'ы (`.zst`)**: активный файл всегда plain; хвост читаем только у файла из
  `transcript_path` текущей сессии.
- **Privacy.** Хук читает `transcript_path` (только хвост, только числовые поля) и
  `auth.json` (только для запроса к OpenAI, только при включённом тумблере). Записать это в
  PRIVACY.md в той же формулировке, что уже есть для Claude.
- **Запись `config.toml`.** Только через app-server `config/batchWrite`; если фаза 0 покажет,
  что метод нестабилен, переключатели MCP Codex деградируют до «только чтение» с кнопкой
  «открыть config.toml» — не до ручного TOML-писателя. Запуск `codex app-server` на каждый
  переключатель — секунды; кэшировать процесс не пытаемся, это уже оптимизация.
- **Identity.** Никаких новых bundle id / имён — приложение остаётся одним; хуки Codex
  хардкодят те же identity-значения, что и Claude-хуки (гвард CI на `identity.env`
  расширить на новые файлы хуков).

## 5. Готовые инструменты — что у них можно подсмотреть

| Инструмент | Источник данных |
|---|---|
| [CodexBar](https://github.com/steipete/CodexBar) (Swift, menu bar) | `auth.json` → `/backend-api/wham/usage`; запасной путь `codex -s read-only -a never app-server` → `account/rateLimits/read`; стоимость из `sessions/**/*.jsonl` |
| [codex-gnome-extension](https://github.com/Almighty-Shogun/codex-gnome-extension) | Только локально: последний `token_count.rate_limits` из `~/.codex/sessions` раз в 30 с |
| [ccusage codex](https://ccusage.com/guide/codex/) | `sessions` + `archived_sessions`: `token_count` + `turn_context.model` |
| [CodexMonitor](https://github.com/Dimillian/CodexMonitor) | `codex app-server` на workspace: `thread/list`, `thread/resume`, `requestApproval` |
| [ClaudeBar](https://github.com/tddworks/ClaudeBar) | Мультипровайдерная полоска квот, включая Codex |

Подтверждает выбранный порядок источников: rollout → эндпоинт → app-server. «Ждёт
разрешения» для Codex уже показывают [codex-status-bar](https://github.com/KiwiGaze/codex-status-bar)
(хуки Codex → файлы состояния, та же схема, что здесь) и
[so-agentbar](https://sotthang.github.io/so-agentbar/); никто не совмещает это с лимитами двух
провайдеров и переключателями MCP в одной панели. Полный обзор и UI-идеи для макета —
`docs/codex-landscape.md`.

## 6. Что сознательно не входит

- Стоимость сессии в USD (Codex её не считает; показывать только токены).
- Поиск/возобновление архивных сессий (`archived_sessions`, `.zst`).
- Windows/Linux.
