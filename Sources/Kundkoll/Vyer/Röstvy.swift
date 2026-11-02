import SwiftUI

/// Låter användaren sätta namn på rösterna i ett samtal.
///
/// Röstanalysen håller hellre isär två röster än slår ihop dem, så samma
/// person kan dyka upp som flera rader. Att slå ihop är enkelt här; ett fel
/// namn i ett kundtranskript är det inte.
struct Röstvy: View {
    let kund: Kund
    let mapp: URL
    @State var inspelning: Inspelning
    /// Rösten man klickade på i transkriptet: den visas utfälld och överst.
    var fokus: Int? = nil
    var vidSparat: (Inspelning) -> Void

    @EnvironmentObject private var arkiv: Arkivet
    @Environment(\.dismiss) private var stäng

    @State private var namn: [Int: String] = [:]
    @State private var profiler: [Röstprofil] = []
    @State private var kontakter: [Kontakt] = []
    @State private var grupperarOm = false
    @State private var omfel: String?
    @State private var filter: Filter = .alla
    /// Röster vars repliker visas i sin helhet, inte bara det längsta provet.
    @State private var utfällda: Set<Int> = []
    @StateObject private var spelare = Yttrandespelare()

    /// Med många röster vill man se de som återstår, eller kolla de som
    /// redan fått namn. Filtret går på det sparade, så att en rad inte
    /// försvinner mitt i att man skriver namnet.
    private enum Filter: String, CaseIterable, Identifiable {
        case alla, utanNamn, namngivna
        var id: String { rawValue }
        var namn: String {
            switch self {
            case .alla: "Alla"
            case .utanNamn: "Utan namn"
            case .namngivna: "Med namn"
            }
        }
    }

    /// Hur väl en röst liknar de kända, bäst först. Avtrycket sparas med
    /// mötet; äldre möten saknar det tills de grupperas om.
    private func likheter(_ grupp: Int) -> [(namn: String, likhet: Double, omdöme: Tröskel.Omdöme)] {
        guard let a = inspelning.röstavtryck[grupp] else { return [] }
        return profiler
            .map { (namn: $0.namn, likhet: $0.likhet(a),
                    omdöme: Tröskel.omdöme(likhet: $0.likhet(a), sekunder: a.sekunder)) }
            .filter { $0.likhet >= 0.3 }
            .sorted { $0.likhet > $1.likhet }
    }

    /// Namn att välja bland: kända röster efter likhet först, sedan de
    /// kallade, kontakterna och övriga kända röster.
    private func förslag(för grupp: Int) -> [(namn: String, etikett: String)] {
        var ut: [(namn: String, etikett: String)] = []
        for l in likheter(grupp) {
            ut.append((l.namn, "\(l.namn) · \(Int((l.likhet * 100).rounded())) %"))
        }
        // De som var kallade till just det här mötet: de är de troligaste.
        for n in inspelning.kallade where !ut.contains(where: { $0.namn == n }) { ut.append((n, n)) }
        for k in kontakter where !ut.contains(where: { $0.namn == k.namn }) { ut.append((k.namn, k.namn)) }
        for p in profiler where !ut.contains(where: { $0.namn == p.namn }) { ut.append((p.namn, p.namn)) }
        return ut
    }

    private func färg(_ omdöme: Tröskel.Omdöme) -> Color {
        switch omdöme {
        case .igenkänd: .green
        case .trolig: .orange
        case .svag: .secondary
        }
    }

    private var grupper: [(grupp: Int, turer: Int, sekunder: Double, exempel: String)] {
        let motpart = inspelning.yttranden.filter { $0.röst == .motpart && $0.röstgrupp != nil }
        return Dictionary(grouping: motpart, by: { $0.röstgrupp! })
            .map { g, rader in
                (g, rader.count,
                 rader.reduce(0.0) { $0 + ($1.slut - $1.start) },
                 rader.max { $0.text.count < $1.text.count }?.text ?? "")
            }
            .sorted { $0.2 > $1.2 }
    }

