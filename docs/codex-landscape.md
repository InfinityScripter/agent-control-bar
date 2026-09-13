# Похожие утилиты: что уже есть и что стоит взять

Обзор menu-bar / tray инструментов для Claude Code и Codex CLI по состоянию на сентябрь 2026.
Собран как контекст к `codex-support-plan.md`: где мы повторяем чужие решения, где отличаемся,
и какие UI-идеи стоит перенести в макет.

## 1. Сессии агентов и «ждёт разрешения»

Это наш главный сценарий, и здесь конкурентов мало.

| Инструмент | Агенты | Как узнаёт о сессии | «Нужен ты» |
|---|---|---|---|
| [codex-status-bar](https://github.com/KiwiGaze/codex-status-bar) (KiwiGaze) | Codex | **Хуки Codex пишут файлы состояния в `~/.codex/statusbar/states.d/`, приложение их читает** — та же архитектура, что у нас для Claude и в плане для Codex | Спиннер + подпись действия (`Editing`, `Running command`) + таймер; **янтарная точка при ожидании approval**; авто-выход после закрытия Codex |
| [so-agentbar](https://sotthang.github.io/so-agentbar/) | Claude (CLI, Xcode, Desktop, Cowork) + Codex (CLI, VS Code) | автодетект запущенных сессий | «Approval Detection»; бейдж происхождения (Code / Cowork / Xcode / Codex); субагенты свёрнуты под родителя с бейджем `×N`; клик открывает проект в редакторе/терминале |
| [AgentPeek](https://agentpeek.app/codex/) | Codex + Claude | локальные логи Codex | Сессии в «чёлке» по проекту, состояние, затронутые файлы; **⌘A approve / ⌘N deny** прямо из панели; Codex 7d рядом с Claude 5h/7d |
| [Vibe Island](https://vibeisland.app/) | 5 провайдеров | — | Строка лимитов над списком живых сессий; approve/deny; клик — в нужный таб терминала |
| [ClaudeBell](https://claude-bell.com/) | Claude | HTTP-хуки на localhost | **Панель отвечает на permission-запрос inline** (стрелки Allow/Deny/Dismiss, Return); ⌘⇧B |
| [claudecodenotify](https://github.com/narlei/claudecodenotify) | Claude | хуки | Плавающий баннер поверх fullscreen-приложений: оранжевый = permission, жёлтый = ждёт ввода, зелёный = готово |
| [Claude Code Notifier](https://claudecodenotifier.com/) | Claude | хуки | «Говорит, какая именно сессия нуждается в тебе»; **не шлёт уведомление, если терминал уже на переднем плане**; тихие часы; push на телефон |
| [gmr/claude-status](https://github.com/gmr/claude-status) | Claude | хуки | Сводный значок ⚡/⏳/💤; виджеты WidgetKit; клик фокусирует iTerm-таб, tmux-панель, VS Code, Zed; `/name-session` для имени сессии |
| [CodexBar](https://github.com/steipete/CodexBar) (design doc) | Codex / Claude / Pi | обнаружение процессов через libproc | Глифы `⌘` Codex, `✦` Claude, `π` Pi; клик по сессии — от PID к окну терминала; **ожидание approval сознательно вне скоупа** (issue #456, low priority) |
| [Dimillian/CodexMonitor](https://github.com/Dimillian/CodexMonitor) | Codex | `codex app-server` на workspace | Полноценный клиент, не menu bar: непрочитанные/бегущие потоки, approval внутри диалога |
| [Cocoanetics/CodexMonitor](https://github.com/Cocoanetics/CodexMonitor) | Codex | читает `~/.codex/sessions/` | Список недавних сессий, какие активны; approval не показывает |

Вывод. Для Codex «нужен ты» достигают тремя способами: хуки (KiwiGaze — наш путь), app-server
(Dimillian, AgentPeek) или эвристики по логам/PTY. Никто не совмещает это с переключателями
MCP и лимитами двух провайдеров в одной панели — это и есть наша ниша. Отдельно стоит взять:
**подавление уведомления, когда терминал уже впереди** (у нас есть для звука в
`NeedsYouSound.shouldCue`, распространить на macOS-уведомления), и **субагенты под родителем
с бейджем `×N`** (в Codex субагенты приходят с `agent_id`, см. план).

## 2. Лимиты нескольких провайдеров

| Инструмент | Что показывает | Раскладка провайдеров | Значок в баре |
|---|---|---|---|
| [CodexBar](https://github.com/steipete/CodexBar) (v0.56, 69 провайдеров) | 5h/неделя, per-model окна, кредиты, история стоимости, инциденты провайдера | По умолчанию **отдельный status item на провайдера**; «Merge Icons» = один значок + переключатель провайдера сверху меню, автовыбор самого загруженного | Двухполосный измеритель (сверху сессия, снизу неделя); редактор раскладки бара из «чипов» (процент, полоски, темп, прогноз исчерпания) и условных правил |
| [CodexBar-Win](https://github.com/babakarto/CodexBar-Win) | то же | **Две вкладки Claude / Codex**, значок перекрашивается по активной вкладке | цвет провайдера |
| [ClaudeBar](https://github.com/tddworks/ClaudeBar) (19 провайдеров) | сессия/неделя/модель, стоимость, время работы, статус провайдера | **Вкладка на провайдера**; отключённые провайдеры сжимают полосу вкладок и бар | `85% \| 4:59` (процент \| отсчёт) или несколько сегментов с логотипами |
| [ModelDeck](https://github.com/timharris707/modeldeck) | Claude Code + Codex CLI, мультиаккаунт, план (`Max 20x`, `Pro`) | **Две колонки Claude / Codex**, карточка на аккаунт, **заголовочная полоска по худшему окну**, окна раскрываются строками; сортировка по ближайшему сбросу / наименьшему остатку | Пустой глиф пока всё хорошо, золотой «% left» когда что-то низко, красный на критике |
| [claude-codex-limits](https://github.com/ArrivaRUS/claude-codex-limits) | Claude + Codex | Карточка на продукт с кольцевыми гейджами; per-model окно — своя пилюля | **«slash-раскладка»** `session% / weekly%` на строку продукта; пользователь выбирает, какое число с какой стороны |
| [claude-codex-battery](https://github.com/dennykim123/claude-codex-battery) | Claude + Codex | строка `Claude Code · % left 5h ▕████░░▏ 87% · resets 2h 36m` | Батарейки в баре с буквами `C` / `X` |
| [ai-usage-menubar](https://github.com/burakgon/ai-usage-menubar) | 7 провайдеров | переключение «осталось / использовано» | одна метрика — только число, несколько — с мини-подписями |
| [SessionWatcher](https://sessionwatcher.com/codex) (платный) | Claude + Codex, темп, история 7/90 дней | строки `CLAUDE 42% resets 2:48` / `CODEX 11% resets 4:48`; метки **On pace / Over rate** | `%` со стрелкой тренда ▲/▼ |
| [Claude-Usage-Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker) | Claude, Codex по профилям | 5 стилей значка × 3 цветовых режима; **сброс: время / остаток / оба** | — |
| [Usagebar](https://usagebar.com/) | Claude | — | **Рядом с лимитом бар показывает не процент, а время до открытия окна** |
| [RateTray](https://ratetray.nowrap.net/) (Windows) | Claude + Codex | значок на каждый лимит с числом внутри; цвет провайдера < 75 %, янтарный 75–89, красный ≥ 90 — «цвет второй канал, никогда единственный» | — |
| [claudeusagewin](https://github.com/sr-kai/claudeusagewin) (Windows) | Claude | **Белая засечка на дуге = прошедшее время окна**: сразу видно, опережаешь лимит или отстаёшь | — |
| [Quotio](https://github.com/nguyenphutrong/quotio) | много | это прокси с failover, не монитор | — |
| Statusline-однострочники ([ccusage](https://ccusage.com/guide/statusline), [claude-code-usage-bar](https://github.com/leeguooooo/claude-code-usage-bar), [ohugonnot](https://github.com/ohugonnot/claude-code-statusline)) | Claude | прогноз к концу окна `→NN%`, отсчёт `↻ 2h30m`, скорость `$0.12/hr` | — |
| Raycast [Agent Usage](https://www.raycast.com/thuggyduck/agent-usage), [ccusage](https://www.raycast.com/nyatinte/ccusage) | 19 агентов | список с раскрытием, ⚡ у активного аккаунта | — |

Как это делают сами провайдеры:

- **Codex `/status`**: `99% left (5h)`, `84% left (weekly)`; словарь «% left». Просят формат
  `5h 25% @11:36pm · weekly 18% @5/27 5:40am` — процент плюс **абсолютное локальное время**.
  Приложение Codex: `Usage remaining / 5h 77% / Weekly 94% / Reset credits / 1 reset available /
  Expires Jul 17, 2026`. Окна зависят от плана, 5h-окно может отсутствовать — окна надо
  моделировать списком, не парой.
- **Claude Code `/usage`**: словарь «% used», секции «Current session / Current week», сброс
  «Resets 1am (Asia/Bangkok)», фолбэк «Showing last-known usage» с возрастом данных.

## 3. Что стоит перенести в макет (по ценности для панели 300pt)

1. **Заголовочная полоска по худшему окну** (ModelDeck, CodexBar). У каждого провайдера одна
   главная полоска — самое загруженное окно, остальные раскрываются строками. Снимает вопрос
   «A/B/C» для полоски лимитов: два ряда по ~40pt вместо 96pt, и Fable/кредиты не теряются.
2. **Отсчёт вместо процента рядом с лимитом** (Usagebar). Когда окно ≥ 90 %, ячейка и значок
   показывают «41m», а не «94 %» — именно это число сейчас нужно.
3. **Засечка прошедшего времени на полоске** (claudeusagewin). Один штрих на баре показывает,
   опережает ли расход время окна. Дешевле любых «pace»-подписей.
4. **Сброс: отсчёт до суток, абсолютное время дальше** (ModelDeck): «2h 36m» для 5h,
   «Wed 5:59 PM» для недели. У нас уже так в `PanelData.until`; добавить абсолютное время в
   тултип.
5. **Уведомления только на переходах** (ModelDeck, ClaudeBar): пересечение порога и сброс окна,
   больше ничего; разные звуки для «сброс» и «упёрлись» (claude-codex-limits). Совпадает с
   тумблером «Notify when a window resets» в макете.
6. **Приоритет «ждёт разрешения» над «думает»** — у нас уже есть; для Codex переносится.
7. **Субагенты под родителем с бейджем `×N`** (so-agentbar) — Codex шлёт `agent_id`.
8. **Не уведомлять, если терминал уже впереди** (Claude Code Notifier) — распространить с
   звука на macOS-уведомления.
9. **Фолбэк «данные N мин назад»** как в `/usage` — у нас есть подпись «measured N min ago»,
   оставить.
10. **Кредиты и banked-сбросы Codex** с датой истечения (thrr87/codex-limits) — строка в
    раскрытой карточке Codex, не в главной полоске.
11. **Глобальная горячая клавиша** открыть панель (⌘U / ⌘⇧B у нескольких инструментов).
12. Не брать: редактор раскладки бара из чипов (CodexBar) — отдельный продукт; конфетти на
    сброс; отдельный status item на провайдера — два краба в баре хуже одного.

Источники: см. ссылки в таблицах; первичные — issues openai/codex
[#15281](https://github.com/openai/codex/issues/15281), [#24080](https://github.com/openai/codex/issues/24080),
[#28963](https://github.com/openai/codex/issues/28963), документация
[Claude Code costs](https://code.claude.com/docs/en/costs).

## 4. Что взято в код (2026-09-11)

Звёзды снимались 2026-09-11 через GitHub API, а не по памяти; раскладки — по README и
скриншотам. Две ссылки из первой редакции обзора поправлены: `ryoppippi/ccusage` переехал в
организацию (`ccusage/ccusage`, 18 491★), а `penicillin0/claude-code-statusline` не существует —
статуслайн с реальной аудиторией это `sirmalloc/ccstatusline` (12 834★).

Самые заметные из тех, кто решает ровно нашу задачу: `steipete/CodexBar` (21 246★),
`getagentseal/codeburn` (10 961★), `hamed-elfayome/Claude-Usage-Tracker` (3 468★),
`tddworks/ClaudeBar` (1 478★), `vinzdg/codenotch` (1 427★), `f-is-h/Usage4Claude` (387★),
`aqua5230/usage` (316★), `Nanako0129/TokenBar` (344★), `dennykim123/claude-codex-battery` (103★),
`timharris707/modeldeck` (83★), `burakgon/ai-usage-menubar` (23★).

Взято:

1. **Два ряда — раскладка по умолчанию.** Все, кто показывает двух провайдеров в узкой панели,
   именно стопкой: `aqua5230/usage`, `ai-usage-menubar`, `claude-codex-battery`. Обе панели с
   чистым переключателем (`ClaudeBar`, `CodexBar-Win`) теряют ответ на вопрос «где я вот-вот
   упрусь» — у скрытой вкладки нет ни числа, ни полоски. Показательно, что `CodexBar` при всём
   своём переключателе добавил вкладку **Overview**, и это ровно ряды.
2. **У переключателя под каждой вкладкой — волосяная полоска самого заполненного окна
   провайдера.** Так делает только `CodexBar` — и это единственное, что лечит слепое пятно
   второй вкладки. Наш `PanelLimitsLayout.switcher` без этой полоски не поставляется.
3. **Провайдер без цифр не рисуется совсем.** Единогласно: `CodexBar` (провайдер выключен — нет
   ни вкладки, ни значка), `Usage4Claude` («колонки Codex нет, пока не добавлен аккаунт»),
   `aqua5230` («карточка появляется сама, когда опрос удался»), `ArrivaRUS` («схлопывается в одну
   строку»). Серой строки «Codex — не настроен» у нас нет.
4. **Заголовок группы: имя провайдера, план и ближайший сброс.** Имя и план — `ai-usage-menubar`
   (пилюля «Max 20x»), `aqua5230`, `CodexBar`. Сброс отсчётом до суток и датой дальше — `ModelDeck`
   («Resets in 1 hr 38 min» против «Resets Sat 4:38 AM»); у нас `PanelData.until` уже так и
   считает.
5. **Цвет значит только «насколько плохо», никогда «чей это провайдер».** Плоские полоски с
   порогами — `CodexBar`, `ModelDeck`, `ai-usage-menubar`, `aqua5230`, `ClaudeBar`. Провайдеры
   различаются глифом и именем.
6. **Снимок старше своего окна не показывается.** `CodexBar` при неудачном обновлении гасит
   значок и рисует прочерк «не выдумывая время», `codenotch` даёт последнему чтению стареть. У нас
   жёстче, потому что источник — не опрос, а транскрипт: окно, которое уже сбросилось, исчезает.

Отброшено:

- **Две колонки рядом** (`ModelDeck` ~640pt; `Usage4Claude` расширяет поповер с 280 до 560pt,
  когда добавляется Codex). В 300pt на провайдера остаётся ~142pt — не хватает на подпись,
  число, полоску и сброс разом.
- **Отдельный status item на каждого провайдера** (умолчание `CodexBar`, `aqua5230`,
  `claude-codex-battery`): на ноутбуке с вырезом лишний значок уезжает за шеврон. Сам `CodexBar`
  держит для этого «Merge Icons».
- **Кольцевые гейджи, где цвет кодирует окно** (`Usage4Claude`, `ArrivaRUS`) и **текстовые
  бейджи статуса** («HEALTHY»/«LOW» у `ClaudeBar`) — ширина, которую уже занял цвет полоски.

Отложено, но стоит своего PR:

- **Переключатель «осталось / потрачено»** прямо в шапке панели (`ai-usage-menubar`), он же
  «Show usage as used» у `CodexBar` и такой же тумблер у `Claude-Usage-Tracker` и `ccstatusline`.
  Поле делится примерно поровну, и голое «36 %» рядом с полоской двусмысленно. Порог подсветки
  обязан считаться от того же числа, которое напечатано, иначе одни и те же 17 % окажутся
  красными в одном месте и зелёными в другом.
- **Время сброса внутри каждой ячейки** (`aqua5230`, `ai-usage-menubar`, `CodexBar`) — стоит
  ~11pt высоты на ряд; сейчас сброс живёт в заголовке группы и в подсказке.
- **Громкая строка «вход протух»** вместо молчания (`ArrivaRUS`: «Sign-in expired · How to fix?»,
  `ModelDeck`: чипы «Healthy» / «Sign in again») — и прекращать опрос с заведомо мёртвым токеном.
- **Скрыть/переставить провайдера руками** (`aqua5230` «Hide Sections», `codenotch` — порядок
  колец).
