# Ergebnisse

Referenzmaschine: **AMD Ryzen 9 9950X3D** (16C/32T, Zen 5, 128 MB L3),
Ubuntu 24.04 unter WSL2, gemessen vom ext4-Dateisystem.
gcc 13.3 · clang 18.1 · rustc 1.97 · GHC 9.10.3 · Node 25.5 · Python 3.12 · Perl 5.38

Rohdaten: [`results/`](../results/). Reproduzieren:

```bash
scripts/stage-wsl.sh bench --preset small --ticks 300 --reps 3
```

Alle Zeiten sind der beste von drei Läufen. `Konf.` ist die Konformitätsstufe
nach [SPEC §7](../spec/SPEC.md): **A** bit-exakt, **B** Toleranz, **C** fast-math.

---

## 1. Sprachvergleich

Klasse S (ein Thread, skalar), `--update serial`, 256×256, 16 384 Agenten,
100 Ticks. Diese Größe ist so gewählt, dass **auch Perl und reines Python sie
in Sekunden schaffen** — nur so passen alle acht Sprachen in eine Tabelle.

| # | Sprache | Variante | Compiler | Konf. | ms/Tick | rel. | RSS MiB |
|---|---|---|---|:-:|---:|---:|---:|
| 1 | C++ | | g++ -O2 | A | 0.221 | 1.00× | 18 |
| 2 | C | | clang -O2 | A | 0.228 | 1.06× | 18 |
| 3 | C++ | | clang++ -O2 | A | 0.231 | 1.06× | 18 |
| 4 | C | | gcc -O2 | A | 0.240 | 1.09× | 18 |
| 5 | Rust | unchecked | native | A | 0.253 | 1.15× | 18 |
| 6 | Rust | safe | release | A | 0.295 | 1.34× | 18 |
| 7 | Haskell | | ghc -O2 | A | 0.478 | 2.12× | 18 |
| 8 | TypeScript | | node | A | 0.664 | 3.25× | 79 |
| 9 | Perl | | perl | B | 37.19 | **160×** | 22 |
| 10 | Python | pur | python3 | B | 37.52 | **161×** | 18 |
| 11 | Python | `--strict-f32` | python3 | A | 85.72 | 367× | 18 |
| 12 | Perl | `--strict-f32` | perl | A | 123.36 | 529× | 22 |

**Alle zehn Stufe-A-Läufe liefern `0x9E8B1688 / 0x0E6A2341`.** Dieselbe
Simulation, sechs Sprachen, Bit für Bit.

Bemerkenswert:

- **Perl und reines Python sind praktisch gleich schnell** (37.19 vs 37.52 ms) —
  auf 0.9 % genau. Zwei unabhängig entwickelte Interpreter, dieselbe
  Schleifenstruktur, dasselbe Ergebnis. Der Interpreter-Dispatch dominiert so
  vollständig, dass die Sprachunterschiede verschwinden.
- **TypeScript mit Faktor 3.3 gegen optimiertes C** ist die eigentliche
  Überraschung der Tabelle. V8 ist hier zwei Größenordnungen näher an C als an
  den anderen Skriptsprachen.
- **RSS ist fast überall 18 MiB** — das Grid dominiert und ist in allen
  Sprachen gleich groß. Ausreißer sind Node (79 MiB Laufzeitumgebung) und
  numpy (40 MiB).

### Mit `--update deferred` (bringt numpy ins Feld)

| # | Sprache | Konf. | ms/Tick | rel. |
|---|---|:-:|---:|---:|
| 1 | C++ g++ -O2 | A | 0.228 | 1.00× |
| 4 | C gcc -O2 | A | 0.258 | 1.13× |
| 5 | Rust unchecked | A | 0.258 | 1.16× |
| 7 | Haskell -O2 | A | 0.508 | 2.21× |
| 8 | **Python / numpy** | A | 0.717 | **3.13×** |
| 9 | TypeScript | A | 0.710 | 3.47× |

