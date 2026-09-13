import Foundation
import CoreAudio
import AVFoundation
import AppKit

struct AudioDeviceInfo: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isInput: Bool
}

/// 对齐 Rust 版 list_devices / has_blackhole 命令：CoreAudio 设备枚举。
enum CoreAudioDevices {
    static func allDevices() -> [AudioDeviceInfo] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &size, &deviceIDs) == noErr else {
            return []
        }
        return deviceIDs.compactMap { device in
            guard let name = deviceName(device), let uid = deviceUID(device) else { return nil }
            let isInput = streamCount(device, scope: kAudioObjectPropertyScopeInput) > 0
            return AudioDeviceInfo(id: device, uid: uid, name: name, isInput: isInput)
        }
    }

    static func inputDevices() -> [AudioDeviceInfo] {
        allDevices().filter(\.isInput)
    }

    /// Rust 的 `BLACKHOLE_NAMES`：虚拟回环声卡的设备名关键字。
    static let loopbackNames = ["blackhole", "soundflower", "loopback"]

    /// 对应 SourceSelector.vue 的 isBlackhole()。
    static func isLoopbackDevice(_ name: String) -> Bool {
        loopbackNames.contains { name.lowercased().contains($0) }
    }

    /// 对齐 has_blackhole：Rust 用 BLACKHOLE_NAMES 三个关键字，不只是 blackhole。
    static func hasBlackhole() -> Bool {
        inputDevices().contains { isLoopbackDevice($0.name) }
    }

    static func device(named name: String) -> AudioDeviceInfo? {
        inputDevices().first { $0.name == name }
    }

    static func defaultInputDevice() -> AudioDeviceInfo? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return nil }
        return allDevices().first { $0.id == deviceID }
    }

    /// 将指定设备设为系统默认输入（录音来源切换用）。
    static func setDefaultInputDevice(_ device: AudioDeviceInfo) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = device.id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &deviceID) == noErr
    }

    private static func deviceName(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let result = name as String? else { return nil }
        return result
    }

    private static func deviceUID(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let result = uid as String? else { return nil }
        return result
    }

    private static func streamCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return 0 }
        return size / UInt32(MemoryLayout<AudioStreamID>.size)
    }
}
