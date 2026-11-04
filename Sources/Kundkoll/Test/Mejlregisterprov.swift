import Foundation
import SQLite3

/// Söker i Mails riktiga register, och jämför med AppleScript-vägen.
///
///     Kundkoll --prov-mejlregister <adress> [--jämför]
///
/// Kräver Full Disk Access för det program som kör provet — Terminal, eller
/// den app terminalen ligger i. Bilagorna sparas i en tillfällig mapp.
/// `--jämför` kör också AppleScript-vägen, som kan låsa Mail i minuter.
enum Mejlregisterprov {

    static func kör(adress: String, jämför: Bool) async -> Int32 {
        Prov.svit("Mejlregistret skarpt")
        let mapp = FileManager.default.temporaryDirectory
            .appending(path: "kundkoll-mejlregister-\(UUID().uuidString)")

        do {
            let data = try Mejlregistret.datamapp()
            print("register: \(data.path)/MailData/Envelope Index")
        } catch {
            print(error.localizedDescription)
            Prov.kolla(false, "registret går att läsa")
            return Prov.sammanfatta()
        }

        let t0 = Date()
        do {
            let svar = try Mejlregistret.sök(adresser: [adress], bilagor: mapp)
            let tid = Date().timeIntervalSince(t0)
            let medText = svar.mejl.filter { !$0.text.isEmpty }.count
            let medID = svar.mejl.filter { !$0.meddelandeID.isEmpty }.count
            print(String(format: "\nregistret: %.2f s", tid))
            print("  \(svar.mejl.count) mejl (\(svar.mejl.filter(\.skickat).count) skickade), "
                  + "\(medText) med brödtext, \(medID) med meddelande-id")
            print("  \(svar.bilagor.count) bilagor i \(mapp.path)")
            for m in svar.mejl.prefix(8) {
                print("  \(m.skickat ? "→" : "←") \(m.datum.map(DateFormatter.klocka.string) ?? "?")  "
                      + "\(m.ämne.prefix(50))  [\(m.låda)]")
            }
            Prov.kolla(!svar.mejl.isEmpty, "registret gav mejl")
            Prov.kolla(tid < 10, "registret svarade på under 10 s")
            Prov.kolla(medID * 2 >= svar.mejl.count, "minst hälften av mejlen hittades som fil")

            if jämför {
                print("\nAppleScript-vägen (Mail kan bli upptaget en stund) …")
                // Från .build ligger skriptet inte i någon appbundel; då tas
                // det ur källträdet, som --prov-bilagehämtning gör.
                let iBundel = URL(fileURLWithPath: Bundle.main.bundlePath)
                    .appending(path: "Contents/Resources/mail-sok.applescript")
                let iKällan = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appending(path: "Resources/mail-sok.applescript")
                let skript = FileManager.default.fileExists(atPath: iBundel.path) ? iBundel : iKällan
                let t1 = Date()
                let gammalt: Mailen.Svar
                do {
                    gammalt = try await Mailen(skript: skript)
                        .sök(adresser: [adress], bilagor: mapp.appending(path: "as"))
                } catch {
                    print("Gick inte: \(error.localizedDescription)")
                    if !FileManager.default.fileExists(atPath: skript.path) {
                        print("(Kör från kundkoll-mappen, så att Resources/mail-sok.applescript hittas.)")
                    }
                    Prov.kolla(false, "AppleScript-vägen gick att jämföra med")
                    return Prov.sammanfatta()
                }
                print(String(format: "AppleScript: %.1f s, %d mejl, %d bilagor",
                             Date().timeIntervalSince(t1), gammalt.mejl.count, gammalt.bilagor.count))
                let nya = Set(svar.mejl.map(\.id))
                let saknas = gammalt.mejl.filter { !nya.contains($0.id) }
                print("  \(saknas.count) mejl som AppleScript hittade men inte registret")
                for m in saknas.prefix(5) { print("    \(m.ämne.prefix(50))  [\(m.låda)]") }
            }
        } catch {
            print("Gick inte: \(error.localizedDescription)")
            Prov.kolla(false, "sökningen i registret gick igenom")
        }
        return Prov.sammanfatta()
    }
}

