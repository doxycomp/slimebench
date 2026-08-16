# slimebench — Physarum Benchmarking Suite

Dieselbe Simulation, acht Sprachen, zwei Rendering-Backends, viele Compiler —
und ein Verifikationsmechanismus, der beweist, dass wirklich dieselbe
Simulation läuft.

## 1. Worum es geht

Physarum polycephalum (Schleimpilz) lässt sich mit einem verblüffend simplen
Agentenmodell nachbilden (Jeff Jones, 2010). Jeder Agent kennt nur eine
Position, eine Richtung und drei Sensoren. Aus dieser lokalen Regel entstehen
globale Transportnetzwerke — ohne dass irgendwo im Code das Wort "Netzwerk"
vorkommt.

Pro Tick:

1. **Chemotaxis** — der Agent liest drei Punkte vor sich (links, geradeaus, rechts).
2. **Rotation** — er dreht sich zum stärksten Signal.
3. **Bewegung** — ein Schritt nach vorn.
4. **Deposit** — er hinterlässt Pheromon.
5. **Diffusion** — 3×3-Blur über das gesamte Grid.
6. **Decay** — alles wird mit 0.94 multipliziert.

Für einen Sprach- und Compiler-Vergleich ist das ein nahezu ideales Workload:

- **Zwei komplementäre Zugriffsmuster.** Der Agenten-Pass ist reines
  Random-Access-Gather/Scatter (cache-feindlich, latenzgebunden), der
  Diffusions-Pass ein dichter Stencil-Stream (bandbreitengebunden,
  vektorisierbar). Sprachen und Compiler verhalten sich in beiden Phasen
  völlig unterschiedlich — deshalb misst die Suite sie **getrennt**.
- **Kein I/O, keine Allokation im Hot Loop, keine Bibliotheken.** Was du misst,
  ist Codegen und Speicherverhalten, nicht das Ökosystem.
- **Chaotisch.** Winzige numerische Abweichungen wachsen sichtbar an — was
  Verifikation schwer macht und deshalb zum eigentlich interessanten Teil des
  Projekts wird (siehe §3).
- **Skaliert glatt** von 512² bis 4096² und von 65k bis 4M Agenten.

## 2. Architektur

```
spec/                normative Spezifikation + generierte Richtungstabelle
  SPEC.md            <- die einzige Wahrheit
  tools/             Codegen für die Trig-Tabelle (alle Sprachen)
  testvectors/       Referenz-Prüfsummen und Stufe-B-Metriken
impl/
  c/                 Referenzimplementierung: Kern + headless + SDL2 + raylib
  cpp/               idiomatisches C++20, dieselben drei Frontends
  rust/              safe- und unchecked-Variante über ein Cargo-Feature
  haskell/           IOUArray in IO, durchgehend strikt
  ts/                Kern + Node-headless + Browser-Entry
  web/               HTML5-Canvas-Frontend (generierter Bundle)
  python/            pure (Stufe B / --strict-f32) und numpy (nur deferred)
  perl/              Stufe B / --strict-f32
bench/
  run.py             Build- und Messharness, Konformitätsprüfung, Report
  targets.toml       Registry: Sprache × Backend × Compiler × Profil
  gridstat.py        Grid-Dump inspizieren, PNG-Vorschau
scripts/
  setup-wsl.sh       Toolchains nachinstallieren (phasenweise)
  stage-wsl.sh       Repo aufs Linux-Dateisystem spiegeln und messen
results/             JSONL-Messreihen
docs/RESULTS.md      ausgewertete Ergebnisse
```

Jede Implementierung ist **strikt zweigeteilt**: ein Simulationskern ohne jede
Ein-/Ausgabe, und darüber austauschbare Frontends (headless / SDL2 / raylib /
Canvas). Nur so lässt sich Rechenzeit von Renderzeit trennen — und nur so ist
der spätere SDL2-vs-raylib-Vergleich fair, weil beide exakt denselben
Byte-Puffer übergeben bekommen.

## 3. Der eigentliche Kniff: Verifikation

Das Problem, an dem solche Vergleichsprojekte normalerweise scheitern:

> Nach 200 Ticks sehen zwei Implementierungen unterschiedlich aus. War das ein
> Portierungsfehler, oder nur eine andere Rundung im letzten Bit?

