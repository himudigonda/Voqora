import AppKit
import SwiftUI

enum AppIconOption: String, CaseIterable, Identifiable {
    case waveLight
    case waveClay

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .waveLight: "Wave — Light"
        case .waveClay: "Wave — Clay"
        }
    }

    var assetName: String {
        switch self {
        case .waveLight: "AppIconWaveLight"
        case .waveClay: "AppIconWaveClay"
        }
    }

    @MainActor
    func apply() {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath != "/" else { return } // test hosts / no real bundle
        NSApp.applicationIconImage = self == .waveLight ? nil : NSImage(named: assetName)
    }

    @MainActor
    static func applyStored() {
        let raw = UserDefaults.standard.string(forKey: "appIconID")
        (raw.flatMap(AppIconOption.init(rawValue:)) ?? .waveLight).apply()
    }
}
