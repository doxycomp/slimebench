# Buildplan

Reihenfolge ist nicht beliebig. Sie folgt zwei Regeln:

1. **Spec und Verifikation zuerst.** Jeder Port wird gegen Referenz-Prüfsummen
   geprüft, bevor er gemessen wird. Ein Port ohne grüne Konformität ist kein
   Datenpunkt, sondern eine Fehlerquelle.
2. **Erst die Sprach-Achse (Klasse S) vollständig, dann Parallelität.**
   Parallelisierung erst dann, wenn alle acht Sprachen single-threaded stehen —
   sonst vergleichst du am Ende Thread-Pools statt Sprachen.

Status: ✅ fertig · 🔨 als nächstes · ⬜ offen

---

## Phase 0 — Fundament ✅

- ✅ `spec/SPEC.md` — normative Spezifikation
- ✅ Richtungstabellen-Codegen (`spec/tools/gen_dirtable.py`)
- ✅ `bench/run.py` — Build, Messung, Konformität, Report
- ✅ `bench/targets.toml` — Registry Sprache × Compiler × Profil
- ✅ `scripts/setup-wsl.sh`, `scripts/stage-wsl.sh`
- ✅ Referenzvektoren `spec/testvectors/SPEC-1.json`

## Phase 1 — Referenzimplementierungen ✅

- ✅ **C headless** — die normative Referenz. Alle Vektoren werden hieraus erzeugt.
- ✅ **C + SDL2** — Fenster-Frontend, gemeinsamer Kern
- ✅ **TypeScript** — Kern + Node-headless
- ✅ **HTML5 Canvas** — interaktives Frontend mit Parameter-Reglern
- ✅ Nachweis: C / Node / Chrome byteidentisch nach 300 Ticks

**Belegt damit:** Die Spec ist implementierbar und cross-language bit-exakt.
Das ist die Voraussetzung für alles Weitere.

---

## Phase 2 — Die kompilierten Sprachen ✅

- ✅ **C++** — idiomatisch (`std::vector`, `std::bit_cast`, RAII), nicht als
  C-Transliteration. Bit-exakt.
- ✅ **Rust** — zwei Varianten über ein Cargo-Feature: `safe` und `unchecked`.
  Beide bit-exakt.
- ✅ **Haskell** — `IOUArray` in `IO`, durchgehend strikt, `unsafeRead`.
  Bit-exakt beim ersten Lauf.
- ✅ Konformitätsgate grün.

---

## Phase 3 — Die Skriptsprachen ✅

- ✅ **Python pur** — Stufe B per Default, Stufe A mit `--strict-f32`
  (nachgewiesen bit-exakt, Aufschlag 2.3×).
- ✅ **Python numpy** — Stufe A, aber **nur `deferred`**: `serial` hat eine
  sequenzielle Abhängigkeit durch das Grid. Die Implementierung lehnt den
  Modus mit klarer Meldung ab. Die vektorisierte xoshiro-Fortschaltung
  (nur Sackgassen-Agenten dürfen ihren Strom weiterdrehen) und `np.add.at`
  reproduzieren die Spec-Semantik exakt.
- ✅ **Perl** — Stufe B per Default, Stufe A mit `--strict-f32` (Aufschlag 3.3×).
- ✅ **Tolerantes Konformitätsgate** — Metriken statt Hashes, getrennt nach
  Erhaltungsgrößen (1e-6) und strukturempfindlichen Größen (2e-2).
- ⬜ Optional: `numba` als drittes Python-Datum.
- ⬜ Rendering für Python/Perl (Phase 4).

---

## Phase 4 — Rendering-Backends 🔨

Beide Backends erhalten exakt denselben Graustufen-Puffer; `--freeze-sim`
hält die Simulation an, damit wirklich nur der Upload-Pfad Grid → Textur →
Bildschirm gemessen wird.

| Sprache | SDL2 | raylib |
|---|---|---|
| C | ✅ | ✅ |
| C++ | ✅ | ✅ |
| Rust | ⬜ `sdl2` crate | ⬜ `raylib` crate |
| Haskell | ⬜ `sdl2` | ⬜ `h-raylib` |
| Python | ⬜ `pygame` | ⬜ `raylib-python-cffi` |
| Perl | ⬜ `SDL2::FFI` | ⬜ `Raylib::FFI` |

**Ergebnis** (1024², 300 Frames, eingefrorene Simulation): raylib ist
konsistent rund 29 % schneller, C und C++ praktisch identisch. Die Erwartung
hat sich bestätigt: es liegt am Pixelformat, nicht an der Bibliothek. raylib
nimmt den 8-Bit-Graustufenpuffer direkt entgegen
(`UNCOMPRESSED_GRAYSCALE`), SDL2 braucht ARGB8888 und damit eine
Expansionsschleife über eine Million Pixel pro Frame. Zahlen in
[RESULTS.md](RESULTS.md).

