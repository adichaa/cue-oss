import WhisperKit
import AVFoundation

final class VoiceRecorder {
    enum VoiceError: Error {
        case micDenied
    }

    var onPartial: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    private var whisperKit: WhisperKit?
    private var audioProcessor: AudioProcessor?
    private var transcriptionTask: Task<Void, Never>?
    private var accumulated = ""
    private var lastCommittedSampleCount = 0
    private var wantsRecording = false

    var isRecording: Bool { wantsRecording }

    func start(appendingTo existing: String = "") async {
        guard !wantsRecording else { return }
        wantsRecording = true
        accumulated = existing
        lastCommittedSampleCount = 0

        do {
            if whisperKit == nil {
                whisperKit = try await WhisperKit(model: "openai_whisper-base.en")
            }
            guard await Self.requestMic() else { throw VoiceError.micDenied }

            let processor = AudioProcessor()
            try processor.startRecordingLive()
            audioProcessor = processor

            startLoop()
        } catch {
            wantsRecording = false
            let cb = onError
            DispatchQueue.main.async { cb?(error) }
        }
    }

    func stop() {
        wantsRecording = false
        transcriptionTask?.cancel()
        transcriptionTask = nil
        audioProcessor?.stopRecording()
        audioProcessor = nil
    }

    private func startLoop() {
        transcriptionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.wantsRecording else { break }
                await self.transcribeLatest()
            }
        }
    }

    private func transcribeLatest() async {
        guard let whisperKit, let audioProcessor else { return }
        let samples = audioProcessor.audioSamples
        let totalCount = samples.count
        // Need at least 1 second of new audio at 16 kHz before bothering
        guard totalCount > lastCommittedSampleCount + 16_000 else { return }

        let chunk = Array(samples[lastCommittedSampleCount...])
        do {
            let results = try await whisperKit.transcribe(audioArray: chunk)
            let text = results.map { $0.text }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacing(#/\[.*?\]|\(.*?\)/#, with: "")  // strip [BLANK_AUDIO], (silence), etc.
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            lastCommittedSampleCount = totalCount
            accumulated = accumulated.isEmpty ? text : accumulated + " " + text
            let display = accumulated
            let cb = onPartial
            DispatchQueue.main.async { cb?(display) }
        } catch {
            // retry next cycle
        }
    }

    private static func requestMic() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
    }
}
