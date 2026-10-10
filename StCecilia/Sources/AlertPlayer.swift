import Foundation
import AudioToolbox

/// Plays the arrival alert beep (660/660/880 Hz, bundled beep.wav).
/// Uses AudioServices (system sound) instead of AVAudioEngine: the engine
/// was terminating the app when starting playback in the background on
/// Domi's iPhone (arrival -> beep -> jump to home screen). System sounds
/// are not subject to that failure mode.
final class AlertPlayer {
    static let shared = AlertPlayer()

    private var soundID: SystemSoundID = 0

    private init() {
        if let url = Bundle.main.url(forResource: "beep", withExtension: "wav") {
            AudioServicesCreateSystemSoundID(url as CFURL, &soundID)
        }
    }

    func play() {
        if soundID != 0 {
            AudioServicesPlaySystemSound(soundID)
        } else {
            // Fallback: plain system beep if the bundle sound is missing.
            AudioServicesPlaySystemSound(1005)
        }
    }
}
