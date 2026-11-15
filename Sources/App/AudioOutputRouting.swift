import AVFoundation
import CoreAudio

enum AudioOutputRouting {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func configure(_ engine: AVAudioEngine, device: AudioDeviceID) throws {
        let output = engine.outputNode
        let mixer = engine.mainMixerNode
        try output.auAudioUnit.setDeviceID(device)
        let hardware = output.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw Failure(message: "The selected output device has no usable audio format.")
        }
        // The auto-created mixer connection can retain the system default's
        // format after changing devices (e.g. Bluetooth at 44.1 kHz vs 48 kHz).
        // Rebuild that connection using the selected device's actual format.
        engine.disconnectNodeOutput(mixer)
        engine.connect(mixer, to: output, format: hardware)
        try validate(engine, device: device)
    }

    static func isRunning(_ engine: AVAudioEngine, on device: AudioDeviceID) -> Bool {
        guard engine.isRunning else { return false }
        do { try validate(engine, device: device); return true }
        catch { return false }
    }

    static func validate(_ engine: AVAudioEngine, device: AudioDeviceID) throws {
        guard engine.outputNode.auAudioUnit.deviceID == device else {
            throw Failure(message: "The audio engine did not retain the selected output device. Refresh the device list and try again.")
        }
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        let mixer = engine.mainMixerNode.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0,
              hardware.sampleRate == mixer.sampleRate,
              hardware.channelCount == mixer.channelCount else {
            throw Failure(message: "The audio engine could not match the selected output device’s format.")
        }
    }
}