---

## Phase 5 — Compiler-Matrix ✅

Das erklärte Hauptziel. Vollautomatisch über `bench/run.py bench`.

| Achse | Werte |
|---|---|
| C | gcc, clang |
| C++ | g++, clang++ |
| Rust | rustc (LLVM), optional `-Zbuild-std` |
| Haskell | GHC NCG vs. LLVM-Backend (`-fllvm`) |
| Profile | `-O0 -O1 -O2 -O3 -Os`, `-march=native`, LTO, PGO, `-Ofast` |

**Erste Befunde aus Phase 1** (small, gcc 13.3, Ryzen 9950X3D):

| Profil | ms total | rel. |
|---|---:|---:|
| `-O2` | 4290 | 1.00× |
| `-O3 -march=native` | 4371 | 1.02× |
| `-Ofast -march=native` | 4422 | 1.03× |

`-O3` und `-Ofast` sind hier **langsamer** als `-O2`. Plausible Erklärung:
Der Agenten-Pass ist zu ~65 % der Laufzeit reines Gather/Scatter mit
datenabhängigen Adressen — davon profitiert keine Vektorisierung, aber der
größere Code drückt auf den µop-Cache. Das ist genau die Art Ergebnis, für die
das Projekt existiert, und es gehört mit `perf`-Zahlen unterfüttert (in WSL2
ersatzweise über `hyperfine` und die Phasen-Timer).

**PGO wurde gemessen und bringt nichts** — bei clang kostet es sogar 6 %. Die
Vier-Wege-Verzweigung auf die Sensorwerte ist datenabhängig und nahezu
gleichverteilt; PGO kann nur *vorhersagbare* Verzweigungen verbessern. Die
Vermutung an dieser Stelle war falsch. Details in
[RESULTS.md §9](RESULTS.md).

---

## Phase 6 — Parallelität 🔨 (C und C++ fertig)

Ausschließlich im `deferred`-Update-Modus (SPEC §5.5) — `serial` ist
prinzipiell nicht deterministisch parallelisierbar.

**Die Determinismus-Regel aus der ersten Fassung war falsch.** Sie forderte
thread-lokale Puffer mit fester Reduktionsreihenfolge und nannte das
deterministisch. Das liefert aber nur Reproduzierbarkeit *je Thread-Zahl*:
`(Σ Thread 0) + (Σ Thread 1) + …` ist eine andere Klammerung als die serielle
Kette. SPEC §5.6 unterscheidet jetzt zwei Strategien, und beide sind gemessen.

| Sprache | Weg | Status |
|---|---|---|
| C | pthreads, `binned` + `private` | ✅ |
| C++ | `std::jthread` + `std::barrier`, beide Strategien | ✅ |
| Rust | rayon oder `std::thread::scope` | ⬜ |
| Haskell | `-threaded -N` | ⬜ |
| TypeScript | Web Worker + `SharedArrayBuffer` | ⬜ |
| Python | `multiprocessing`, oder Free-Threaded 3.13+ | ⬜ |
| Perl | `threads` — vermutlich der ernüchterndste Datenpunkt der Suite | ⬜ |

