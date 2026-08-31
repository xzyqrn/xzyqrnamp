import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let hasInput: Bool
    let hasOutput: Bool
    let transport: UInt32

    var isAnalogJack: Bool {
        let n = name.lowercased()
        let u = uid.lowercased()
        if u.contains("headphoneinput") || u.contains("headphoneoutput") || u.contains("headset") {
            return true
        }
        return n.contains("external microphone")
            || n.contains("external mic")
            || n.contains("micrófono externo")
            || n.contains("microphone externe")
            || n.contains("externes mikrofon")
            || n.contains("line in")
            || n.contains("headset")
            || n.contains("headphone")
            || n.contains("irig")
    }

    var isAnalogInput: Bool {
        hasInput && isAnalogJack && !uid.lowercased().contains("headphoneoutput") && !name.lowercased().contains("headphone")
    }

    var isAnalogOutput: Bool {
        hasOutput && (uid.lowercased().contains("headphoneoutput")
            || name.lowercased().contains("headphone")
            || name.lowercased().contains("headset"))
    }

    var isLaptopMic: Bool {
        let n = name.lowercased()
        let u = uid.lowercased()
        if isAnalogJack { return false }
        return u.contains("builtinmicrophone")
            || n.contains("macbook")
            || n.contains("imac")
            || (transport == kAudioDeviceTransportTypeBuiltIn && n.contains("microphone"))
    }

    var isBuiltInSpeaker: Bool {
        let n = name.lowercased()
        let u = uid.lowercased()
        if isAnalogJack { return false }
        return u.contains("built-in output")
            || u.contains("builtinspeaker")
            || n.contains("macbook air speakers")
            || n.contains("macbook pro speakers")
            || n.contains("imac speakers")
            || (transport == kAudioDeviceTransportTypeBuiltIn && n.contains("speaker"))
    }

    var displayName: String {
        if isAnalogInput {
            return "\(name)  ·  analog input"
        }
        if isAnalogOutput {
            return "\(name)  ·  analog output"
        }
        return name
    }
}

enum CoreAudioDevices {
    static func list() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids) == noErr else {
            return []
        }
        return ids.compactMap { device(from: $0) }
    }

    static func defaultInputID() -> AudioDeviceID {
        defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    }

    static func defaultOutputID() -> AudioDeviceID {
        defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func preferredInputID(in devices: [AudioDevice]) -> AudioDeviceID {
        let system = defaultInputID()
        if devices.contains(where: { $0.id == system && $0.hasInput && !$0.isLaptopMic }) {
            return system
        }
        if let jack = devices.first(where: \.isAnalogInput) {
            return jack.id
        }
        if let other = devices.first(where: { $0.hasInput && !$0.isLaptopMic }) {
            return other.id
        }
        return devices.first(where: \.hasInput)?.id ?? system
    }

    static func preferredOutputID(in devices: [AudioDevice]) -> AudioDeviceID {
        let system = defaultOutputID()
        if devices.contains(where: { $0.id == system && $0.hasOutput }) {
            return system
        }
        if let jack = devices.first(where: \.isAnalogOutput) {
            return jack.id
        }
        return devices.first(where: \.hasOutput)?.id ?? system
    }

    @discardableResult
    static func setDefaultInput(_ id: AudioDeviceID) -> OSStatus {
        setDefaultDevice(id, selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    @discardableResult
    static func setDefaultOutput(_ id: AudioDeviceID) -> OSStatus {
        setDefaultDevice(id, selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func setBufferFrameSize(_ frames: UInt32, device: AudioDeviceID) {
        guard device != 0 else { return }
        let clamped = clampBuffer(frames, device: device)
        var value = clamped
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
    }

    static func clampBuffer(_ frames: UInt32, device: AudioDeviceID) -> UInt32 {
        guard let range = bufferRange(device: device) else { return frames }
        let lo = UInt32(max(32, range.mMinimum))
        let hi = UInt32(max(range.mMaximum, range.mMinimum))
        return min(max(frames, lo), hi)
    }

    static func bufferRange(device: AudioDeviceID) -> AudioValueRange? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &range) == noErr else { return nil }
        return range
    }

    static func supportsSampleRate(_ rate: Double, device: AudioDeviceID) -> Bool {
        availableSampleRates(device: device).contains { span in
            rate + 0.5 >= span.mMinimum && rate - 0.5 <= span.mMaximum
        }
    }

    static func availableSampleRates(device: AudioDeviceID) -> [AudioValueRange] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var values = Array(repeating: AudioValueRange(), count: count)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &values) == noErr else { return [] }
        return values
    }

    static func setSampleRate(_ rate: Double, device: AudioDeviceID) {
        guard device != 0, supportsSampleRate(rate, device: device) else { return }
        var value = Float64(rate)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
    }

    static func currentSampleRate(device: AudioDeviceID) -> Double {
        var value = Float64(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return value
    }

    static func currentBufferFrameSize(device: AudioDeviceID) -> UInt32 {
        var value: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return value
    }

    /// Analog iRig levels are often buried by the macOS mic/headphone sliders.
    static func raiseVolumeIfNeeded(device: AudioDeviceID, scope: AudioObjectPropertyScope, minimum: Float) {
        guard device != 0 else { return }
        let elements: [UInt32] = [kAudioObjectPropertyElementMain, 1, 2]
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: scope,
                mElement: element
            )
            var writable: DarwinBoolean = false
            guard AudioObjectHasProperty(device, &address),
                  AudioObjectIsPropertySettable(device, &address, &writable) == noErr,
                  writable.boolValue else { continue }
            var current: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &current) == noErr,
               current >= minimum {
                continue
            }
            var value = min(1, max(0, minimum))
            AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
        }
    }

    static func addHardwareListener(_ block: @escaping () -> Void) -> AudioObjectPropertyListenerBlock {
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            DispatchQueue.main.async { block() }
        }
        let selectors = [
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDevices
        ]
        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                listener
            )
        }
        return listener
    }

    static func removeHardwareListener(_ listener: @escaping AudioObjectPropertyListenerBlock) {
        let selectors = [
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDevices
        ]
        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                listener
            )
        }
    }

    private static func setDefaultDevice(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> OSStatus {
        guard id != 0 else { return kAudioHardwareBadDeviceError }
        var device = id
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &device)
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var device = AudioDeviceID(0)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    private static func device(from id: AudioDeviceID) -> AudioDevice? {
        guard isAlive(id) else { return nil }
        let name = stringProperty(id, kAudioObjectPropertyName) ?? "Device \(id)"
        let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "\(id)"
        let ins = channelCount(id, kAudioDevicePropertyScopeInput)
        let outs = channelCount(id, kAudioDevicePropertyScopeOutput)
        if ins == 0 && outs == 0 { return nil }
        return AudioDevice(
            id: id,
            name: name,
            uid: uid,
            hasInput: ins > 0,
            hasOutput: outs > 0,
            transport: transportType(id)
        )
    }

    private static func isAlive(_ id: AudioDeviceID) -> Bool {
        var value: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var value: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return nil }
        var cf: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &cf) == noErr else { return nil }
        return cf?.takeRetainedValue() as String?
    }

    private static func channelCount(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<Int>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
