import Combine
import Foundation

struct UserFacingError: LocalizedError, Equatable {
    let message: String

    var errorDescription: String? {
        message
    }
}

enum VoicesLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

final class VoiceBlendStore: ObservableObject {
    static let shared = VoiceBlendStore()

    @Published private(set) var blends: [VoiceBlend] = []
    @Published private(set) var maxBlends = 50
    @Published private(set) var state: VoicesLoadState = .idle
    @Published private(set) var revision = 0

    let directory: VoiceBlendDirectory
    private let service: any VoiceBlendServing
    private var refreshGeneration = 0

    init(service: (any VoiceBlendServing)? = nil, directory: VoiceBlendDirectory? = nil) {
        self.service = service ?? VoiceBlendService()
        self.directory = directory ?? .shared
    }

    var liveIDs: Set<String> {
        Set(blends.map(\.id))
    }

    var canCreateMore: Bool {
        blends.count < maxBlends
    }

    func blend(id: String) -> VoiceBlend? {
        blends.first { $0.id == id }
    }

    func displayName(for id: String) -> String {
        blend(id: id)?.name ?? directory.name(for: id) ?? "Custom Voice"
    }

    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        if state != .loaded {
            state = .loading
        }
        do {
            let list = try await service.list()
            guard generation == refreshGeneration else { return }
            directory.record(list.blends)
            blends = list.blends
            maxBlends = list.maxBlends
            state = .loaded
            revision &+= 1
        } catch {
            guard generation == refreshGeneration else { return }
            VoqoraLog.warn("VoiceBlendStore", "Voice blends failed to load", ["status": BackendAPIError.logLabel(for: error)])
            if state != .loaded {
                state = .failed(error.localizedDescription)
            }
        }
    }

    @discardableResult
    func save(_ draft: VoiceBlendDraft, editing id: String?) async throws -> VoiceBlend {
        if let message = draft.validationMessage {
            throw UserFacingError(message: message)
        }
        if id == nil, !canCreateMore {
            throw UserFacingError(message: "You can save up to \(maxBlends) custom voices.")
        }
        let saved: VoiceBlend
        do {
            if let id {
                saved = try await service.update(id: id, with: draft.request)
            } else {
                saved = try await service.create(draft.request)
            }
        } catch {
            VoqoraLog.warn("VoiceBlendStore", "Voice blend save failed", ["status": BackendAPIError.logLabel(for: error)])
            throw error
        }
        directory.record([saved])
        if let index = blends.firstIndex(where: { $0.id == saved.id }) {
            blends[index] = saved
        } else {
            blends.append(saved)
        }
        refreshGeneration &+= 1
        revision &+= 1
        VoqoraLog.info("VoiceBlendStore", id == nil ? "Voice blend created" : "Voice blend updated", ["components": "\(saved.components.count)"])
        return saved
    }

    func delete(_ blend: VoiceBlend) async throws {
        directory.record([blend])
        do {
            try await service.delete(id: blend.id)
        } catch let error as BackendAPIError where error.statusCode == 404 {
            VoqoraLog.info("VoiceBlendStore", "Voice blend was already deleted")
        } catch {
            VoqoraLog.warn("VoiceBlendStore", "Voice blend delete failed", ["status": BackendAPIError.logLabel(for: error)])
            throw error
        }
        blends.removeAll { $0.id == blend.id }
        refreshGeneration &+= 1
        revision &+= 1
        VoqoraLog.info("VoiceBlendStore", "Voice blend deleted")
    }

    func resolvedVoice(_ voice: String) -> String {
        guard state == .loaded else { return voice }
        return VoiceSelectionResolver.resolve(voice, liveBlendIDs: liveIDs, directory: directory)
    }
}
