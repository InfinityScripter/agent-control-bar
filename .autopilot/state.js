window.STATE =
{
  "version": 2,
  "slug": "whenreset-odds",
  "dir": "2026-10-14-whenreset-odds--wip",
  "title": "Шанс сброса лимитов из whenreset.app",
  "mode": "full",
  "depth": "normal",
  "tier": "T1",
  "briefFile": "2026-10-14-brief.md",
  "memoryFile": "CLAUDE.md",
  "memoryOwner": "user",
  "skillDir": "/Users/talalaev-m/.agents/skills/autopilot",
  "baseCommit": null,
  "startedAt": "2026-10-14T20:27:50+03:00",
  "updatedAt": "2026-10-14T20:37:14+03:00",
  "finishedAt": null,
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
      "status": "active",
      "startedAt": "2026-10-14T20:36:36+03:00"
    },
    {
      "id": "build",
      "status": "pending"
    },
    {
      "id": "review",
      "status": "pending"
    },
    {
      "id": "final",
      "status": "pending"
    }
  ],
  "requirements": {
    "total": 8,
    "done": 0,
    "inTicket": 8,
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
      "status": "pending",
      "retries": 0,
      "repairs": 0
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
      "status": "pending",
      "retries": 0,
      "repairs": 0
    }
  ],
  "tests": null,
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
  "concerns": [],
  "blind": null,
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
    "2026-10-14T20:37:14+03:00"
  ],
  "rev": 13,
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
    }
  ],
  "reqList": [
    {
      "id": "R01",
      "text": "«https://whenreset.app/api/ можешь добавить апишку в наш вот этот вот э, плагин для определения сессий»",
      "status": "in-ticket"
    },
    {
      "id": "R02",
      "text": "«дополнительную плашечку вверху сделать, типа либо внизу, тут по дизайну сам придумай, как это будет лучше, красивее»",
      "status": "in-ticket"
    },
    {
      "id": "R03",
      "text": "«процент шанс того, что обнулятся лимиты»",
      "status": "in-ticket"
    },
    {
      "id": "R04",
      "text": "«где-нибудь, может быть, э, в информации, типа что, где вот ну, у нас есть резеты, да, разные указаны»",
      "status": "in-ticket"
    },
    {
      "id": "R05",
      "text": "«И там еще вот эту галочку»",
      "status": "in-ticket"
    },
    {
      "id": "R06",
      "text": "«чтобы можно было через нее посмотреть, сколько в кодексе резетов»",
      "status": "in-ticket"
    },
    {
      "id": "R07i",
      "text": "(подразумевается) без сети или при сбое API панель не ломается и не врёт",
      "status": "in-ticket"
    },
    {
      "id": "R08i",
      "text": "(подразумевается) не дёргать чужой сервер на каждой перерисовке панели",
      "status": "in-ticket"
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
      "at": "2026-10-14T20:37:14+03:00",
      "problems": 0
    }
  },
  "result": null
}
