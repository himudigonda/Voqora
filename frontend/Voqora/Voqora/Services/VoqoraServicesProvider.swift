import AppKit
import Foundation

final class VoqoraServicesProvider: NSObject {
    private let inputs: SpeechInputCoordinator

    init(inputs: SpeechInputCoordinator) {
        self.inputs = inputs
        super.init()
    }

    @objc func speakWithVoqora(_ pasteboard: NSPasteboard, userData _: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = Self.serviceText(from: pasteboard) else {
            error.pointee = SpeechInputCoordinator.Message.noText as NSString
            return
        }
        VoqoraLog.info("VoqoraServicesProvider", "Speak service invoked", ["chars": "\(text.count)"])
        Task { [inputs] in
            await inputs.speak(text)
        }
    }

    @objc func addToVoqoraLibrary(_ pasteboard: NSPasteboard, userData _: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = Self.serviceText(from: pasteboard) else {
            error.pointee = SpeechInputCoordinator.Message.noText as NSString
            return
        }
        VoqoraLog.info("VoqoraServicesProvider", "Library service invoked", ["chars": "\(text.count)"])
        if case let .failed(message) = inputs.addToLibrary(text) {
            error.pointee = message as NSString
        }
    }

    static func serviceText(from pasteboard: NSPasteboard) -> String? {
        pasteboard.string(forType: .string).flatMap(SpeechInputCoordinator.readableText)
    }
}
