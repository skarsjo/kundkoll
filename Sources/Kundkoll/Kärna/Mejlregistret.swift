import Foundation
import SQLite3

/// Söker i Mails eget register i stället för att fråga Mail.
///
/// Mail håller ett SQLite-register över alla mejl, `Envelope Index`, och
/// själva mejlen som .emlx-filer bredvid. Att fråga Mail via AppleScript
/// låste Mail i minuter med ett stort arkiv: Mail svarar på AppleScript i
/// sin egen huvudtråd, och `whose` går igenom varje mejl i lådan. Registret
/// har index och svarar på någon sekund, och Mail märker ingenting.
///
/// Kräver Full Disk Access: ~/Library/Mail är skyddat av systemet. Utan den
/// används AppleScript-vägen i `Mailen` som förut.
///
/// Registret öppnas skrivskyddat. Inte `immutable`: Mail skriver i
/// WAL-läge, och med `immutable` skulle det som ännu ligger i loggen — de
/// senaste mejlen — inte synas. En läsare i WAL-läge stör inte skrivaren.
enum Mejlregistret {

    enum Fel: LocalizedError, Equatable {
        case saknarBehörighet, finnsInte, kanInteÖppna(String), okäntSchema(String)

        var errorDescription: String? {
            switch self {
            case .saknarBehörighet:
                "\(Appnamn.visat) får inte läsa Mails register. Ge Full Disk Access i "
                    + "Systeminställningar → Integritet och säkerhet → Full Disk Access."
            case .finnsInte: "Mails register hittades inte."
            case .kanInteÖppna(let f): "Mails register gick inte att öppna: \(f)"
            case .okäntSchema(let f): "Mails register ser annorlunda ut än väntat: \(f)"
            }
        }
    }

