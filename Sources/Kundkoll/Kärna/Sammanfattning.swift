import Foundation

/// Vad ett möte landade i.
///
/// Ett fyrtio minuter långt samtal blir fyra hundra rader transkript. Det man
/// behöver därifrån är tre saker: vad beslutades, vad lovade jag, och vad är
/// fortfarande öppet. Resten är underlag man går tillbaka till vid behov.
struct Mötessammanfattning: Codable, Hashable {
    var kärna: String
    var beslut: [String]
    var åtaganden: [Åtagande]
    var öppet: [String]
    var skriven = Date()

    struct Åtagande: Codable, Hashable, Identifiable {
        var id = UUID()
        var vad: String
        /// Vem som ska göra det, med namnet som står i transkriptet.
        var vem: String?
        /// När, som det sades — "före fredag", "nästa vecka".
        var när: String?
        /// När som ett riktigt datum, när modellen kunde räkna ut det.
        var senast: Date?
        var klart = false

        init(id: UUID = UUID(), vad: String, vem: String? = nil,
             när: String? = nil, senast: Date? = nil, klart: Bool = false) {
            self.id = id
            self.vad = vad
            self.vem = vem
            self.när = när
            self.senast = senast
            self.klart = klart
        }

        /// Skriven för hand: se `Inspelning`.
        init(from avkodare: Decoder) throws {
            let c = try avkodare.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            vad = try c.decodeIfPresent(String.self, forKey: .vad) ?? ""
            vem = try c.decodeIfPresent(String.self, forKey: .vem)
            när = try c.decodeIfPresent(String.self, forKey: .när)
            senast = try c.decodeIfPresent(Date.self, forKey: .senast)
            klart = try c.decodeIfPresent(Bool.self, forKey: .klart) ?? false
        }
    }

    var tom: Bool { beslut.isEmpty && åtaganden.isEmpty && öppet.isEmpty }

    init(kärna: String, beslut: [String], åtaganden: [Åtagande],
         öppet: [String], skriven: Date = Date()) {
        self.kärna = kärna
        self.beslut = beslut
        self.åtaganden = åtaganden
        self.öppet = öppet
        self.skriven = skriven
    }

    /// Ligger inne i möte.json. Faller den går hela inspelningen förlorad ur
    /// listan, så den läses lika försiktigt som inspelningen själv.
    init(from avkodare: Decoder) throws {
        let c = try avkodare.container(keyedBy: CodingKeys.self)
        kärna = try c.decodeIfPresent(String.self, forKey: .kärna) ?? ""
        beslut = try c.decodeIfPresent([String].self, forKey: .beslut) ?? []
        åtaganden = try c.decodeIfPresent([Åtagande].self, forKey: .åtaganden) ?? []
        öppet = try c.decodeIfPresent([String].self, forKey: .öppet) ?? []
        skriven = try c.decodeIfPresent(Date.self, forKey: .skriven) ?? Date()
    }
}

