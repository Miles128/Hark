import AVFoundation
import CoreAudio

enum RecordingError: LocalizedError {
    case noInputDevice
    case engineStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "没有可用的输入设备"
        case .engineStartFailed(let msg):
            return "录音引擎启动失败: \(msg)"
        }
    }
}

enum AudioSourceKind {
    case microphone
    case system
    case both
}

@MainActor
@Observable
final class AudioRecorder {
    private(set) var isRecording = false
    private(set) var db: Float = -60
    private(set) var level: Double = 0

    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var outputURL: URL?
    private var source: AudioSourceKind = .microphone

    static var recordingsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Hark/recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 录音期间持续读取音量；结束后返回 wav 文件路径。
    func startRecording(
        source: AudioSourceKind,
        micDevice: AudioDeviceInfo?,
        systemDevice: AudioDeviceInfo?
    ) throws {
        guard !isRecording else { return }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecordingError.noInputDevice
        }

        if let device = micDevice ?? systemDevice {
            routeInput(of: input, to: device)
        }

        let stamp = Int(Date().timeIntervalSince1970)
        let url = Self.recordingsDir.appendingPathComponent("hark-\(stamp).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)

        Self.installTap(on: input, format: format, file: file, recorder: self)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecordingError.engineStartFailed(error.localizedDescription)
        }

        self.engine = engine
        self.file = file
        self.outputURL = url
        self.source = source
        self.isRecording = true
    }

    /// 停止录音，返回写入完成的 wav 文件。
    func stopRecording() -> URL? {
        guard isRecording, let url = outputURL else { return nil }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        // file 由 tap 持有引用，释放即写入完成
        engine = nil
        file = nil
        outputURL = nil
        isRecording = false
        db = -60
        level = 0
        return url
    }

    private func routeInput(of node: AVAudioInputNode, to device: AudioDeviceInfo) {
        guard let audioUnit = node.audioUnit else { return }
        var deviceID = device.id
        AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    private nonisolated static func installTap(
        on node: AVAudioInputNode,
        format: AVAudioFormat,
        file: AVAudioFile,
        recorder: AudioRecorder
    ) {
        node.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            try? file.write(from: buffer)

            let samples = buffer.floatChannelData?[0]
            var sumSquares: Float = 0
            if let samples {
                for i in 0..<Int(buffer.frameLength) {
                    let v = samples[i]
                    sumSquares += v * v
                }
            }
            let rms = sqrtf(sumSquares / max(Float(buffer.frameLength), 1))
            let db = 20 * log10(max(rms, 1e-6))
            Task { @MainActor in
                recorder.publishLevel(db: db)
            }
        }
    }

    private func publishLevel(db: Float) {
        guard isRecording else { return }
        self.db = db
        level = Double(min(max((db + 60) / 60, 0), 1))
    }
}
