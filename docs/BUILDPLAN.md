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

## Phase 5 — Compiler-Matrix ⬜

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

Zusätzlich messen: **PGO**. Bei so verzweigungslastigem Code der plausibelste
echte Gewinn.

---

## Phase 6 — Parallelität ⬜

Erst wenn Klasse S vollständig ist. Ausschließlich im `deferred`-Update-Modus
(SPEC §5.5) — `serial` ist prinzipiell nicht deterministisch parallelisierbar.

**Determinismus-Regel:** Thread-lokale Deposit-Puffer, Reduktion in fester
Thread-Reihenfolge. Atomare `f32`-Additionen sind verboten, weil ihr Ergebnis
von der Ausführungsreihenfolge abhängt.

| Sprache | Weg |
|---|---|
| C | OpenMP, pthreads |
| C++ | OpenMP, `std::jthread`, `std::execution::par` |
| Rust | rayon |
| Haskell | `Control.Parallel.Strategies`, `-threaded -N` |
| TypeScript | Web Worker + `SharedArrayBuffer` — funktioniert überraschend gut |
| Python | `multiprocessing` (GIL), oder Free-Threaded 3.13+ als eigener Datenpunkt |
| Perl | `threads` — vermutlich der ernüchterndste Datenpunkt der Suite |

Interessant ist hier nicht die Skalierung an sich (auf 32 Threads skaliert der
Diffusionspass fast linear, der Agenten-Pass wegen Scatter-Konflikten nicht),
sondern **wie viel Code es in jeder Sprache kostet**.

---

## Phase 7 — SIMD ⬜

Realistisch nur C, C++ und Rust. Für Haskell, Python, Perl und TS gibt es
keinen ehrlichen Weg, explizites SIMD zu schreiben — das wird so dokumentiert,
statt es zu erfinden.

Der Diffusionspass ist der lohnende Teil: ein dichter 3×3-Stencil über f32,
AVX2 gibt 8 Lanes, AVX-512 (auf Zen 5 vorhanden) 16. Erwartung: 4–8× auf
diesem Pass, was bei ~35 % Laufzeitanteil rund 25–30 % gesamt bedeutet.

Der Agenten-Pass ist Gather/Scatter. AVX2 kann `vgatherdps`, hat aber keinen
Scatter; AVX-512 kann beides, ist aber bei zufälligen Adressen oft langsamer
als skalar. Das zu messen ist interessanter, als es vorherzusagen.

Achtung: umsortierte Reduktion ⇒ Konformitätsstufe C.

---

## Phase 8 — GPU ⬜

### Zur offenen Frage: ist GPU sprachübergreifend abbildbar?

Teilweise — und man sollte präzise sein, worin der Vergleich dann besteht.

**Der Rechenkern wandert in einen Shader.** Die Hostsprache allokiert Puffer,
startet den Dispatch und wartet. Damit misst Klasse G **nicht mehr die
Sprache**, sondern Shader-Compiler und Treiber. Rust und Perl würden dieselbe
Zahl liefern. Klasse G ist deshalb als *Obergrenze für dieses Problem*
wertvoll, nicht als Zeile im Sprachranking — und der Report muss das so sagen.

**Empfehlung: ein einziger WGSL-Kernel über wgpu-native.**

| Weg | Sprachreichweite | Browser | Bewertung |
|---|---|---|---|
| **WGSL + wgpu-native** | C-ABI ⇒ C, C++, Rust, Python (cffi), Haskell (FFI), Node | ✅ WebGPU nutzt denselben Shader | **Empfohlen.** Eine Shader-Quelle für alles. |
| GLSL 4.3 Compute + OpenGL | überall wo ein GL-Kontext existiert (SDL2/raylib haben ihn schon) | ❌ WebGL2 kann kein Compute | Nativ am schnellsten aufgesetzt, aber zweite Shader-Quelle für den Browser nötig |
| Vulkan Compute | wie GLSL, mehr Kontrolle | ❌ | Viel Boilerplate für wenig Zusatzerkenntnis |
| CUDA | nur NVIDIA | ❌ | Als *Ceiling-Referenz* auf der RTX 5080 durchaus reizvoll |

WSL2 ist vorbereitet: `/dev/dxg` ist vorhanden, GPU-Passthrough funktioniert.

**Konformität:** Klasse G landet praktisch immer in Stufe C. GPU-Trigonometrie
und Standard-Fast-Math weichen ab, und Reduktionsreihenfolgen sind nicht
garantiert. Die quantisierte Richtungstabelle (SPEC §4) hilft trotzdem — sie
eliminiert die `sin`/`cos`-Abweichung und lässt nur noch die Additionsordnung
als Fehlerquelle übrig. Mit `deferred` + ganzzahligen Atomics wäre sogar
Determinismus erreichbar; das ist ein eigenes Experiment wert.

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