numpy holt Python von Faktor 161 auf **3.1** — und bleibt dabei bit-exakt.
Der Preis ist, dass es `--update serial` prinzipiell nicht kann (§4).

---

## 2. Compiler-Matrix

Klasse S, Preset `small` (1024×1024, 262 144 Agenten), 300 Ticks.

| # | Sprache | Compiler | Profil | Konf. | ms total | Agent % | rel. | Binär KiB |
|---|---|---|---|:-:|---:|---:|---:|---:|
| 1 | C++ | clang++ | -O3 -march=native -flto | A | 1114 | 75 | 1.00× | 38 |
| 2 | C++ | clang++ | -O3 -march=native | A | 1118 | 75 | 1.00× | 38 |
| 3 | C | clang | -O3 -march=native -flto | A | 1129 | 75 | 1.01× | 34 |
| 4 | C | clang | -O3 -march=native | A | 1131 | 74 | 1.02× | 34 |
| 5 | C++ | g++ | -O3 | A | 1197 | 75 | 1.07× | 42 |
| 6 | C++ | g++ | -O2 | A | 1228 | 76 | 1.10× | 42 |
| 7 | C | gcc | -O2 | A | 1310 | 69 | 1.18× | 34 |
| 8 | C++ | g++ | -O3 -march=native | A | 1313 | 79 | 1.18× | 42 |
| 9 | C | gcc | -O3 | A | 1317 | 69 | 1.18× | 34 |
| 10 | C | gcc | -O3 -march=native -flto | A | 1327 | 78 | 1.19× | 34 |
| 11 | C | gcc | -O3 -march=native | A | 1330 | 78 | 1.19× | 38 |
| 12 | C++ | g++ | -O3 -march=native -flto | A | 1335 | 79 | 1.20× | 42 |
| 13 | C | gcc | **-Ofast -march=native** | C | 1352 | 79 | 1.21× | 38 |
| 14 | C++ | clang++ | -O2 | A | 1371 | 79 | 1.23× | 38 |
| 15 | C | clang | -O2 | A | 1375 | 79 | 1.23× | 34 |
| 16 | C | clang | -O3 | A | 1380 | 80 | 1.24× | 34 |
| 18 | C++ | g++ | **-Ofast -march=native** | C | 1448 | 72 | 1.30× | 42 |
| 19 | Rust | cargo | release + native + unchecked | A | 1510 | 82 | 1.36× | 440 |
| 20 | Rust | cargo | + fat LTO | A | 1556 | 82 | 1.40× | 403 |
| 21 | Rust | cargo | release + unchecked | A | 1642 | 83 | 1.47× | 436 |
| 22 | C | clang | **-Ofast -march=native** | C | 1663 | **50** | 1.49× | 34 |
| 23 | C++ | clang++ | **-Ofast -march=native** | C | 1691 | **51** | 1.52× | 42 |
| 24 | Rust | cargo | release (safe) | A | 1715 | 75 | 1.54× | 438 |
| 25 | Rust | cargo | release + native (safe) | A | 1729 | 78 | 1.55× | 442 |
| 26 | Haskell | ghc | -O2 | A | 2662 | 78 | 2.39× | 2671 |
| 27 | C | clang | -O0 | A | 3645 | 59 | 3.27× | 34 |
| 28 | TypeScript | node | – | A | 3724 | 56 | 3.34× | – |
| 29 | Haskell | ghc | -O1 | A | 4043 | 52 | 3.63× | 2667 |
| 30 | C++ | clang++ | -O0 | A | 4300 | 65 | 3.86× | 90 |
| 31 | C | gcc | -O0 | A | 4503 | 58 | 4.04× | 62 |
| 32 | C++ | g++ | -O0 | A | 5289 | 63 | 4.75× | 102 |

`ghc -O2 -fllvm` schlägt fehl (LLVM `opt`/`llc` nicht installiert) und wird als
Fehlschlag ausgewiesen statt stillschweigend übersprungen.

