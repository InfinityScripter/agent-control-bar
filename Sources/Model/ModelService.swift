/// The model endpoint used by a session, independently of the agent that hosts it.
enum ModelService: String, CaseIterable, Identifiable {
    case anthropic, openai, deepseek, zai, openrouter, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .deepseek: return "DeepSeek"
        case .zai: return "Z.ai"
        case .openrouter: return "OpenRouter"
        case .custom: return "Other services"
        }
    }

    static func native(for agent: String) -> ModelService {
        agent == Provider.codex.id ? .openai : .anthropic
    }

    init(reported: String?, agent: String) {
        guard let reported, !reported.isEmpty else {
            self = Self.native(for: agent)
            return
        }
        self = Self(rawValue: reported) ?? .custom
    }
}