Bei einem chaotischen System sind beide Ursachen nach wenigen hundert Ticks
optisch **nicht unterscheidbar**. Ohne Antwort darauf vergleichst du am Ende
möglicherweise eine korrekte Implementierung mit einer kaputten.

slimebench löst das mit vier Bausteinen:

| Baustein | Wirkung |
|---|---|
| **Vorgeschriebene Operationsreihenfolge** (SPEC §5.4) | Gleitkomma-Addition ist nicht assoziativ. Die Summationsreihenfolge im Diffusionskernel ist normativ festgelegt. |
| **Generierte Trig-Tabelle** (SPEC §4) | `sin`/`cos` sind zwischen glibc, V8, Rust und GPU-Treibern **nicht** bit-identisch. Deshalb sind Richtungen ganzzahlig quantisiert (NDIR=1440) und die Tabelle wird als u32-Bitmuster in jede Sprache generiert. Nebeneffekt: schneller als `sinf`. |
| **Portabler 32-Bit-PRNG** (SPEC §3) | xoshiro128++ und SplitMix32, reine 32-Bit-Ganzzahlarithmetik — direkt abbildbar in JS, Perl, GLSL und WGSL, wo 64-Bit teuer oder gar nicht verfügbar ist. |
| **Prüfsummen** (SPEC §6) | Getrennte Hashes für Grid und Agenten. Weicht nur das Grid ab, liegt der Fehler im Diffusionspass; weichen beide ab, im Agenten-Pass. `--hash-every N` grenzt den ersten divergierenden Tick binär ein. |

**Ergebnis:** Sechs von acht Implementierungen — C, C++, Rust, Haskell,
TypeScript und Python/numpy — sind bit-exakt gegen die C-Referenz, über
Grid- *und* Agenten-Prüfsumme, bei drei Grid-Größen × beiden Update-Modi ×
Tick-Ständen bis 1000. Python (pur) und Perl erreichen dasselbe mit
`--strict-f32`; ohne das Flag laufen sie in Stufe B.

Damit ist die Frage oben beantwortbar geworden: weicht ein Port ab, ist es ein
Bug, kein Rundungsartefakt.

Und wo Bit-Exaktheit prinzipiell unmöglich ist (fast-math, GPU, SIMD mit
umsortierter Reduktion), sagt die Spec das vorher und weist die Läufe in einer
eigenen Konformitätsstufe aus, statt sie stillschweigend danebenzustellen.

## 4. Was gemessen wird

Pro Lauf, von der Implementierung selbst gemeldet:

- Gesamtzeit, **aufgeteilt nach Agenten-Pass und Diffusions-Pass**
- ms/Tick als Median und p99 (nicht nur Mittelwert — Ausreißer sind aussagekräftig)
- MAUPS (Mio. Agenten-Updates/s) und MCUPS (Mio. Zell-Updates/s)
- Grid- und Agenten-Prüfsumme

Vom Harness von außen gemessen, damit sich niemand selbst schönrechnen kann:

- Peak RSS (per `os.wait4`, kein `time(1)` nötig)
- Binärgröße, roh und `strip`ped
- Buildzeit

## 5. Benchmark-Klassen

Ein Vergleich über Klassengrenzen hinweg ist bedeutungslos und wird vom Report
verhindert:

| Klasse | Was sie misst |
|---|---|
| **S** | Skalar, ein Thread. **Die Sprach-Achse** — hier steht "wie schnell ist Sprache X". |
| **P** | Multi-Thread. Misst, wie zugänglich das Ökosystem Parallelisierung macht. |
| **V** | SIMD. Realistisch nur für C, C++ und Rust. |
| **G** | GPU-Compute. Misst **nicht** die Sprache, sondern Shader-Compiler und Treiber. |

## 6. Umgebung

Kanonischer Messhost ist **WSL2 / Ubuntu 24.04** — dort sind gcc, clang, rustc,
GHC, SDL2 und raylib alle erstklassig verfügbar.

Eine Warnung ist im Harness eingebaut: liegt das Repo unter `/mnt/c`, läuft
jeder Dateizugriff über die 9p-Brücke, und Buildzeiten wie Prozessstart messen
die Brücke statt den Code. `scripts/stage-wsl.sh` spiegelt das Repo vorher aufs
Linux-Dateisystem.

Referenzmaschine: AMD Ryzen 9 9950X3D (16C/32T), NVIDIA RTX 5080.
