import Foundation

/// Läser ett mejl i råformat: rubriker, brödtext och bilagor.
///
/// Mails .emlx-filer är ett vanligt RFC 822-meddelande med en rad före som
/// säger hur många byte det är, och en plist efter. Allt här arbetar på
/// texten avkodad som ISO 8859-1, som avbildar varje byte på ett tecken —
/// då går det att leta efter gränser och rubriker som i en sträng, och få
/// tillbaka exakt samma byte när en del ska avkodas på riktigt.
enum Mimetolk {

    struct Bilaga: Equatable {
        var namn: String
        var data: Data
    }

    struct Meddelande {
        var rubriker: [String: String]
        /// Brödtexten: första text/plain, annars första text/html utan taggar.
        var text: String
        var bilagor: [Bilaga]

        var meddelandeID: String {
            (rubriker["message-id"] ?? "").trimmingCharacters(in: .whitespaces)
        }
    }

    /// En .emlx-fil: byteantalet på första raden, sedan meddelandet.
    static func tolkaEmlx(_ data: Data) -> Meddelande {
        guard let radslut = data.firstIndex(of: UInt8(ascii: "\n")),
              let antal = Int(String(decoding: data[data.startIndex..<radslut], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)) else {
            return tolka(data)
        }
        let start = data.index(after: radslut)
        let slut = min(data.endIndex, start + antal)
        return tolka(data.subdata(in: start..<slut))
    }

    static func tolka(_ data: Data) -> Meddelande {
        let text = String(data: data, encoding: .isoLatin1) ?? ""
        let del = Del(rå: text)
        var brödtext: String?
        var html: String?
        var bilagor: [Bilaga] = []
        samla(del, brödtext: &brödtext, html: &html, bilagor: &bilagor, djup: 0)
        return Meddelande(rubriker: del.rubriker,
                          text: brödtext ?? html.map(utanTaggar) ?? "",
                          bilagor: bilagor)
    }

    // MARK: - Delar

    private struct Del {
        var rubriker: [String: String]
        var kropp: String

        init(rå: String) {
            let normal = rå.replacingOccurrences(of: "\r\n", with: "\n")
            let (huvud, kropp) = Self.dela(normal)
            self.rubriker = Mimetolk.rubriker(huvud)
            self.kropp = kropp
        }

        private static func dela(_ s: String) -> (String, String) {
            if s.hasPrefix("\n") { return ("", String(s.dropFirst())) }
            guard let r = s.range(of: "\n\n") else { return (s, "") }
            return (String(s[..<r.lowerBound]), String(s[r.upperBound...]))
        }

        var typ: (värde: String, param: [String: String]) {
            Mimetolk.värdeOchParametrar(rubriker["content-type"] ?? "text/plain")
        }
        var disposition: (värde: String, param: [String: String]) {
            Mimetolk.värdeOchParametrar(rubriker["content-disposition"] ?? "")
        }
        var filnamn: String? {
            let n = disposition.param["filename"] ?? typ.param["name"]
            return n.map(Mimetolk.avkodaOrd).flatMap { $0.isEmpty ? nil : $0 }
        }

        /// Kroppen som byte, efter överföringskodningen.
        var avkodad: Data {
            switch (rubriker["content-transfer-encoding"] ?? "").lowercased()
                .trimmingCharacters(in: .whitespaces) {
            case "base64":
                return Data(base64Encoded: kropp.filter { !$0.isWhitespace },
                            options: .ignoreUnknownCharacters) ?? Data()
            case "quoted-printable":
                return Mimetolk.avkodaQP(kropp)
            default:
                return Data(kropp.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
            }
        }

        var textinnehåll: String {
            Mimetolk.sträng(avkodad, teckenkod: typ.param["charset"])
        }
    }

