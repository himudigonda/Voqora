import CoreAudio
import Foundation

nonisolated enum AudioOutputRoutePolicy {
    static func routeWasLost(previous: UInt32?, current: UInt32?, connected: [UInt32]) -> Bool {
        guard let previous, previous != current else { return false }
        return !connected.contains(previous)
    }
}

final class CoreAudioOutputRouteMonitor: AudioOutputRouteMonitoring {
    var onRouteLost: (() -> Void)?

    private var currentDevice: AudioDeviceID?
    private var listener: AudioObjectPropertyListenerBlock?

    func start() {
        guard listener == nil else { return }
        currentDevice = Self.defaultOutputDevice()
        let block = Self.makeListener { [weak self] in
            self?.defaultOutputChanged()
        }
        var address = Self.propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        guard status == noErr else {
            VoqoraLog.warn("AudioOutputRoute", "Could not observe the audio output device", ["status": "\(status)"])
            return
        }
        listener = block
    }

    private func defaultOutputChanged() {
        let previous = currentDevice
        let current = Self.defaultOutputDevice()
        currentDevice = current
        let lost = AudioOutputRoutePolicy.routeWasLost(previous: previous, current: current, connected: Self.connectedDevices())
        VoqoraLog.info("AudioOutputRoute", "Default output device changed", ["routeLost": "\(lost)"])
        if lost {
            onRouteLost?()
        }
    }

    private nonisolated static func makeListener(_ onChange: @escaping @MainActor () -> Void) -> AudioObjectPropertyListenerBlock {
        { _, _ in
            Task { @MainActor in
                onChange()
            }
        }
    }

    private nonisolated static func propertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private nonisolated static func defaultOutputDevice() -> AudioDeviceID? {
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return device
    }

    private nonisolated static func connectedDevices() -> [AudioDeviceID] {
        var address = propertyAddress(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !devices.isEmpty, AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }
}