**28 von 28 Stufe-A-Läufen liefern `0x4F236CC6 / 0x4236A1D1`** — über zwei
Sprachen, zwei Compiler, sechs Optimierungsprofile und LTO hinweg. Die beiden
fast-math-Builds weichen ab, und zwar *pro Compiler unterschiedlich*: gcc und
clang liefern zwei verschiedene Ergebnisse. Genau deshalb ist fast-math eine
eigene Konformitätsstufe.

### Befund 1: clang und gcc reagieren gegensätzlich auf `-march=native`

| | `-O2` | `-O3` | `-O3 -march=native` |
|---|---:|---:|---:|
| gcc | **1310** | 1317 | 1330 |
| clang | 1375 | 1380 | **1131** |

Bei gcc ist `-O2` das Optimum und alles darüber leicht schlechter. Bei clang
bringt `-march=native` **18 %** — und ohne es liegt clang hinter gcc. Wer nur
`-O2` vergleicht, kommt zum Schluss "gcc ist schneller"; wer `-march=native`
dazunimmt, zum gegenteiligen. Beide Aussagen mit demselben Quelltext.

### Befund 2: `-Ofast` ist immer schlechter — aber aus zwei verschiedenen Gründen

Für jeden Compiler ist der `-Ofast`-Build langsamer als sein `-O3`-Pendant.
Die Phasenzahlen (1024², 300 Ticks, jeweils `-march=native`) zeigen, dass die
Ursache je Compiler eine andere ist:

| | gesamt | Agenten-Pass | Diffusions-Pass |
|---|---:|---:|---:|
| clang `-O3` | 1131 | 838 | 292 |
| clang `-Ofast` | 1663 | 832 | **831** |
| gcc `-O3` | 1330 | 1037 | 293 |
| gcc `-Ofast` | 1352 | **1072** | 280 |

Bei **clang** kostet fast-math **47 %**, und zwar vollständig im
Diffusionspass: 292 → 831 ms, Faktor **2.85**. Der Agenten-Pass bleibt exakt
gleich (838 → 832). Die Reassoziationsfreiheit lässt clang den 9-Punkt-Stencil
umordnen, und das Resultat ist deutlich schlechter als der geradlinige Code.

Bei **gcc** passiert das Gegenteil im Kleinen: der Diffusionspass wird sogar
minimal schneller (293 → 280), dafür der Agenten-Pass langsamer
(1037 → 1072). Netto 2 % Verlust.

Zwei Compiler, dasselbe Flag, gegenläufige Wirkung auf dieselben zwei
Schleifen. Für `-Ofast` bezahlt man hier also Determinismus und bekommt
nichts — im clang-Fall verliert man beides.

Der Agenten-Pass profitiert erwartungsgemäß nirgends: er ist Gather/Scatter
mit datenabhängigen Adressen, da hilft weder Vektorisierung noch
Reassoziation.

### Befund 3: Bounds-Checking kostet im Stencil, nicht im Agenten-Pass

1024², 300 Ticks, beide Profilpaare:

| Profil | gesamt | Agenten-Pass | Diffusions-Pass |
|---|---:|---:|---:|
| `release` safe | 1715 | 1290 | 425 |
| `release` unchecked | 1642 | 1365 | **277** (−35 %) |
| `release+native` safe | 1729 | 1346 | 382 |
| `release+native` unchecked | 1510 | 1234 | **276** (−28 %) |

Der Diffusionspass verliert durch die Checks konsistent **28–35 %** — sie
stehen der Vektorisierung des dichten Stencils im Weg.

Im Agenten-Pass ist der Effekt **nicht robust**: einmal 1290 → 1365
(langsamer!), einmal 1346 → 1234 (schneller). Beide Differenzen liegen in der
Größenordnung der Codegen-Streuung zwischen Builds. Die ehrliche Aussage ist
daher: im Gather/Scatter-Teil ist kein Effekt messbar. Plausibel, weil die CPU
dort ohnehin auf Cache-Misses wartet und die Prüfung in deren Schatten fällt.

