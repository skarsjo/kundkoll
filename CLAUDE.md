# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Om projektet

Bjarbys kundkoll — nativ macOS-app (SwiftUI, macOS 26) för inspelning, lokal
transkribering och kundkunskap. Allt — kod, identifierare, kommentarer, commits
och dokumentation — är på **svenska**; skriv likadant. Commit-rubriker börjar med
`Kundkoll: `.

Det här är en fork: `origin` = skarsjo/kundkoll, `upstream` = fltman/kundkoll.
Läs `ATT-GORA.md` om den finns — den beskriver pågående överlämningsarbete.

## Bygga och testa

Ett enda SwiftPM-mål (`Package.swift`, språkläge Swift 5). Xcode behövs inte.

```bash
swift build                                         # debug
./scripts/bygg-app.sh                               # release → dist/Bjarbys kundkoll.app (kopierar in rostanalys.py och AppleScript)
"$(swift build --show-bin-path)/Kundkoll" --test     # hela provsviten
```

Binärens väg beror på SwiftPM-versionen: README säger
`.build/arm64-apple-macosx/debug/`, med Swift 6.4 blir det
`.build/out/Products/Debug/`. Ta den från `swift build --show-bin-path`.

- Det finns ingen XCTest/Swift Testing. Testerna är ett läge i appen:
  `Prov.svit/kolla/lika` i `Test/Provkörning.swift`, sviterna i
  `Test/Tester.swift` anropas i ordning från `Tester.kör()`. Det finns inget
  filter — för att köra en enda svit, kommentera tillfälligt bort de andra i
  `kör()`. Nya prov läggs i rätt svit där.
- `--prov-*`-flaggorna (listade i README under "Bygga", tolkade i
  `KundkollApp.swift`) kör delar av kedjan skarpt mot riktiga modeller och filer,
  t.ex. `--prov-ljud f.wav` för hela kedjan och `--prov-chatt [leverantör] [modell]`.
- `KUNDKOLL_ROT=<mapp>` pekar arkivet på en annan rot än `~/Documents/Kunder`
  — använd det för skarpa prov så att riktig kunddata inte rörs.
- Med Swift 6.4 kan långa SwiftUI-modifierkedjor ge "unable to type-check this
  expression in reasonable time"; lyft ut closure-kroppar till metoder.

## Arkitektur

- `Kärna/` — modell och tjänster. `Arkivet` (singleton, `@MainActor`) äger
  kunder/projekt/möten. **Filsystemet är sanningen**, ingen databas: varje kund
  är en Obsidian-vault under `~/Documents/Kunder`, mötet lagras som `möte.json`
  + wav-spår, och `Filbevakare` plockar upp ändringar gjorda i Finder/Obsidian.
  Genererade filer (`Transkript.md`, `Att göra.md`, `Läget.md`, `Tid.md`,
  `Mail.md`) bär `genererad: kundkoll` och skrivs om helt; anteckningar och
  kontaktnoters brödtext är användarens och får aldrig skrivas över.
- `Ljud/` — inspelning via ScreenCaptureKit med två skilda spår (mikrofon =
  jag, datorljud = motpart), live-transkribering i fönster vid pauser
  (`Tystnadsfilter` stoppar tysta fönster så whisper inte hallucinerar), och
  `Efterbearbetning` efter mötet: arkivpass med större modell → röstanalys →
  sammanfattning → uppgifter. `Importkö` kör jobben och överlever omstart.
- Externa processer startas via `Underprocess`: whisper.cpp
  (`~/Projekt/whisper.cpp`), MLX-whisper, och `scripts/rostanalys.py` (pyannote
  + speechbrain i Pythonmiljön `~/Projekt/transcriber/venv`) för diarisering
  och röstavtryck (`Röstprofil`).
- LLM-anrop: `Leverantör` (OpenRouter, Anthropic, OpenAI, Azure, lokal) och
  `Chatt.fråga` används av chatten, `Sammanfattning`, `Lägesbild`,
  `Insikter` och uppgiftsletningen i mejl. Lokala servrar talar OpenAI-formatet;
  `Sammanfattning` går direkt mot Ollamas `/api/chat` (port 11434) med
  JSON-schema. `Inbäddare` (bge-m3 via Ollama) + `Kunskapsbank` (SQLite FTS5)
  ger hybridsökningen.
- `Vyer/` — SwiftUI. `Huvudvy` är ramen (sidopanel, innehåll, chattpanel);
  inspelningen har ett eget fönster (`Inspelningsfönster`).

Mätningarna bakom modell- och parameterval står i `docs/VERIFIERAD-STACK.md`,
`docs/RÖSTANALYS.md`, `docs/KUNSKAPSBANK.md` och `docs/INSIKTER.md` — ändra
inte trösklar eller modellval utan att läsa dem.
