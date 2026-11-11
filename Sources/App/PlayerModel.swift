import AppKit
import AVFoundation
import AudioToolbox
import Combine
import UniformTypeIdentifiers
import CoreAudio

struct PlayerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// The render callback owns a reference, so its C state outlives every render call.
final class TapeStream: @unchecked Sendable {
    let handle: OpaquePointer
    init(_ handle: OpaquePointer) { self.handle = handle }
    deinit { mzt_destroy(handle) }
    var totalFrames: UInt64 { mzt_total_frames(handle) }
    var playedFrames: UInt64 { mzt_played_frames(handle) }
}

func prepareTape(_ data: Data, conventional: Bool, inverted: Bool) throws -> TapeStream {
    var error = [CChar](repeating: 0, count: 512)
    let result = data.withUnsafeBytes { bytes in
        mzt_create(bytes.bindMemory(to: UInt8.self).baseAddress, data.count,
                   conventional ? 1 : 0, inverted ? 1 : 0, &error, 512)
    }
    guard let handle = result else { throw PlayerError(message: String(cString: error)) }
    return TapeStream(handle)
}

enum RecordTransition: String, CaseIterable, Identifiable {
    case confirm = "Ask before next record"
    case timed = "Wait 5 seconds"

    var id: Self { self }
}

@MainActor
final class PlayerModel: ObservableObject {
    @Published var source: URL?
    @Published private(set) var tapeHeaders: [TapeHeader] = []
    @Published private(set) var selectedRecords: Set<Int> = []
    private var tapeImage: Data?
    @Published var devices: [OutputDevice] = []
    @Published var selectedUID = ""
    @Published var conventional = false
    @Published var inverted = false
    @Published var recordTransition: RecordTransition = .confirm
    @Published private(set) var nextRecordPrompt: String?
    @Published private(set) var gapDeadline: TimeInterval?
    private var pendingRecords: ArraySlice<Int> = []
    private var currentRecord: Int?
    private var playbackToken = UUID()
    @Published var volume: Float = 0.5
    @Published var monitorMuted = false
    @Published var monitorDecibels: Double = -70
    @Published private(set) var defaultOutputID: AudioDeviceID = 0
    @Published var monitorStatus = "Local monitor: quiet playback on the default output, when different."
    @Published var busy = false
    @Published var playing = false
    @Published var paused = false
    @Published var elapsed: Double = 0
    @Published var duration: Double = 0
    @Published var status = "Choose an MZT or MZF tape image to begin."
    @Published var errorMessage: String?
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var stream: TapeStream?
    private var monitorEngine: AVAudioEngine?
    private var monitorDevice: AudioDeviceID?
    private var tapeDevice: AudioDeviceID?
    private var defaultAddress = AudioDevices.property(kAudioHardwarePropertyDefaultOutputDevice)
    private var completionDeadline: TimeInterval?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var hardwareAddress = AudioDevices.property(kAudioHardwarePropertyDevices)
    private var hardwareListener: AudioObjectPropertyListenerBlock?

    var active: Bool { playing || paused || gapDeadline != nil || nextRecordPrompt != nil }
    var monitorAvailable: Bool {
        guard defaultOutputID != 0,
              let selected = devices.first(where: { $0.uid == selectedUID }) else { return false }
        return defaultOutputID != (tapeDevice ?? selected.id)
    }
    private var monitorGain: Float { Float(pow(10, monitorDecibels / 20)) }

