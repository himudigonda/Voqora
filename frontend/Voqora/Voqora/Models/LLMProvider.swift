import Foundation
import SwiftUI

nonisolated enum LLMProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case openai
    case anthropic
    case xai
    case groq
    case cerebras
    case google
    case openrouter
    case ollama
    case lmstudio
    case custom

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        case .xai: "xAI"
        case .groq: "Groq"
        case .cerebras: "Cerebras"
        case .google: "Google"
        case .openrouter: "OpenRouter"
        case .ollama: "Ollama"
        case .lmstudio: "LM Studio"
        case .custom: "Custom Provider"
        }
    }

    var connectionSummary: String {
        switch self {
        case .ollama, .lmstudio: "Local connection"
        case .custom: "Your service or server"
        default: "Connect with an API key"
        }
    }

    var isLocal: Bool {
        self == .ollama || self == .lmstudio
    }

    var requiresKey: Bool {
        !isLocal && self != .custom
    }

    var acceptsKey: Bool {
        !isLocal
    }

    var acceptsServerURL: Bool {
        isLocal || self == .custom
    }

    var requiresModelChoice: Bool {
        defaultModel.isEmpty
    }

    var defaultModel: String {
        switch self {
        case .openai: "gpt-6-luna"
        case .anthropic: "claude-haiku-5-5"
        case .xai: "grok-4.20-0309-non-reasoning"
        case .groq: "openai/gpt-oss-120b"
        case .cerebras: "gpt-oss-120b"
        case .google: "gemini-3.8-flash"
        case .openrouter: "google/gemini-2.5-flash-lite"
        case .ollama, .lmstudio, .custom: ""
        }
    }

    var defaultServerURL: String {
        switch self {
        case .ollama: "http://localhost:11434/v1"
        case .lmstudio: "http://localhost:1234/v1"
        default: ""
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .openai: "sk-…"
        case .anthropic: "sk-ant-…"
        case .xai: "xai-…"
        case .groq: "gsk_…"
        case .cerebras: "csk-…"
        case .google: "AIza…"
        case .openrouter: "sk-or-…"
        case .custom: "Optional"
        case .ollama, .lmstudio: ""
        }
    }

    var keyPageURL: URL? {
        switch self {
        case .openai: URL(string: "https://platform.openai.com/api-keys")
        case .anthropic: URL(string: "https://platform.claude.com/settings/keys")
        case .xai: URL(string: "https://console.x.ai")
        case .groq: URL(string: "https://console.groq.com/keys")
        case .cerebras: URL(string: "https://cloud.cerebras.ai")
        case .google: URL(string: "https://aistudio.google.com/apikey")
        case .openrouter: URL(string: "https://openrouter.ai/settings/keys")
        case .ollama: URL(string: "https://ollama.com/download")
        case .lmstudio: URL(string: "https://lmstudio.ai")
        case .custom: nil
        }
    }

    var keyPageTitle: String {
        isLocal ? "Download \(displayName)" : "Get a \(displayName) API key"
    }

    var dataNotice: String {
        if isLocal {
            return "Runs with \(displayName) on your Mac. Page text never leaves it."
        }
        if self == .custom {
            return "Sends page text and scanned pages to your server."
        }
        return "Sends page text and scanned pages to \(displayName)."
    }

    var keychainKey: KeychainKey {
        .llmAPIKey(self)
    }
}

nonisolated struct LLMProviderSettings: Codable, Equatable, Sendable {
    var model: String
    var serverURL: String

    init(model: String = "", serverURL: String = "") {
        self.model = model
        self.serverURL = serverURL
    }
}

nonisolated struct LLMCredential: Equatable, Sendable {
    let provider: LLMProvider
    let apiKey: String
    let model: String
    let serverURL: String

    var resolvedModel: String {
        model.isEmpty ? provider.defaultModel : model
    }

    func apply(to request: inout URLRequest) {
        request.setValue(provider.rawValue, forHTTPHeaderField: "X-Voqora-LLM-Provider")
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-Voqora-LLM-Key")
        }
        if !model.isEmpty {
            request.setValue(model, forHTTPHeaderField: "X-Voqora-LLM-Model")
        }
        if !serverURL.isEmpty {
            request.setValue(serverURL, forHTTPHeaderField: "X-Voqora-LLM-Base-URL")
        }
    }
}

nonisolated struct LLMVerification: Equatable, Sendable {
    let verified: Bool
    let models: [String]
    let error: String?
}

nonisolated enum ProviderRemovalNotice {
    static func title(for provider: LLMProvider) -> String {
        "Remove \(provider.displayName)?"
    }

    static func message(
        provider: LLMProvider,
        isActive: Bool,
        cleaningCount: Int,
        remaining: [LLMProvider]
    ) -> String {
        var sentences = [provider.acceptsKey ? "Its API key is deleted from your Keychain." : "Voqora forgets this connection."]
        guard isActive else { return sentences.joined(separator: " ") }
        if cleaningCount > 0 {
            let books = cleaningCount == 1 ? "1 audiobook is" : "\(cleaningCount) audiobooks are"
            sentences.append("\(books) cleaning with \(provider.displayName) right now. Resuming later needs another provider.")
        }
        switch remaining.count {
        case 0: sentences.append("Audiobook cleanup stays off until you add a provider.")
        case 1: sentences.append("Audiobooks will switch to \(remaining[0].displayName).")
        default: sentences.append("You'll choose which provider audiobooks use next.")
        }
        return sentences.joined(separator: " ")
    }
}
