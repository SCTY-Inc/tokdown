import Foundation
import AVFoundation
import CoreAudio
import OSLog

/// Captures system audio via a Core Audio process tap (macOS 14.4+).
///
/// Why a process tap and not ScreenCaptureKit: SCK has no display-independent audio
/// path — its audio rides a display-bound `SCStream`, so closing the lid (built-in
/// display off, no external monitor) starved the tap and produced silent captures
/// (the "(No transcript)" incident). A process tap anchors to the default *output
/// device*, which survives lid-close, sleep, and screen lock. Audio routing keeps
/// working in clamshell mode; only the display goes away.
@MainActor
final class SystemAudioService: NSObject {
    private static let log = Logger(subsystem: "com.scty.tokdown", category: "SystemAudio")

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var writer: TapWriter?
    private var outputURL: URL?

    private(set) var isRecording = false

    func startCapture(to url: URL) async throws {
        let outputDevice = try defaultOutputDevice()
        let outputUID = try deviceUID(outputDevice)

        // 1. Create the tap: stereo mixdown of all system audio (global), excluding nothing.
        //    TokDown plays no audio while recording, so a global tap needs no self-exclusion.
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.name = "TokDown"
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted
        tapDescription.isPrivate = true

        var newTapID: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard tapStatus == noErr, newTapID != 0 else {
            throw SystemAudioError.tapCreationFailed(tapStatus)
        }

        // 2. Read the tap's stream format (float32 mixdown).
        let tapFormat: AVAudioFormat
        do {
            tapFormat = try Self.tapStreamFormat(newTapID)
        } catch {
            AudioHardwareDestroyProcessTap(newTapID)
            throw error
        }

        // 3. Wrap the tap in a private aggregate device anchored to the current output device.
        var newAggregateID: AudioObjectID = 0
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TokDown Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString
                ]
            ]
        ]

        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard aggregateStatus == noErr, newAggregateID != 0 else {
            AudioHardwareDestroyProcessTap(newTapID)
            throw SystemAudioError.aggregateCreationFailed(aggregateStatus)
        }

        // 4. Open the output file in the tap's processing format (AAC .m4a output).
        let file: AVAudioFile
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: tapFormat.sampleRate,
                AVNumberOfChannelsKey: tapFormat.channelCount,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: tapFormat.isInterleaved
            )
        } catch {
            AudioHardwareDestroyAggregateDevice(newAggregateID)
            AudioHardwareDestroyProcessTap(newTapID)
            throw SystemAudioError.writeFailed(error)
        }

        let tapWriter = TapWriter(file: file)

        // 5. Install the IO proc. The block runs on a Core Audio real-time thread;
        //    TapWriter serializes file access and level metering internally.
        var newProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, newAggregateID, nil) { _, inInputData, _, _, _ in
            tapWriter.ingest(inInputData)
        }
        guard procStatus == noErr, let procID = newProcID else {
            AudioHardwareDestroyAggregateDevice(newAggregateID)
            AudioHardwareDestroyProcessTap(newTapID)
            Self.removePartialCaptureFile(at: url)
            throw SystemAudioError.aggregateCreationFailed(procStatus)
        }

        let startStatus = AudioDeviceStart(newAggregateID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(newAggregateID, procID)
            AudioHardwareDestroyAggregateDevice(newAggregateID)
            AudioHardwareDestroyProcessTap(newTapID)
            Self.removePartialCaptureFile(at: url)
            throw SystemAudioError.aggregateCreationFailed(startStatus)
        }

        tapID = newTapID
        aggregateID = newAggregateID
        ioProcID = procID
        writer = tapWriter
        outputURL = url
        isRecording = true
        Self.log.info("System audio capture started: \(tapFormat.sampleRate, format: .fixed(precision: 0))Hz, \(tapFormat.channelCount)ch, interleaved=\(tapFormat.isInterleaved)")
    }

    func stopCapture() async throws -> URL? {
        guard isRecording else { return nil }

        if aggregateID != 0, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
        }

        let url = outputURL
        let snapshot = writer?.finish()

        ioProcID = nil
        aggregateID = 0
        tapID = 0
        writer = nil
        outputURL = nil
        isRecording = false

        let frames = snapshot?.frames ?? 0
        Self.log.info("System audio capture stopped: \(frames) frames written, audible=\(snapshot?.heardAudio ?? false)")

        guard frames > 0 else {
            if let url { Self.removePartialCaptureFile(at: url) }
            throw SystemAudioError.noAudioCaptured
        }

        return url
    }

    /// Whether any audible (above-noise-floor) signal has been captured so far.
    /// Polled by the coordinator to warn the user live if the capture is silent.
    func hasCapturedAudibleSignal() -> Bool {
        writer?.snapshot().heardAudio ?? false
    }

    // MARK: - Core Audio helpers

    private func defaultOutputDevice() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else {
            throw SystemAudioError.deviceUnavailable
        }
        return deviceID
    }

    private func deviceUID(_ device: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // kAudioDevicePropertyDeviceUID returns a +1-retained CFStringRef. Read it as an
        // Unmanaged value (pointer-sized, no object-reference aliasing) and take ownership.
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else {
            throw SystemAudioError.deviceUnavailable
        }
        return uid.takeRetainedValue() as String
    }

    private static func tapStreamFormat(_ tap: AudioObjectID) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw SystemAudioError.tapCreationFailed(status)
        }
        return format
    }

    nonisolated static func removePartialCaptureFile(at url: URL, fileManager: FileManager = .default) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }
}

