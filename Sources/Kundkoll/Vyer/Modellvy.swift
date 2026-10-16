import SwiftUI
import AppKit
import AVFoundation
import EventKit
import Contacts
import UserNotifications

/// Inställningarna: modellen för chatten, transkriberingen, röster och
/// insikter — och en diagnossida som säger vad som finns på maskinen.
///
/// Diagnosen fanns inte förut. Kontrollerna av Pythonmiljön och pyannote
/// beräknades men visades ingenstans, så en trasig miljö gav namnlösa
/// röster i varje möte utan att någon sa varför. Sökvägarna var dessutom
/// hårdkodade till ~/Projekt, vilket gjorde appen obrukbar på någon annans
/// dator.
struct Modellvy: View {
    @Environment(\.dismiss) private var stäng

    enum Flik: String, CaseIterable, Identifiable {
        case modell, transkribering, röster, lagring, diagnos
        var id: String { rawValue }
        var namn: String {
            switch self {
            case .modell: "Modell"
            case .transkribering: "Transkribering"
            case .röster: "Röster och insikter"
            case .lagring: "Lagring"
            case .diagnos: "Diagnos"
            }
        }
    }

    @State private var flik: Flik = .modell
    @State private var val = Modellval.läs()
    @State private var nyckel = ""
    @State private var harNyckel = false
    @State private var meddelande: String?
    @State private var provar = false
    @State private var insiktsmodell = Inställningar.insiktsmodell
    @State private var delaRöster = Inställningar.delaRöstprofiler
    @State private var automatiska = Inställningar.automatiskaModellanrop
    @State private var transkribering = Transkriberingsval.läs()
    @State private var elevenNyckel = ""
    @State private var harElevenNyckel = Nyckelring.hämta("kundkoll-elevenlabs") != nil
    @State private var whisperRot = Inställningar.whisperRot ?? ""
    @State private var pythonMiljö = Inställningar.pythonMiljö ?? ""
    @State private var packaLjud = Inställningar.packaLjud
    @State private var packar = false
    @State private var packläge = ""
    @State private var packresultat: String?
    @State private var diagnos: [Diagnosrad] = []
    @State private var kontrollerar = false

    struct Diagnosrad: Identifiable {
        let id = UUID()
        var namn: String
        /// Sant: fungerar. Falskt: saknas och behövs. Nil: saknas men är
        /// frivilligt.
        var ok: Bool?
        var text: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Inställningar").font(.headline)
                Spacer()
            }
            .padding(16)
            Picker("", selection: $flik) {
                ForEach(Flik.allCases) { f in Text(f.namn).tag(f) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch flik {
                    case .modell: modellflik
                    case .transkribering: transkriberingsflik
                    case .röster: röstflik
                    case .lagring: lagringsflik
                    case .diagnos: diagnosflik
                    }
                }
                .padding(16)
            }