    private static func samla(_ del: Del, brödtext: inout String?, html: inout String?,
                              bilagor: inout [Bilaga], djup: Int) {
        guard djup < 12 else { return }
        let typ = del.typ.värde
        if typ.hasPrefix("multipart/"), let gräns = del.typ.param["boundary"], !gräns.isEmpty {
            for bit in delar(del.kropp, gräns: gräns) {
                samla(Del(rå: bit), brödtext: &brödtext, html: &html, bilagor: &bilagor, djup: djup + 1)
            }
            return
        }
        let somBilaga = del.disposition.värde == "attachment"
            || (del.filnamn != nil && !(typ == "text/plain" && del.disposition.värde == "inline"))
        if somBilaga, let namn = del.filnamn {
            bilagor.append(Bilaga(namn: namn, data: del.avkodad))
        } else if typ == "text/plain", brödtext == nil {
            brödtext = del.textinnehåll
        } else if typ == "text/html", html == nil {
            html = del.textinnehåll
        }
    }

    private static func delar(_ kropp: String, gräns: String) -> [String] {
        let markör = "--" + gräns
        var ut: [String] = []
        var aktuell: [Substring]?
        for rad in kropp.split(separator: "\n", omittingEmptySubsequences: false) {
            let r = rad.hasSuffix("\r") ? rad.dropLast() : rad
            if r == markör + "--" {
                if let a = aktuell { ut.append(a.joined(separator: "\n")) }
                return ut
            }
            if r == markör {
                if let a = aktuell { ut.append(a.joined(separator: "\n")) }
                aktuell = []
                continue
            }
            aktuell?.append(rad)
        }
        if let a = aktuell { ut.append(a.joined(separator: "\n")) }
        return ut
    }

    // MARK: - Rubriker

