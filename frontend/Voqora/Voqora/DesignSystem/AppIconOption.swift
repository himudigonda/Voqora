//
//  AppIconOption.swift
//  Voqora
//
//  Two minimalistic wave marks in Voqora's clay accent — `waveLight` (ivory
//  canvas, clay wave) mirrors the app's own light-mode chrome and is the
//  icon baked into the bundle's own `AppIcon.appiconset`; `waveClay` (clay
//  canvas, ivory wave) inverts it. Both live again as standalone
//  `.appiconset` catalogs (`AppIconWaveLight`, `AppIconWaveClay`) purely so
//  `NSImage(named:)` can resolve every mac-idiom size Xcode already built,
//  the same way it resolves the bundle's own `AppIcon`.
//

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

    /// Applies this icon to the running app's Dock/Cmd+Tab presence and to
    /// the Finder icon of the app bundle on disk.
    ///
    /// `NSWorkspace.setIcon(_:forFile:)` writes a Finder-metadata icon
    /// overlay alongside the bundle rather than touching any code-signed
    /// resource inside it, so switching icons can never invalidate the
    /// signature — and passing `nil` removes the override, which is exactly
    /// what selecting `waveLight` should do, since that design is already
    /// the bundle's own baked-in `AppIcon`.
    @MainActor
    func apply() {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath != "/" else { return } // test hosts / no real bundle
        if self == .waveLight {
            NSWorkspace.shared.setIcon(nil, forFile: bundlePath, options: [])
            NSApp.applicationIconImage = nil
        } else if let image = NSImage(named: assetName) {
            NSWorkspace.shared.setIcon(image, forFile: bundlePath, options: [])
            NSApp.applicationIconImage = image
        }
    }

    /// Re-applies whatever icon was last chosen. Called on launch, before
    /// any view exists to read the `@AppStorage`-backed preference — this
    /// mirrors AppDelegate's own launch-time cleanup elsewhere, reading
    /// `UserDefaults` directly rather than through a view model.
    @MainActor
    static func applyStored() {
        let raw = UserDefaults.standard.string(forKey: "appIconID")
        (raw.flatMap(AppIconOption.init(rawValue:)) ?? .waveLight).apply()
    }
}
