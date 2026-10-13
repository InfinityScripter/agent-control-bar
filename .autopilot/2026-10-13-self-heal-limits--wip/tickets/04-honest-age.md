# 04 — Честный возраст цифр по каждому провайдеру

**Требования:** R10i, R10i.1, R10i.2, R10i.3
**Зависит от:** 02
**Зона:** `scripts/mcpbar_codex.py` (`merge_codex_limits`) · `tests/test_mcpbar.py` (класс `CodexLimits`, швы `build/seam/codex-limits*.json`) · `Sources/Model/LimitsNote.swift` (новый) · `Sources/PanelData.swift` · `Sources/PanelStore.swift` · `Sources/PanelView.swift` · `tests/model/main.swift` · `CHANGELOG.md`
**Волна:** 4
**Ревью:** нет
**Модель:** обычная

## Что должно заработать

Подпись в футере панели больше не берёт самую старую метку на всех: при двух провайдерах она говорит «Claude 1d ago · Codex just now», при одном — «Limits · 4 min ago», как сейчас. У Codex возраст записи считается по свежайшему замеру обычного пула, а не по давно не обновлявшемуся резервному. Подсказка группы Codex говорит, что цифры взяты из последней сессии Codex. Правило возраста и футера живёт в модели и проверяется моделью.

## Из брифа, дословно

> «внизу "Limits · 28d ago"» (из описания скриншота)

> «Они не обновляются, особенно в клоде коде.»

## Разделы спецификации

Истории 18–20 и 24; Решения по реализации — возраст Codex, футер; `interfaces.md` — `LimitsNote`, правило корневого `ts` Codex.

## Критерии приёмки

- [ ] `merge_codex_limits`: корневой `ts` = max `ts` окон пула `codex`; без них — max по всем окнам; per-window `ts` не меняются; тест `test_возраст_записи_это_самый_старый_замер` заменён тестом нового правила (обычный пул свежий + резерв старый → корень свежий; только резерв → его замер)
- [ ] швы `build/seam/codex-limits*.json` перегенерированы тестами, Swift-проверки на них зелёные
- [ ] `Sources/Model/LimitsNote.swift`: `age(of:now:)` с прежним поведением («just now», «N min ago», «Nh ago», «Nd ago») и `footer(_:)`: пусто → «», один → «Limits · <age>», два и больше → «<title> <age> · <title> <age>»; проверено в `tests/model/main.swift`
- [ ] `PanelData.panelLimitGroups` использует `LimitsNote`; дублирующий `PanelData.age` удалён или делегирует
- [ ] подсказка группы Codex: «… · measured 5 min ago · from the last Codex session»
- [ ] тесты Python, Node, Swift-модель зелёные; `swiftc -typecheck` проходит
- [ ] `CHANGELOG.md` `### Fixed`: футер и возраст Codex