    static var mailrot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Mail")
    }

    /// Rutan i Systeminställningar där Full Disk Access ges.
    static let behörighetsruta = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Den nyaste datamappen, V10 eller senare.
    static func datamapp(i rot: URL = mailrot) throws -> URL {
        let innehåll: [String]
        do {
            innehåll = try FileManager.default.contentsOfDirectory(atPath: rot.path)
        } catch {
            // Utan Full Disk Access nekas läsningen, men mappen finns.
            throw FileManager.default.fileExists(atPath: rot.path) ? Fel.saknarBehörighet : Fel.finnsInte
        }
        let versioner = innehåll.compactMap { n -> (Int, String)? in
            guard n.hasPrefix("V"), let v = Int(n.dropFirst()) else { return nil }
            return (v, n)
        }
        guard let senaste = versioner.max(by: { $0.0 < $1.0 }) else { throw Fel.finnsInte }
        return rot.appending(path: senaste.1)
    }

    static var harBehörighet: Bool {
        do {
            _ = try datamapp()
            return true
        } catch Fel.saknarBehörighet {
            return false
        } catch {
            return true
        }
    }

    // MARK: - Sökning

    /// Mejl från och till en kunds adresser, nyast först, och bilagorna i dem.
    ///
    /// Från: alla lådor utom papperskorg och skräppost — registret ser också
    /// arkiv och egna mappar, vilket AppleScript-vägen aldrig gjorde. Till:
    /// skickat-lådorna. `antal` och `maxBilagor` gäller per adress och
    /// riktning.
    static func sök(adresser: [String], bilagor mapp: URL, max antal: Int = 20,
                    maxBilagor: Int = 40, rot: URL = mailrot) throws -> Mailen.Svar {
        let data = try datamapp(i: rot)
        let db = try Databas(fil: data.appending(path: "MailData/Envelope Index"))
        let schema = try Schema(db)
        try FileManager.default.createDirectory(at: mapp, withIntermediateDirectories: true)

        var mejl: [Mailen.Mejl] = []
        var bilagor: [Bilagor.Bilaga] = []
        var sedda = Set<String>()
        for adress in adresser.map({ $0.lowercased().trimmingCharacters(in: .whitespaces) })
        where !adress.isEmpty {
            for riktning in ["fran", "till"] {
                let rader = try db.rader(schema.sql(riktning: riktning),
                                         [adress, String(antal * 4)])
                var mejlkvot = antal, bilagekvot = maxBilagor
                for rad in rader.compactMap(Rad.init) {
                    if riktning == "fran", lådtyp(rad.låda) == .skräp { continue }
                    guard mejlkvot > 0 || bilagekvot > 0 else { break }
                    // Samma mejl kan ligga i flera lådor (Gmails etiketter).
                    guard sedda.insert(rad.unikt).inserted else { continue }
                    let fil = emlx(id: rad.id, låda: rad.låda, i: data)
                    let tolkat = fil.flatMap { try? Data(contentsOf: $0) }.map(Mimetolk.tolkaEmlx)
                    if mejlkvot > 0 {
                        mejlkvot -= 1
                        mejl.append(rad.mejl(riktning: riktning, tolkat: tolkat))
                    }
                    if bilagekvot > 0, let fil {
                        let nya = spara(bilagor: tolkat?.bilagor ?? [], frånFil: fil, id: rad.id,
                                        ämne: rad.ämne, till: mapp, max: bilagekvot)
                        bilagekvot -= nya.count
                        bilagor += nya
                    }
                }
            }
        }
        var seddaID = Set<String>()
        mejl = mejl.filter { seddaID.insert($0.id).inserted }
            .sorted { ($0.datum ?? .distantPast) > ($1.datum ?? .distantPast) }
        var seddaFiler = Set<String>()
        bilagor = bilagor.filter { seddaFiler.insert($0.fil).inserted }
        return Mailen.Svar(mejl: mejl, bilagor: bilagor)
    }

    /// En träff ur registret.
    private struct Rad {
        var id: Int64
        var datum: Date?
        var adress: String
        var namn: String
        var ämne: String
        var låda: String
        var unikt: String
        var sammandrag: String

        init?(_ f: [String?]) {
            guard f.count >= 8, let id = f[0].flatMap({ Int64($0) }) else { return nil }
            self.id = id
            datum = f[1].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            adress = f[2] ?? ""
            namn = f[3] ?? ""
            ämne = (f[4] ?? "").isEmpty ? "(utan ämne)" : f[4]!
            låda = f[5] ?? ""
            unikt = f[6] ?? "\(id)"
            sammandrag = f[7] ?? ""
        }

        func mejl(riktning: String, tolkat: Mimetolk.Meddelande?) -> Mailen.Mejl {
            var text = tolkat?.text ?? ""
            if text.isEmpty { text = sammandrag }
            return Mailen.Mejl(
                datum: datum,
                datumText: datum.map { Mejlregistret.datumformat.string(from: $0) } ?? "",
                avsändare: namn.isEmpty ? adress : "\(namn) <\(adress)>",
                ämne: ämne,
                meddelandeID: tolkat?.meddelandeID ?? "",
                konto: URL(string: låda)?.host ?? "",
                låda: Mejlregistret.lådnamn(låda),
                riktning: riktning,
                text: Mailen.städaBrödtext(String(text.prefix(4000))))
        }
    }

    static let datumformat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE, d MMMM yyyy 'at' HH:mm:ss"
        return f
    }()

    // MARK: - Lådor och filer

    enum Lådtyp { case skickat, skräp, övrigt }

    static func lådnamn(_ url: String) -> String {
        URL(string: url)?.pathComponents.filter { $0 != "/" }.joined(separator: "/") ?? url
    }

    static func lådtyp(_ url: String) -> Lådtyp {
        let n = lådnamn(url).lowercased()
        if ["trash", "junk", "spam", "deleted", "papperskorg", "skräp", "borttagna"]
            .contains(where: n.contains) { return .skräp }
        if ["sent", "skickat", "skickade"].contains(where: n.contains) { return .skickat }
        return .övrigt
    }

    /// Lådans mapp på disk. `imap://KONTO/INBOX` → `V10/KONTO/INBOX.mbox`,
    /// `imap://KONTO/A/B` → `V10/KONTO/A.mbox/B.mbox`, `local:///X` →
    /// `V10/Mailboxes/X.mbox`.
    static func mboxmapp(för url: String, i data: URL) -> URL? {
        guard let u = URL(string: url) else { return nil }
        var väg = u.scheme == "local" || (u.host ?? "").isEmpty
            ? data.appending(path: "Mailboxes")
            : data.appending(path: u.host!)
        for del in u.pathComponents where del != "/" {
            väg = väg.appending(path: del + ".mbox")
        }
        return väg
    }

    /// Mappen under `Data` där ett mejl med visst nummer ligger: tusentalen
    /// baklänges, en siffra per nivå. 123456 → `3/2/1`, under 1000 → ingen.
    static func sifferväg(_ id: Int64) -> [String] {
        let tusental = id / 1000
        guard tusental > 0 else { return [] }
        return String(tusental).reversed().map(String.init)
    }

    /// Mejlets .emlx-fil, hel eller partiell (då ligger bilagorna för sig).
    static func emlx(id: Int64, låda: String, i data: URL) -> URL? {
        guard let mbox = mboxmapp(för: låda, i: data) else { return nil }
        let fm = FileManager.default
        // Inne i .mbox ligger en mapp per lager, med ett UUID som namn.
        let lager = ((try? fm.contentsOfDirectory(at: mbox, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appending(path: "Data") } + [mbox.appending(path: "Data")]
        for d in lager where fm.fileExists(atPath: d.path) {
            var m = d
            for s in sifferväg(id) { m = m.appending(path: s) }
            m = m.appending(path: "Messages")
            for namn in ["\(id).emlx", "\(id).partial.emlx"] {
                let f = m.appending(path: namn)
                if fm.fileExists(atPath: f.path) { return f }
            }
        }
        return nil
    }

    /// Sparar mejlets bilagor i kundens bilagemapp. En hel .emlx bär dem i
    /// sig; en partiell har dem i `Attachments/<nummer>/` bredvid.
    private static func spara(bilagor inbäddade: [Mimetolk.Bilaga], frånFil fil: URL, id: Int64,
                              ämne: String, till mapp: URL, max: Int) -> [Bilagor.Bilaga] {
        let fm = FileManager.default
        var ut: [Bilagor.Bilaga] = []
        var kandidater: [(namn: String, data: () -> Data?, storlek: Int)] =
            inbäddade.map { b in (b.namn, { b.data }, b.data.count) }
        if fil.lastPathComponent.hasSuffix(".partial.emlx") {
            let mapp = fil.deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Attachments/\(id)")
            if let filer = fm.enumerator(at: mapp, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                for case let f as URL in filer {
                    let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    guard v?.isRegularFile == true else { continue }
                    kandidater.append((f.lastPathComponent, { try? Data(contentsOf: f) }, v?.fileSize ?? 0))
                }
            }
        }
        for k in kandidater where ut.count < max {
            let namn = rensaNamn(k.namn)
            // Stora filer är sällan text; signaturbilder och kalenderfiler
            // tillför inget — samma bedömning som för AppleScript-vägen.
            guard k.storlek < 25 * 1024 * 1024, Bilagor.ärIntressant(namn) else { continue }
            let mål = mapp.appending(path: namn)
            let befintlig = (try? fm.attributesOfItem(atPath: mål.path)[.size] as? Int) ?? nil
            if befintlig != k.storlek {
                guard let data = k.data(), (try? data.write(to: mål, options: .atomic)) != nil else { continue }
            }
            ut.append(Bilagor.Bilaga(ämne: ämne, namn: namn, fil: mål.standardizedFileURL.path,
                                     storlek: k.storlek))
        }
        return ut
    }

    /// Namnet kommer från avsändaren: snedstreck och kolon blir bindestreck,
    /// och en inledande punkt får ett understreck före sig, så att filen
    /// aldrig hamnar utanför bilagemappen eller blir dold.
    static func rensaNamn(_ namn: String) -> String {
        var s = namn.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix(".") { s = "_" + s }
        return s.isEmpty ? "bilaga" : s
    }

    // MARK: - Schema

    /// Vilka kolumner registret har. De som krävs kontrolleras; de som bara
    /// gör svaret bättre används när de finns.
    struct Schema {
        var unikt = "m.ROWID"
        var inteBorttagen = ""
        var sammandrag = "''"
        var sammandragJoin = ""
        var prefix = ""

        init(_ db: Databas) throws {
            func kolumner(_ tabell: String) throws -> Set<String> {
                Set(try db.rader("PRAGMA table_info(\(tabell))", []).compactMap { $0.count > 1 ? $0[1] : nil })
            }
            let krav: [(String, [String])] = [
                ("messages", ["sender", "subject", "date_received", "mailbox"]),
                ("addresses", ["address", "comment"]),
                ("subjects", ["subject"]),
                ("mailboxes", ["url"]),
                ("recipients", ["message", "address"]),
            ]
            var saknas: [String] = []
            var meddelanden: Set<String> = []
            for (tabell, fält) in krav {
                let finns = try kolumner(tabell)
                if tabell == "messages" { meddelanden = finns }
                saknas += fält.filter { !finns.contains($0) }.map { "\(tabell).\($0)" }
            }
            guard saknas.isEmpty else { throw Fel.okäntSchema("saknar " + saknas.joined(separator: ", ")) }

            if meddelanden.contains("global_message_id") { unikt = "m.global_message_id" }
            if meddelanden.contains("deleted") { inteBorttagen = "AND m.deleted = 0" }
            if meddelanden.contains("subject_prefix") { prefix = "COALESCE(m.subject_prefix, '') || " }
            if meddelanden.contains("summary"), try kolumner("summaries").contains("summary") {
                sammandrag = "COALESCE(su.summary, '')"
                sammandragJoin = "LEFT JOIN summaries su ON su.ROWID = m.summary"
            }
        }

        /// Kolumnerna: id, datum, adress, namn, ämne, låda, unikt, sammandrag.
        func sql(riktning: String) -> String {
            let urval = """
                SELECT DISTINCT m.ROWID, m.date_received, a.address, a.comment,
                       \(prefix)COALESCE(s.subject, ''), mb.url, \(unikt), \(sammandrag)
                """
            let resten = """
                JOIN addresses a ON a.ROWID = m.sender
                LEFT JOIN subjects s ON s.ROWID = m.subject
                JOIN mailboxes mb ON mb.ROWID = m.mailbox
                \(sammandragJoin)
                """
            if riktning == "fran" {
                return """
                    \(urval)
                    FROM messages m
                    \(resten)
                    WHERE lower(a.address) = ?1 \(inteBorttagen)
                    ORDER BY m.date_received DESC LIMIT ?2
                    """
            }
            return """
                \(urval)
                FROM recipients r
                JOIN addresses ra ON ra.ROWID = r.address
                JOIN messages m ON m.ROWID = r.message
                \(resten)
                WHERE lower(ra.address) = ?1 \(inteBorttagen)
                  AND (mb.url LIKE '%sent%' OR mb.url LIKE '%skickat%' OR mb.url LIKE '%skickade%')
                ORDER BY m.date_received DESC LIMIT ?2
                """
        }
    }

    // MARK: - SQLite

    final class Databas {
        private var db: OpaquePointer?

        init(fil: URL) throws {
            guard FileManager.default.fileExists(atPath: fil.path) else { throw Fel.finnsInte }
            let väg = fil.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fil.path
            let flaggor = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
            var kod = sqlite3_open_v2("file:\(väg)?mode=ro", &db, flaggor, nil)
            if kod != SQLITE_OK {
                // Går WAL-filerna inte att röra kan registret ändå läsas som
                // det ligger på disk — utan de allra senaste mejlen.
                sqlite3_close(db)
                db = nil
                kod = sqlite3_open_v2("file:\(väg)?mode=ro&immutable=1", &db, flaggor, nil)
            }
            guard kod == SQLITE_OK else {
                let text = db.map { String(cString: sqlite3_errmsg($0)) } ?? "kod \(kod)"
                sqlite3_close(db)
                throw kod == SQLITE_AUTH || kod == SQLITE_PERM ? Fel.saknarBehörighet : Fel.kanInteÖppna(text)
            }
            sqlite3_busy_timeout(db, 3000)
        }

        deinit { sqlite3_close(db) }

        /// Kör en fråga och ger varje rad som text.
        func rader(_ sql: String, _ värden: [String]) throws -> [[String?]] {
            var sats: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &sats, nil) == SQLITE_OK else {
                throw Fel.kanInteÖppna(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(sats) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (i, v) in värden.enumerated() {
                if let tal = Int64(v) {
                    sqlite3_bind_int64(sats, Int32(i + 1), tal)
                } else {
                    sqlite3_bind_text(sats, Int32(i + 1), v, -1, transient)
                }
            }
            var ut: [[String?]] = []
            while true {
                let steg = sqlite3_step(sats)
                if steg == SQLITE_DONE { break }
                guard steg == SQLITE_ROW else {
                    throw Fel.kanInteÖppna(String(cString: sqlite3_errmsg(db)))
                }
                let n = sqlite3_column_count(sats)
                ut.append((0..<n).map { i in
                    sqlite3_column_text(sats, i).map { String(cString: $0) }
                })
            }
            return ut
        }
    }
}
