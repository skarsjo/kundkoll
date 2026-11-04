import Foundation

extension Tester {

    static func teamet() {
        Prov.svit("Teamet")

        do {   // fälten i inställningarna
            var t = Team()
            t.domäntext = "Rackfish.com, @rackfish.se\nx.se"
            Prov.lika(t.domäner, ["rackfish.com", "rackfish.se", "x.se"], "domänerna, rensade och gemena")
            t.kollegatext = "Martin Malmgren, martin@rackfish.com\n\n, bara@x.se\nAnna"
            Prov.lika(t.kollegor, [Team.Kollega(namn: "Martin Malmgren", epost: ["martin@rackfish.com"]),
                                   Team.Kollega(namn: "Anna")],
                      "en kollega per rad; rader utan namn hoppas över")
            Prov.lika(t.kollegatext, "Martin Malmgren, martin@rackfish.com\nAnna", "och tillbaka till text")
        }

        do {   // egna adresser
            let t = Team(domäner: ["rackfish.com"],
                         kollegor: [Team.Kollega(namn: "Martin Malmgren", epost: ["martin@privat.se"])])
            Prov.kolla(t.ärEgen(adress: "Johan@Rackfish.com"), "den egna domänen, oavsett skiftläge")
            Prov.kolla(t.ärEgen(adress: "a@mail.rackfish.com"), "underdomäner räknas")
            Prov.kolla(!t.ärEgen(adress: "a@notrackfish.com"), "en annan domän som slutar likadant räknas inte")
            Prov.kolla(t.ärEgen(adress: "martin@privat.se"), "en kollegas adress på annan domän")
            Prov.kolla(!t.ärEgen(adress: "anna@acme.se"), "kundens adress är inte egen")
            Prov.kolla(t.ärKollega("martin malmgren"), "kollegan känns igen oavsett skiftläge")
            Prov.kolla(!t.ärKollega("Martin"), "men inte på halva namnet")
        }

        let rot = FileManager.default.temporaryDirectory.appending(path: "kundkoll-team-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rot) }
        let arkiv = Arkivet(rot: rot)
        do {
            let a = try arkiv.skapaKund(namn: "Acme")
            let b = try arkiv.skapaKund(namn: "Beta")
            Prov.lika(arkiv.team(), Team(), "utan fil är teamet tomt")
            try arkiv.sparaTeam(Team(domäner: ["rackfish.com"],
                                     kollegor: [Team.Kollega(namn: "Martin Malmgren")]))
            Prov.lika(arkiv.team().domäner, ["rackfish.com"], "teamet sparas och läses")

            // Martin får namn i ett Acme-möte och ska kännas igen hos Beta.
            try arkiv.lärDigRöst(namn: "Martin Malmgren",
                                 avtryck: Avtryck(vektor: [1, 0, 0], sekunder: 6), hos: a)
            Prov.lika(arkiv.egnaRöstprofiler(för: a).count, 0, "kollegans röst sparas inte hos kunden")
            Prov.lika(arkiv.teamprofiler().map(\.namn), ["Martin Malmgren"], "utan i teamet")
            Prov.kolla(arkiv.röstprofiler(för: b, dela: false).contains { $0.namn == "Martin Malmgren" },
                       "och känns igen hos en annan kund")
            try arkiv.lärDigRöst(namn: "Anna", avtryck: Avtryck(vektor: [0, 1, 0], sekunder: 6), hos: a)
            Prov.lika(arkiv.röstprofiler(för: b, dela: false).map(\.namn), ["Martin Malmgren"],
                      "kundens egna röster läcker fortfarande inte")

            try arkiv.läggTill(Kontakt(namn: "Anna", epost: ["anna@acme.se", "Anna@Acme.se"]), hos: a)
            try arkiv.läggTill(Kontakt(namn: "Johan", epost: ["johan@rackfish.com"]), hos: a)
            Prov.lika(arkiv.sökbaraAdresser(för: a), ["anna@acme.se"],
                      "mejlsökningen hoppar över den egna domänen och dubbletter")
        } catch {
            Prov.kolla(false, "teamet gick att prova: \(error)")
        }
    }
}