/// Skriver sammanfattningen med den modell som valts för chatten.
actor Sammanfattare {

    private let chatt: Chatt

    init(chatt: Chatt = Chatt()) { self.chatt = chatt }

    /// Ett transkript kan vara långt. Det som betyder något för besluten sägs
    /// nästan alltid i klartext, så hela texten skickas — men kapad, så att en
    /// tre timmar lång inspelning inte spränger fönstret.
    private let maxTecken = 60_000

    func skriv(för inspelning: Inspelning, kund: String) async throws -> Mötessammanfattning {
        let rader = inspelning.yttranden.map { y in
            "[\(y.tidsstämpel)] \(y.etikett(inspelning.röstnamn, enspårig: inspelning.enspårig)): \(y.text)"
        }
        var text = rader.joined(separator: "\n")
        if text.count > maxTecken {
            // Slutet av ett möte bär besluten; början bär sammanhanget.
            let halva = maxTecken / 2
            text = String(text.prefix(halva)) + "\n\n[…]\n\n" + String(text.suffix(halva))
        }

        let dag: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: inspelning.inledd)
        }()
        let uppdrag = """
        Här är transkriptet från ett möte med kunden \(kund), hållet \(dag).

        Sammanfatta det som JSON med exakt dessa fält:

        {
          "kärna": "två eller tre meningar om vad mötet handlade om",
          "beslut": ["det som faktiskt bestämdes"],
          "åtaganden": [{"vad": "…", "vem": "namn eller null", \
        "när": "som det sades, eller null", "senast": "ÅÅÅÅ-MM-DD eller null"}],
          "öppet": ["frågor som lämnades obesvarade"]
        }

        "senast" är sista dagen som ett riktigt datum, räknat från mötesdagen \
        \(dag) — "före fredag" blir fredagens datum. Går det inte att räkna \
        ut, null.

        Ta bara med sådant som verkligen sades. Hellre en tom lista än ett
        påhittat beslut. Skriv på svenska, kort och konkret, utan artigheter.
        Svara med enbart JSON.

        Transkript:
        \(text)
        """

        let val = await chatt.modellval
        let svarstext: String
        if let ollama = Self.ollamaAdress(för: val) {
            svarstext = try await Self.frågaOllama(uppdrag, modell: val.modell, adress: ollama)
        } else {
            svarstext = try await chatt.fråga(uppdrag, om: kund, projekt: inspelning.projekt,
                                              träffar: [], historik: []).text
        }
        guard let tolkad = Self.tolka(svarstext) else { throw Fel.otolkbart }
        return tolkad
    }

    // MARK: - Ollama direkt

    /// Ollamas OpenAI-gränssnitt kör med standardfönstret, ofta 4096 tokens.
    /// Ett transkript på 60 000 tecken kapas då bakifrån och framåt, och med
    /// början försvinner uppdraget — modellen ser bara en bit samtal och
    /// svarar med fritext. qwen3 tänker dessutom högt och kan lägga hela
    /// svarsutrymmet på det. Ollamas eget gränssnitt låter oss sätta fönstret,
    /// stänga av tänkandet och kräva svar enligt ett JSON-schema.
    static func ollamaAdress(för val: Modellval) -> URL? {
        guard val.leverantör == .lokal, let url = val.url, url.port == 11434,
              var delar = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        delar.path = "/api/chat"
        delar.query = nil
        return delar.url
    }

    /// Fönstret räknas fram ur texten: svensk text blir ungefär en token per
    /// tre tecken. Större fönster än nödvändigt kostar minne i onödan.
    static func fönster(för uppdrag: String) -> Int {
        let behov = uppdrag.count / 3 + 4096
        let steg = 4096
        return min(max(8192, (behov + steg - 1) / steg * steg), 32768)
    }

    static let schema: [String: Any] = {
        let text: [String: Any] = ["type": "string"]
        let kanskeText: [String: Any] = ["type": ["string", "null"]]
        let lista: [String: Any] = ["type": "array", "items": text]
        let åtagande: [String: Any] = [
            "type": "object",
            "properties": ["vad": text, "vem": kanskeText,
                           "när": kanskeText, "senast": kanskeText] as [String: Any],
            "required": ["vad"],
        ]
        return [
            "type": "object",
            "properties": [
                "kärna": text,
                "beslut": lista,
                "åtaganden": ["type": "array", "items": åtagande] as [String: Any],
                "öppet": lista,
            ] as [String: Any],
            "required": ["kärna", "beslut", "åtaganden", "öppet"],
        ]
    }()

    private static func frågaOllama(_ uppdrag: String, modell: String, adress: URL) async throws -> String {
        let kropp: [String: Any] = [
            "model": modell,
            "messages": [
                ["role": "system", "content":
                    "Du sammanfattar mötestranskript åt en konsult. Svara alltid med JSON enligt schemat."],
                ["role": "user", "content": uppdrag],
            ],
            "stream": false,
            "format": schema,
            "think": false,
            "options": [
                "num_ctx": fönster(för: uppdrag),
                "num_predict": 4096,
                "temperature": 0.2,
            ] as [String: Any],
        ]
        var r = URLRequest(url: adress)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: kropp)
        // Ett långt möte på en laptop kan ta ett par minuter.
        r.timeoutInterval = 600

        let (data, svar): (Data, URLResponse)
        do {
            (data, svar) = try await URLSession.shared.data(for: r)
        } catch {
            throw Fel.nårInteOllama
        }
        guard let http = svar as? HTTPURLResponse, http.statusCode == 200 else {
            throw Fel.frånOllama(String(data: data, encoding: .utf8) ?? "")
        }
        struct Yttre: Decodable {
            struct M: Decodable { let content: String? }
            let message: M
        }
        guard let text = (try? JSONDecoder().decode(Yttre.self, from: data))?.message.content,
              !text.isEmpty else { throw Fel.otolkbart }
        return text
    }

    /// Modeller lägger gärna JSON i en kodruta, eller skriver en rad före.
    static func tolka(_ text: String) -> Mötessammanfattning? {
        var rent = text
        // Tänkande modeller (qwen3, deepseek-r1) kan skriva ut sitt
        // resonemang först, och där finns gärna klamrar som stör.
        while let start = rent.range(of: "<think>"),
              let slut = rent.range(of: "</think>", range: start.upperBound..<rent.endIndex) {
            rent.removeSubrange(start.lowerBound..<slut.upperBound)
        }
        rent = rent.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = rent.range(of: "```") {
            rent = String(rent[start.upperBound...])
            if rent.hasPrefix("json") { rent = String(rent.dropFirst(4)) }
            if let slut = rent.range(of: "```") { rent = String(rent[..<slut.lowerBound]) }
        }
        guard let första = rent.firstIndex(of: "{"), let sista = rent.lastIndex(of: "}") else {
            return nil
        }
        rent = String(rent[första...sista])

        struct Rå: Decodable {
            struct Å: Decodable {
                let vad: String?; let vem: String?; let när: String?; let senast: String?
            }
            let kärna: String?
            let beslut: [String]?
            let åtaganden: [Å]?
            let öppet: [String]?
        }
        guard let rå = try? JSONDecoder().decode(Rå.self, from: Data(rent.utf8)) else { return nil }
        return Mötessammanfattning(
            kärna: rå.kärna ?? "",
            beslut: rå.beslut ?? [],
            åtaganden: (rå.åtaganden ?? []).compactMap { å -> Mötessammanfattning.Åtagande? in
                guard let vad = tomSomNil(å.vad) else { return nil }
                return Mötessammanfattning.Åtagande(vad: vad, vem: tomSomNil(å.vem), när: tomSomNil(å.när),
                      senast: Uppgift.dag(tomSomNil(å.senast)))
            },
            öppet: rå.öppet ?? [])
    }

    private static func tomSomNil(_ s: String?) -> String? {
        guard let s, !s.isEmpty, s.lowercased() != "null" else { return nil }
        return s
    }

    enum Fel: LocalizedError {
        case otolkbart
        case nårInteOllama
        case frånOllama(String)
        var errorDescription: String? {
            switch self {
            case .otolkbart: "Sammanfattningen gick inte att tolka."
            case .nårInteOllama: "Ollama svarar inte på 127.0.0.1:11434. Starta den med: ollama serve"
            case .frånOllama(let text): "Ollama svarade med ett fel: \(text.prefix(300))"
            }
        }
    }
}
