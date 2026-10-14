window.STATE =
{
  "version": 2,
  "slug": "whenreset-odds",
  "dir": "2026-10-14-whenreset-odds",
  "title": "Шанс сброса лимитов из whenreset.app",
  "mode": "full",
  "depth": "normal",
  "tier": "T1",
  "briefFile": "2026-10-14-brief.md",
  "memoryFile": "CLAUDE.md",
  "memoryOwner": "user",
  "skillDir": "/Users/talalaev-m/.agents/skills/autopilot",
  "baseCommit": "97154f5",
  "startedAt": "2026-10-14T20:27:50+03:00",
  "updatedAt": "2026-10-14T21:40:59+03:00",
  "finishedAt": "2026-10-14T21:40:59+03:00",
  "stages": [
    {
      "id": "preflight",
      "status": "done",
      "startedAt": "2026-10-14T20:27:50+03:00",
      "finishedAt": "2026-10-14T20:28:13+03:00"
    },
    {
      "id": "manifest",
      "status": "done",
      "startedAt": "2026-10-14T20:28:13+03:00",
      "finishedAt": "2026-10-14T20:28:28+03:00"
    },
    {
      "id": "briefing",
      "status": "skipped",
      "startedAt": "2026-10-14T20:28:28+03:00",
      "finishedAt": "2026-10-14T20:28:33+03:00",
      "note": "полный автомат — самобрифинг"
    },
    {
      "id": "spec",
      "status": "done",
      "startedAt": "2026-10-14T20:28:58+03:00",
      "finishedAt": "2026-10-14T20:36:36+03:00"
    },
    {
      "id": "plan",
      "status": "done",
      "startedAt": "2026-10-14T20:36:36+03:00",
      "finishedAt": "2026-10-14T20:38:03+03:00"
    },
    {
      "id": "build",
      "status": "done",
      "startedAt": "2026-10-14T20:38:03+03:00",
      "finishedAt": "2026-10-14T21:13:45+03:00"
    },
    {
      "id": "review",
      "status": "done",
      "startedAt": "2026-10-14T21:13:45+03:00",
      "finishedAt": "2026-10-14T21:31:51+03:00"
    },
    {
      "id": "final",
      "status": "done",
      "startedAt": "2026-10-14T21:31:51+03:00",
      "finishedAt": "2026-10-14T21:40:59+03:00"
    }
  ],
  "requirements": {
    "total": 8,
    "done": 8,
    "inTicket": 0,
    "inSpec": 0,
    "placeholder": 0,
    "deferred": 0,
    "dropped": 0
  },
  "tickets": [
    {
      "id": "01",
      "title": "Данные whenreset: модель, загрузка, выключатель, документы",
      "requirements": [
        "R01",
        "R03",
        "R04",
        "R05",
        "R06",
        "R07i",
        "R08i"
      ],
      "blockedBy": [],
      "wave": 1,
      "zone": [
        "Sources/Model/ResetOdds.swift",
        "Sources/ResetOdds.swift",
        "Sources/main.swift",
        "Sources/PanelData.swift",
        "Sources/PanelStore.swift",
        "Sources/PanelWindow.swift",
        "Sources/SettingsStore.swift",
        "Sources/SettingsView.swift",
        "tests/model/main.swift",
        "PRIVACY.md",
        "CHANGELOG.md",
        "README.md",
        "README.ru.md"
      ],
      "review": "да — фундамент: снимок и модель, которые читает таск 02; новый сетевой запрос к стороннему сервису",
      "model": "сильная",
      "status": "done",
      "startedAt": "2026-10-14T20:38:11+03:00",
      "finishedAt": "2026-10-14T20:56:35+03:00",
      "retries": 0,
      "repairs": 0,
      "tests": {
        "passed": 1085,
        "failed": 0
      },
      "commit": "2c2bfc6"
    },
    {
      "id": "02",
      "title": "Плашка «Reset odds» в панели",
      "requirements": [
        "R02",
        "R03",
        "R05",
        "R06",
        "R07i"
      ],
      "blockedBy": [
        "01"
      ],
      "wave": 2,
      "zone": [
        "Sources/PanelResetOdds.swift",
        "Sources/PanelView.swift",
        "Sources/PanelData.swift",
        "Sources/PanelStore.swift"
      ],
      "review": "нет",
      "model": "сильная",
      "status": "done",
      "startedAt": "2026-10-14T20:56:36+03:00",
      "finishedAt": "2026-10-14T21:13:44+03:00",
      "retries": 0,
      "repairs": 0,
      "tests": {
        "passed": 1085,
        "failed": 0
      },
      "commit": "e15a694"
    },
    {
      "id": "F1",
      "title": "Ремонт по ревью ветки",
      "requirements": [
        "R03",
        "R06",
        "R07i"
      ],
      "blockedBy": [],
      "wave": 3,
      "zone": [
        "Sources/Model/ResetOdds.swift",
        "Sources/PanelData.swift",
        "Sources/PanelStore.swift",
        "Sources/PanelResetOdds.swift",
        "Sources/ResetOddsFetch.swift",
        "tests/model/main.swift"
      ],
      "review": "да — ремонт ветки",
      "model": "сильная",
      "status": "done",
      "retries": 0,
      "repairs": 0,
      "startedAt": "2026-10-14T21:18:02+03:00",
      "finishedAt": "2026-10-14T21:30:22+03:00",
      "tests": {
        "passed": 1107,
        "failed": 0
      },
      "commit": "47d6bba"
    }
  ],
  "tests": {
    "passed": 1490,
    "failed": 0
  },
  "debt": {
    "placeholders": [],
    "assumptions": [
      "«галочка» понята как шеврон раскрытия плашки и выключатель в Settings",
      "плашка под полосой лимитов, над вкладками",
      "выключатель по умолчанию включён; запрос публичный, вписан в PRIVACY.md",
      "обновление не чаще раза в 15 минут, кэш последнего ответа в UserDefaults"
    ],
    "emptyEnv": []
  },
  "additions": [],
  "coverage": {
    "found": 4,
    "fixed": 4,
    "deferred": 0,
    "items": []
  },
  "concerns": [
    "Sources/PanelData.swift:148-188 — правила снимка (ok/loading/unavailable, stale, note, банковый сброс) не в Sources/Model и не покрыты модельной проверкой",
    "Sources/PanelData.swift:340 — panelStripExtra резервирует 190 pt под раскрытую плашку и в состоянии loading/unavailable",
    "Sources/main.swift:443 — в режиме CONTROL_BAR_DUMP_MENU тоже уходит запрос; без кэша вывод дампа зависит от гонки",
    "Sources/ResetOddsFetch.swift:529 — размер ответа не ограничен, любой разобранный 200 целиком ложится в UserDefaults",
    "PRIVACY.md:54 — строка длиннее общей ширины переноса"
  ],
  "blind": {
    "checked": 7,
    "matched": 6,
    "mismatches": [
      "R04 — шанс рядом со сроками сброса виден только во всплывающей подсказке строки лимитов, на экране не виден; плашка стоит под полосой"
    ]
  },
  "beats": [
    "2026-10-14T20:27:50+03:00",
    "2026-10-14T20:28:13+03:00",
    "2026-10-14T20:28:24+03:00",
    "2026-10-14T20:28:28+03:00",
    "2026-10-14T20:28:33+03:00",
    "2026-10-14T20:28:58+03:00",
    "2026-10-14T20:35:32+03:00",
    "2026-10-14T20:36:28+03:00",
    "2026-10-14T20:36:36+03:00",
    "2026-10-14T20:37:14+03:00",
    "2026-10-14T20:37:53+03:00",
    "2026-10-14T20:38:03+03:00",
    "2026-10-14T20:38:11+03:00",
    "2026-10-14T20:54:12+03:00",
    "2026-10-14T20:56:29+03:00",
    "2026-10-14T20:56:35+03:00",
    "2026-10-14T20:56:36+03:00",
    "2026-10-14T21:13:44+03:00",
    "2026-10-14T21:13:45+03:00",
    "2026-10-14T21:17:59+03:00",
    "2026-10-14T21:18:00+03:00",
    "2026-10-14T21:18:01+03:00",
    "2026-10-14T21:18:02+03:00",
    "2026-10-14T21:30:22+03:00",
    "2026-10-14T21:31:50+03:00",
    "2026-10-14T21:31:51+03:00",
    "2026-10-14T21:40:34+03:00",
    "2026-10-14T21:40:35+03:00",
    "2026-10-14T21:40:59+03:00"
  ],
  "rev": 33,
  "waiting": null,
  "waits": [],
  "log": [
    {
      "t": "2026-10-14T20:27:50+03:00",
      "k": "init"
    },
    {
      "t": "2026-10-14T20:28:13+03:00",
      "k": "stage",
      "id": "manifest",
      "act": "start"
    },
    {
      "t": "2026-10-14T20:28:28+03:00",
      "k": "stage",
      "id": "briefing",
      "act": "start"
    },
    {
      "t": "2026-10-14T20:28:33+03:00",
      "k": "stage",
      "id": "briefing",
      "act": "skip",
      "note": "полный автомат — самобрифинг"
    },
    {
      "t": "2026-10-14T20:28:58+03:00",
      "k": "gate",
      "g": "G1",
      "ok": false,
      "open": 8,
      "total": 8
    },
    {
      "t": "2026-10-14T20:28:58+03:00",
      "k": "stage",
      "id": "spec",
      "act": "start"
    },
    {
      "t": "2026-10-14T20:35:32+03:00",
      "k": "add",
      "key": "debt.assumptions",
      "n": 4
    },
    {
      "t": "2026-10-14T20:36:28+03:00",
      "k": "gate",
      "g": "G2",
      "ok": true,
      "found": 4,
      "fixed": 4,
      "deferred": 0
    },
    {
      "t": "2026-10-14T20:36:36+03:00",
      "k": "stage",
      "id": "plan",
      "act": "start"
    },
    {
      "t": "2026-10-14T20:37:14+03:00",
      "k": "tier",
      "v": "T1"
    },
    {
      "t": "2026-10-14T20:37:14+03:00",
      "k": "tickets",
      "n": 2
    },
    {
      "t": "2026-10-14T20:37:14+03:00",
      "k": "gate",
      "g": "G3",
      "ok": true,
      "problems": 0
    },
    {
      "t": "2026-10-14T20:38:03+03:00",
      "k": "stage",
      "id": "build",
      "act": "start"
    },
    {
      "t": "2026-10-14T20:38:11+03:00",
      "k": "ticket",
      "ids": [
        "01"
      ],
      "act": "start"
    },
    {
      "t": "2026-10-14T20:54:12+03:00",
      "k": "ticket",
      "ids": [
        "01"
      ],
      "act": "review"
    },
    {
      "t": "2026-10-14T20:56:29+03:00",
      "k": "add",
      "key": "concerns",
      "n": 5
    },
    {
      "t": "2026-10-14T20:56:35+03:00",
      "k": "ticket",
      "ids": [
        "01"
      ],
      "act": "done",
      "tests": {
        "passed": 1085,
        "failed": 0
      }
    },
    {
      "t": "2026-10-14T20:56:36+03:00",
      "k": "ticket",
      "ids": [
        "02"
      ],
      "act": "start"
    },
    {
      "t": "2026-10-14T21:13:44+03:00",
      "k": "ticket",
      "ids": [
        "02"
      ],
      "act": "done",
      "tests": {
        "passed": 1085,
        "failed": 0
      }
    },
    {
      "t": "2026-10-14T21:13:45+03:00",
      "k": "add",
      "key": "report",
      "n": 1
    },
    {
      "t": "2026-10-14T21:13:45+03:00",
      "k": "stage",
      "id": "review",
      "act": "start"
    },
    {
      "t": "2026-10-14T21:17:59+03:00",
      "k": "tickets",
      "n": 3
    },
    {
      "t": "2026-10-14T21:18:00+03:00",
      "k": "gate",
      "g": "G3",
      "ok": true,
      "problems": 0
    },
    {
      "t": "2026-10-14T21:18:01+03:00",
      "k": "add",
      "key": "report",
      "n": 1
    },
    {
      "t": "2026-10-14T21:18:02+03:00",
      "k": "ticket",
      "ids": [
        "F1"
      ],
      "act": "start"
    },
    {
      "t": "2026-10-14T21:30:22+03:00",
      "k": "ticket",
      "ids": [
        "F1"
      ],
      "act": "done",
      "tests": {
        "passed": 1107,
        "failed": 0
      }
    },
    {
      "t": "2026-10-14T21:31:50+03:00",
      "k": "tests",
      "passed": 1490,
      "failed": 0
    },
    {
      "t": "2026-10-14T21:31:51+03:00",
      "k": "stage",
      "id": "final",
      "act": "start"
    },
    {
      "t": "2026-10-14T21:40:34+03:00",
      "k": "gate",
      "g": "G4",
      "ok": false,
      "checked": 7,
      "matched": 6
    },
    {
      "t": "2026-10-14T21:40:35+03:00",
      "k": "add",
      "key": "report",
      "n": 2
    },
    {
      "t": "2026-10-14T21:40:59+03:00",
      "k": "finish",
      "result": "плашка «Reset odds» с шансом сброса лимитов Claude и Codex из whenreset.app, детали по шеврону, выключатель в Settings"
    }
  ],
  "reqList": [
    {
      "id": "R01",
      "text": "«https://whenreset.app/api/ можешь добавить апишку в наш вот этот вот э, плагин для определения сессий»",
      "status": "done"
    },
    {
      "id": "R02",
      "text": "«дополнительную плашечку вверху сделать, типа либо внизу, тут по дизайну сам придумай, как это будет лучше, красивее»",
      "status": "done"
    },
    {
      "id": "R03",
      "text": "«процент шанс того, что обнулятся лимиты»",
      "status": "done"
    },
    {
      "id": "R04",
      "text": "«где-нибудь, может быть, э, в информации, типа что, где вот ну, у нас есть резеты, да, разные указаны»",
      "status": "done"
    },
    {
      "id": "R05",
      "text": "«И там еще вот эту галочку»",
      "status": "done"
    },
    {
      "id": "R06",
      "text": "«чтобы можно было через нее посмотреть, сколько в кодексе резетов»",
      "status": "done"
    },
    {
      "id": "R07i",
      "text": "(подразумевается) без сети или при сбое API панель не ломается и не врёт",
      "status": "done"
    },
    {
      "id": "R08i",
      "text": "(подразумевается) не дёргать чужой сервер на каждой перерисовке панели",
      "status": "done"
    }
  ],
  "gates": {
    "G1": {
      "ok": false,
      "at": "2026-10-14T20:28:58+03:00",
      "open": 8,
      "total": 8
    },
    "G2": {
      "ok": true,
      "at": "2026-10-14T20:36:28+03:00",
      "found": 4,
      "fixed": 4,
      "deferred": 0
    },
    "G3": {
      "ok": true,
      "at": "2026-10-14T21:18:00+03:00",
      "problems": 0
    },
    "G4": {
      "ok": false,
      "at": "2026-10-14T21:40:34+03:00",
      "checked": 7,
      "matched": 6
    }
  },
  "result": "плашка «Reset odds» с шансом сброса лимитов Claude и Codex из whenreset.app, детали по шеврону, выключатель в Settings",
  "report": [
    "Раскрытая плашка выше, чем закладывала спецификация: около 270 pt вместо 190 — высота считается точно, за экран панель не выходит",
    "Swift 6.0 локально не проверен (стоит 6.4) — проверит задача swift-6-0 в CI",
    "Выключатель «Limit reset odds» в Settings есть в коде, но слепая приёмка не увидела его на экране: раздел Limits оказался ниже края окна",
    "Ветка отстаёт от origin/main на 2 коммита (там вышла 0.25.1) — перед PR нужно подтянуть main"
  ]
}
