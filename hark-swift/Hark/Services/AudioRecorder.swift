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

    /// 对齐 Rust 的 slice_duration：5 秒一切。
    static let sliceDuration: Double = 5

    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var outputURL: URL?
    private var source: AudioSourceKind = .microphone
    private var slicer: Slicer?

    /// 切片队列（对应 Rust 的 slice_queue_tx）。未开启边录边转时为 nil。
    private(set) var sliceStream: AsyncStream<(URL, Int)>?
    private var sliceContinuation: AsyncStream<(URL, Int)>.Continuation?

    static var recordingsDir: URL { HarkPaths.ensure(HarkPaths.recordings) }

    /// 开启切片：startRecording 之前调用，之后从 sliceStream 取结果。
    func enableSlicing() {
        var continuation: AsyncStream<(URL, Int)>.Continuation?
        sliceStream = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        sliceContinuation = continuation
        let sink = continuation
        slicer = Slicer(directory: Self.recordingsDir, sliceDuration: Self.sliceDuration) { url, index in
            sink?.yield((url, index))
        }
    }

    func disableSlicing() {
        slicer = nil
        sliceContinuation?.finish()
        sliceContinuation = nil
        sliceStream = nil
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
        let url = Self.recordingsDir.appendingPathComponent("recording_\(stamp).wav")
        let file = try AVAudioFile(forWriting: url, settings: Self.wavSettings(for: format))

        Self.installTap(on: input, format: format, file: file, recorder: self, slicer: slicer)

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
        disableSlicing()
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
        recorder: AudioRecorder,
        slicer: Slicer?
    ) {
        node.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            try? file.write(from: buffer)
            // 与 Rust 一样在采集线程切文件，不把工作甩回主线程。
            slicer?.append(buffer)

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

    nonisolated static func wavSettings(for format: AVAudioFormat) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }
}

/// 边录边转的切片累加器，对齐 Rust `audio.rs` 的 `save_slice`。
///
/// 只在采集线程被 `append`，用锁只是为了和主线程的开启/停止安全交错。
/// buffer 在 tap 回调返回后即失效，所以必须深拷贝再攒。
final class Slicer: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let sliceDuration: Double
    private let onSlice: (URL, Int) -> Void

    private var pending: [AVAudioPCMBuffer] = []
    private var pendingFrames = 0
    private var format: AVAudioFormat?
    private var index = 0

    init(directory: URL, sliceDuration: Double, onSlice: @escaping (URL, Int) -> Void) {
        self.directory = directory
        self.sliceDuration = sliceDuration
        self.onSlice = onSlice
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard buffer.frameLength > 0 else { return }
        if format == nil { format = buffer.format }
        guard let format, buffer.format == format else { return }

        guard let copy = Self.copy(buffer, format: format) else { return }
        pending.append(copy)
        pendingFrames += Int(buffer.frameLength)

        let threshold = Int(Double(format.sampleRate) * sliceDuration)
        guard pendingFrames >= threshold else { return }

        let buffers = pending
        let sliceIndex = index
        pending = []
        pendingFrames = 0
        index += 1

        let url = directory.appendingPathComponent(String(format: "slice_%04d.wav", sliceIndex))
        guard let file = try? AVAudioFile(
            forWriting: url,
            settings: AudioRecorder.wavSettings(for: format)
        ) else { return }
        for buffer in buffers {
            try? file.write(from: buffer)
        }
        onSlice(url, sliceIndex)
    }

    private static func copy(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let clone = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let source = buffer.floatChannelData,
              let target = clone.floatChannelData else { return nil }
        clone.frameLength = buffer.frameLength
        let bytes = Int(buffer.frameLength) * MemoryLayout<Float>.stride
        for channel in 0..<Int(format.channelCount) {
            memcpy(target[channel], source[channel], bytes)
        }
        return clone
    }
}
