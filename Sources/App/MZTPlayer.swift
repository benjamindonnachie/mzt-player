import SwiftUI
import AppKit
import AVFoundation

@main
struct MZTPlayerApp: App {
    @StateObject private var model = PlayerModel()

    init() {
        // Diagnostic conversion never starts playback or alters system audio settings.
        let arguments = CommandLine.arguments
        if arguments.count >= 2, arguments[1] == "--check" {
            do {
                guard arguments.count >= 3, (arguments.count - 3).isMultiple(of: 2) else {
                    throw PlayerError(message: "Usage: --check <tape image> [--record <number>]…")
                }
                let url = URL(fileURLWithPath: arguments[2])
                let data = try TapeHeader.readImage(from: url)
                let headers = try TapeHeader.records(in: data)
                var selected: Set<Int> = []
                for index in stride(from: 3, to: arguments.count, by: 2) {
                    guard arguments[index] == "--record",
                          let number = Int(arguments[index + 1]), (1...headers.count).contains(number) else {
                        throw PlayerError(message: "Use --record with a record number from 1 to \(headers.count).")
                    }
                    selected.insert(number - 1)
                }
                let playbackData = TapeHeader.playbackData(in: data, records: headers, selected: arguments.count == 3 ? Set(headers.indices) : selected)
                let tape = try prepareTape(playbackData, conventional: true, inverted: false)
                for (index, header) in headers.enumerated() {
                    print("Tape record \(index + 1): \(header.filename ?? "(unnamed)") | \(header.typeDescription)")
                    print(header.loadingHint)
                }
                print("Audio: \(tape.totalFrames) frames, \(mzt_sample_rate()) Hz; direct PCM streaming")
                for device in AudioDevices.outputs() { print("Output: \(device.name) [\(device.uid)]") }
                exit(0)
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
    }

    var body: some Scene {
        WindowGroup("MZT Player") {
            PlayerView(model: model)
                .onOpenURL { model.load($0) }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Tape Image…") { model.chooseFile() }
                    .keyboardShortcut("o").disabled(model.busy)
            }
            CommandGroup(replacing: .appInfo) {
                Button("About MZT Player") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationName: "MZT Player",
                        .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.5.0",
                        .credits: NSAttributedString(string: "Tape encoding implemented from the documented Sharp MZ PWM format.\nProtocol references are included with the source.")
                    ])
                }
            }
        }
    }
}

struct PlayerView: View {
    @ObservedObject var model: PlayerModel

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func recordTitle(_ header: TapeHeader, number: Int) -> some View {
        Text("Record \(number): \(header.filename ?? "(unnamed)")")
            .font(.callout.weight(.medium))
    }