    private var synliga: [(grupp: Int, turer: Int, sekunder: Double, exempel: String)] {
        let urval = grupper.filter { g in
            switch filter {
            case .alla: true
            case .utanNamn: inspelning.röstnamn[g.grupp] == nil
            case .namngivna: inspelning.röstnamn[g.grupp] != nil
            }
        }
        guard let fokus, let i = urval.firstIndex(where: { $0.grupp == fokus }) else { return urval }
        return [urval[i]] + urval.enumerated().filter { $0.offset != i }.map(\.element)
    }

    /// Rösternas repliker i tidsordning, för att höra och läsa mer än ett prov.
    private func repliker(_ grupp: Int) -> [Yttrande] {
        inspelning.yttranden
            .filter { $0.röst == .motpart && $0.röstgrupp == grupp }
            .sorted { $0.start < $1.start }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Vem är vem?").font(.headline)
                        Text("\(grupper.count) röster på motpartsspåret"
                             + (inspelning.röstmetod.map { " · delade med \($0)" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $filter) {
                        ForEach(Filter.allCases) { f in Text(f.namn).tag(f) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if let varning = inspelning.röstvarning {
                    Label(varning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Uppdelningen är en gissning ur ljudet. Den som var med i
                // samtalet vet hur många som talade, och det är den snabbaste
                // vägen till rätt indelning.
                HStack(spacing: 8) {
                    Text("Antal röster")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(2...6, id: \.self) { n in
                        Button("\(n)") { grupperaOm(antal: n) }
                            .buttonStyle(.bordered)
                            .disabled(grupperarOm)
                    }
                    // Stora möten är ovanliga men finns: nio i ett rum
                    // hände. Knapparna räcker för det vanliga, resten i en meny.
                    Menu("Fler") {
                        ForEach(7...15, id: \.self) { n in
                            Button("\(n) röster") { grupperaOm(antal: n) }
                        }
                    }
                    .fixedSize()
                    .disabled(grupperarOm)
                    Button("Låt appen avgöra") { grupperaOm(antal: nil) }
                        .buttonStyle(.borderless)
                        .disabled(grupperarOm)
                    if grupperarOm { ProgressView().controlSize(.small) }
                }
                if let omfel {
                    Text(omfel).font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(spacing: 14) {
                    ForEach(synliga, id: \.grupp) { g in
                        rad(g)
                    }
                    if synliga.isEmpty && !grupper.isEmpty {
                        Text(filter == .utanNamn ? "Alla röster har namn." : "Ingen röst har namn än.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 20)
                    }
                }
                .padding(16)
            }

            Divider()
            HStack {
                Text("Namn du sätter sparas som röstavtryck hos \(kund.namn) och känns igen nästa gång.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Avbryt") { stäng() }
                    .accessibilityIdentifier("röster.avbryt")
                Button("Spara", action: spara)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 660, height: 600)
        .onAppear {
            namn = inspelning.röstnamn
            profiler = arkiv.röstprofiler(för: kund)
            kontakter = arkiv.kontakter(för: kund)
            if let fokus { utfällda.insert(fokus) }
            spelare.ladda(mapp: mapp, inspelning: inspelning)
        }
        .onDisappear { spelare.sluta() }
    }

    private func rad(_ g: (grupp: Int, turer: Int, sekunder: Double, exempel: String)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Röst \(g.grupp + 1)")
                    .font(.subheadline.weight(.medium))
                Text("\(g.turer) inlägg · \(formateraLängd(g.sekunder))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let satt = inspelning.röstnamn[g.grupp] {
                    let träff = likheter(g.grupp).first { $0.namn == satt }
                    Text(träff.map { "igenkänd · \(Int(($0.likhet * 100).rounded())) %" } ?? "igenkänd")
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.green.opacity(0.2), in: .capsule)
                }
            }
            // Ett prov räcker sällan när många talar. Klicket fäller ut
            // rösternas repliker, var och en spelbar.
            Button {
                if utfällda.contains(g.grupp) { utfällda.remove(g.grupp) } else { utfällda.insert(g.grupp) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: utfällda.contains(g.grupp) ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text(utfällda.contains(g.grupp) ? "Dölj replikerna" : "«\(g.exempel.prefix(120))»")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(utfällda.contains(g.grupp) ? "Dölj replikerna" : "Visa alla repliker från rösten")
            if utfällda.contains(g.grupp) { replikerna(g.grupp) }

            // Likheten mot de kända rösterna, i procent. Grönt är över
            // tröskeln för automatisk namngivning, orange är troligt men
            // frågar hellre än gissar. Ett klick sätter namnet.
            let liknar = likheter(g.grupp).prefix(4)
            if !liknar.isEmpty {
                HStack(spacing: 6) {
                    Text("Liknar").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(liknar), id: \.namn) { l in
                        Button {
                            namn[g.grupp] = l.namn
                        } label: {
                            HStack(spacing: 4) {
                                Text(l.namn)
                                Text("\(Int((l.likhet * 100).rounded())) %").monospacedDigit()
                            }
                            .font(.caption)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(färg(l.omdöme).opacity(0.13), in: .capsule)
                            .foregroundStyle(färg(l.omdöme))
                        }
                        .buttonStyle(.plain)
                        .help(l.omdöme == .igenkänd ? "Över tröskeln för igenkänning — klicka för att sätta namnet"
                              : l.omdöme == .trolig ? "Trolig, men under tröskeln — klicka om det stämmer"
                              : "Svag likhet")
                    }
                }
            } else if inspelning.röstavtryck[g.grupp] == nil {
                Text("Inget avtryck sparat för rösten — gruppera om för att få likheter.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                TextField("Namn", text: Binding(
                    get: { namn[g.grupp] ?? "" },
                    set: { namn[g.grupp] = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder)
                let alternativ = förslag(för: g.grupp)
                if !alternativ.isEmpty {
                    Menu("Välj") {
                        ForEach(alternativ, id: \.namn) { a in
                            Button(a.etikett) { namn[g.grupp] = a.namn }
                        }
                    }
                    .fixedSize()
                }
            }
        }
        .padding(12)
        .kort(hörn: Stil.radhörn)
        .overlay {
            if fokus == g.grupp {
                RoundedRectangle(cornerRadius: Stil.radhörn).stroke(Color.accentColor, lineWidth: 1.5)
            }
        }
    }

    private func replikerna(_ grupp: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(repliker(grupp)) { y in
                let hörs = spelare.aktuell == y.id && spelare.igång
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button {
                        spelare.växla(y, bara: true)
                    } label: {
                        Image(systemName: hörs ? "pause.fill" : "play.fill")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(hörs ? Color.accentColor : Color.secondary)
                    .disabled(!spelare.harLjud)
                    .help(hörs ? "Pausa" : "Lyssna på repliken")
                    Text(y.tidsstämpel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Text(y.text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, 18)
    }

    /// Kör om uppdelningen med ett angivet antal röster.
    private func grupperaOm(antal: Int?) {
        grupperarOm = true
        omfel = nil
        Task {
            do {
                inspelning = try await arkiv.grupperaOm(inspelning, i: mapp, antal: antal)
                namn = inspelning.röstnamn
                spelare.ladda(mapp: mapp, inspelning: inspelning)
                vidSparat(inspelning)
            } catch {
                omfel = error.localizedDescription
            }
            grupperarOm = false
        }
    }

    private func spara() {
        inspelning.röstnamn = namn.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        try? arkiv.spara(inspelning, i: mapp)

        // Lär in avtrycken för de röster som fått namn, så att personen känns
        // igen i nästa samtal. Bladet stängs direkt, så det som inte gick
        // sägs i en notis — tidigare försvann det i tysthet, och personen
        // kändes aldrig igen igen utan att man förstod varför.
        let sparad = inspelning
        Task {
            let misslyckade = await Röstanalys().lärIn(sparad, mapp: mapp, kund: kund, arkiv: arkiv)
            if !misslyckade.isEmpty {
                Notiser.skicka(
                    titel: "Röstavtryck",
                    text: "Kunde inte lära in \(misslyckade.joined(separator: ", ")): för lite "
                        + "tal, eller så gick avtrycken inte att läsa. Namnet gäller ändå för "
                        + "det här mötet.",
                    kund: kund.namn)
            }
        }
        // En person man satt namn på hör till kunden. Att behöva lägga upp
        // hen en gång till som kontakt vore onödigt dubbelarbete.
        for personnamn in Set(inspelning.röstnamn.values)
        where !kontakter.contains(where: { $0.namn == personnamn }) {
            try? arkiv.läggTill(Kontakt(namn: personnamn), hos: kund)
        }

        vidSparat(inspelning)
        stäng()
    }
}
