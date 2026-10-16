import Foundation
import AVFoundation

/// Hur mötets ljud ligger på disk.
///
/// Under inspelningen och efterbearbetningen är spåren wav: rå PCM tål en
/// krasch mitt i (huvudet går att laga, se `Wav.rättaHuvud`), och whisper
/// och röstanalysen läser bara wav. När mötet är färdigbearbetat packas
/// spåren till AAC i m4a — runt åtta gånger mindre, vilket spelar roll när
/// kundmappen synkas med Obsidian Sync eller iCloud.
///
/// Behövs ljudet igen — omkörning, ny röstuppdelning — packas det upp till
/// wav medan arbetet pågår, och wav-filen tas bort efteråt. m4a-filen är
/// då sanningen och skrivs aldrig om: att packa om en uppackning vore en
/// generationsförlust för varje omkörning.
///
/// Uppmätt på tre röster (sv, nb, en) med ECAPA-avtryck: samma klipp före
/// och efter rundturen ligger på cosinus 0,95–0,99, samma röst i två olika
/// klipp flyttar sig högst 0,01, och olika röster hamnar lika långt eller
/// längre isär. Komprimeringen kostar alltså inte igenkänningen.
enum Ljudlagring {

    static let spår = ["jag", "motpart"]

    /// 32 kbit/s mono räcker gott för tal i 16 kHz.
    static let bithastighet = 32_000

    private static var fm: FileManager { .default }

    /// Spårets fil: wav om den finns, annars m4a.
    static func fil(_ spår: String, i mapp: URL) -> URL? {
        for ändelse in ["wav", "m4a"] {
            let url = mapp.appending(path: "\(spår).\(ändelse)")
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Om mappen innehåller ljud i någon av formerna.
    static func harLjud(i mapp: URL) -> Bool {
        spår.contains { fil($0, i: mapp) != nil }
    }

    /// Om filnamnet är ett av mötets ljudspår.
    static func ärLjudfil(_ namn: String) -> Bool {
        namn.hasSuffix(".wav") || namn.hasSuffix(".m4a")
    }

    // MARK: - Packa upp

    /// Ser till att varje spår finns som wav. Spår som bara finns som m4a
    /// packas upp; `packaIhop` tar bort dem igen när arbetet är klart.
    static func packaUpp(i mapp: URL) async throws {
        for s in spår {
            let wav = mapp.appending(path: "\(s).wav")
            let m4a = mapp.appending(path: "\(s).m4a")
            guard !fm.fileExists(atPath: wav.path), fm.fileExists(atPath: m4a.path) else { continue }
            // Via en tillfällig fil: ett avbrott mitt i får inte lämna en
            // halv wav som sedan tas för hela spåret.
            let tillfällig = mapp.appending(path: ".\(s)-packas-upp.wav")
            try? fm.removeItem(at: tillfällig)
            do {
                _ = try await Import.tillWhisperformat(m4a, mål: tillfällig)
                behållTid(från: m4a, på: tillfällig)
                try fm.moveItem(at: tillfällig, to: wav)
            } catch {
                try? fm.removeItem(at: tillfällig)
                throw error
            }
        }
    }

    // MARK: - Packa ihop

    /// Efter ett arbete på mötets ljud: wav som bara var uppackade tas bort,
    /// och nya wav packas till m4a om inställningen säger det.
    ///
    /// Rör ingenting medan efterbearbetningen pågår — då läser whisper eller
    /// röstanalysen fortfarande wav-filerna.
    ///
    /// - Returns: hur många byte som frigjordes.
    @discardableResult
    static func packaIhop(i mapp: URL, packa: Bool = Inställningar.packaLjud) async -> Int64 {
        // Kodningen tar några sekunder för ett långt möte och får inte
        // hålla huvudtråden.
        await Task.detached(priority: .utility) {
            packaIhopNu(i: mapp, packa: packa)
        }.value
    }

    private static func packaIhopNu(i mapp: URL, packa: Bool) -> Int64 {
        guard !bearbetas(i: mapp) else { return 0 }
        var frigjort: Int64 = 0
        for s in spår {
            let wav = mapp.appending(path: "\(s).wav")
            let m4a = mapp.appending(path: "\(s).m4a")
            guard fm.fileExists(atPath: wav.path) else { continue }
            let storlek = Int64((try? wav.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if fm.fileExists(atPath: m4a.path) {
                // En uppackning; m4a-filen är sanningen.
                if (try? fm.removeItem(at: wav)) != nil { frigjort += storlek }
                continue
            }
            guard packa else { continue }
            do {
                _ = try? Wav.rättaHuvud(i: wav)
                try komprimera(wav, till: m4a)
                try fm.removeItem(at: wav)
                let ny = Int64((try? m4a.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                frigjort += storlek - ny
            } catch {
                // wav-filen ligger kvar orörd; mötet fungerar som förut.
                try? fm.removeItem(at: m4a)
            }
        }
        return frigjort
    }

    /// Skriver wav-filen som AAC. Skrivs till en tillfällig fil som läses
    /// tillbaka och jämförs i längd innan den får heta som spåret — först
    /// då är det säkert att ta bort originalet.
    static func komprimera(_ wav: URL, till m4a: URL) throws {
        let in_ = try AVAudioFile(forReading: wav)
        let format = in_.processingFormat
        let tillfällig = m4a.deletingLastPathComponent()
            .appending(path: ".\(m4a.deletingPathExtension().lastPathComponent)-packas.m4a")
        try? fm.removeItem(at: tillfällig)

        do {
            let ut = try AVAudioFile(
                forWriting: tillfällig,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: format.channelCount,
                    AVEncoderBitRateKey: bithastighet,
                ],
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved)
            guard let buffert = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
                throw Enkeltfel("Kunde inte förbereda ljudet för komprimering.")
            }
            while in_.framePosition < in_.length {
                try in_.read(into: buffert)
                if buffert.frameLength == 0 { break }
                try ut.write(from: buffert)
            }
            ut.close()

            let före = Double(in_.length) / in_.fileFormat.sampleRate
            let läst = try AVAudioFile(forReading: tillfällig)
            let efter = Double(läst.length) / läst.fileFormat.sampleRate
            guard abs(före - efter) < 0.5 else {
                throw Enkeltfel("Den komprimerade filen blev \(efter) s i stället för \(före) s.")
            }
            behållTid(från: wav, på: tillfällig)
            try fm.moveItem(at: tillfällig, to: m4a)
        } catch {
            try? fm.removeItem(at: tillfällig)
            throw error
        }
    }

    /// Filens ändringstid är när mötet spelades in — en omkörning läser
    /// datumet därifrån. Packningen får inte flytta den till i dag.
    private static func behållTid(från källa: URL, på mål: URL) {
        guard let tid = try? källa.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate else { return }
        try? fm.setAttributes([.modificationDate: tid], ofItemAtPath: mål.path)
    }

    /// Sant medan efterbearbetningen arbetar i mappen.
    private static func bearbetas(i mapp: URL) -> Bool {
        guard let data = try? Data(contentsOf: mapp.appending(path: "möte.json")),
              let i = try? JSONDecoder.kundkoll.decode(Inspelning.self, from: data)
        else { return false }
        return i.bearbetas
    }
}
