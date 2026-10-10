import Foundation
import AVFoundation

/// Plays the arrival alert: three sine beeps at 660/660/880 Hz,
/// mirroring the Android AlertPlayer (offsets 0/.22/.44 s, 0.18 s each,
/// 20 ms attack, exponential decay).
final class AlertPlayer {
    static let shared = AlertPlayer()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var sessionConfigured = false

    private init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
    }

    func play() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if !self.sessionConfigured {
                    try AVAudioSession.sharedInstance().setCategory(
                        .playback, mode: .default, options: [.mixWithOthers])
                    self.sessionConfigured = true
                }
                try AVAudioSession.sharedInstance().setActive(true)
                guard let buffer = self.makeBeepBuffer() else { return }
                if !self.engine.isRunning {
                    try self.engine.start()
                }
                self.player.scheduleBuffer(buffer, at: nil, options: [])
                self.player.play()
            } catch {
                // Ignore audio failures; vibration + notification still fire.
            }
        }
    }

    private func makeBeepBuffer() -> AVAudioPCMBuffer? {
        let sampleRate = 44100.0
        let freqs = [660.0, 660.0, 880.0]
        let offsets = [0.0, 0.22, 0.44]
        let beepLen = 0.18
        let total = 0.44 + beepLen + 0.05
        let frames = Int(total * sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let data = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        for b in 0..<3 {
            let start = Int(offsets[b] * sampleRate)
            let len = Int(beepLen * sampleRate)
            for i in 0..<len {
                let idx = start + i
                if idx >= frames { break }
                let t = Double(i) / sampleRate
                let env: Double = t < 0.02 ? t / 0.02 : exp(-(t - 0.02) * 22)
                let v = sin(2.0 * .pi * freqs[b] * t) * env * 0.5
                data[idx] = data[idx] + Float(v)
            }
        }
        return buffer
    }
}
