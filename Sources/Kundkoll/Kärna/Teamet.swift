import Foundation

/// De egna: kollegorna och den egna domänen.
///
/// En kollega är med i många kunders möten men hör inte till någon kund.
/// Två saker följer av det. Kollegans röst ska kännas igen i alla kunders
/// möten — inte bara hos den kund där namnet råkade sättas först. Och
/// kollegans adress, liksom allt på den egna domänen, ska inte sökas efter
/// i Mail: den matchar en stor del av all post och säger ingenting om
/// kunden.
///
/// Ligger i kundmappens `.kundkoll/team.json`, och kollegornas röster i
/// `.kundkoll/team-röstprofiler.json` bredvid. Kundernas egna profiler
/// rörs inte.
struct Team: Codable, Equatable {
    var domäner: [String] = []
    var kollegor: [Kollega] = []

    struct Kollega: Codable, Equatable, Hashable {
        var namn: String
        var epost: [String] = []

        init(namn: String, epost: [String] = []) {
            self.namn = namn
            self.epost = epost
        }

        /// Skriven för hand: se `Inspelning`.
        init(from avkodare: Decoder) throws {
            let c = try avkodare.container(keyedBy: CodingKeys.self)
            namn = try c.decodeIfPresent(String.self, forKey: .namn) ?? ""
            epost = try c.decodeIfPresent([String].self, forKey: .epost) ?? []
        }
    }

    init(domäner: [String] = [], kollegor: [Kollega] = []) {
        self.domäner = domäner
        self.kollegor = kollegor
    }

    init(from avkodare: Decoder) throws {
        let c = try avkodare.container(keyedBy: CodingKeys.self)
        domäner = try c.decodeIfPresent([String].self, forKey: .domäner) ?? []
        kollegor = try c.decodeIfPresent([Kollega].self, forKey: .kollegor) ?? []
    }

    func ärKollega(_ namn: String) -> Bool {
        let n = namn.trimmingCharacters(in: .whitespaces)
        return kollegor.contains { $0.namn.compare(n, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    /// En adress på den egna domänen eller en kollegas.
    func ärEgen(adress: String) -> Bool {
        let a = adress.lowercased().trimmingCharacters(in: .whitespaces)
        if kollegor.contains(where: { $0.epost.contains { $0.lowercased() == a } }) { return true }
        guard let snabel = a.lastIndex(of: "@") else { return false }
        let domän = a[a.index(after: snabel)...]
        return domäner.contains { d in
            let d = d.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " @"))
            // Underdomäner räknas: mail.rackfish.com hör till rackfish.com.
            return !d.isEmpty && (domän == d || domän.hasSuffix("." + d))
        }
    }

    // MARK: - Som text i inställningarna

    /// "rackfish.com, rackfish.se" ↔ ["rackfish.com", "rackfish.se"].
    var domäntext: String {
        get { domäner.joined(separator: ", ") }
        set {
            domäner = newValue.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " @")).lowercased() }
                .filter { !$0.isEmpty }
        }
    }

    /// En kollega per rad: namnet, sedan adresserna, åtskilda av komma.
    ///
    ///     Martin Malmgren, martin.malmgren@rackfish.com
    var kollegatext: String {
        get { kollegor.map { ([$0.namn] + $0.epost).joined(separator: ", ") }.joined(separator: "\n") }
        set {
            kollegor = newValue.split(separator: "\n").compactMap { rad in
                let delar = rad.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                let adresser = delar.filter { $0.contains("@") }
                guard let namn = delar.first(where: { !$0.contains("@") }) else { return nil }
                return Kollega(namn: namn, epost: adresser)
            }
        }
    }
}

extension Arkivet {

    private var teamfil: URL { rot.appending(path: ".kundkoll/team.json") }
    private var teamröster: URL { rot.appending(path: ".kundkoll/team-röstprofiler.json") }

    func team() -> Team {
        guard let data = try? Data(contentsOf: teamfil),
              let t = try? JSONDecoder.kundkoll.decode(Team.self, from: data) else { return Team() }
        return t
    }

    func sparaTeam(_ team: Team) throws {
        try FileManager.default.createDirectory(at: teamfil.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder.kundkoll.encode(team).write(to: teamfil, options: .atomic)
    }

    /// Kollegornas röster. Gäller i alla kunders möten.
    func teamprofiler() -> [Röstprofil] {
        guard let data = try? Data(contentsOf: teamröster),
              let p = try? JSONDecoder.kundkoll.decode([Röstprofil].self, from: data) else { return [] }
        return p
    }

    func sparaTeamprofiler(_ profiler: [Röstprofil]) throws {
        try FileManager.default.createDirectory(at: teamröster.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder.kundkoll.encode(profiler).write(to: teamröster, options: .atomic)
    }

    /// Kundens adresser att söka på i Mail: utan kollegor och den egna
    /// domänen, och högst fem.
    func sökbaraAdresser(för kund: Kund) -> [String] {
        let team = team()
        let alla = kontakter(för: kund).flatMap(\.epost).filter { !team.ärEgen(adress: $0) }
        var sedda = Set<String>()
        return Array(alla.filter { sedda.insert($0.lowercased()).inserted }.prefix(5))
    }
}
