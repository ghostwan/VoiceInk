import AppKit
import AVFoundation
import os
import SwiftUI

enum SpeakerSettings {
    static let askParticipantsKey = "AskParticipantsBeforeRecording"
    static let lastParticipantsKey = "LastRecordingParticipants"
    static let myNameKey = "RecordingMyName"
    static let captureRemoteKey = "CaptureRemoteAudio"
}

/// Tracks participants and speaker turns for the current recording.
@MainActor
final class SpeakerSession: ObservableObject {
    static let shared = SpeakerSession()

    struct Turn {
        let offset: TimeInterval
        let speaker: String
    }

    struct Capture {
        let turns: [Turn]
        let myName: String
        let systemURL: URL?
        /// Seconds the system recording started after the microphone recording.
        let systemOffset: TimeInterval
    }

    @Published private(set) var participants: [String] = []
    @Published private(set) var currentSpeaker: String?
    private(set) var myName = ""
    private(set) var turns: [Turn] = []
    private var recordingStart: Date?
    private var systemURL: URL?

    var isActive: Bool { !participants.isEmpty }
    var selfLabel: String { myName.isEmpty ? String(localized: "Me") : myName }
    var chipNames: [String] { [selfLabel] + participants }

    func configure(participants: [String], myName: String) {
        reset()
        self.participants = participants
        self.myName = myName
    }

    func beginRecording() {
        guard recordingStart == nil else { return }
        recordingStart = Date()

        guard UserDefaults.standard.bool(forKey: SpeakerSettings.captureRemoteKey) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("system-\(UUID().uuidString).wav")
        systemURL = url
        Task {
            do {
                try await SystemAudioRecorder.shared.start(to: url)
                Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SpeakerSession").notice("system capture started")
            } catch {
                Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SpeakerSession").error("system capture failed: \(String(describing: error), privacy: .public)")
                NotificationManager.shared.showNotification(
                    title: String(localized: "Remote audio capture unavailable: grant Screen Recording permission"),
                    type: .warning, duration: 4.0)
                if self.systemURL == url { self.systemURL = nil }
            }
        }
    }

    func select(_ speaker: String) {
        guard let recordingStart else { return }
        currentSpeaker = speaker
        turns.append(Turn(offset: Date().timeIntervalSince(recordingStart), speaker: speaker))
    }

    /// Stops remote capture and returns what was collected, clearing the session.
    func finish() async -> Capture? {
        let started = recordingStart
        let url = systemURL
        let result = turns
        let name = myName
        let firstBuffer = url != nil ? await SystemAudioRecorder.shared.stop() : nil
        reset(removingSystemFile: false)

        var systemFile = url
        if let u = url, firstBuffer == nil || !FileManager.default.fileExists(atPath: u.path) {
            try? FileManager.default.removeItem(at: u)
            systemFile = nil
        }
        Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SpeakerSession").notice("finish: turns=\(result.count, privacy: .public) systemFile=\(systemFile != nil, privacy: .public) firstBuffer=\(firstBuffer != nil, privacy: .public)")
        guard !result.isEmpty || systemFile != nil else { return nil }
        let offset = (firstBuffer != nil && started != nil) ? firstBuffer!.timeIntervalSince(started!) : 0
        return Capture(turns: result, myName: name, systemURL: systemFile, systemOffset: offset)
    }

    func reset(removingSystemFile: Bool = true) {
        if removingSystemFile {
            if let systemURL {
                Task { _ = await SystemAudioRecorder.shared.stop(); try? FileManager.default.removeItem(at: systemURL) }
            }
        }
        participants = []
        currentSpeaker = nil
        turns = []
        recordingStart = nil
        systemURL = nil
        myName = ""
    }

    static func parse(_ input: String) -> [String] {
        var seen = Set<String>()
        return input
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Asks the user for participants. Returns false if the user cancelled the recording.
    static func promptForParticipants() -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Who is taking part?")
        alert.informativeText = String(
            localized: "Enter participant names separated by commas. You can switch the active speaker while recording.")
        alert.addButton(withTitle: String(localized: "Start"))
        alert.addButton(withTitle: String(localized: "Skip"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 28, width: 320, height: 24))
        field.stringValue = ""
        field.placeholderString = "Alice, Bob"
        let meField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        meField.stringValue = UserDefaults.standard.string(forKey: SpeakerSettings.myNameKey) ?? ""
        meField.placeholderString = String(localized: "Your name (microphone)")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
        container.addSubview(field)
        container.addSubview(meField)
        alert.accessoryView = container
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let me = meField.stringValue.trimmingCharacters(in: .whitespaces)
            let names = parse(field.stringValue).filter { $0.caseInsensitiveCompare(me) != .orderedSame }
            UserDefaults.standard.set(me, forKey: SpeakerSettings.myNameKey)
            shared.configure(participants: names, myName: me)
            return true
        case .alertSecondButtonReturn:
            shared.reset()
            return true
        default:
            return false
        }
    }
}

// MARK: - Chips bar

struct SpeakerChipsBar: View {
    @ObservedObject var session: SpeakerSession

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(session.chipNames, id: \.self) { name in
                    let selected = session.currentSpeaker == name
                    Button {
                        session.select(name)
                    } label: {
                        Text(name)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .foregroundStyle(selected ? Color.black : Color.white)
                            .background(
                                Capsule().fill(selected ? Color.white : Color.white.opacity(0.15))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }
}