Der oft gehörte Satz "Bounds-Checking kostet nichts" und sein Gegenteil sind
beide falsch — es hängt am Zugriffsmuster, und dieser Benchmark hat zufällig
beide Sorten in einem Programm.

### Befund 4: Skalierung ist nicht linear zwischen den Größen

C++ g++ `-O2` ist bei 256² die schnellste Konfiguration (1.00×), bei 1024²
aber nur noch 1.10×, weil clang++ `-march=native` dort davonzieht. Bei kleinen
Grids passt alles in L2 und der Code ist latenzgebunden; bei 1024² (4 MiB
Grid × 2 Puffer) beginnt Bandbreite zu zählen und Vektorisierung zahlt sich
aus. **Eine einzelne Grid-Größe genügt für eine Compiler-Aussage nicht.**

---

## 3. Rendering-Backends

Klasse R, 1024×1024, 300 Frames, `--freeze-sim` (Simulation angehalten, damit
wirklich nur der Upload-Pfad Grid → Textur → Bildschirm gemessen wird).

| Sprache | Backend | ms/Frame (Median) | p99 | fps-äquiv. | MPixel/s |
|---|---|---:|---:|---:|---:|
| C++ | raylib | **2.031** | 2.82 | 492 | 516 |
| C | raylib | **2.094** | 2.61 | 477 | 501 |
| C++ | SDL2 | 2.876 | 3.44 | 348 | 365 |
| C | SDL2 | 2.922 | 3.52 | 342 | 359 |

raylib ist konsistent **rund 29 % schneller**, C und C++ praktisch identisch
(Unterschied unter 2 %, also Rauschen).

Die Ursache ist nicht die Bibliothek, sondern das Pixelformat. raylib nimmt
den 8-Bit-Graustufenpuffer direkt entgegen (`UNCOMPRESSED_GRAYSCALE`), SDL2
braucht `ARGB8888` — also eine Expansionsschleife über eine Million Pixel pro
Frame, bevor überhaupt etwas hochgeladen wird.

Das ist bewusst nicht wegnormiert: es ist der Code, den man in beiden
Bibliotheken tatsächlich schreiben würde. Wer SDL2 dasselbe Format gäbe, würde
die Differenz weitgehend verschwinden sehen — und genau diese Erkenntnis ist
das Ergebnis.

---

## 4. Was numpy nicht kann

`impl/python/slimebench_numpy.py` implementiert **nur** `--update deferred`
und lehnt `serial` mit Exit-Code 3 und einer Erklärung ab.

Der Grund ist strukturell, nicht handwerklich: in `serial` muss Agent *i* den
Deposit von Agent *i−1* aus demselben Tick sehen. Das ist eine sequenzielle
Abhängigkeit durch das Grid; kein numpy-Ausdruck bildet sie ab. Selbst
`grid[idx] += deposit` mit doppelten Indizes akkumuliert nicht korrekt, ganz
abgesehen davon, dass das Ergebnis in die Sensorik späterer Elemente desselben
Batches zurückfließen müsste.

In `deferred` gibt es diese Abhängigkeit nicht, und `np.add.at` akkumuliert
ungepuffert in Indexreihenfolge — exakt die von SPEC-1 vorgeschriebene
Reihenfolge. Deshalb ist die numpy-Variante trotz vollständiger Vektorisierung
bit-exakt, inklusive der Feinheit, dass nur Sackgassen-Agenten ihren
PRNG-Strom weiterdrehen dürfen.

Das ist ein Befund über das Programmiermodell, kein Mangel — und es steht so
in der Registry (`updates = ["deferred"]`), damit das Harness es nicht
stillschweigend als Lücke behandelt.

---

## 5. Was Bit-Exaktheit kostet

Python und Perl laufen per Default in Stufe B. `--strict-f32` rundet jede
Zwischenoperation über `struct`/`pack` auf f32 und ist nachweislich bit-exakt
mit der C-Referenz.