/// Serializes real-time IO-proc writes to the audio file and tracks level metering.
/// `@unchecked Sendable`: the IO proc runs off the main actor; all mutable state is
/// guarded by `lock`. The PCM buffer aliases the callback's `AudioBufferList` and is
/// written synchronously inside the callback, so its backing memory stays valid.
private final class TapWriter: @unchecked Sendable {
    /// ~ -50 dBFS. Above this we treat the capture as carrying real signal, not the
    /// digital-silence/noise floor produced by a dead capture path.
    static let silenceThreshold: Float = 0.003

    private let file: AVAudioFile
    private let format: AVAudioFormat
    private let lock = NSLock()
    private var heardAudio = false
    private var frames: Int64 = 0

    init(file: AVAudioFile) {
        self.file = file
        self.format = file.processingFormat
    }

    func ingest(_ bufferList: UnsafePointer<AudioBufferList>) {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: bufferList) else { return }

        var peak: Float = 0
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.assumingMemoryBound(to: Float.self)
            var i = 0
            while i < count {
                let amplitude = abs(samples[i])
                if amplitude > peak { peak = amplitude }
                i += 1
            }
        }

        lock.lock()
        try? file.write(from: pcm)
        frames += Int64(pcm.frameLength)
        if peak > Self.silenceThreshold { heardAudio = true }
        lock.unlock()
    }

    func snapshot() -> (heardAudio: Bool, frames: Int64) {
        lock.lock()
        defer { lock.unlock() }
        return (heardAudio, frames)
    }

    /// Returns the final snapshot; the file flushes when it deinits after this call.
    func finish() -> (heardAudio: Bool, frames: Int64) {
        snapshot()
    }
}

enum SystemAudioError: LocalizedError {
    case deviceUnavailable
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case noAudioCaptured
    case writeFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .deviceUnavailable:
            return "No audio output device available to capture."
        case .tapCreationFailed(let status):
            return "Could not create system audio tap (\(status)). Grant audio recording permission in System Settings ▸ Privacy & Security."
        case .aggregateCreationFailed(let status):
            return "Could not start system audio capture (\(status))."
        case .noAudioCaptured:
            return "No system audio was captured."
        case .writeFailed(let underlying):
            if let msg = underlying?.localizedDescription {
                return "Audio write failed: \(msg)"
            }
            return "Audio write failed."
        }
    }
}
