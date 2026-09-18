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

    /// Applies this icon to the running app's Dock/Cmd+Tab presence for
    /// *this process only* — an in-memory `NSApp.applicationIconImage`
    /// assignment, which is instant and touches nothing on disk.
    ///
    /// This deliberately does NOT call `NSWorkspace.setIcon(_:forFile:)` to
    /// also stamp a Finder-visible icon overlay onto the app bundle itself.
    /// Two independent problems were found with that, both traced to the
    /// same call: (1) it writes Finder metadata directly into the already
    /// code-signed bundle, which invalidates the signature — every user who
    /// picked a non-default icon would fail Gatekeeper/`codesign --verify`
    /// on their next launch, and break Sparkle auto-updates. (2) the API
    /// itself is a synchronous, unbounded filesystem call — under the hood
    /// the deprecated Carbon `FSSetCatalogInfo` path, ending in a raw
    /// `setattrlist` syscall — observed to hang indefinitely on this
    /// machine, freezing the entire app before its window ever appeared,
    /// with no crash report, because it used to run unconditionally on the
    /// main thread during `applicationDidFinishLaunching`. Backgrounding
    /// that call fixed the hang but not the signature problem, and the two
    /// together aren't worth the trade for a cosmetic Finder-icon overlay:
    /// the Dock/Cmd+Tab icon while the app is actually running is the part
    /// of this feature users see, and that never needed the disk write.
    @MainActor
    func apply() {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath != "/" else { return } // test hosts / no real bundle
        NSApp.applicationIconImage = self == .waveLight ? nil : NSImage(named: assetName)
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