    init() {
        refreshDevices()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updatePosition() }
        }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refreshDevices() }
        }
        hardwareListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &hardwareAddress, .main, listener)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, .main, listener)
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            // Dispatch asynchronously: reconfiguring inside the engine notification can deadlock.
            Task { @MainActor in
                guard let self, let changed = note.object as? AVAudioEngine, self.active else { return }
                if changed === self.engine {
                    self.stop()
                    self.status = "Audio configuration changed. Check the output device, then press Play to restart."
                    self.refreshDevices()
                } else if changed === self.monitorEngine {
                    self.monitorEngine?.stop(); self.monitorEngine = nil; self.monitorDevice = nil
                    self.monitorStatus = "Local monitor interrupted. Toggle its mute control to reconnect."
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        })
    }

    func refreshDevices() {
        devices = AudioDevices.outputs()
        defaultOutputID = AudioDevices.defaultOutput()
        if selectedUID.isEmpty {
            selectedUID = devices.first(where: { $0.id == defaultOutputID })?.uid ?? devices.first?.uid ?? ""
        } else if !devices.contains(where: { $0.uid == selectedUID }) {
            if active { stop() }
            selectedUID = ""
            status = "The selected output was disconnected. Choose an output device."
        }
        syncMonitor()
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Sharp tape image"
        panel.allowedContentTypes = [UTType(filenameExtension: "mzt")!, UTType(filenameExtension: "mzf")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    func load(_ url: URL) {
        guard !busy else { return }
        guard ["mzt", "mzf"].contains(url.pathExtension.lowercased()) else {
            errorMessage = "Choose an MZT or MZF tape image."
            return
        }
        do {
            let image = try TapeHeader.readImage(from: url)
            let headers = try TapeHeader.records(in: image)
            stop()
            tapeImage = image
            selectedRecords = Set(headers.indices)
            tapeHeaders = headers
            source = url
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        duration = 0
        status = "Ready. Set the Sharp to load from tape, then press Play."
    }

    func setRecord(_ index: Int, checked: Bool) {
        guard !active, !busy, tapeHeaders.indices.contains(index) else { return }
        if checked { selectedRecords.insert(index) }
        else { selectedRecords.remove(index) }
        resetSelectionProgress()
    }

    func selectWholeTape() {
        guard !active, !busy else { return }
        selectedRecords = Set(tapeHeaders.indices)
        resetSelectionProgress()
    }

    var wholeTapeSelected: Bool { !tapeHeaders.isEmpty && selectedRecords.count == tapeHeaders.count }

    private func resetSelectionProgress() {
        duration = 0
        elapsed = 0
        status = selectedRecords.isEmpty ? "Check at least one record to play." : "Ready to play \(selectionDescription)."
    }

    private var selectionDescription: String {
        if wholeTapeSelected { return "the whole tape" }
        if selectedRecords.count == 1, let index = selectedRecords.first { return "record \(index + 1)" }
        return "\(selectedRecords.count) selected records"
    }

    var playButtonTitle: String {
        if paused { return "Resume" }
        if wholeTapeSelected { return tapeHeaders.count > 1 ? "Play Whole Tape" : "Play" }
        if selectedRecords.isEmpty { return "Play" }
        if selectedRecords.count == 1, let index = selectedRecords.first { return "Play Record \(index + 1)" }
        return "Play \(selectedRecords.count) Records"
    }

    private var playbackStatus: String {
        if let currentRecord { return "Playing record \(currentRecord + 1)." }
        return selectedRecords.isEmpty ? "Playing tape." : "Playing \(selectionDescription)."
    }

    func play() {
        if paused {
            do {
                try engine?.start()
                paused = false; playing = true; status = playbackStatus
                do { try monitorEngine?.start() }
                catch {
                    monitorEngine?.stop(); monitorEngine = nil; monitorDevice = nil
                    monitorStatus = "Local monitor could not resume: \(error.localizedDescription)"
                }
            } catch { stop(); errorMessage = error.localizedDescription }
            return
        }
        guard !busy, !active, tapeImage != nil, !selectedRecords.isEmpty else { return }
        pendingRecords = selectedRecords.sorted()[...]
        startNextRecord()
    }

    func continueAfterRecord() {
        guard nextRecordPrompt != nil else { return }
        nextRecordPrompt = nil
        startNextRecord()
    }

    private func startNextRecord() {
        guard let image = tapeImage, let index = pendingRecords.popFirst() else { return }
        currentRecord = index
        startPlayback(image[tapeHeaders[index].recordRange])
    }

    private func startPlayback(_ data: Data) {
        guard let device = devices.first(where: { $0.uid == selectedUID }) else {
            stop()
            errorMessage = "Choose an available output device."
            return
        }
        busy = true
        status = "Preparing tape audio…"
        let token = playbackToken
        let conventional = conventional, inverted = inverted
        Task {
            do {
                let tape = try await Task.detached(priority: .userInitiated) {
                    try prepareTape(data, conventional: conventional, inverted: inverted)
                }.value
                guard token == playbackToken else { return }
                // Resolve the UID again because hardware IDs can change during conversion.
                guard let current = AudioDevices.outputs().first(where: { $0.uid == device.uid }) else {
                    throw PlayerError(message: "The selected output device was disconnected.")
                }
                try startAudio(tape, device: current.id)
                status = playbackStatus
            } catch {
                guard token == playbackToken else { return }
                stop()
                errorMessage = error.localizedDescription
                status = "Playback could not start."
            }
            busy = false
        }
    }

    private func makeEngine(_ tape: TapeStream, device: AudioDeviceID, level: Float) throws -> (AVAudioEngine, AVAudioSourceNode) {
        let engine = AVAudioEngine()
        guard let unit = engine.outputNode.audioUnit else { throw PlayerError(message: "The audio output unit is unavailable.") }
        var id = device
        let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                         kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout.size(ofValue: id)))
        guard result == noErr else { throw PlayerError(message: "Cannot use the selected output device (Core Audio error \(result)).") }
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        guard outputFormat.sampleRate > 0, outputFormat.channelCount > 0 else { throw PlayerError(message: "The output device has no usable audio format.") }
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(mzt_sample_rate()), channels: 1)!
        let source = AVAudioSourceNode(format: format) { isSilence, _, count, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard let buffer = buffers.first, let memory = buffer.mData else { return kAudio_ParamError }
            isSilence.pointee = false
            mzt_render(tape.handle, memory.assumingMemoryBound(to: Float.self), Int(count))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = level
        engine.prepare()
        return (engine, source)
    }

    private func startAudio(_ tape: TapeStream, device: AudioDeviceID) throws {
        let (engine, source) = try makeEngine(tape, device: device, level: volume)
        self.engine = engine; sourceNode = source; stream = tape; tapeDevice = device
        duration = Double(tape.totalFrames) / Double(mzt_sample_rate())
        elapsed = 0; completionDeadline = nil
        try engine.start()
        playing = true; paused = false
        syncMonitor()
    }

    func pause() {
        guard playing else { return }
        updatePosition()
        guard playing else { return }
        engine?.pause(); monitorEngine?.pause(); playing = false; paused = true
        status = "Paused. Resume to continue, or Stop to rewind."
    }

    func stop() {
        playbackToken = UUID()
        busy = false
        pendingRecords = []
        currentRecord = nil
        gapDeadline = nil
        nextRecordPrompt = nil
        stopAudio()
        elapsed = 0
        status = source == nil ? "Choose an MZT or MZF tape image to begin." : "Stopped. Play restarts from the beginning."
    }

    private func stopAudio() {
        monitorEngine?.stop(); monitorEngine = nil; monitorDevice = nil
        engine?.stop()
        tapeDevice = nil
        playing = false; paused = false
        sourceNode = nil; engine = nil; stream = nil; completionDeadline = nil
    }

    func setVolume() { engine?.mainMixerNode.outputVolume = volume }

    func setMonitorVolume() { monitorEngine?.mainMixerNode.outputVolume = monitorGain }

    func syncMonitor() {
        guard monitorAvailable else {
            monitorEngine?.stop(); monitorEngine = nil; monitorDevice = nil
            monitorStatus = defaultOutputID == 0 || selectedUID.isEmpty
                ? "Local monitor unavailable: choose an output device."
                : "Local monitor disabled: tape output is the default device."
            return
        }
        guard active, let tapeDevice, let stream else {
            monitorStatus = monitorMuted ? "Local monitor muted." : "Local monitor: quiet playback on the default output, when different."
            return
        }
        let defaultDevice = AudioDevices.defaultOutput()
        if monitorMuted || defaultDevice == tapeDevice || defaultDevice == 0 {
            monitorEngine?.stop(); monitorEngine = nil; monitorDevice = nil
            monitorStatus = monitorMuted ? "Local monitor muted." : "Local monitor skipped: tape output is the default device."
            return
        }
        if monitorEngine != nil, monitorDevice == defaultDevice { return }
        monitorEngine?.stop(); monitorEngine = nil; monitorDevice = nil
        do {
            guard let handle = mzt_copy_at_frame(stream.handle, stream.playedFrames) else {
                throw PlayerError(message: "Cannot allocate the local monitor stream.")
            }
            let copy = TapeStream(handle)
            let (monitor, _) = try makeEngine(copy, device: defaultDevice, level: monitorGain)
            monitorEngine = monitor; monitorDevice = defaultDevice
            if playing { try monitor.start() }
            monitorStatus = "Quiet monitor: \(AudioDevices.outputs().first(where: { $0.id == defaultDevice })?.name ?? "default output")."
        } catch {
            monitorEngine?.stop(); monitorEngine = nil; monitorDevice = nil
            monitorStatus = "Local monitor unavailable: \(error.localizedDescription)"
        }
    }

    private func finishRecordOrTape() {
        guard let next = pendingRecords.first else {
            let length = duration
            stop()
            elapsed = length
            status = "Playback complete."
            return
        }
        stopAudio()
        elapsed = duration
        let label = "record \(next + 1): \(tapeHeaders[next].filename ?? "(unnamed)")"
        switch recordTransition {
        case .timed:
            gapDeadline = ProcessInfo.processInfo.systemUptime + 5
            status = "Waiting five seconds before \(label)."
        case .confirm:
            nextRecordPrompt = "Next is \(label). Continue when the Sharp is ready."
            status = "Waiting for you to continue."
        }
    }

    private func updatePosition() {
        if let deadline = gapDeadline, ProcessInfo.processInfo.systemUptime >= deadline {
            gapDeadline = nil
            startNextRecord()
            return
        }
        guard playing, let stream else { return }
        let rendered = Double(stream.playedFrames) / Double(mzt_sample_rate())
        let latency = engine?.outputNode.presentationLatency ?? 0
        elapsed = min(duration, max(0, rendered - latency))
        if stream.playedFrames >= stream.totalFrames {
            let now = ProcessInfo.processInfo.systemUptime
            if completionDeadline == nil {
                // Let the last generated buffer reach the output before stopping the engine.
                completionDeadline = now + max(0.2, latency + 0.1)
            } else if now >= completionDeadline! {
                finishRecordOrTape()
            }
        }
    }
}