| Sprache | Stufe B | Stufe A | Aufschlag |
|---|---:|---:|---:|
| Python (pur) | 37.52 ms/Tick | 85.72 ms/Tick | 2.3× |
| Perl | 37.19 ms/Tick | 123.36 ms/Tick | 3.3× |

Die ursprüngliche Schätzung in der Spec lag bei zwei Größenordnungen und war
schlicht falsch. In einer Sprache, die pro Operation ohnehin einen
Interpreter-Dispatch zahlt, verschwinden neun zusätzliche C-Level-Aufrufe pro
Zelle weitgehend im vorhandenen Overhead.

Perl zahlt mehr als Python, weil ein Perl-Array volle NVs speichert und damit
*jede* Operation gerundet werden muss, während Pythons `array('f')` beim Store
ohnehin auf f32 rundet.

---

## 6. Footprint

| Sprache | Binär (gestrippt) | RSS bei 1024² |
|---|---:|---:|
| C (gcc/clang -O3) | **34 KiB** | 18 MiB |
| C++ (g++/clang++ -O3) | 38–42 KiB | 18 MiB |
| Rust (release+LTO) | 403 KiB | 18 MiB |
| Rust (release) | 436–442 KiB | 18 MiB |
| Haskell (ghc -O2) | 2 671 KiB | 22 MiB |
| Python / Perl / Node | – (interpretiert) | 18–91 MiB |

Rust liegt beim Zwölffachen von C, Haskell beim Achtzigfachen — beides
Laufzeitsystem, nicht generierter Code. Fat LTO holt bei Rust 8 % Binärgröße
zurück und kostet 3 % Laufzeit.

Der RSS ist über alle kompilierten Sprachen identisch, weil das Grid ihn
dominiert: 2 × 4 MiB Puffer plus Agentendaten. Nur die Laufzeitumgebungen
fallen auf, Node am deutlichsten.

---

## 7. Parallelisierung (Klasse P)

C, pthreads, `--update deferred`, gcc `-O3 -march=native`. Zwei
Reduktionsstrategien nach [SPEC §5.6](../spec/SPEC.md).

### Determinismus zuerst

Bevor irgendeine Zahl zählt: liefert der parallele Lauf dasselbe Ergebnis?

| `deposit` | Strategie | T=1 | T=4 | T=32 |
|---|---|---|---|---|
| 10.0 (Default) | `binned` | `0xC5C53969` | `0xC5C53969` ✓ | `0xC5C53969` ✓ |
| 10.0 | `private` | `0xC5C53969` | `0xC5C53969` ✓ | `0xC5C53969` ✓ |
| **0.1** | `binned` | `0x95EEB32D` | `0x95EEB32D` ✓ | `0x95EEB32D` ✓ |
| **0.1** | `private` | `0x95EEB32D` | `0xE82B2012` ✗ | `0x9AA0D4F3` ✗ |

`binned` ist bit-identisch zu T=1 — geprüft für T ∈ {2,3,4,7,8,16,32}, also
auch für Thread-Zahlen, die kein Teiler der Höhe sind.

`private` stimmt mit den **Default-Parametern zufällig auch**: bei
`deposit = 10.0` bleibt jede Teilsumme `k · 10` unter 2²⁴ und ist in f32 exakt,
also spielt die Klammerung keine Rolle. Mit `--deposit 0.1` bricht das sofort —
und zwar *pro Thread-Zahl unterschiedlich*. Damit ist belegt, dass die
Unterscheidung in §5.6 keine Theorie ist, sondern das Verhalten beschreibt.

### Skalierung

`medium` (2048², 1 048 576 Agenten), 100 Ticks:

