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

## Phase 2 — Die kompilierten Sprachen 🔨

Reihenfolge nach absteigender Nähe zur C-Referenz — jeder Port wird leichter,
weil der vorherige die Spec-Lücken schon gefunden hat.

### 2.1 C++ 🔨
Portierung ist mechanisch, interessant sind die Fragen dahinter:
`std::vector` vs. rohes `new[]`, `std::mt19937` (bewusst **nicht** — wir
brauchen xoshiro für Bit-Gleichheit), und ob `g++` und `gcc` bei identischem
Code identischen Maschinencode erzeugen. Erwartung: praktisch gleichauf mit C;
jede Abweichung ist ein Befund.

### 2.2 Rust ⬜
Der Knackpunkt ist Bounds-Checking. Zwei Varianten bauen und vergleichen:
sicher (`grid[idx]`) und unsafe (`get_unchecked`). Die Differenz ist eine der
meistdiskutierten und selten sauber gemessenen Zahlen überhaupt.
Profile: `release`, `release` + `target-cpu=native`, `release` + fat LTO.

### 2.3 Haskell ⬜
Der aufwändigste Port und der lehrreichste. Mit `Data.Vector.Unboxed.Mutable`
und `IOUVector Float` in `IO`/`ST` ist die innere Schleife strukturell wie in C
— aber Strictness-Annotationen (`{-# UNPACK #-}`, `!`) entscheiden über
Faktor 10. Erwartung: mit Mühe im Bereich 1.5–3× C, naiv geschrieben 50×.

### 2.4 Konformitätsgate ⬜
Alle vier kompilierten Sprachen müssen `bench/run.py conformance` grün
bestehen, bevor Phase 3 beginnt.

---

## Phase 3 — Die Skriptsprachen ⬜

Hier wird es ehrlich unangenehm, und genau das ist der Punkt.

### 3.1 Python ⬜
**Zwei getrennte Implementierungen**, weil sie verschiedene Fragen beantworten:
- `impl/python/pure/` — reine Schleifen. Die Baseline. Rechne mit 300–1000× C.
  Nur `tiny` mit wenigen Ticks messbar; das Preset muss das aushalten.
- `impl/python/numpy/` — Diffusion voll vektorisiert (der Stencil ist ein
  perfekter numpy-Fall), Agenten-Pass mit Fancy-Indexing. Achtung: der
  `serial`-Modus ist in numpy **nicht** korrekt abbildbar (`arr[idx] += v`
  behandelt doppelte Indizes nicht sequenziell) — numpy kann deshalb nur
  `deferred` bedienen. Das ist ein spezifikationsrelevanter Befund und gehört
  in den Report.
- Optional: `impl/python/numba/` als drittes Datum.

### 3.2 Perl ⬜
Kern über flache Skalar-Strings mit `vec`/`pack`/`unpack` oder `PDL`.
Default Stufe B (Doubles), zusätzlich ein `--strict-f32`-Lauf, um die Kosten
der Bit-Exaktheit zu beziffern. Rendering über `SDL2::FFI`.

### 3.3 Tolerantes Konformitätsgate ⬜
`bench/run.py` um den Stufe-B-Vergleich erweitern (Metriken statt Hashes,
SPEC §7.2).

---

## Phase 4 — Rendering-Backends ⬜

Erst jetzt, weil vorher niemand weiß, ob der Kern stimmt.

Jede kompilierte Sprache bekommt SDL2 **und** raylib. Beide erhalten exakt
denselben Graustufen-Puffer aus `sb_render_gray` — gemessen wird also wirklich
nur der Upload-Pfad Grid → Textur → Bildschirm.

| Sprache | SDL2 | raylib |
|---|---|---|
| C | ✅ | ⬜ |
| C++ | ⬜ | ⬜ |
| Rust | ⬜ `sdl2` crate | ⬜ `raylib` crate |
| Haskell | ⬜ `sdl2` | ⬜ `h-raylib` |
| Python | ⬜ `pygame` | ⬜ `raylib-python-cffi` |
| Perl | ⬜ `SDL2::FFI` | ⬜ `Raylib::FFI` |

Messgröße ist **nicht** die Simulationsrate, sondern reine Renderzeit pro
Frame bei eingefrorener Simulation. Sonst dominiert der Kern und die Backends
sind ununterscheidbar.

Erwartung: der Unterschied ist klein und liegt fast ganz darin, ob das Backend
`glTexSubImage2D` mit passendem Pixelformat trifft oder intern konvertiert.
Ein Format-Mismatch kostet mehr als die Wahl der Bibliothek.

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
