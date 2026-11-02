import Foundation

/// Plockar ut text ur filer på samma sätt som bilagor behandlas.
///
///     Kundkoll --prov-bilaga <fil> [fil …]
///
/// Textutvinningen är det som avgör om en bilaga är värd något i
/// kunskapsbanken, och den beter sig olika för PDF, bild och kontorsfil.
///
/// Ligger utanför huvudaktören: provet väntar in resultatet synkront, och då
/// måste huvudtråden vara fri att köra arbetet.
enum Bilageprov {

    /// Hämtar bilagor ur Mail på samma väg som appen gör.
    ///
    ///     Kundkoll --prov-bilagehämtning <adress> [målmapp]
    static func hämtning(adress: String, mapp: String?) async -> Int32 {
        Prov.svit("Bilagehämtning")
        let skript = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "Resources/mail-sok.applescript")
        let iBundel = URL(fileURLWithPath: Bundle.main.bundlePath)
            .appending(path: "Contents/Resources/mail-sok.applescript")
        let använd = FileManager.default.fileExists(atPath: iBundel.path) ? iBundel : skript

        print("skript: \(använd.path)")
        Prov.kolla(FileManager.default.fileExists(atPath: använd.path), "skriptet finns")

        let mål = URL(fileURLWithPath: mapp ?? FileManager.default.temporaryDirectory
            .appending(path: "kundkoll-bilagor-\(UUID().uuidString)").path)
        do {
            let t0 = Date()
            let svar = try await Mailen(skript: använd).sök(adresser: [adress], bilagor: mål)
            let hittade = svar.bilagor
            print("\(svar.mejl.count) mejl på \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
            print("\n\(hittade.count) bilagor sparade i \(mål.path)")
            Prov.kolla(!hittade.isEmpty, "bilagor hämtades")

            var medText = 0
            for b in hittade {
                let text = await Bilagor.text(ur: b)
                if let text, !text.isEmpty { medText += 1 }
                print("  \(b.namn) (\(b.storlek / 1024) kB) — "
                      + (text.map { "\($0.count) tecken text" } ?? "ingen text"))
            }
            Prov.kolla(medText > 0, "minst en bilaga gav text (\(medText) av \(hittade.count))")
        } catch {
            print("Gick inte: \(error.localizedDescription)")
            Prov.kolla(false, "hämtningen gick igenom")
        }
        return Prov.sammanfatta()
    }

    static func kör(filer: [String]) async -> Int32 {
        guard !filer.isEmpty else { print("Ange minst en fil."); return 1 }
        Prov.svit("Bilagor")

        for väg in filer {
            let url = URL(fileURLWithPath: väg)
            guard FileManager.default.fileExists(atPath: url.path) else {
                Prov.kolla(false, "\(url.lastPathComponent) finns")
                continue
            }
            let storlek = (try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let bilaga = Bilagor.Bilaga(ämne: "prov", namn: url.lastPathComponent,
                                        fil: url.path, storlek: storlek ?? 0)

            let t0 = Date()
            let text = await Bilagor.text(ur: bilaga)
            let tid = Date().timeIntervalSince(t0)

            print("\n\(url.lastPathComponent) (\(bilaga.ändelse), \((storlek ?? 0) / 1024) kB) "
                  + "— \(String(format: "%.1f", tid)) s")
            if let text {
                let rader = text.split(separator: "\n")
                print("  \(text.count) tecken, \(rader.count) rader")
                for r in rader.prefix(6) { print("    \(r.prefix(76))") }
                if rader.count > 6 { print("    … och \(rader.count - 6) rader till") }
            } else {
                print("  ingen text")
            }

            Prov.kolla(text != nil, "\(url.lastPathComponent): text gick att få ut")
            if let text {
                Prov.kolla(text.count > 20, "\(url.lastPathComponent): texten är mer än en rubrik")
                Prov.kolla(!text.contains("<"), "\(url.lastPathComponent): inga taggar läckte igenom")
            }
        }
        return Prov.sammanfatta()
    }
}
