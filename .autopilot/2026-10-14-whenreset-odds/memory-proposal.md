# Что предлагаю дописать в CLAUDE.md (и в .claude/rules/architecture.md)

Твой `CLAUDE.md` сборка не трогала. Три пункта — применить по желанию.

1. **CLAUDE.md, «Критические ограничения»** — строка:
   «Сборка из `build/` с тем же bundle id сама уходит, если запущено установленное приложение. Смотреть изменения панели — на копии в /tmp со сменённым `CFBundleIdentifier` (PlistBuddy) и ad-hoc подписью, запуск с `CONTROL_BAR_DUMP_MENU=1` или `CONTROL_BAR_DIAGNOSE=menu`; установленное приложение не завершать.»
2. **CLAUDE.md, «Ключевые команды»** — строка про одну проверку Swift:
   «Typecheck как задача CI swift-6-0: `swiftc -typecheck -target arm64-apple-macos13.0 Sources/*.swift Sources/Model/*.swift -framework Cocoa -framework SwiftUI`.»
3. **.claude/rules/architecture.md, таблица владельцев** — строка:
   «`resetOddsCache`/`resetOddsFetchedAt`/`lastResetOddsAttempt`/`resetOdds` в UserDefaults — только Swift (`Sources/ResetOddsFetch.swift`): запрос к whenreset.app идёт из Swift напрямую, как проверка обновлений; файла в `~/.claude/control-bar/` у него нет намеренно. Правила плашки — `ResetOddsLook` в `Sources/Model/ResetOdds.swift`.»
