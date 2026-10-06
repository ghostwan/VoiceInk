import AVFoundation
import FluidAudio
import Foundation
import os

/// Splits recordings per speaker (mic = user, system audio = remote participants) and transcribes each part.
enum SpeakerTranscriber {
    private struct Segment {
        var label: String?
        var url: URL
        var start: TimeInterval
        var end: TimeInterval
        /// Start in microphone time, used for ordering and matching with manual clicks.
        var globalStart: TimeInterval
        var globalEnd: TimeInterval
    }

    private static let window: TimeInterval = 0.05
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SpeakerTranscriber")
    @MainActor private static var diarizer: OfflineDiarizerManager?

    @MainActor
    static func transcribe(
        micURL: URL,
        capture: SpeakerSession.Capture,
        shouldCancel: () -> Bool,
        transcribeSegment: (URL) async throws -> String
    ) async throws -> String {
        defer { if let u = capture.systemURL { try? FileManager.default.removeItem(at: u) } }

        var segments: [Segment]
        if let systemURL = capture.systemURL {
            segments = await remoteAwareSegments(micURL: micURL, systemURL: systemURL, capture: capture)
        } else {
            segments = try manualSegments(micURL: micURL, turns: capture.turns)
        }
        segments.sort { $0.globalStart < $1.globalStart }

        var lines: [(label: String?, text: String)] = []
        for segment in segments {
            if shouldCancel() { break }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            let source = try AVAudioFile(forReading: segment.url)
            try write(from: source, start: segment.start, end: segment.end, to: url)
            let raw = try await transcribeSegment(url)
            let text = TranscriptionOutputFilter.filter(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = lines.last, last.label == segment.label {
                lines[lines.count - 1].text += " " + text
            } else {
                lines.append((segment.label, text))
            }
        }

        return lines
            .map { line in line.label.map { "\($0): \(line.text)" } ?? line.text }
            .joined(separator: "\n\n")
    }

    // MARK: - Manual only (microphone + clicks)

    private static func manualSegments(micURL: URL, turns: [SpeakerSession.Turn]) throws -> [Segment] {
        let file = try AVAudioFile(forReading: micURL)
        let total = Double(file.length) / file.processingFormat.sampleRate
        var result: [Segment] = []
        func add(_ label: String?, _ s: TimeInterval, _ e: TimeInterval) {
            guard e - s >= 0.3 else { return }
            result.append(Segment(label: label, url: micURL, start: s, end: e, globalStart: s, globalEnd: e))
        }
        if let first = turns.first { add(nil, 0, first.offset) }
        for (i, turn) in turns.enumerated() {
            add(turn.speaker, turn.offset, min(i + 1 < turns.count ? turns[i + 1].offset : total, total))
        }
        return result
    }

    // MARK: - Mic + system audio

    @MainActor
    private static func remoteAwareSegments(
        micURL: URL, systemURL: URL, capture: SpeakerSession.Capture
    ) async -> [Segment] {
        let offset = capture.systemOffset
        let myName = capture.myName.isEmpty ? String(localized: "Me") : capture.myName
        let micRMS = rmsWindows(micURL)
        let sysRMS = rmsWindows(systemURL)
        let micThreshold = threshold(for: micRMS)
        let sysThreshold = threshold(for: sysRMS)

        // Microphone activity, ignoring windows that are just echo of the remote audio.
        var micActive = [Bool](repeating: false, count: micRMS.count)
        for i in 0..<micRMS.count where micRMS[i] > micThreshold {
            let j = Int(((Double(i) * window) - offset) / window)
            let remoteActive = sysRMS.indices.contains(j) && sysRMS[j] > sysThreshold
            micActive[i] = !remoteActive || micRMS[i] > 2 * sysRMS[j]
        }
        let micSpans = spans(from: micActive)

        logger.notice("rms mic windows=\(micRMS.count, privacy: .public) thr=\(micThreshold, privacy: .public) max=\(micRMS.max() ?? 0, privacy: .public); system windows=\(sysRMS.count, privacy: .public) thr=\(sysThreshold, privacy: .public) max=\(sysRMS.max() ?? 0, privacy: .public) offset=\(offset, privacy: .public) micSpans=\(micSpans.count, privacy: .public)")
        // Remote speakers: diarization, falling back to a single "Remote" speaker.
        var remote: [(speaker: String, start: TimeInterval, end: TimeInterval)] = []
        do {
            let manager = diarizer ?? OfflineDiarizerManager()
            try await manager.prepareModels()
            diarizer = manager
            let result = try await manager.process(systemURL)
            remote = result.segments
                .map { ($0.speakerId, TimeInterval($0.startTimeSeconds), TimeInterval($0.endTimeSeconds)) }
        } catch {
            logger.error("Diarization failed: \(error.localizedDescription, privacy: .public)")
            remote = spans(from: sysRMS.map { $0 > sysThreshold }).map { ("Remote", $0.0, $0.1) }
        }
        remote.sort { $0.start < $1.start }
        logger.notice("remote segments=\(remote.count, privacy: .public) speakers=\(Set(remote.map(\.speaker)).count, privacy: .public)")

        // Names: manual clicks on a name vote for the remote speaker talking at that moment.
        var votes: [String: [String: TimeInterval]] = [:]
        for (i, turn) in capture.turns.enumerated() where turn.speaker.caseInsensitiveCompare(myName) != .orderedSame {
            let from = turn.offset
            let to = min(i + 1 < capture.turns.count ? capture.turns[i + 1].offset : from + 8, from + 8)
            for seg in remote {
                let overlap = min(to, seg.end + offset) - max(from, seg.start + offset)
                if overlap > 0 { votes[seg.speaker, default: [:]][turn.speaker, default: 0] += overlap }
            }
        }
        var labels: [String: String] = [:]
        var used = Set<String>()
        var unnamed = 0
        for speaker in remote.map(\.speaker).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } } {
            if let best = votes[speaker]?.max(by: { $0.value < $1.value })?.key, !used.contains(best) {
                labels[speaker] = best
                used.insert(best)
            } else {
                unnamed += 1
                labels[speaker] = speaker == "Remote" ? String(localized: "Remote") : "Speaker \(unnamed)"
            }
        }