| Threads | `binned` | Speedup | `private` | Speedup |
|---:|---:|---:|---:|---:|
| 1 (seriell) | 5567 ms | 1.00× | 5567 ms | 1.00× |
| 2 | 2829 ms | 1.97× | 3142 ms | 1.77× |
| 4 | 1636 ms | 3.40× | 1822 ms | 3.06× |
| 8 | 1087 ms | 5.12× | 1576 ms | 3.53× |
| 16 | **588 ms** | **9.47×** | 2731 ms | 2.04× |
| 32 | 636 ms | 8.75× | 7286 ms | **0.76×** |

`small` (1024², 262 144 Agenten), 300 Ticks:

| Threads | `binned` | Speedup | `private` | Speedup |
|---:|---:|---:|---:|---:|
| 1 | 1675 ms | 1.00× | 1675 ms | 1.00× |
| 4 | 1065 ms | 1.57× | 933 ms | 1.80× |
| 8 | 830 ms | 2.02× | 882 ms | 1.90× |
| 16 | **693 ms** | **2.42×** | 2079 ms | 0.81× |
| 32 | 1148 ms | 1.46× | 5583 ms | 0.30× |

### Was daran interessant ist

**`private` kollabiert bei hohen Thread-Zahlen — bis unter die serielle
Laufzeit.** Der Grund ist die Reduktionsphase: sie liest `T` vollständige
Grids. Bei `medium` und 32 Threads sind das 32 × 16 MiB = **512 MiB**
Speicherverkehr pro Tick, allein um die Deposits zusammenzuzählen.
`binned` braucht dafür 8 MiB (zwei `u32`-Arrays über die Agenten), unabhängig
von der Thread-Zahl. Die Strategie, die man naiv zuerst schreibt, ist also
nicht nur die schwächere Garantie, sondern ab acht Threads auch die
langsamere — und ab sechzehn deutlich.

**Skalierung hängt stark an der Problemgröße.** `medium` erreicht 9.5×,
`small` nur 2.4×. Ein Tick besteht aus fünf Barrieren; bei `small` mit 300
Ticks sind das 1500 Synchronisationspunkte auf 1.7 Sekunden Arbeit, bei
`medium` verteilt sich derselbe Overhead auf viel mehr Rechenzeit pro Tick.

**16 Threads sind das Optimum, 32 bringen nichts.** Der Ryzen 9950X3D hat 16
physische Kerne und 32 SMT-Threads; der Agenten-Pass ist latenzgebunden auf
zufälligen Speicherzugriffen und profitiert kaum von SMT, während die
zusätzlichen Barrieren-Teilnehmer kosten. Bei `medium` bleibt T=32 mit 8.75×
knapp unter T=16.

**9.5× auf 16 Kernen ist nicht linear, und das ist erwartbar.** Zwei Gründe:
der Agenten-Pass wartet auf Cache-Misses, und `binned` hat konstruktionsbedingt
Lastungleichheit — Physarum-Agenten ballen sich auf den Filamenten, also sind
die Zeilenblöcke unterschiedlich stark belegt. Ein Thread, dessen Block ein
dichtes Filament enthält, hält alle anderen an der Barriere auf.

---

## 8. Offene Punkte

Parallelisierung existiert bisher nur in C. C++, Rust (rayon oder
`std::thread::scope`), Haskell (`-threaded`) und TypeScript (Worker +
`SharedArrayBuffer`) fehlen noch — dort wird die eigentliche Frage sein, wie
viel Code die jeweilige Sprache für dieselbe Garantie braucht.

Ebenfalls offen: SIMD (Klasse V), GPU-Compute (G), PGO-Builds — bei diesem
verzweigungslastigen Agenten-Pass der plausibelste verbleibende Gewinn — und
die Rendering-Backends für Rust, Haskell, Python und Perl.

Eine Idee aus den Skalierungsdaten: `binned` leidet an Lastungleichheit, weil
Zeilenblöcke gleich groß, aber ungleich belegt sind. Eine Aufteilung nach
Agentenzahl statt nach Zeilenzahl (Präfixsumme über die Bucket-Belegung des
Vortakts) sollte das weitgehend beheben, ohne die Determinismusgarantie zu
verlieren.
