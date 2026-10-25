import AppKit
import AVFoundation

enum SoundChoice: Int, CaseIterable {
    case classic = 1, fracture, brownout, arc, stutter
    var id: String { ["classic", "fracture", "brownout", "arc", "stutter"][rawValue - 1] }
    var name: String { ["Classic", "Fracture", "Brownout", "Arc", "Stutter"][rawValue - 1] }
    var title: String { "\(rawValue) · \(name)" }
    var detail: String {
        switch self {
        case .classic: return "The original digital crackle: dry packets and irregular broken stutters."
        case .fracture: return "Ragged tearing cuts, splintered packets, and sudden gaps."
        case .brownout: return "A darker, dirtier crackle with a low electrical growl."
        case .arc: return "Bright, crisp sparks and fine electrical snapping."
        case .stutter: return "A repeating broken-buffer rhythm with shifting packet lengths."
        }
    }
    init?(id: String) {
        guard let match = Self.allCases.first(where: { $0.id == id }) else { return nil }
        self = match
    }
    func url() throws -> URL {
        guard let url = Bundle.main.url(forResource: id, withExtension: "wav", subdirectory: "Sounds") else {
            throw Failure.message("Sound \(id) is missing from the app")
        }
        return url
    }
}

@MainActor final class GlitchSound {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let speed = AVAudioUnitVarispeed()
    let file: AVAudioFile
    let choice: SoundChoice
    init(choice: SoundChoice, duration: Double, volume: Float) throws {
        self.choice = choice
        file = try AVAudioFile(forReading: choice.url())
        let sourceDuration = Double(file.length) / file.processingFormat.sampleRate
        engine.attach(player); engine.attach(speed)
        engine.connect(player, to: speed, format: file.processingFormat)
        engine.connect(speed, to: engine.mainMixerNode, format: file.processingFormat)
        speed.rate = Float(sourceDuration / duration)
        player.volume = volume
        engine.prepare(); try engine.start()
        log("SOUND_READY option=\(choice.rawValue) source_ms=\(Int((sourceDuration * 1000).rounded())) rate=\(speed.rate) local_volume=\(volume)")
    }
    func play() {
        player.stop()
        player.scheduleFile(file, at: nil)
        player.play()
        log("SOUND_PLAY option=\(choice.rawValue)")
    }
    func shutDown() { player.stop(); engine.stop() }
}

