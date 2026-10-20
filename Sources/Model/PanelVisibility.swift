import Foundation

enum PanelTab: String, CaseIterable, Identifiable {
    case sessions, mcp

    var id: String { rawValue }
    var title: String { self == .sessions ? "Sessions" : "MCP" }
    /// Both are SF Symbols the app already relies on elsewhere; nothing is bundled for them.
    var icon: String { self == .sessions ? "terminal" : "powerplug" }
}

struct PanelVisibility: Equatable {
    var limits = true
    var chance = true
    var sessions = true
    var mcp = true

    init(limits: Bool = true, chance: Bool = true, sessions: Bool = true, mcp: Bool = true) {
        self.limits = limits
        self.chance = chance
        self.sessions = sessions
        self.mcp = mcp
    }

    init(defaults: UserDefaults) {
        limits = defaults.object(forKey: "panelShowLimits") as? Bool ?? true
        chance = defaults.object(forKey: "panelShowChance") as? Bool ?? true
        sessions = defaults.object(forKey: "panelShowSessions") as? Bool ?? true
        mcp = defaults.object(forKey: "panelShowMCP") as? Bool ?? true
    }

    func save(to defaults: UserDefaults) {
        defaults.set(limits, forKey: "panelShowLimits")
        defaults.set(chance, forKey: "panelShowChance")
        defaults.set(sessions, forKey: "panelShowSessions")
        defaults.set(mcp, forKey: "panelShowMCP")
    }

    var tabs: [PanelTab] {
        PanelTab.allCases.filter { $0 == .sessions ? sessions : mcp }
    }

    func selectedTab(_ current: PanelTab) -> PanelTab? {
        tabs.contains(current) ? current : tabs.first
    }
}
