import Foundation

/// Kör om röstanalysen på en färdig inspelning.
///
///     Kundkoll --prov-omröst <inspelningsmapp> [förväntat antal röster]
///
/// Finns för att kunna mäta grupperingen mot verkligt material i stället för
/// att gissa: ett riktigt samtal har korta inpass som ett uppläst manus saknar.
enum Omröstprov {

    static func kör(mapp väg: String, förväntat: Int?) async -> Int32 {
        let mapp = URL(fileURLWithPath: väg)
        guard let data = try? Data(contentsOf: mapp.appending(path: "möte.json")),
              let inspelning = try? JSONDecoder.kundkoll.decode(Inspelning.self, from: data)
        else { print("Hittar ingen möte.json i \(väg)"); return 1 }

        guard Ljudlagring.fil("motpart", i: mapp) != nil else {
            print("Hittar inget ljud i \(väg)"); return 1
        }
        do { try await Ljudlagring.packaUpp(i: mapp) } catch {
            print("Kunde inte packa upp ljudet: \(error.localizedDescription)"); return 1
        }
        let fil = mapp.appending(path: "motpart.wav")

        let rader = inspelning.yttranden.filter { $0.röst == .motpart }
        print("\(inspelning.titel): \(formateraLängd(inspelning.längd)), \(rader.count) yttranden")

        let turer = Röstanalys.turer(av: rader)
        let längder = turer.map(\.längd).sorted()
        print("\(turer.count) turer, median \(String(format: "%.1f", längder[längder.count / 2])) s, "
              + "kortast \(String(format: "%.1f", längder.first ?? 0)), "
              + "längst \(String(format: "%.1f", längder.last ?? 0))")

        let sökvägar = Röstanalys.Sökvägar(
            python: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Projekt/transcriber/venv/bin/python"),
            skript: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appending(path: "scripts/rostanalys.py"))
        let analys = Röstanalys(sökvägar: sökvägar)

        // Avtrycken cachas: de beror bara på ljudet och turindelningen, och
        // att hämta om dem för varje tröskelsweep vore minuter av väntan.
        let cachefil = mapp.appending(path: ".avtryck-cache.json")
        var par: [(Röstanalys.Tur, Avtryck)] = []
        struct Rad: Codable { let start: Double; let slut: Double; let text: String; let vektor: [Float] }

        if let data = try? Data(contentsOf: cachefil),
           let rader = try? JSONDecoder().decode([Rad].self, from: data),
           rader.count == turer.count {
            print("Läser avtryck ur cachen (\(rader.count) st)")
            par = rader.map { (Röstanalys.Tur(start: $0.start, slut: $0.slut, text: $0.text),
                               Avtryck(vektor: $0.vektor, sekunder: $0.slut - $0.start)) }
        } else {
            print("Hämtar röstavtryck …")
            let t0 = Date()
            guard let hämtade = try? await analys.avtryck(fil: fil, turer: turer), !hämtade.isEmpty else {
                print("Fick inga avtryck."); return 1
            }
            par = hämtade
            print("  \(par.count) avtryck på \(String(format: "%.0f", Date().timeIntervalSince(t0))) s")
            let rader = par.map { Rad(start: $0.0.start, slut: $0.0.slut,
                                      text: $0.0.text, vektor: $0.1.vektor) }
            try? JSONEncoder().encode(rader).write(to: cachefil)
        }
        guard !par.isEmpty else { print("Inga avtryck."); return 1 }

        // Först pyannote, som är det appen faktiskt gör nu.
        var grupper: [Röstanalys.Röstgrupp] = []
        var metod = "klustring"
        let t1 = Date()
        if let segment = try? await analys.diarisera(fil: fil, antal: förväntat) {
            var avtryckPerTur: [Röstanalys.Tur: Avtryck] = [:]
            for (t, a) in par { avtryckPerTur[t] = a }
            grupper = Röstanalys.gruppera(turer: turer, avtryck: avtryckPerTur, enligt: segment)
            metod = "pyannote"
            print("  \(segment.count) talarsegment på \(String(format: "%.0f", Date().timeIntervalSince(t1))) s")
        }
        if grupper.isEmpty {
            grupper = Röstanalys.gruppera(par, väntade: förväntat)
            metod = "klustring"
        }
        print("metod: \(metod)")
        let total = grupper.reduce(0.0) { $0 + $1.längd }
        print("\n\(grupper.count) röster:")
        for (i, g) in grupper.prefix(12).enumerated() {
            print(String(format: "  %2d. %5.0f s (%4.1f %%), %3d turer  «%@»",
                         i + 1, g.längd, g.längd / total * 100, g.turer.count,
                         String(g.exempel.prefix(46))))
        }
        if grupper.count > 12 {
            let rest = grupper.dropFirst(12)
            print("  … och \(rest.count) till, tillsammans "
                  + String(format: "%.0f s (%.1f %%)",
                           rest.reduce(0.0) { $0 + $1.längd },
                           rest.reduce(0.0) { $0 + $1.längd } / total * 100))
        }

        // Hur stor del av taltiden ligger i de största grupperna?
        let störst = grupper.prefix(förväntat ?? 2).reduce(0.0) { $0 + $1.längd }
        print(String(format: "\nDe %d största rösterna täcker %.0f %% av taltiden.",
                     förväntat ?? 2, störst / total * 100))

        Prov.svit("Gruppering")
        Prov.kolla(!grupper.isEmpty, "ljudet gav röstgrupper")
        if let förväntat {
            Prov.kolla(grupper.count <= förväntat * 3,
                       "antalet röster är i rätt storleksordning (\(grupper.count) mot \(förväntat) väntade)")
            Prov.kolla(störst / total >= 0.9,
                       String(format: "de %d största täcker minst 90 %% av taltiden (%.0f %%)",
                              förväntat, störst / total * 100))
        }
        await Ljudlagring.packaIhop(i: mapp, packa: false)
        return Prov.sammanfatta()
    }
}