    private func recordMetadata(_ header: TapeHeader) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Type: \(header.typeDescription)").font(.caption)
            Text("Loading: \(header.loadingHint)").font(.callout)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSApplication.shared.applicationIconImage)
                    .resizable().interpolation(.high).frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("MZT Player").font(.largeTitle.weight(.semibold))
                    Text("Sharp tape playback for macOS").foregroundStyle(.secondary)
                }
                Spacer()
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 14) {
                        Image(systemName: "doc").font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.source?.lastPathComponent ?? "No tape selected")
                                .fontWeight(.medium).lineLimit(2).id(model.source)
                            Text(model.source?.deletingLastPathComponent().path ?? "Select an .mzt or .mzf file")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Choose File…", action: model.chooseFile).disabled(model.busy)
                    }.padding(10)
                    if model.tapeHeaders.count > 1 {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Tape records (\(model.tapeHeaders.count))").font(.callout.weight(.medium))
                                Spacer()
                                Button(model.wholeTapeSelected ? "Whole tape selected" : "Select whole tape") {
                                    model.selectWholeTape()
                                }.disabled(model.active || model.busy || model.wholeTapeSelected)
                            }
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    ForEach(model.tapeHeaders.indices, id: \.self) { index in
                                        let header = model.tapeHeaders[index]
                                        VStack(alignment: .leading, spacing: 5) {
                                            Toggle(isOn: Binding(
                                                get: { model.selectedRecords.contains(index) },
                                                set: { model.setRecord(index, checked: $0) }
                                            )) {
                                                recordTitle(header, number: index + 1)
                                            }
                                            .toggleStyle(.checkbox)
                                            .disabled(model.active || model.busy)
                                            recordMetadata(header).padding(.leading, 23)
                                        }
                                        .padding(7)
                                        .background(model.selectedRecords.contains(index) ? Color.accentColor.opacity(0.16) : Color.clear,
                                                    in: RoundedRectangle(cornerRadius: 6))
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(height: 168).id(model.source)
                        }.padding(10)
                    } else if let header = model.tapeHeaders.first {
                        VStack(alignment: .leading, spacing: 5) {
                            recordTitle(header, number: 1)
                            recordMetadata(header)
                        }.padding(10)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Audio output").fontWeight(.medium)
                    Spacer()
                    Button("Refresh", action: model.refreshDevices).controlSize(.small).disabled(model.active || model.busy)
                }
                Picker("Audio output", selection: $model.selectedUID) {
                    Text("Choose an output device").tag("")
                    ForEach(model.devices) { Text($0.name).tag($0.uid) }
                }.labelsHidden().disabled(model.active || model.busy)
                    .onChange(of: model.selectedUID) { _ in model.syncMonitor() }
                Text("The tape signal uses this device. The macOS default output is unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tape format").fontWeight(.medium)
                    Picker("Tape format", selection: $model.conventional) {
                        Text("Conventional (duplicate blocks)").tag(true)
                        Text("Short transfer (single blocks)").tag(false)
                    }.labelsHidden().frame(width: 285)
                    Text("Both use documented Sharp MZ-700 PWM timings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Reverse polarity", isOn: $model.inverted).padding(.top, 30)
            }.disabled(model.active || model.busy)
            Picker("Between records", selection: $model.recordTransition) {
                ForEach(RecordTransition.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }.disabled(model.active || model.busy)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text("Local monitor").fontWeight(.medium)
                    Slider(value: $model.monitorDecibels, in: -90 ... -20, step: 1)
                        .accessibilityLabel("Local monitor volume")
                        .accessibilityValue("\(Int(model.monitorDecibels)) decibels")
                        .onChange(of: model.monitorDecibels) { _ in model.setMonitorVolume() }
                        .disabled(!model.monitorAvailable || model.monitorMuted)
                    Text("\(Int(model.monitorDecibels)) dB")
                        .font(.system(.caption, design: .monospaced)).frame(width: 48)
                    Toggle("Mute", isOn: $model.monitorMuted)
                        .accessibilityLabel("Mute local monitor")
                        .onChange(of: model.monitorMuted) { _ in model.syncMonitor() }
                        .disabled(!model.monitorAvailable)
                }
                Text(model.monitorStatus).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(spacing: 8) {
                ProgressView(value: model.duration > 0 ? model.elapsed / model.duration : 0)
                    .accessibilityLabel("Playback progress")
                HStack {
                    Text(clock(model.elapsed))
                    Spacer()
                    Text(model.duration > 0 ? clock(model.duration) : "--:--")
                }.font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button(model.playButtonTitle) { model.play() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.space, modifiers: [])
                    .disabled(model.source == nil || model.selectedRecords.isEmpty || model.selectedUID.isEmpty || (model.active && !model.paused) || model.busy)
                Button("Pause", action: model.pause).disabled(!model.playing)
                Button("Stop", action: model.stop).disabled(!model.active && !model.busy)
                Spacer()
                Text("Level").foregroundStyle(.secondary)
                Slider(value: $model.volume, in: 0...1).frame(width: 110)
                    .accessibilityLabel("Playback level")
                    .onChange(of: model.volume) { _ in model.setVolume() }
            }
            HStack(spacing: 8) {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(minHeight: 34, alignment: .leading)
            Text("Connect the output to the Sharp’s cassette input. Adjust the level to suit the interface. Pausing during a block may require restarting the load.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(28).frame(width: 640)
        .alert("Ready for the next record?", isPresented: Binding(
            get: { model.nextRecordPrompt != nil }, set: { _ in }
        )) {
            Button("Continue", action: model.continueAfterRecord)
            Button("Stop", role: .cancel, action: model.stop)
        } message: {
            Text(model.nextRecordPrompt ?? "")
        }
        .alert("MZT Player", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}