        var result: [Segment] = []
        // Microphone spans are labeled from manual clicks (people in the same room); default is the user.
        let turns = capture.turns
        for span in micSpans {
            var cuts = [span.0]
            cuts += turns.map(\.offset).filter { $0 > span.0 && $0 < span.1 }
            cuts.append(span.1)
            for k in 0..<(cuts.count - 1) where cuts[k + 1] - cuts[k] >= 0.3 {
                let label = turns.last(where: { $0.offset <= cuts[k] + 0.01 })?.speaker ?? myName
                result.append(
                    Segment(label: label, url: micURL, start: max(0, cuts[k] - 0.1), end: cuts[k + 1] + 0.1,
                            globalStart: cuts[k], globalEnd: cuts[k + 1]))
            }
        }
        for seg in remote where seg.end - seg.start >= 0.3 {
            result.append(
                Segment(label: labels[seg.speaker], url: systemURL, start: max(0, seg.start - 0.1), end: seg.end + 0.1,
                        globalStart: seg.start + offset, globalEnd: seg.end + offset))
        }
        return result
    }

    // MARK: - Audio helpers

    private static func rmsWindows(_ url: URL) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(window * format.sampleRate)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return [] }
        var result: [Float] = []
        while file.framePosition < file.length {
            do { try file.read(into: buffer, frameCount: frames) } catch { break }
            guard buffer.frameLength > 0, let data = buffer.floatChannelData?[0] else { break }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
            result.append((sum / Float(buffer.frameLength)).squareRoot())
        }
        return result
    }

    private static func threshold(for rms: [Float]) -> Float {
        guard !rms.isEmpty else { return 1 }
        let sorted = rms.sorted()
        return max(sorted[sorted.count / 5] * 4, 0.004)
    }

    /// Turns a per-window activity flag into spans, bridging gaps shorter than 0.5s.
    private static func spans(from active: [Bool]) -> [(TimeInterval, TimeInterval)] {
        let hang = Int(0.5 / window)
        var result: [(TimeInterval, TimeInterval)] = []
        var start: Int?
        var lastActive = 0
        for (i, flag) in active.enumerated() {
            if flag {
                if start == nil { start = i }
                lastActive = i
            } else if let s = start, i - lastActive > hang {
                result.append((Double(s) * window, Double(lastActive + 1) * window))
                start = nil
            }
        }
        if let s = start { result.append((Double(s) * window, Double(lastActive + 1) * window)) }
        return result
    }

    private static func write(from file: AVAudioFile, start: TimeInterval, end: TimeInterval, to url: URL) throws {
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let startFrame = min(AVAudioFramePosition(start * sampleRate), file.length)
        file.framePosition = startFrame
        var remaining = AVAudioFrameCount(max(0, min(end * sampleRate, Double(file.length)) - Double(startFrame)))
        let out = try AVAudioFile(forWriting: url, settings: file.fileFormat.settings)
        while remaining > 0 {
            let count = min(32768, remaining)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { break }
            try file.read(into: buffer, frameCount: count)
            if buffer.frameLength == 0 { break }
            try out.write(from: buffer)
            remaining -= buffer.frameLength
        }
    }
}
