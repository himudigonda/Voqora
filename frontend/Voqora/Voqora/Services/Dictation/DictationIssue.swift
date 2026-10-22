import Foundation

nonisolated enum PrivacySettingsPane: String, Sendable {
    case microphone = "Privacy_Microphone"
    case speechRecognition = "Privacy_SpeechRecognition"
    case accessibility = "Privacy_Accessibility"

    var url: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")
    }
}

nonisolated enum DictationIssue: String, Error, Sendable {
    case microphoneDenied = "microphone_denied"
    case speechRecognitionDenied = "speech_recognition_denied"
    case localeUnsupported = "locale_unsupported"
    case onDeviceUnavailable = "on_device_unavailable"
    case recognizerUnavailable = "recognizer_unavailable"
    case audioInputUnavailable = "audio_input_unavailable"
    case recognitionFailed = "recognition_failed"
    case localModelUnavailable = "parakeet_unavailable"
    case localModelNotInstalled = "local_model_not_installed"
    case nothingHeard = "nothing_heard"

    var message: String {
        switch self {
        case .microphoneDenied:
            "Voqora needs microphone access to dictate. Turn it on in System Settings, then try again."
        case .speechRecognitionDenied:
            "Voqora needs Speech Recognition access to dictate. Turn it on in System Settings, then try again."
        case .localeUnsupported:
            "Dictation isn't available for this language. Choose another one on the Dictation page."
        case .onDeviceUnavailable:
            "On-device recognition isn't available for this language. Choose another language, or allow server recognition on the Dictation page."
        case .recognizerUnavailable:
            "Speech recognition isn't available right now. Try again in a moment."
        case .audioInputUnavailable:
            "Voqora couldn't start your microphone. Check the input device in System Settings, then try again."
        case .recognitionFailed:
            "Voqora couldn't transcribe that. Try again."
        case .localModelUnavailable:
            "The local speech model could not be loaded. Reinstall it in Settings → Dictation, or switch to Apple."
        case .localModelNotInstalled:
            "Your speech model isn't installed yet. Finish the download in Settings → Dictation, or switch to Apple."
        case .nothingHeard:
            "Voqora didn't hear anything. Press the shortcut and start speaking."
        }
    }

    var settingsPane: PrivacySettingsPane? {
        switch self {
        case .microphoneDenied: .microphone
        case .speechRecognitionDenied: .speechRecognition
        default: nil
        }
    }
}

nonisolated enum DictationInsertionOutcome: String, Sendable {
    case pasted
    case copied
    case copiedNeedsAccessibility = "copied_needs_accessibility"
    case copiedAppChanged = "copied_app_changed"
    case cancelledSaved = "cancelled_saved"

    var message: String {
        switch self {
        case .pasted: "Inserted"
        case .copied: "Copied to the clipboard"
        case .copiedNeedsAccessibility: "Copied to the clipboard. Allow Accessibility so Voqora can paste for you."
        case .copiedAppChanged: "Copied to the clipboard. You switched apps, so Voqora didn't paste."
        case .cancelledSaved: "Cancelled. Saved to history."
        }
    }

    var settingsPane: PrivacySettingsPane? {
        self == .copiedNeedsAccessibility ? .accessibility : nil
    }
}
