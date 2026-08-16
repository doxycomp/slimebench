# slimebench

Physarum-Simulation (Schleimpilz) in acht Sprachen — mit einem
Verifikationsmechanismus, der beweist, dass überall wirklich dieselbe
Simulation läuft, und einem Harness für Performance- und Footprint-Vergleiche
über Sprachen, Rendering-Backends und Compiler hinweg.

| | |
|---|---|
| **Was es ist** | [docs/PROJECT.md](docs/PROJECT.md) |
| **Wie es weitergeht** | [docs/BUILDPLAN.md](docs/BUILDPLAN.md) |
| **Die Regeln** | [spec/SPEC.md](spec/SPEC.md) — normativ |

## Stand

| Sprache | headless | SDL2 | raylib | Konformität |
|---|:-:|:-:|:-:|:-:|
| C | ✅ | ✅ | ✅ | Stufe A (Referenz) |
| C++ | ✅ | ✅ | ✅ | Stufe A |
| Rust (safe + unchecked) | ✅ | ⬜ | ⬜ | Stufe A |
| Haskell | ✅ | ⬜ | ⬜ | Stufe A |
| TypeScript / Node | ✅ | — | — | Stufe A |
| TypeScript / Canvas | — | ✅ Browser | — | Stufe A |
| Python / numpy | ✅ | ⬜ | ⬜ | Stufe A, nur `deferred` |
| Python / pur | ✅ | ⬜ | ⬜ | Stufe B, A mit `--strict-f32` |
| Perl | ✅ | ⬜ | ⬜ | Stufe B, A mit `--strict-f32` |

**Alle acht Sprachen bestehen `bench/run.py conformance`.** Sechs davon
bit-exakt gegen die C-Referenz über Grid- *und* Agenten-Prüfsumme, bei
`micro`/`tiny`/`small` × `serial`/`deferred` × Tick-Ständen {1, 10, 100, 1000}.
Python und Perl erreichen mit `--strict-f32` ebenfalls Bit-Exaktheit.

Messwerte: [docs/RESULTS.md](docs/RESULTS.md).

## Schnellstart

Kanonische Umgebung ist WSL2 / Ubuntu. Benötigt werden nur `gcc`, `make` und
`node` — alles Weitere installiert `scripts/setup-wsl.sh` bei Bedarf.

C-Referenz bauen und laufen lassen:

```bash
make -C impl/c CC=gcc PROFILE=o2 headless && ./impl/c/build/gcc-o2/slimebench-headless --preset small --ticks 600
```

Dasselbe in TypeScript, mit identischem Ergebnis:

```bash
node --experimental-strip-types impl/ts/src/main-node.ts --preset small --ticks 600
```

Prüfen, dass alle Implementierungen übereinstimmen:

```bash
python3 bench/run.py conformance
```

Weitere Toolchains nachinstallieren (phasenweise: `base`, `render`, `rust`, `haskell`, `scripting`, `gpu`):

```bash
scripts/setup-wsl.sh all
```

Benchmarken (vom Linux-Dateisystem aus, sonst misst du die 9p-Brücke):

```bash
scripts/stage-wsl.sh bench --preset medium --reps 3
```

Parallel (Klasse P, nur `deferred`) — `binned` ist bit-identisch zum seriellen Lauf:

```bash
./impl/c/build/gcc-o3-native/slimebench-headless --preset medium --ticks 100 --update deferred --threads 16 --deposit-reduce binned
```

Interaktiv im Browser, mit Reglern für alle Parameter:

```bash
cd impl/ts && npm install && npm run build:web && python3 -m http.server 8765 --directory ../web
```

Grafisches C-Frontend (SDL2, läuft unter WSLg):

```bash
make -C impl/c CC=gcc PROFILE=o3-native sdl2 && ./impl/c/build/gcc-o3-native/slimebench-sdl2 --preset browser --render
```

## Die interessanten Details

- **Warum es überhaupt bit-exakt sein kann.** `sin`/`cos` sind zwischen glibc,
  V8 und GPU-Treibern nicht bit-identisch, und Physarum ist chaotisch genug,
  dass 1 ULP nach 200 Ticks sichtbar wird. Deshalb sind Agentenrichtungen
  ganzzahlig quantisiert und die Trig-Tabelle wird als u32-Bitmuster in jede
  Sprache generiert. Details: [SPEC §4](spec/SPEC.md).
- **Warum JavaScript trotzdem Stufe A schafft.** `Math.fround(f64_op(a,b))` ist
  für `+ − × ÷` beweisbar identisch mit der f32-Operation, weil `53 ≥ 2·24+2`.
- **Warum es zwei Update-Modi gibt.** Der Referenzmodus `serial` lässt Agenten
  die Deposits ihrer Vorgänger im selben Tick sehen — schön, aber prinzipiell
  nicht deterministisch parallelisierbar. `deferred` löst das und ist die
  Grundlage aller Parallel-, SIMD- und GPU-Varianten.
- **Warum numpy nur `deferred` kann.** `serial` hat eine sequenzielle
  Abhängigkeit durch das Grid, die sich nicht vektorisieren lässt. Die
  Implementierung lehnt den Modus mit klarer Meldung ab, statt still etwas
  anderes zu rechnen — siehe Docstring in
  [slimebench_numpy.py](impl/python/slimebench_numpy.py).
- **Was Bounds-Checking in Rust kostet.** Im Diffusionspass ein Drittel, im
  Agenten-Pass nichts. Siehe [docs/RESULTS.md](docs/RESULTS.md).
- **Warum es zwei Reduktionsstrategien für Threads gibt.** Thread-lokale
  Deposit-Puffer sind nur *je Thread-Zahl* reproduzierbar, nicht bit-identisch
  zum seriellen Lauf. Die räumlich gebündelte Variante ist es — und ab acht
  Threads zusätzlich schneller. Siehe [SPEC §5.6](spec/SPEC.md).
- **Warum `-O3` hier langsamer ist als `-O2`.** Siehe
  [docs/RESULTS.md](docs/RESULTS.md).

## Herkunft

Modell nach Jeff Jones (2010), *Characteristics of pattern formation and
evolution in approximations of Physarum transport networks*. Ausgangspunkt für
Parameter und Aufbau war
[programmingchaos.dev](https://www.programmingchaos.dev/physarum-simulations-programming-slime-molds/).
