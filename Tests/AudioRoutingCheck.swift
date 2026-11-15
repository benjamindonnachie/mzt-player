import Foundation
@main struct PlayerRoutingCheck {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 2 else {
            print("Usage: audio-routing-check <non-default output UID>")
            exit(2)
        }
        let initial = AudioDevices.defaultOutput()
        let devices = AudioDevices.outputs()
        guard let target = devices.first(where: { $0.uid == CommandLine.arguments[1] }), target.id != initial else {
            print("The chosen output must be connected and differ from the system default.")
            exit(2)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mzt")
        defer { try? FileManager.default.removeItem(at: url) }
        var image = Data(repeating: 0, count: 129)
        image[0] = 1; image[18] = 1
        try! image.write(to: url)
        let model = PlayerModel()
        model.volume = 0
        model.monitorMuted = true
        model.selectedUID = target.uid
        model.load(url)
        model.play()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        print("Primary:",model.playing,model.status,model.errorMessage ?? "No error")
        guard model.playing, model.errorMessage == nil else { model.stop(); exit(1) }
        model.monitorDecibels = -.infinity // test both routes using silence
        model.monitorMuted = false
        model.syncMonitor()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        print("With monitor:",model.playing,model.monitorStatus)
        guard model.playing, model.monitorStatus.hasPrefix("Quiet monitor:") else { model.stop(); exit(1) }
        model.pause()
        precondition(model.paused && !model.playing)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        model.play()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        precondition(model.playing && model.errorMessage == nil)
        model.stop()
        precondition(!model.active)
        precondition(AudioDevices.defaultOutput() == initial)
        print("Selected output, independent monitor and pause/resume verified; default unchanged.")
    }
}