extension Tester {

    static func mejlregistret() {
        Prov.svit("Mejlregistret")

        do {   // kodade ord och parametrar
            Prov.lika(Mimetolk.avkodaOrd("=?utf-8?Q?R=C3=A4kna?= =?utf-8?Q?_mer?="), "Räkna mer",
                      "Q-kodade ord, blanksteget mellan dem försvinner")
            Prov.lika(Mimetolk.avkodaOrd("Re: =?iso-8859-1?B?5A==?= tack"), "Re: ä tack",
                      "B-kodat i ISO 8859-1 mitt i texten")
            Prov.lika(Mimetolk.avkodaOrd("vanlig text"), "vanlig text", "okodat lämnas")
            let p = Mimetolk.värdeOchParametrar(
                "attachment; filename*0*=utf-8''Lev%C3%A5; filename*1=\"rans.pdf\"")
            Prov.lika(p.värde, "attachment", "värdet före parametrarna")
            Prov.lika(p.param["filename"], "Levårans.pdf", "uppdelat RFC 2231-namn")
            Prov.lika(Mimetolk.värdeOchParametrar("text/plain; charset=\"a;b\"").param["charset"], "a;b",
                      "semikolon inom citat delar inte")
            Prov.lika(Mimetolk.utanTaggar("<p>Hej&nbsp;<b>du</b></p><style>x{}</style>"), "Hej du",
                      "html blir text")
        }

        do {   // ett helt mejl
            let mejl = """
                From: Anna <anna@acme.se>
                Message-Id: <m1@acme.se>
                Content-Type: multipart/alternative; boundary=ALT

                --ALT
                Content-Type: text/html; charset=utf-8

                <p>Bara html</p>
                --ALT--
                """
            let t = Mimetolk.tolka(Data(mejl.utf8))
            Prov.lika(t.text, "Bara html", "utan text/plain används html utan taggar")
            Prov.lika(t.meddelandeID, "<m1@acme.se>", "meddelande-id ur rubrikerna")
            Prov.lika(t.bilagor.count, 0, "inga bilagor")
        }

        // Ett påhittat Mail-bibliotek med register och .emlx-filer.
        let rot = FileManager.default.temporaryDirectory.appending(path: "kundkoll-mail-\(UUID().uuidString)")
        let data = rot.appending(path: "V10")
        defer { try? FileManager.default.removeItem(at: rot) }
        do {
            try byggBibliotek(data)
        } catch {
            Prov.kolla(false, "provbiblioteket gick att bygga: \(error)")
            return
        }

        do {   // vägar
            Prov.lika(Mejlregistret.sifferväg(1_001_234), ["1", "0", "0", "1"], "tusentalen baklänges")
            Prov.lika(Mejlregistret.sifferväg(999), [], "under tusen: ingen undermapp")
            Prov.lika(Mejlregistret.mboxmapp(för: "imap://KONTO/Arkiv/2025", i: data)?.path,
                      data.appending(path: "KONTO/Arkiv.mbox/2025.mbox").path, "nästlade lådor")
            Prov.lika(Mejlregistret.mboxmapp(för: "local:///Utkast", i: data)?.path,
                      data.appending(path: "Mailboxes/Utkast.mbox").path, "lokala lådor")
            Prov.kolla(Mejlregistret.lådtyp("imap://K/Sent%20Messages") == .skickat, "skickat känns igen")
            Prov.kolla(Mejlregistret.lådtyp("imap://K/Papperskorg") == .skräp, "papperskorgen känns igen")
            Prov.lika(Mejlregistret.rensaNamn("../a/b:c"), "_..-a-b-c", "namn kan inte peka ut ur mappen")
        }

        let mapp = rot.appending(path: "Kund/Mail/Bilagor")
        do {   // sökningen
            let svar = try Mejlregistret.sök(adresser: ["Anna@Acme.se"], bilagor: mapp, rot: rot)
            Prov.lika(svar.mejl.map(\.ämne), ["Offert", "Re: Avtal", "Gammalt"],
                      "från alla lådor utom papperskorgen, skickat, utan borttagna och dubbletter")
            let offert = svar.mejl.first
            Prov.lika(offert?.avsändare, "Anna Svensson <anna@acme.se>", "avsändaren med namn")
            Prov.lika(offert?.text, "Hej! Här är offerten. Mvh Anna", "brödtexten ur .emlx, QP-avkodad")
            Prov.lika(offert?.meddelandeID, "<m1@acme.se>", "meddelande-id, så att mejlet går att öppna")
            Prov.lika(offert?.låda, "INBOX", "lådans namn")
            Prov.kolla(svar.mejl.dropFirst().first?.skickat == true, "det skickade räknas som skickat")
            Prov.lika(svar.mejl.last?.text, "", "mejl utan fil kommer med ändå")
            Prov.lika(svar.bilagor.map(\.namn).sorted(), ["avtal.txt", "offert å.pdf"],
                      "bilagor både inbäddade och från Attachments")
            let pdf = svar.bilagor.first { $0.namn.hasSuffix(".pdf") }
            Prov.lika(pdf.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0.fil)) },
                      Data("%PDF-1.4\n".utf8), "bilagan base64-avkodad")
            Prov.kolla(svar.bilagor.allSatisfy { Arkivet.ligger($0.fil, i: mapp) }, "bilagorna i kundens mapp")

            let igen = try Mejlregistret.sök(adresser: ["anna@acme.se"], bilagor: mapp, rot: rot)
            Prov.lika(igen.bilagor.count, svar.bilagor.count, "en andra sökning ger samma bilagor")
            let tom = try Mejlregistret.sök(adresser: ["ingen@x.se"], bilagor: mapp, rot: rot)
            Prov.lika(tom.mejl.count, 0, "okänd adress ger inga mejl")
        } catch {
            Prov.kolla(false, "sökningen gick igenom: \(error.localizedDescription)")
        }

        do {   // fel
            let saknas = rot.appending(path: "finns-inte")
            Prov.kolla((try? Mejlregistret.sök(adresser: ["a@b.se"], bilagor: mapp, rot: saknas)) == nil,
                       "utan Mail-mapp blir det fel, inte tomt svar")
            let fel = Result { try Mejlregistret.datamapp(i: saknas) }
            if case .failure(let f) = fel { Prov.lika(f as? Mejlregistret.Fel, .finnsInte, "finnsInte") }

            let annan = rot.appending(path: "annat")
            try FileManager.default.createDirectory(at: annan.appending(path: "V11/MailData"),
                                                    withIntermediateDirectories: true)
            try skapaDB(annan.appending(path: "V11/MailData/Envelope Index"),
                        "CREATE TABLE messages(ROWID INTEGER PRIMARY KEY, sender INT)")
            Prov.lika(try Mejlregistret.datamapp(i: annan).lastPathComponent, "V11", "nyaste versionen väljs")
            let schemafel = Result { try Mejlregistret.sök(adresser: ["a@b.se"], bilagor: mapp, rot: annan) }
            if case .failure(let f) = schemafel, case .okäntSchema? = f as? Mejlregistret.Fel {
                Prov.kolla(true, "ett okänt schema ger okäntSchema")
            } else {
                Prov.kolla(false, "ett okänt schema ger okäntSchema")
            }
        } catch {
            Prov.kolla(false, "felfallen gick att ställa upp: \(error)")
        }
    }

    private static func skapaDB(_ fil: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(fil.path, &db) == SQLITE_OK else { throw Mejlregistret.Fel.finnsInte }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw Mejlregistret.Fel.kanInteÖppna(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func emlx(_ meddelande: String) -> Data {
        let kropp = Data(meddelande.replacingOccurrences(of: "\n", with: "\r\n").utf8)
        return Data("\(kropp.count)\n".utf8) + kropp + Data("<?xml version=\"1.0\"?><plist/>".utf8)
    }

    /// Anna skriver från acme.se. Offerten (1 001 234) ligger i inkorgen och
    /// som Gmail-dubblett i Arkiv; "Gammalt" i Arkiv/2025 saknar fil; ett
    /// mejl i papperskorgen och ett borttaget ska inte med; svaret till
    /// henne ligger i skickat som partiell .emlx med bilagan för sig; ett
    /// mejl där hon bara står som kopia i inkorgen räknas inte som skickat.
    private static func byggBibliotek(_ data: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: data.appending(path: "MailData"), withIntermediateDirectories: true)
        try skapaDB(data.appending(path: "MailData/Envelope Index"), """
            CREATE TABLE addresses(ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
            CREATE TABLE subjects(ROWID INTEGER PRIMARY KEY, subject TEXT);
            CREATE TABLE mailboxes(ROWID INTEGER PRIMARY KEY, url TEXT);
            CREATE TABLE messages(ROWID INTEGER PRIMARY KEY, sender INT, subject INT, subject_prefix TEXT,
                                  date_received INT, mailbox INT, deleted INT, global_message_id INT);
            CREATE TABLE recipients(ROWID INTEGER PRIMARY KEY, message INT, address INT, type INT);
            INSERT INTO addresses VALUES (1,'anna@acme.se','Anna Svensson'),(2,'jag@rackfish.com','Johan'),
                                         (3,'kollega@rackfish.com','');
            INSERT INTO subjects VALUES (1,'Offert'),(2,'Gammalt'),(3,'Avtal'),(4,'Skräp'),(5,'Kopia');
            INSERT INTO mailboxes VALUES (1,'imap://KONTO/INBOX'),(2,'imap://KONTO/Sent%20Messages'),
                                         (3,'imap://KONTO/Trash'),(4,'imap://KONTO/Arkiv/2025'),
                                         (5,'imap://KONTO/Arkiv');
            INSERT INTO messages VALUES
                (1001234,1,1,NULL,1780000000,1,0,100),
                (1001240,1,1,NULL,1779999999,5,0,100),
                (5,1,2,NULL,1700000000,4,0,105),
                (7,1,4,NULL,1790000000,3,0,107),
                (8,1,4,NULL,1790000000,1,1,108),
                (9,2,3,'Re: ',1750000000,2,0,109),
                (10,3,5,NULL,1795000000,1,0,110);
            INSERT INTO recipients VALUES (1,9,1,0),(2,10,1,1);
            """)

        let inkorg = data.appending(path: "KONTO/INBOX.mbox/LAGER/Data/1/0/0/1/Messages")
        try fm.createDirectory(at: inkorg, withIntermediateDirectories: true)
        try emlx("""
            From: Anna Svensson <anna@acme.se>
            Subject: Offert
            Message-Id: <m1@acme.se>
            MIME-Version: 1.0
            Content-Type: multipart/mixed; boundary="GRANS"

            --GRANS
            Content-Type: text/plain; charset=utf-8
            Content-Transfer-Encoding: quoted-printable

            Hej! H=C3=A4r =C3=A4r offerten.=
             Mvh Anna

            --GRANS
            Content-Type: application/pdf; name="=?utf-8?B?b2ZmZXJ0IMOlLnBkZg==?="
            Content-Disposition: attachment; filename*=utf-8''offert%20%C3%A5.pdf
            Content-Transfer-Encoding: base64

            JVBERi0xLjQK
            --GRANS--
            """).write(to: inkorg.appending(path: "1001234.emlx"))

        let skickat = data.appending(path: "KONTO/Sent Messages.mbox/LAGER/Data")
        try fm.createDirectory(at: skickat.appending(path: "Messages"), withIntermediateDirectories: true)
        try fm.createDirectory(at: skickat.appending(path: "Attachments/9/2"), withIntermediateDirectories: true)
        try emlx("""
            From: Johan <jag@rackfish.com>
            To: Anna Svensson <anna@acme.se>
            Subject: Re: Avtal
            Message-Id: <m9@rackfish.com>
            Content-Type: text/plain; charset=utf-8

            Avtalet bifogas.
            """).write(to: skickat.appending(path: "Messages/9.partial.emlx"))
        try Data("avtalstext".utf8).write(to: skickat.appending(path: "Attachments/9/2/avtal.txt"))
    }
}