    static func rubriker(_ huvud: String) -> [String: String] {
        var ut: [String: String] = [:]
        var nyckel: String?
        for rad in huvud.split(separator: "\n", omittingEmptySubsequences: false) {
            if let första = rad.first, första == " " || första == "\t", let n = nyckel {
                ut[n, default: ""] += " " + rad.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let kolon = rad.firstIndex(of: ":") else { continue }
            let n = rad[..<kolon].trimmingCharacters(in: .whitespaces).lowercased()
            // Första förekomsten gäller: Received och liknande upprepas.
            if ut[n] == nil {
                ut[n] = rad[rad.index(after: kolon)...].trimmingCharacters(in: .whitespaces)
            }
            nyckel = ut[n] == nil ? nil : n
        }
        return ut
    }

    /// `text/plain; charset="utf-8"` → ("text/plain", ["charset": "utf-8"]).
    /// Klarar RFC 2231: `filename*=utf-8''%C3%A5.pdf` och uppdelade
    /// `filename*0=…; filename*1=…`.
    static func värdeOchParametrar(_ s: String) -> (värde: String, param: [String: String]) {
        let bitar = delaUtanförCitat(s, vid: ";")
        let värde = (bitar.first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        var param: [String: String] = [:]
        var styckat: [String: [(Int, String, Bool)]] = [:]
        for bit in bitar.dropFirst() {
            guard let lika = bit.firstIndex(of: "=") else { continue }
            var n = bit[..<lika].trimmingCharacters(in: .whitespaces).lowercased()
            var v = bit[bit.index(after: lika)...].trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
            let kodat = n.hasSuffix("*")
            if kodat { n.removeLast() }
            if let stjärna = n.firstIndex(of: "*"), let i = Int(n[n.index(after: stjärna)...]) {
                styckat[String(n[..<stjärna]), default: []].append((i, v, kodat))
            } else {
                param[n] = kodat ? avkodaRFC2231(v) : v
            }
        }
        for (n, delar) in styckat {
            let sorterat = delar.sorted { $0.0 < $1.0 }
            if sorterat.contains(where: \.2) {
                param[n] = avkodaRFC2231(sorterat.map(\.1).joined())
            } else {
                param[n] = sorterat.map(\.1).joined()
            }
        }
        return (värde, param)
    }

    private static func delaUtanförCitat(_ s: String, vid tecken: Character) -> [String] {
        var ut: [String] = []
        var aktuell = ""
        var iCitat = false
        for c in s {
            if c == "\"" { iCitat.toggle() }
            if c == tecken && !iCitat {
                ut.append(aktuell)
                aktuell = ""
            } else {
                aktuell.append(c)
            }
        }
        ut.append(aktuell)
        return ut
    }

    /// `utf-8''%C3%A5.pdf` → "å.pdf".
    private static func avkodaRFC2231(_ v: String) -> String {
        let delar = v.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        let (kod, text) = delar.count == 3 ? (String(delar[0]), String(delar[2])) : ("utf-8", v)
        var byte: [UInt8] = []
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "%", let s = text.index(i, offsetBy: 3, limitedBy: text.endIndex),
               let b = UInt8(text[text.index(after: i)..<s], radix: 16) {
                byte.append(b)
                i = s
            } else {
                byte.append(contentsOf: Array(String(text[i]).utf8))
                i = text.index(after: i)
            }
        }
        return sträng(Data(byte), teckenkod: kod)
    }

    /// Kodade ord i rubriker: `=?utf-8?B?w6U=?=` och `=?iso-8859-1?Q?=E5?=`.
    static func avkodaOrd(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        let mönster = #/=\?([^?]+)\?([bBqQ])\?([^?]*)\?=/#
        var ut = ""
        var rest = s[...]
        var förraVarOrd = false
        while let träff = rest.firstMatch(of: mönster) {
            let mellan = rest[..<träff.range.lowerBound]
            // Blanksteg mellan två kodade ord hör inte till texten.
            if !(förraVarOrd && mellan.allSatisfy(\.isWhitespace)) { ut += mellan }
            let (kod, sätt, text) = (String(träff.1), träff.2.lowercased(), String(träff.3))
            let data: Data
            if sätt == "b" {
                data = Data(base64Encoded: text, options: .ignoreUnknownCharacters) ?? Data()
            } else {
                data = avkodaQP(text.replacingOccurrences(of: "_", with: " "))
            }
            ut += sträng(data, teckenkod: kod)
            rest = rest[träff.range.upperBound...]
            förraVarOrd = true
        }
        return ut + rest
    }

    // MARK: - Avkodning

    static func avkodaQP(_ s: String) -> Data {
        var ut: [UInt8] = []
        let byte = Array(s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
        var i = 0
        while i < byte.count {
            let b = byte[i]
            if b == UInt8(ascii: "=") {
                // Mjukt radbyte: "=" sist på raden.
                if i + 1 < byte.count, byte[i + 1] == UInt8(ascii: "\n") { i += 2; continue }
                if i + 2 < byte.count, byte[i + 1] == UInt8(ascii: "\r"), byte[i + 2] == UInt8(ascii: "\n") {
                    i += 3; continue
                }
                if i + 2 < byte.count,
                   let v = UInt8(String(bytes: byte[(i + 1)...(i + 2)], encoding: .ascii) ?? "", radix: 16) {
                    ut.append(v)
                    i += 3
                    continue
                }
            }
            ut.append(b)
            i += 1
        }
        return Data(ut)
    }

    static func sträng(_ data: Data, teckenkod: String?) -> String {
        if let kod = teckenkod?.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")),
           !kod.isEmpty {
            let cf = CFStringConvertIANACharSetNameToEncoding(kod as CFString)
            if cf != kCFStringEncodingInvalidId {
                let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let s = String(data: data, encoding: enc) { return s }
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    static func utanTaggar(_ html: String) -> String {
        var s = html.replacing(#/(?is)<(script|style)[^>]*>.*?<\/\1>/#, with: " ")
        s = s.replacing(#/(?i)<br\s*\/?>|<\/p>|<\/div>/#, with: "\n")
        s = s.replacing(#/<[^>]+>/#, with: "")
        for (a, b) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                       ("&quot;", "\""), ("&#39;", "'"), ("&aring;", "å"), ("&auml;", "ä"),
                       ("&ouml;", "ö"), ("&Aring;", "Å"), ("&Auml;", "Ä"), ("&Ouml;", "Ö")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        return s.replacing(#/[ \t]+/#, with: " ")
            .replacing(#/\n\s*\n+/#, with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