            Divider()
            HStack {
                if flik == .modell {
                    Button("Prova", action: prova)
                        .disabled(provar)
                    if provar { ProgressView().controlSize(.small) }
                }
                Spacer()
                Button("Avbryt") { stäng() }
                    .accessibilityIdentifier("inställningar.avbryt")
                Button("Spara", action: spara).keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 620)
        .onAppear(perform: läsNyckel)
        .onChange(of: flik) { if flik == .diagnos, diagnos.isEmpty { kontrollera() } }
    }

    // MARK: - Modell

    @ViewBuilder
    private var modellflik: some View {
        Picker("Kör hos", selection: $val.leverantör) {
            ForEach(Leverantör.allCases) { l in Text(l.namn).tag(l) }
        }
        .pickerStyle(.segmented)
        .onChange(of: val.leverantör) { _, ny in
            val.modell = ny.standardmodell
            val.adress = ny.behöverEgenAdress ? ny.standardadress : ""
            läsNyckel()
            meddelande = nil
        }

        Text(val.leverantör.beskrivning)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if val.leverantör != .azure {
            fält("Modell") {
                TextField(val.leverantör.standardmodell, text: $val.modell)
                    .textFieldStyle(.roundedBorder)
            }
        }

        if val.leverantör.behöverEgenAdress {
            fält("Adress") {
                TextField(val.leverantör.standardadress, text: $val.adress)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
        }

        if val.leverantör == .lokal {
            // De tre vanliga lokala servrarna talar alla OpenAI-formatet
            // men lyssnar på olika portar. Knapparna fyller i adressen;
            // modellnamnet är det som står i serverns egen lista.
            fält("Vanliga servrar") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        förval("Ollama", port: 11434, modell: "llama3.1:8b")
                        förval("LM Studio", port: 1234, modell: nil)
                        förval("MLX", port: 8080, modell: nil)
                    }
                    if val.adress.contains(":8080") {
                        Text("MLX startas med `mlx_lm.server --model "
                             + "mlx-community/…` och modellfältet ska "
                             + "vara samma namn.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }

        if val.leverantör.behöverNyckel {
            fält(harNyckel ? "API-nyckel (sparad)" : "API-nyckel") {
                VStack(alignment: .leading, spacing: 6) {
                    SecureField(harNyckel ? "•••••••• — skriv en ny för att byta" : "Klistra in nyckeln",
                                text: $nyckel)
                        .textFieldStyle(.roundedBorder)
                    if let var_ = val.leverantör.nyckeladress {
                        Text("Hämtas på \(var_)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Label("Ingen nyckel behövs. Materialet lämnar aldrig datorn.",
                  systemImage: "lock")
                .font(.callout)
                .foregroundStyle(.green)
        }

        Divider().padding(.vertical, 4)

        // Det här är det enda i appen som skickar material utan att man
        // frågat. Det ska stå i klartext, och gå att stänga av.
        fält("I bakgrunden") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Låt modellen arbeta utan att jag frågar", isOn: $automatiska)
                Text(automatiska
                     ? "Sammanfattningen skrivs när mötet är klart, nya mejl gås igenom "
                       + "efter åtaganden när de hämtas, och lägesbilden skrivs när ett "
                       + "projekt öppnas. "
                       + (val.leverantör == .lokal
                          ? "Modellen körs lokalt, så inget lämnar datorn."
                          : "Hela transkript och mejltexter skickas då till "
                            + "\(val.leverantör.namn) i bakgrunden.")
                     : "Inget skickas till modellen förrän du ber om det: «Sammanfatta "
                       + "mötet» i mötesvyn, «Skriv lägesbilden» i projektet. Mejl gås "
                       + "inte igenom efter åtaganden. Chatten och insikterna under "
                       + "samtal fungerar som vanligt.")
                    .font(.caption)
                    .foregroundStyle(automatiska && val.leverantör != .lokal
                                     ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if let meddelande {
            Text(meddelande)
                .font(.callout)
                .foregroundStyle(meddelande.hasPrefix("Fungerar") ? .green : .orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Transkribering

    @ViewBuilder
    private var transkriberingsflik: some View {
        fält("Transkribering av färdiga möten") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $transkribering.motor) {
                    ForEach(Transkriberingsmotor.allCases) { m in
                        Text(m.namn).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: transkribering.motor) { transkribering.modell = "" }

                Text(transkribering.motor.beskrivning)
                    .font(.caption)
                    .foregroundStyle(transkribering.motor.lokal ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)

                if transkribering.motor == .whisperCpp {
                    Picker("Modell", selection: bindningArkivmodell) {
                        ForEach(lokalaModeller, id: \.self) { m in
                            Text(m.replacingOccurrences(of: ".bin", with: "")).tag(m)
                        }
                    }
                } else {
                    TextField(transkribering.motor.standardmodell,
                              text: $transkribering.modell)
                        .textFieldStyle(.roundedBorder)
                }

                if transkribering.motor == .elevenlabs {
                    SecureField(harElevenNyckel
                                ? "•••••••• — skriv en ny för att byta"
                                : "API-nyckel från elevenlabs.io",
                                text: $elevenNyckel)
                        .textFieldStyle(.roundedBorder)
                }
                if transkribering.motor == .openai {
                    Text(Transkriberingsmotor.openai.nyckel == nil
                         ? "Använder OpenAI-nyckeln från chatten — lägg in en under Modell."
                         : "Använder OpenAI-nyckeln som redan finns.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let brist = Arkivtranskribering.brister(transkribering).first,
                   !(transkribering.motor == .elevenlabs && !elevenNyckel.isEmpty) {
                    Label(brist, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }

        fält("Livetranskribering — alltid lokal") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("", selection: $transkribering.livemodell) {
                    ForEach(lokalaModeller, id: \.self) { m in
                        Text(m.replacingOccurrences(of: ".bin", with: "")).tag(m)
                    }
                }
                .labelsHidden()
                Text("Fönstren under ett samtal är sekunder långa och går genom "
                     + "whisper-server som håller modellen varm. Gäller från nästa "
                     + "inspelning.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        Divider().padding(.vertical, 4)

        fält("Sökvägar") {
            VStack(alignment: .leading, spacing: 10) {
                sökväg("whisper.cpp", text: $whisperRot,
                       standard: "~/Projekt/whisper.cpp",
                       hjälp: "Mappen med build/bin/whisper-server, whisper-cli och models/.")
                sökväg("Pythonmiljö", text: $pythonMiljö,
                       standard: "~/Projekt/transcriber/venv",
                       hjälp: "venv med torch och speechbrain för röstanalysen, och mlx-whisper "
                            + "för möten på andra språk än svenska.")
                Text("Tomt betyder standardvägen. Diagnosfliken säger om det som ligger där "
                     + "räcker.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var lokalaModeller: [String] {
        let rot = whisperRot.trimmingCharacters(in: .whitespaces)
        return Transkriberingsval.lokalaModeller(
            i: rot.isEmpty ? Whisper.Sökvägar.standard.rot : URL(fileURLWithPath: rot))
    }

    private func sökväg(_ namn: String, text: Binding<String>, standard: String,
                        hjälp: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(namn).frame(width: 90, alignment: .leading)
                TextField(standard, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Button("Välj …") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.message = "Välj mappen för \(namn)"
                    if panel.runModal() == .OK, let url = panel.url { text.wrappedValue = url.path }
                }
            }
            Text(hjälp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Röster och insikter

    @ViewBuilder
    private var röstflik: some View {
        fält("Modell för insikter under samtal") {
            VStack(alignment: .leading, spacing: 6) {
                TextField(Insikter.standardmodell, text: $insiktsmodell)
                    .textFieldStyle(.roundedBorder)
                Text("Körs lokalt via Ollama och lyssnar efter frågeställningar medan ett möte pågår. Uppmätt: qwen3:8b 12 av 12 rätt utan falska larm, gemma3:4b 11 av 12, gemma3:1b 7 av 12.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        fält("Röstanalys") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Känn igen röster mellan kunder", isOn: $delaRöster)
                    .help("Av som standard: röstprofiler ligger hos kunden, och samma person kan förekomma i flera kundärenden utan att man vill koppla ihop dem.")
                let brister = Röstanalys.Sökvägar.standard.brister
                if brister.isEmpty {
                    Label(Röstanalys.Sökvägar.standard.harDiarisering
                          ? "Pythonmiljön och pyannote finns. Rösterna delas upp med pyannote."
                          : "Pythonmiljön finns, men pyannote saknas. Rösterna delas med reservmetoden, som är sämre.",
                          systemImage: Röstanalys.Sökvägar.standard.harDiarisering
                              ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Röstanalys.Sökvägar.standard.harDiarisering
                                         ? Color.secondary : Color.orange)
                } else {
                    Label(brister.joined(separator: " ") + " Rösterna delas inte upp och ingen känns igen.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Lagring

    /// Kundmappen och ljudet byts inte mitt i ett möte eller en bearbetning:
    /// båda läser och skriver i mötesmapparna.
    private var lagringenLedig: Bool {
        !Inspelningssession.delad.pågår
            && Importkö.delad.aktuell == nil && Importkö.delad.väntande.isEmpty
    }

    @ViewBuilder
    private var lagringsflik: some View {
        fält("Kundmapp") {
            VStack(alignment: .leading, spacing: 8) {
                Text(Arkivet.shared.rot.path.replacingOccurrences(
                        of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                if let valv = Arkivet.shared.huvudvalv {
                    Label("Ligger i Obsidian-valvet \(valv.lastPathComponent). Kunderna är mappar "
                          + "i det valvet och länkas ihop med resten av dina anteckningar.",
                          systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Varje kund är ett eget Obsidian-valv. Väljer du en mapp i ditt vanliga "
                         + "valv blir kunderna mappar där i stället — och följer med när valvet "
                         + "synkas.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if Arkivet.miljörot != nil {
                    Label("Styrs av miljövariabeln KUNDKOLL_ROT.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        Button("Byt kundmapp …", action: väljKundmapp)
                            .disabled(!lagringenLedig)
                        if !lagringenLedig {
                            Text("Inte medan en inspelning eller bearbetning pågår.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }

        Divider().padding(.vertical, 4)

        fält("Ljud") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Packa ljudet till m4a när mötet är klart", isOn: $packaLjud)
                Text("Spåren spelas in som wav, som tål en krasch mitt i och är vad whisper "
                     + "läser. När efterbearbetningen är klar packas de till AAC, runt åtta "
                     + "gånger mindre: ett entimmesmöte med två spår går från 230 MB till under "
                     + "30 MB. Behövs ljudet igen packas det upp medan arbetet pågår. Uppmätt "
                     + "påverkas röstavtrycken inte märkbart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Packa befintliga möten", action: packaBefintliga)
                        .disabled(packar || !lagringenLedig)
                    if packar {
                        ProgressView().controlSize(.small)
                        Text(packläge).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let packresultat {
                    Text(packresultat).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func väljKundmapp() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Välj"
        panel.message = "Välj kundmappen — varje mapp i den blir en kund. Ligger den i ett "
            + "Obsidian-valv blir kunderna mappar i valvet."
        guard panel.runModal() == .OK, let ny = panel.url else { return }
        let arkiv = Arkivet.shared

        if let invändning = Arkivet.invändning(mot: ny, nuvarande: arkiv.rot) {
            let ruta = NSAlert()
            ruta.messageText = "Den mappen går inte att använda"
            ruta.informativeText = invändning
            ruta.runModal()
            return
        }

        let antal = arkiv.kunder.count
        var text = antal == 1
            ? "Kunden flyttas med allt innehåll — inspelningar, anteckningar, mejl och uppgifter. "
            : "De \(antal) kunderna flyttas med allt innehåll — inspelningar, anteckningar, "
                + "mejl och uppgifter. "
        if let valv = Obsidian.valvrot(ovanför: ny) {
            text += "Mappen ligger i valvet \(valv.lastPathComponent): kundernas egna "
                + ".obsidian-mappar läggs i papperskorgen och kunderna tas ur Obsidians valvlista.\n\n"
                + "Synkas valvet: packa ljudet först, så tar ett möte runt 15 MB per timme och spår "
                + "i stället för 115. Och kör inte appen på två datorer mot samma kundmapp — båda "
                + "skriver om de genererade filerna.\n\n"
        }
        text += "Sökindexet byggs om, och appen startas om efteråt."

        let ruta = NSAlert()
        ruta.messageText = "Flytta kunderna till \(ny.lastPathComponent)?"
        ruta.informativeText = text
        ruta.addButton(withTitle: "Flytta och starta om")
        ruta.addButton(withTitle: "Avbryt")
        ruta.addButton(withTitle: "Byt utan att flytta")
        let svar = ruta.runModal()
        guard svar != .alertSecondButtonReturn else { return }

        if svar == .alertFirstButtonReturn {
            do {
                try arkiv.flyttaKunder(till: ny)
            } catch {
                let fel = NSAlert()
                fel.messageText = "Kunderna kunde inte flyttas"
                fel.informativeText = error.localizedDescription
                fel.runModal()
                return
            }
        }
        let förvald = Arkivet.kanonisk(Arkivet.förvaldRot.path)
        Inställningar.kundmapp = Arkivet.kanonisk(ny.path) == förvald ? nil : ny.path
        Inställningar.packaLjud = packaLjud
        Omstart.nu()
    }

    private func packaBefintliga() {
        packar = true
        packresultat = nil
        Task {
            let arkiv = Arkivet.shared
            let mappar = arkiv.kunder
                .flatMap { arkiv.inspelningar(för: $0).map(\.1) }
                .filter { !Importkö.delad.gäller($0) }
            var möten = 0
            var frigjort: Int64 = 0
            for (n, mapp) in mappar.enumerated() {
                packläge = "\(n + 1) av \(mappar.count)"
                let f = await Ljudlagring.packaIhop(i: mapp, packa: true)
                if f > 0 { möten += 1; frigjort += f }
            }
            packresultat = möten == 0
                ? "Inget att packa — allt ljud är redan m4a."
                : "\(möten) möten packade, "
                    + ByteCountFormatter.string(fromByteCount: frigjort, countStyle: .file)
                    + " frigjort."
            packar = false
        }
    }

    // MARK: - Diagnos

    @ViewBuilder
    private var diagnosflik: some View {
        HStack {
            Text("Vad som finns på den här datorn, och vilka behörigheter appen har.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if kontrollerar { ProgressView().controlSize(.small) }
            Button("Kontrollera igen") { kontrollera() }
                .disabled(kontrollerar)
        }
        VStack(spacing: 0) {
            ForEach(Array(diagnos.enumerated()), id: \.element.id) { i, rad in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle()
                        .fill(rad.ok == true ? Color.green : rad.ok == false ? Color.orange : Color.gray)
                        .frame(width: 9, height: 9)
                    Text(rad.namn).frame(width: 190, alignment: .leading)
                    Text(rad.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                if i < diagnos.count - 1 { Divider() }
            }
        }
        .kort(hörn: Stil.radhörn)
        Text("Grönt fungerar. Orange saknas och behövs. Grått saknas men är frivilligt. "
             + "Behörigheter ges i Systeminställningar → Integritet och säkerhet.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func kontrollera() {
        kontrollerar = true
        Task {
            diagnos = await Self.diagnostisera()
            kontrollerar = false
        }
    }

    /// Kontrollerna, samlade. Utbrutna för att kunna köras från
    /// kommandoraden också.
    static func diagnostisera() async -> [Diagnosrad] {
        var rader: [Diagnosrad] = []
        let fm = FileManager.default

        let w = Whisper.Sökvägar.standard
        rader.append(Diagnosrad(namn: "whisper.cpp", ok: w.brister.isEmpty,
                                text: w.brister.isEmpty ? w.rot.path : w.brister.joined(separator: ". ")))

        let r = Röstanalys.Sökvägar.standard
        rader.append(Diagnosrad(namn: "Röstanalys (Python)", ok: r.brister.isEmpty,
                                text: r.brister.isEmpty ? r.python.path : r.brister.joined(separator: ". ")))
        rader.append(Diagnosrad(namn: "pyannote", ok: r.harDiarisering,
                                text: r.harDiarisering
                                    ? "modellen finns i huggingface-cachen"
                                    : "saknas — rösterna delas med reservmetoden, som är sämre"))

        let mlx = fm.isExecutableFile(atPath: MlxWhisper.körbar.path)
        rader.append(Diagnosrad(namn: "mlx_whisper", ok: mlx ? true : nil,
                                text: mlx ? MlxWhisper.körbar.path
                                          : "saknas — behövs för andra språk än svenska när KB-Whisper är vald"))
        let ffmpeg = MlxWhisper.harFfmpeg
        rader.append(Diagnosrad(namn: "ffmpeg", ok: ffmpeg ? true : nil,
                                text: ffmpeg ? "finns — mlx_whisper läser ljudet genom den"
                                             : "saknas — mlx_whisper kan inte läsa ljudet: brew install ffmpeg"))

        let ollama = await Insikter().tillgänglig
        rader.append(Diagnosrad(namn: "Ollama", ok: ollama ? true : nil,
                                text: ollama ? "svarar på 127.0.0.1:11434"
                                             : "svarar inte — insikter under samtal och betydelsesökning är av"))
        if ollama {
            let bge = await Inbäddare.delad.tillgänglig
            rader.append(Diagnosrad(namn: "bge-m3", ok: bge ? true : nil,
                                    text: bge ? "betydelsesökningen är på"
                                              : "inte hämtad — ollama pull bge-m3"))
        }

        let claude = await Kodagent().finns
        rader.append(Diagnosrad(namn: "Claude Code", ok: claude ? true : nil,
                                text: claude ? "kopplade mappar kan genomsökas"
                                             : "hittades inte — kopplade mappar kan inte genomsökas"))

        func behörighet(_ namn: String, _ ok: Bool, frivillig: Bool = false) -> Diagnosrad {
            Diagnosrad(namn: namn, ok: ok ? true : (frivillig ? nil : false),
                       text: ok ? "beviljad" : "inte beviljad")
        }
        rader.append(behörighet("Mikrofon", AVCaptureDevice.authorizationStatus(for: .audio) == .authorized))
        rader.append(behörighet("Skärminspelning (datorljud)", CGPreflightScreenCaptureAccess()))
        rader.append(behörighet("Kalender", EKEventStore.authorizationStatus(for: .event) == .fullAccess,
                                frivillig: true))
        rader.append(behörighet("Kontakter", CNContactStore.authorizationStatus(for: .contacts) == .authorized,
                                frivillig: true))
        rader.append(behörighet("Påminnelser", EKEventStore.authorizationStatus(for: .reminder) == .fullAccess,
                                frivillig: true))
        let notiser = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        rader.append(Diagnosrad(namn: "Notiser",
                                ok: notiser == .authorized ? true : (notiser == .notDetermined ? nil : false),
                                text: notiser == .authorized ? "beviljade"
                                    : notiser == .notDetermined ? "frågas första gången något blir klart i bakgrunden"
                                    : "avstängda"))
        return rader
    }

    // MARK: - Småsaker

    /// En knapp som fyller i adressen för en känd lokal server.
    private func förval(_ namn: String, port: Int, modell: String?) -> some View {
        let adress = "http://127.0.0.1:\(port)/v1/chat/completions"
        return Button(namn) {
            val.adress = adress
            if let modell { val.modell = modell }
            meddelande = nil
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(val.adress == adress ? Color.accentColor : Color.secondary)
    }

    /// whisper.cpp-väljaren skriver tomt när standarden valts, så att en
    /// framtida standardhöjning slår igenom av sig själv.
    private var bindningArkivmodell: Binding<String> {
        Binding(get: { transkribering.arkivmodell },
                set: { transkribering.modell =
                    $0 == transkribering.motor.standardmodell ? "" : $0 })
    }

    private func fält<I: View>(_ rubrik: String, @ViewBuilder _ innehåll: () -> I) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(rubrik).font(.subheadline.weight(.medium))
            innehåll()
        }
    }

    private func läsNyckel() {
        harNyckel = Nyckelring.förLeverantör(val.leverantör) != nil
        nyckel = ""
    }

    private func sparaNyckel() {
        let ren = nyckel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ren.isEmpty else { return }
        Nyckelring.spara(ren, som: val.leverantör.nyckelkonto)
        harNyckel = true
        nyckel = ""
    }

    private func spara() {
        sparaNyckel()
        val.spara()
        transkribering.spara()
        if !elevenNyckel.isEmpty {
            Nyckelring.spara(elevenNyckel.trimmingCharacters(in: .whitespaces),
                             som: "kundkoll-elevenlabs")
        }
        let ren = insiktsmodell.trimmingCharacters(in: .whitespacesAndNewlines)
        Inställningar.insiktsmodell = ren.isEmpty ? Insikter.standardmodell : ren
        Inställningar.delaRöstprofiler = delaRöster
        Inställningar.automatiskaModellanrop = automatiska
        Inställningar.whisperRot = whisperRot
        Inställningar.pythonMiljö = pythonMiljö
        Inställningar.packaLjud = packaLjud
        stäng()
    }

    /// Ett riktigt anrop, för att felet ska visa sig här och inte mitt i en fråga.
    private func prova() {
        sparaNyckel()
        val.spara()
        provar = true
        meddelande = nil
        Task {
            let chatt = Chatt(val: val)
            do {
                let svar = try await chatt.fråga(
                    "Svara med ordet klart.", om: "prov", projekt: nil,
                    träffar: [], historik: [])
                meddelande = "Fungerar. Modellen svarade: \(svar.text.prefix(60))"
            } catch {
                meddelande = error.localizedDescription
            }
            provar = false
        }
    }
}

/// Startar om appen, efter ett byte av kundmapp: arkivet läser sin rot en
/// gång per körning. Körd från kommandoraden finns inget paket att öppna,
/// och då avslutas den bara.
enum Omstart {
    @MainActor
    static func nu() {
        let paket = Bundle.main.bundlePath
        if paket.hasSuffix(".app") {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            // Vänta tills den här instansen är borta; annars aktiverar open
            // bara den som håller på att avslutas.
            p.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; "
                           + "/usr/bin/open \"$0\"", paket, String(getpid())]
            try? p.run()
        }
        NSApp.terminate(nil)
    }
}
