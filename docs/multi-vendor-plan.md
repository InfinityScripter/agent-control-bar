# Другие агенты: план

Статус: черновик, 2026-11-13. Источники: t3code `10fbff5`, Orca `fde1ae7` (только чтение кода, ничего
не запускалось). Сравнение с Orca по жизненному циклу сессий — в
`.autopilot/2026-10-21-stale-sessions/orca-comparison.md`.

Обновление 2026-11-19. В 0.28.0 добавлена поддержка сервисов моделей внутри Claude Code и Codex.
Сервис определяется по адресу API в Claude Code или идентификатору провайдера в Codex. Агент
продолжает отвечать за состояние сессии и переход к ней. [Возможности в T3 Code](https://github.com/pingdotgg/t3code/blob/main/docs/orchestration-v2/README.md) · [Фильтры Herdr](https://github.com/herdrdev/herdr/blob/ee5bfb5041bb3e4a49d591c72308aae3c81ecdde/src/agent_view_eval.rs)

Баланс DeepSeek читается через официальный API. Для Z.ai используется маршрут официального
плагина Personal Coding Plan и схема Orca для защиты ключа и проверки актуальности ответа.
[DeepSeek](https://api-docs.deepseek.com/api/get-user-balance/) · [Плагин Z.ai](https://docs.z.ai/devpack/extension/usage-query-plugin) · [Реализация Orca](https://github.com/stablyai/orca/blob/6b2a4eb7e283be98a9eced1b4a268fa7c9e3dea9/src/main/rate-limits/providers/zcode/zcode-usage-fetcher.ts)

## Что взять у t3code и Orca

**t3code** сам запускает агентов и говорит с ними по протоколу (Claude Agent SDK, `codex app-server`,
ACP, HTTP OpenCode). Сессии, начатые в терминале пользователя, он не видит. Для строки меню, которая
наблюдает чужие сессии, эта модель не подходит. Из t3code берём только форму адаптера (у драйвера —
метаданные, снимок установки, необязательный читатель лимитов) и нормализацию лимитов в окна
`usedPercent` / `resetsAt`.

**Orca** наблюдает агентов, запущенных в его терминалах, и получает статус из управляемых хуков в
конфиге самого агента. Это та же модель, что у нас для Claude и Codex. Его PTY-правила и OSC 7501 нам
недоступны: терминал не наш.

Вывод: подключаем агента так же, как Codex — хук в его конфиге → `update.js --provider <id>` →
`~/.claude/control-bar/<id>/state.d/<session>.json` → Swift читает файл. Отдельный каталог на
провайдера, форма файла общая.

## Агенты по стоимости подключения

| Группа | Агенты | Что нужно |
|---|---|---|
| A. Хуки в формате Claude | Qwen Code (`~/.qwen/settings.json`), Factory Droid (`~/.factory/settings.json`), GitHub Copilot CLI (`~/.copilot/hooks/*.json`), Qoder, CodeBuddy, OpenClaude, Devin, Kimi, Grok, ZCode, Muse | Путь конфига, список событий, имя бинаря. Тот же stdin JSON (`session_id`, `cwd`, `tool_name`, `transcript_path`), тот же `update.js` |
| B. Свои события | Gemini CLI (`~/.gemini/settings.json`: BeforeAgent, AfterAgent, BeforeTool, AfterTool), Cursor Agent (`~/.cursor/hooks.json`: beforeSubmitPrompt, preToolUse, postToolUse, stop; хук обязан ответить JSON), Kiro, Jcode | Своя таблица «событие → наш глагол». Ожидание разрешения у Gemini и Cursor хуком не приходит — у Orca оно берётся с экрана, нам это недоступно |
| C. Плагин, а не хук | OpenCode (JS-плагин), Amp, Hermes, Pi | Свой файл плагина, который вызывает `update.js`. Отдельная работа на агента |
| D. Только процесс | Aider, Goose, Cline, Crush, Continue и др. | Хуков нет. Можно показать «запущен» по процессу, без состояния. Не делаем в первой волне |

У каждого нового агента свой источник показателей. Для этой части сначала проверяем официальный
контракт, вид ключа и доступность нужных показателей.

MCP-переключатели: ни t3code, ни Orca не умеют их для других агентов. Не входит.

## Волны

1. **Реестр провайдеров.** `Provider` становится таблицей: id, имя, значок, каталог состояния,
   конфиг, бинарь, `features` (limits, mcp, resetOdds). Claude и Codex — как сейчас. Новые агенты
   получают только сессии. В Node — тот же реестр: путь конфига, формат, события.
2. **Группа A + Gemini CLI.** Установка/снятие хуков (`install.js`, `uninstall.js`, только если
   каталог агента существует, чужие записи не трогаем, неизменённый файл не переписываем), разбор
   событий в `update.js`/`lifecycle.js`, тесты на каждый формат.
3. **Отображение.** Сессии новых агентов — в панели со своим значком. В строке меню — см. вопрос 2.
4. **Cursor Agent и OpenCode** (протокол ответа хука, плагин).
5. Лимиты по одному агенту, только по согласию пользователя в Settings.

## Открытые вопросы

1. Какие агенты в первой волне.
2. Как показывать новых агентов в строке меню: отдельный блок на агента, пока у него есть сессии,
   или общий блок «Other».
3. Шаблон PR говорит «Other agents are still out of scope» — поменять вместе с первой волной.

## Риски

- Схемы хуков у агентов не сверены с их документацией, только с кодом Orca. Перед каждой волной —
  проверка на живой установке агента.
- `AgentDisplay` сейчас enum из четырёх случаев с `both`; его придётся обобщить без потери
  сохранённого выбора пользователя.
- Swift собирается компилятором пользователя; каждая волна проходит `swift-6-0` в CI.