**Ergebnis** (2048², 1 M Agenten): `binned` skaliert auf **9.5× bei 16
Threads** und ist für jede Thread-Zahl bit-identisch zum seriellen Lauf.
`private` erreicht nur 3.5× und **fällt bei 32 Threads unter die serielle
Laufzeit** — die Reduktion liest dort 512 MiB pro Tick. C und C++ sind bis
acht Threads ununterscheidbar. Zahlen und Begründung in
[RESULTS.md](RESULTS.md#7-parallelisierung-klasse-p).

Codeumfang für dieselbe Garantie: **C 326 Zeilen, C++ 264**. Der Unterschied
steckt fast vollständig im Lebenszyklus — `std::jthread` joint beim Zerstören,
`std::barrier` braucht kein `init`/`destroy`-Paar.

**Barrieren sind der Flaschenhals**, nicht die Arbeitsverteilung: 35 % der
Laufzeit bei T=16, 53 % bei T=32. Eine spinnende Barriere bringt dort +7 %,
kostet bei 32 Threads aber 55 % (die Spinner nehmen ihren SMT-Geschwistern die
Ausführungsressourcen weg). Die hybride Variante — spinnen, dann auf einem
Futex parken — ist nie schlechter als `pthread` und wird über
`SLIMEBENCH_BARRIER` gewählt. Der Gewinn bleibt klein, weil die Zeit im
*Warten* steckt und nicht im Aufwecken.

---

## Phase 7 — SIMD ✅ (C, C++, Rust)

| Sprache | Status |
|---|---|
| C | ✅ AVX2 + AVX-512 für den Diffusionspass, `--simd` |
| C++ | ✅ dieselben Intrinsics |
| Rust | ✅ `core::arch` (nicht `std::simd`, das ist nightly-only) |
| Haskell, Python, Perl, TS | — kein ehrlicher Weg, wird so dokumentiert |

**Die Annahme „umsortierte Reduktion ⇒ Stufe C" war falsch.** Der Kernel hat
keine Cross-Lane-Reduktion; jede Lane rechnet eine Ausgabezelle mit derselben
Operationsfolge wie die skalare Schleife. Das Ergebnis ist bit-identisch —
nachgewiesen unter gcc und clang, in beiden Update-Modi und kombiniert mit
16 Threads. Bedingungen: kein FMA, echte Division. Siehe SPEC §8.1.

**Ergebnis:** Diffusionspass **4.6× schneller** (AVX-512), gesamt 1.21–1.31×
bei einem Thread. Aber: AVX2 mit halber Lane-Zahl erreicht 4.18× — die
Verdopplung der Vektorbreite bringt nur 11 %, der Stencil ist
bandbreitengebunden. Und zusammen mit acht Threads bringt SIMD **gar nichts**
mehr, weil beide dieselbe Ressource angreifen.

Der Agenten-Pass bleibt skalar: die Deposits mehrerer Agenten pro Vektor in
dieselbe Zelle bräuchten Konfliktauflösung, und das wäre dann echt Stufe C.

---

## Phase 8 — GPU ✅ (CUDA + OpenGL)

| Weg | Status |
|---|---|
| CUDA | ✅ **Konformitätsstufe A**, 99x gegen einen CPU-Kern |
| GLSL 4.3 Compute | ✅ Stufe A auf llvmpipe, ~2 ULP daneben auf D3D12/NVIDIA |
| WGSL via wgpu-native | ❌ nicht gangbar, siehe unten |

**Der ursprünglich empfohlene Weg funktioniert unter WSL2 nicht.** Vulkan sieht
die NVIDIA-GPU nicht: die ICD-Dateien unter `/usr/lib/wsl/drivers/` zeigen auf
`nvoglv64.dll`, also Windows-Treiber, die aus Linux nicht ladbar sind. Damit
fällt wgpu-native aus, und die WGSL-Idee „eine Shaderquelle für alles" mit ihr.

Gangbar sind stattdessen zwei Wege, beide implementiert:

* **CUDA** — nur NVIDIA, aber unter WSL2 offiziell unterstützt und der
  schnellste. Das Toolkit hier (12.0) kennt Blackwell nicht; Kompilieren nach
  PTX für `compute_90` und JIT durch den Treiber funktioniert.
* **OpenGL 4.3 Compute** — erreicht die RTX 5080 über Mesas D3D12-Backend
  (`GALLIUM_DRIVER=d3d12 MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA`) und läuft
  aus jeder Sprache, die einen GL-Kontext bekommt. Damit näher am
  ursprünglichen Ziel als wgpu es gewesen wäre.

**Die Annahme „Klasse G ist zwangsläufig Stufe C" war falsch** — jedenfalls für
CUDA. Nötig sind `-fmad=false`, korrekt gerundete Division und ganzzahlige
Deposit-Atomics statt `atomicAdd(float*)`. Details in SPEC §8.2 und
[RESULTS.md §10](RESULTS.md).

Offen: ein Host in einer zweiten Sprache (der GL-Weg macht das billig), eine
Determinismus-Analyse für weitere Treiber, und eine Wiederholung auf nativem
Linux-GL statt über die D3D12-Übersetzung.

---

## Phase 9 — Auswertung ⬜

- `docs/RESULTS.md` — automatisch generiert aus `results/*.jsonl`
- Diagramme: MAUPS pro Sprache (Klasse S), Compiler-Matrix als Heatmap,
  Agenten- vs. Diffusionsanteil gestapelt, Skalierung über die Presets
- **Footprint-Tabelle:** RSS, gestrippte Binärgröße, Buildzeit, Zeilen Code
- Kurzes Fazit pro Sprache: erreichte Performance vs. Aufwand, den sie gekostet hat

---

## Bewusst außerhalb des Scope

Damit das Projekt endlich wird:

- Weitere Sprachen (Go, Zig, Java, C#) — die Spec macht Ports trivial, aber
  die Matrix ist schon groß genug.
- Distributed / Multi-Node.
- Anderes Physarum-Modell (mehrere Spezies, Nahrungsquellen, 3D). Reizvoll,
  aber eine andere Simulation und damit eine andere Spec.
