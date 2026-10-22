import Combine
import Foundation

enum AudiobookCreateSource: Equatable {
    case file(URL)
    case link(URL)
    case text(String, title: String?)
}

@MainActor
final class AudiobookCreateRequest: ObservableObject {
    static let shared = AudiobookCreateRequest()

    @Published var pending: AudiobookCreateSource?
}
