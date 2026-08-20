# Ergebnisse

Alle Zahlen in diesem Dokument stammen aus **einem** Lauf,
[`results/run-20260819-2056/`](../results/run-20260819-2056/), erzeugt mit:

```bash
scripts/stage-wsl.sh && bench/full-run.sh
```

Das ist neu, und der Grund ist ein Fehler in der vorherigen Fassung: die Zahlen
waren über ein Dutzend Sitzungen an verschiedenen Tagen entstanden. Innerhalb
einer Reihe ist das unkritisch, über Reihen hinweg still irreführend — und das
Dokument zog mehrere Vergleiche über Reihen hinweg. Die Tabellen werden jetzt
mit `bench/tables.py` aus dem Ergebnisverzeichnis erzeugt, nicht aus einem
Transkript abgetippt.

```
cpu     AMD Ryzen 9 9950X3D  (16C/32T, Zen 5, 128 MB L3)
gpu     NVIDIA RTX 5080 (84 SMs), über Mesa D3D12
os      Ubuntu 24.04 unter WSL2, 46 GiB, ext4
gcc 13.3 · clang 18.1.3 · rustc 1.97.1 · GHC 9.10.3 · Node 25.5
python 3.12.3 · perl 5.38.2 · CUDA 12.0
```

---

## Inhalt

1. [Die kurze Fassung](#1-die-kurze-fassung)
2. [Sprachvergleich (Klasse S)](#2-sprachvergleich-klasse-s)
3. [Compiler](#3-compiler)
4. [Wie sehr der Programmierstil zählt (Haskell)](#4-wie-sehr-der-programmierstil-zählt-haskell)
5. [Parallelität (Klasse P)](#5-parallelität-klasse-p)
6. [SIMD (Klasse V)](#6-simd-klasse-v)
7. [GPU (Klasse G)](#7-gpu-klasse-g)
8. [Rendering (Klasse R)](#8-rendering-klasse-r)
9. [Footprint](#9-footprint)
10. [Was nicht funktioniert hat](#10-was-nicht-funktioniert-hat)
11. [Wo ich mich geirrt habe](#11-wo-ich-mich-geirrt-habe)
12. [Offene Punkte](#12-offene-punkte)

---

## 1. Die kurze Fassung

Dieselbe Simulation, elf Implementierungen in acht Sprachen, von einem
Perl-Interpreter bis zu 84 Streaming-Multiprozessoren.

![Klassenübersicht](charts/classes.svg)

| Klasse | beste Konfiguration | `medium`, 100 Ticks | vs. 1 CPU-Kern |
|---|---|---:|---:|
| S — ein Thread | C, clang `-O3 -march=native -flto` | 5609 ms | 1× |
| P — 32 Threads | C++, `std::jthread`, `binned` | 698 ms | **8.0×** |
| G — GPU | CUDA, RTX 5080 | **52 ms** | **108×** |

Klasse V steht nicht in dieser Tabelle, weil sie bei `small` gemessen wird —
dort bringt AVX-512 **1.22×** (1234 → 1012 ms). Der Diffusionspass allein wird
viermal schneller, macht aber nur ein Viertel der Laufzeit aus; §6.

Vier Ergebnisse, die ich vorher nicht erwartet hätte:

- **Bit-Exaktheit hält durch alles hindurch.** 31 von 31 Stufe-A-Läufen im
  `serial`-Modus liefern `0x9E8B1688 / 0x0E6A2341`, 34 von 34 im
  `deferred`-Modus `0xAAB0115C / 0x328E3716`. Dazu Klasse P in allen sieben
  Sprachen für jede Thread-Zahl, SIMD, und CUDA bei jedem Preset. Die Spec
  hatte für SIMD und GPU jeweils das Gegenteil angenommen.
- **Eine Sprachrangliste aus einer Klasse überträgt sich nicht auf die
  nächste.** TypeScript ist in Klasse S 3.5× langsamer als C und skaliert in
  Klasse P am besten von allen (11.5×). Haskell liegt in Klasse S bei 1.19×
  und trifft in Klasse P und Klasse R jeweils C.
- **Klasse R vergleicht nicht die Sprache.** Auf raylib liegen vier
  kompilierte Sprachen innerhalb von **4 %**. Was zählt, ist das Pixelformat.
- **Fast jede „offensichtliche" Optimierung hat verloren.** PGO, die parallele
  Präfixsumme, der Lastausgleich, die reine Spin-Barriere — vier Versuche, ein
  brauchbares Ergebnis. Details in §10.

---

## 2. Sprachvergleich (Klasse S)

Ein Thread, skalar. 256×256 mit 16 384 Agenten und 100 Ticks — diese Größe ist
so gewählt, dass **auch Perl und reines Python sie in Sekunden schaffen**, denn
nur so passen alle Sprachen in eine Tabelle. Jede Implementierung steht einmal,
mit ihrem besten Profil; die Compiler-Achse hat ihren eigenen Abschnitt.

![Sprachvergleich](charts/languages.svg)

### `--update serial`

| # | Sprache | Profil | Konf. | ms/Tick | rel. | RSS MiB |
|---:|---|---:|:-:|---:|---:|---:|
| 1 | C (clang) | o3-native-lto | A | 0.193 | 1.00× | 18 |
| 2 | C++ (clang++) | o3-native | A | 0.214 | 1.11× | 18 |
| 3 | C++ (g++) | o3 | A | 0.217 | 1.13× | 18 |
| 4 | C (gcc) | o3 | A | 0.221 | 1.14× | 18 |
| 5 | **Haskell** | o2-llvm | A | **0.230** | **1.19×** | 18 |
| 6 | Rust (unchecked) | release-native-lto-unchecked | A | 0.264 | 1.36× | 18 |
| 7 | Rust (safe) | release | A | 0.290 | 1.50× | 18 |
| 8 | TypeScript | node | A | 0.670 | 3.47× | 81 |
| 9 | Python (pur) | — | B | 38.45 | 199× | 18 |
| 10 | Perl | — | B | 40.44 | 209× | 22 |
| 11 | Python (`--strict-f32`) | — | A | 88.21 | 457× | 18 |
| 12 | Perl (`--strict-f32`) | — | A | 128.71 | 666× | 22 |

**31 von 31 Stufe-A-Läufen: `0x9E8B1688 / 0x0E6A2341`.**

### `--update deferred`

Hier können auch numpy und die idiomatische Haskell-Fassung antreten.

| # | Sprache | Konf. | ms/Tick | rel. |
|---:|---|:-:|---:|---:|
| 1 | C (clang, o3-native-lto) | A | 0.195 | 1.00× |
| 2 | C++ (clang++, o3-native) | A | 0.214 | 1.10× |
| 4 | C (gcc, o3) | A | 0.226 | 1.16× |
| 5 | Haskell (o2-llvm) | A | 0.255 | 1.31× |
| 6 | Rust (unchecked) | A | 0.275 | 1.41× |
| 8 | Haskell (idiomatisch, `vector`) | A | 0.515 | 2.64× |
| 9 | TypeScript | A | 0.753 | 3.86× |
| 10 | Python (numpy) | A | 1.118 | 5.74× |

**34 von 34 Stufe-A-Läufen: `0xAAB0115C / 0x328E3716`.**

Bemerkenswert:

- **Haskell ist auf Platz 5, vor Rust.** Das ist neu und kommt aus §4: eine
  einzige Änderung (`Data.Array.Unboxed.(!)` → `unsafeAt`) war Faktor 1.45. Die
  vorherige Fassung dieses Dokuments hatte Haskell bei 2.16×.
- **Perl und reines Python liegen 5 % auseinander** (40.4 vs. 38.4 ms/Tick).
  Der Interpreter-Dispatch dominiert so vollständig, dass der Sprachunterschied
  fast verschwindet.
- **TypeScript mit Faktor 3.5** ist zwei Größenordnungen näher an C als an den
  anderen Skriptsprachen — und dabei in Konformitätsstufe A, weil `Math.fround`
  um jede Operation beweisbar dasselbe liefert wie f32-Arithmetik
  (`53 ≥ 2·24+2`).
- **numpy liegt bei 5.7×**, nicht bei 3.1× wie in der alten Reihe. Der
  Unterschied ist der Refactor auf bereichsweise Pässe für Klasse P: die
  Diffusion sammelt ihre Zeilen jetzt per Indexarray statt per `np.roll` über
  das ganze Grid, was bei 256² relativ mehr kostet als bei 1024².
- **RSS ist fast überall 18 MiB**, weil das Grid ihn dominiert. Auffällig sind
  nur die Laufzeitumgebungen: Node mit 81 MiB, numpy mit 39.

### Was Bit-Exaktheit in den Skriptsprachen kostet

| Sprache | Stufe B | Stufe A | Aufschlag |
|---|---:|---:|---:|
| Python (pur) | 38.45 | 88.21 | 2.3× |
| Perl | 40.44 | 128.71 | 3.2× |

Deutlich billiger als erwartet, und das ist selbst der Befund: in einer Sprache,
die pro Operation ohnehin einen Interpreter-Dispatch zahlt, verschwinden neun
zusätzliche C-Level-Aufrufe pro Zelle weitgehend im vorhandenen Overhead.

Perl zahlt mehr als Python, weil ein Perl-Array volle Doubles speichert und
damit *jede* Operation gerundet werden muss, während Pythons `array('f')` beim
Store ohnehin auf f32 rundet.

---

## 3. Compiler

1024×1024, 262 144 Agenten, 300 Ticks, bester von drei Läufen.

![Compiler-Matrix](charts/compilers.svg)

| Sprache | Compiler | Profil | Konf. | ms | rel. | Binär KiB |
|---|---|---:|:-:|---:|---:|---:|
| C | clang | o3-native-lto | A | **1234** | 1.00× | 54 |
| C | clang | o3-native | A | 1272 | 1.03× | 54 |
| C | gcc | o2 | A | 1290 | 1.05× | 50 |
| C++ | g++ | o3 | A | 1293 | 1.05× | 70 |
| C | gcc | o3 | A | 1319 | 1.07× | 58 |
| C++ | g++ | o3-native | A | 1348 | 1.09× | 74 |
| C++ | clang++ | o3-native | A | 1361 | 1.10× | 63 |
| C++ | g++ | ofast-native | **C** | 1370 | 1.11× | 74 |
| C | gcc | o3-native | A | 1432 | 1.16× | 62 |
| C | gcc | ofast-native | **C** | 1478 | 1.20× | 62 |
| Haskell | ghc | o2-llvm | A | 1507 | 1.22× | 2860 |
| C | clang | o2 | A | 1547 | 1.25× | 50 |
| Rust | cargo | release-native-lto-unchecked | A | 1703 | 1.38× | 441 |
| Rust | cargo | release-native-unchecked | A | 1774 | 1.44× | 474 |
| C | clang | ofast-native | **C** | 1870 | **1.52×** | 54 |
| Rust | cargo | release-native | A | 1966 | 1.59× | 476 |
| Haskell | ghc | o2 | A | 1971 | 1.60× | 2832 |
| C++ | clang++ | ofast-native | **C** | 2064 | **1.67×** | 63 |
| Haskell | ghc | o1 | A | 3747 | 3.04× | 2779 |
| C | clang | o0 | A | 4185 | 3.39× | 54 |
| C++ | g++ | o0 | A | 5693 | 4.61× | 166 |

**Alle Stufe-A-Läufe stimmen überein.** Die vier fast-math-Builds weichen ab,
und zwar *pro Compiler unterschiedlich* — genau deshalb ist fast-math eine
eigene Konformitätsstufe.

### `-Ofast` verliert immer, und bei clang katastrophal

| | `-O3 -march=native` | `-Ofast -march=native` | Aufschlag |
|---|---:|---:|---:|
| C, gcc | 1432 | 1478 | +3 % |
| C++, g++ | 1348 | 1370 | +2 % |
| C, clang | 1272 | 1870 | **+47 %** |
| C++, clang++ | 1361 | 2064 | **+52 %** |

Bei gcc kostet es ein paar Prozent, bei clang die Hälfte. Die
Reassoziationsfreiheit lässt clang den 9-Punkt-Stencil in etwas Schlechteres
umordnen. Man bezahlt Determinismus und bekommt nichts.

### clang gewinnt — aber nur mit `-march=native`

`-O2`: gcc 1290, clang 1547. `-O3 -march=native`: gcc 1432, clang 1272.
Wer nur `-O2` vergleicht, schließt „gcc ist 20 % schneller"; wer
`-march=native` dazunimmt, das Gegenteil. Derselbe Quelltext.

LTO bringt bei clang weitere 3 % (1272 → 1234) und **kostet** bei gcc 1 %
(1432 → 1453).

### Bounds-Checking in Rust

`release-native-unchecked` 1774 gegen `release-native` 1966 — die Checks kosten
hier **11 %**. Eine frühere Reihe hat das aufgeschlüsselt: 28–35 % im
Diffusionspass, nichts messbares im Agenten-Pass. Die Checks stehen der
Vektorisierung des Stencils im Weg; im Agenten-Pass wartet die CPU ohnehin auf
Cache-Misses. „Bounds-Checking kostet nichts" und das Gegenteil sind beide
falsch — es hängt am Zugriffsmuster, und dieser Benchmark hat zufällig beide
Sorten in einem Programm.

### GHC: das LLVM-Backend lohnt sich

`-O1` 3747, `-O2` 1971, `-O2 -fllvm` **1507**. Das LLVM-Backend bringt **24 %**
gegenüber dem nativen Codegenerator, für 1 % mehr Binärgröße. Alle drei
bit-exakt. GHC 9.10 warnt, dass LLVM 18 außerhalb des unterstützten Bereichs
liegt, und macht trotzdem korrekt weiter — geprüft gegen die
Konformitätsvektoren, nicht geglaubt.

---

## 4. Wie sehr der Programmierstil zählt (Haskell)

Ein Haskell-Programmierer, der den Port gelesen hat, hat ihn so beschrieben:
*„it looks just like if you took the C and tried to just line by line re-create
it in Haskell — this is not how you write Haskell code."* Das trifft zu.
`impl/haskell/src/Sim.hs` ist `IOUArray` in `IO` mit handgeschriebener
Endrekursion und expliziter Indexarithmetik, und so schreibt das niemand, der
nicht gerade eine C-Referenz Anweisung für Anweisung nachbaut.

Derselbe Programmierer nannte zwei Dinge, die sich hier gegenseitig
widersprechen: dass man in Haskell üblicherweise *hochlevel* schreibt und GHC
machen lässt — und dass man mit sorgfältigem Low-Level-Code *nahe an C*
herankommt. Beides ist messbar.

![Haskell-Stile](charts/haskell-style.svg)

`small`/300 `deferred`, alle bit-identisch:

| Variante | ms | vs. C |
|---|---:|---:|
| C-Referenz, clang `-O3 -march=native -flto` | 1234 | 1.00× |
| **Haskell low-level, `unsafeAt`** | **1507** | **1.22×** |
| Haskell low-level, `Data.Array.Unboxed.(!)` | 2561 | 2.08× |
| Haskell idiomatisch, `Data.Vector.Unboxed` | 5778 | 4.68× |

Drei Befunde:

**„Nahe an C" stimmt — und hing an vier Zeichen.** Die Trigonometrie-Tabelle
wurde mit `Data.Array.Unboxed.(!)` gelesen, viermal pro Agent. Das ist die
naheliegende Schreibweise, geht aber über die `Ix`-Klasse, rechnet den Offset
aus und prüft die Grenzen — und GHC eliminiert beides nicht, obwohl die Grenzen
Compile-Time-Konstanten sind. Ersetzt durch `unsafeAt` fällt der Agenten-Pass
von 1962 auf 1197 ms und die Gesamtzeit um **1.45×**.

**Hochlevel kostet hier 3.8× gegen den Low-Level-Port.** Die idiomatische
Fassung ist ehrlich idiomatisch: reine Funktionen über unveränderliche
`U.Vector`, kein `IO` im Kern, der Diffusionspass ist ein `U.generate`, der
Deposit-Scatter ein `U.accumulate`. Der Stencil ist als reine Abbildung genau
der Fall, in dem Fusion funktioniert. Der Agenten-Pass ist es nicht: jeder Tick
baut fünf neue Vektoren auf, wo die mutable Fassung in bestehende Puffer
schreibt.

**Der idiomatische Stil scheitert an derselben Stelle wie numpy.**
`--update serial` verlangt, dass ein Agent die Deposits seiner Vorgänger
*innerhalb desselben Ticks* sieht. Über unveränderliche Vektoren hieße das, das
Grid einmal pro Agent neu zu bauen. Die Implementierung lehnt den Modus mit
Exit-Code 3 ab — dieselbe Wand wie in
[`slimebench_numpy.py`](../impl/python/slimebench_numpy.py), aus demselben
Grund.

Und ein Fehler, den die getrennten Prüfsummen gefangen haben: die erste Fassung
akkumulierte die Deposits per `U.accumulate` direkt ins Grid. Zwei Deposits auf
dieselbe Zelle ergeben dann `(g + d₁) + d₂` statt der vorgeschriebenen
`g + (d₁ + d₂)` — 1 ULP, sobald `g` groß genug ist. Der *Grid*-Hash wich ab,
der *Agenten*-Hash nicht, und damit war der Fehler ohne Suche lokalisiert.
Genau dafür trennt [SPEC §6.3](../spec/SPEC.md) die beiden.

> Was das *nicht* zeigt: dass idiomatisches Haskell langsam ist. Es zeigt, dass
> es auf **dieser** Last langsam ist — ein mutables Gitter, das eine Million
> Mal pro Tick punktuell verändert wird. Das ist der ungünstigste denkbare Fall
> für persistente Datenstrukturen, und die Spec schreibt ihn vor.

---

## 5. Parallelität (Klasse P)

Nur im `deferred`-Modus — `serial` lässt Agenten die Deposits ihrer Vorgänger
im selben Tick sehen und ist damit prinzipiell nicht deterministisch
parallelisierbar.

![Skalierung über Sprachen](charts/scaling-langs.svg)

`medium` (2048², 1 048 576 Agenten), 100 Ticks. Perl steht bei `tiny`, weil
`medium` dort Stunden dauern würde.

### `binned` — bit-identisch zum seriellen Lauf

| Sprache | T=1 | T=2 | T=4 | T=8 | T=16 | T=32 | Speedup |
|---|---:|---:|---:|---:|---:|---:|---:|
| C | 5609 | 2627 | 1339 | 1048 | 752 | **707** | 7.9× |
| C++ | 5972 | 2683 | 1440 | 1057 | 738 | **698** | 8.6× |
| Haskell | 6806 | 2737 | 1501 | 948 | **808** | 844 | 8.4× |
| Rust | 7796 | 3301 | 1928 | 1238 | **990** | 1264 | 7.9× |
| TypeScript | 15642 | 5033 | 2567 | 1748 | **1357** | 1607 | **11.5×** |
| Python | 9298 | 6789 | 3568 | 2496 | **2257** | 2660 | 4.1× |
| Perl ¹ | 4866 | 2764 | 1950 | **1753** | 2077 | 3527 | 2.8× |

¹ `tiny`, replizierte Reduktion — siehe unten.

### `private` — nur je Thread-Zahl reproduzierbar

| Sprache | T=2 | T=4 | T=8 | T=16 | T=32 |
|---|---:|---:|---:|---:|---:|
| C | 2879 | 1806 | **1519** | 2909 | 7759 |
| C++ | 3031 | 1886 | **1529** | 2833 | 7657 |
| Haskell | 2411 | 1477 | **1450** | 2982 | 8272 |
| Rust | 3507 | 2019 | **1735** | 2931 | 7464 |
| TypeScript | 8180 | 4131 | **2812** | 3254 | 7541 |
| Python | 5932 | 3286 | **2542** | 3354 | 3934 |

**`private` fällt bei 32 Threads unter die serielle Laufzeit** — in C auf
7759 ms gegen 5609. Die Reduktion liest `T` vollständige Grids: bei `medium`
und 32 Threads sind das 512 MiB Speicherverkehr pro Tick, nur um Deposits
zusammenzuzählen. `binned` braucht dafür 8 MiB, unabhängig von der Thread-Zahl.
Die Strategie, die man naiv zuerst schreibt, ist also nicht nur die schwächere
Garantie, sondern ab acht Threads auch die langsamere.

### Determinismus

| `deposit` | Strategie | T=1 | T=4 | T=32 |
|---|---|---|---|---|
| 10.0 (Default) | `binned` | `0xC5C53969` | ✓ | ✓ |
| 10.0 | `private` | `0xC5C53969` | ✓ | ✓ |
| **0.1** | `binned` | `0x95EEB32D` | ✓ | ✓ |
| **0.1** | `private` | `0x95EEB32D` | `0xE82B2012` ✗ | ✗ |

`binned` ist bit-identisch zu T=1 für **jede** Thread-Zahl, geprüft für
T ∈ {2,3,4,7,8,16,32}, also auch für Zahlen, die kein Teiler der Höhe sind.

`private` stimmt mit den Default-Parametern *zufällig* auch: bei
`deposit = 10.0` bleibt jede Teilsumme `k · 10` unter 2²⁴ und ist in f32 exakt.
Mit `--deposit 0.1` bricht das sofort — und **fünf Sprachen liefern bei T=4
denselben falschen Hash `0xE82B2012`**. Dieselbe Klammerung, derselbe Fehler.
Das ist ein besserer Beleg dafür, dass die Ports dieselbe Rechnung machen, als
es die richtigen Ergebnisse allein wären.

### Was die einzelnen Sprachen kostet

**TypeScript skaliert am besten, obwohl es in Klasse S 3.5× zurückliegt.** Der
Abstand zu C schrumpft von 3.5× auf 1.9×. Und `binned` ist dort bei *zwei*
Threads schon 3.1× schneller als ein Thread — das ist nicht die Parallelität,
sondern die Lokalität: bei gleicher Thread-Zahl schlägt `binned` die
`private`-Strategie um 1.63×, in C nur um 1.10×. Die Zielzellen sequenziell in
`aidx` zu schreiben und sie danach zeilenblockweise anzuwenden ersetzt ein
gestreutes Read-Modify-Write über 16 MiB durch einen sequenziellen Write plus
einen sortierten. In V8 ist das viel mehr wert als in C.

**Haskells Barriere ist `MVar`-basiert, nicht STM.** Die STM-Variante liest
sich schöner (`retry` blockiert, bis der Generationszähler sich ändert), aber
jeder Wartende validiert seine Transaktion bei jedem Aufwachen neu, und bei
sechs Barrieren pro Tick ist das ein Retry-Sturm.

**Python zahlt für den GIL mit Prozessen.** `threading` würde genau die
Schleifen serialisieren, um die es geht — numpy gibt den GIL in großen
ufunc-Aufrufen frei, aber der Agenten-Pass ist eine Kette von Dutzenden
kleiner, mit Python-Code dazwischen, und der hält das Lock. Also
`multiprocessing` über einen `shared_memory`-Block, jedes Array von Hand
platziert. Nebeneffekt: die Barriere ist ein OS-Objekt und kostet
Zehner-Mikrosekunden statt Hunderter-Nanosekunden — in C wäre das der
Flaschenhals, hier verschwindet es in einem Tick von 23 ms. Die langsamste
Implementierung kann sich die teuerste Barriere leisten.

**Perl hat Threads, und sie sind hier das falsche Werkzeug.** Gemessen, für
262 144 Elemente:

| Operation | einfaches Array | `threads::shared` | Faktor |
|---|---:|---:|---:|
| sequenzielles Read-Modify-Write | 4.5 ms | 78.2 ms | 17× |
| zufälliges Read-Modify-Write | 13.9 ms | 105.7 ms | **7.6×** |
| `pack`+`unpack` derselben Werte | 12.0 ms | – | – |

Der Diffusionsstencil liest neun Zellen pro Ausgabezelle. Ein geteiltes Grid
müsste also erst Faktor 7.6 aufholen, bevor der erste Thread etwas beiträgt.
Ein ganzer Block durch `pack`/`unpack` kostet dagegen etwa so viel wie *ein*
Durchlauf über ein normales Array. Also `fork` mit privaten Grids, und über die
Pipes läuft nur gepacktes Binär.

Das erzwingt eine dritte Reduktionsstrategie, die
[SPEC §5.6](../spec/SPEC.md) nicht kennt: **repliziert**. Jeder Prozess wendet
*jeden* Deposit an, in aufsteigendem Agentenindex — also exakt die serielle
Kette, bit-identisch für jede Prozesszahl, ohne den `binned`-Sort. Der Preis
ist, dass Deposit- und Merge-Pass N-mal statt einmal laufen, und genau das
deckelt den Speedup bei 2.8×: parallel ist nur der Agenten-Pass.

### Der Flaschenhals sind die Barrieren

`SLIMEBENCH_PHASE_STATS=1` trennt Arbeit und Barrierenwartezeit
(C, `medium`, T=16, Thread 0):

| Phase | Arbeit | Barriere | Summe |
|---|---:|---:|---:|
| agents | 2.755 | 1.085 | 3.839 |
| prefix | **0.000** | 0.265 | 0.265 |
| scatter | 0.074 | 0.269 | 0.343 |
| deposit | 0.425 | 0.335 | 0.761 |
| merge | 0.356 | 0.354 | 0.710 |
| diffuse | 0.424 | — | 0.424 |

**Barrieren sind 35 % der Laufzeit bei T=16 und 53 % bei T=32.** Die
Präfixsumme, die vorher als „serielle O(T²)-Sektion" im Verdacht stand, leistet
0,000 ms messbare Arbeit.

Codeumfang für dieselbe Garantie: **C 326 Zeilen, C++ 264** — der Unterschied
steckt fast vollständig im Lebenszyklus (`std::jthread` joint beim Zerstören,
`std::barrier` braucht kein `init`/`destroy`).

---

## 6. SIMD (Klasse V)

Explizite Intrinsics für den Diffusionspass, `--simd`, `small`/300. Der
Agenten-Pass bleibt skalar: mehrere Agenten pro Vektor deponieren routinemäßig
in dieselbe Zelle, was Konfliktauflösung bräuchte — und das wäre dann echt
Stufe C.

| Sprache | Compiler | ISA | gesamt | Diffusion | Diffusion skalar | Faktor |
|---|---|---|---:|---:|---:|---:|
| C | clang | AVX-512 | **1012** | 79.6 | 314.4 | **3.95×** |
| C++ | g++ | AVX2 | 1071 | 81.7 | 306.0 | 3.75× |
| C | gcc | AVX2 | 1118 | 88.2 | 307.9 | 3.49× |
| C++ | g++ | AVX-512 | 1111 | 76.8 | 306.0 | **3.98×** |
| C | clang | AVX2 | 1149 | 81.1 | 314.4 | 3.88× |
| C++ | clang++ | AVX-512 | 1145 | 80.3 | 301.6 | 3.76× |
| Rust | cargo | AVX-512 (safe) | 1512 | 84.0 | 431.2 | **5.13×** |
| Rust | cargo | AVX-512 (unchecked) | 1523 | 90.3 | 301.4 | 3.34× |

### Es ist Stufe A

Der Kernel hat **keine Cross-Lane-Reduktion**: jede Lane rechnet eine
Ausgabezelle mit exakt derselben Operationsfolge wie die skalare Schleife.
Bit-identisch unter gcc und clang, in beiden Update-Modi, auch mit
`--threads 16 --deposit-reduce binned`.

Zwei Bedingungen: kein FMA (`4.0f*c + acc` als eine gerundete Operation wäre
eine andere Zahl) und eine echte `_mm*_div_ps`.

### Der Stencil wird 4×, das Programm 1.2×

Die Diffusion fällt von ~305 auf ~80 ms, aber sie ist nur ein Viertel der
Laufzeit — der Agenten-Pass bleibt skalar und dominiert. Amdahl, in einer Zeile.

**Verdoppelte Vektorbreite kauft fast nichts.** AVX2 gegen AVX-512 bei gcc:
88.2 gegen 77.5 ms, also 12 %; bei clang 81.1 gegen 79.6, also 2 %. Der
3×3-Stencil liest 36 Byte, um 4 Byte zu schreiben — er ist bandbreitengebunden,
die Ausführungseinheiten warten auf Speicher.

**Rusts „safe" gewinnt hier den größten Faktor, und das ist ein Artefakt.**
5.13× klingt beeindruckend, ist aber nur groß, weil der *skalare* Vergleichswert
schlecht ist: mit Bounds-Checks kostet der skalare Stencil 431 ms statt 301.
Der SIMD-Kernel geht in beiden Fällen über rohe Zeiger und landet bei 84–90 ms.
Wer Faktoren gegen die eigene Baseline meldet, misst manchmal die Baseline.

**Neben dem `-Ofast`-Befund aus §3 gelesen:** clang macht dieselbe Schleife mit
fast-math 1.5× langsamer und mit handgeschriebenen Intrinsics 4× schneller.
Zwischen der besten und der schlechtesten Vektorisierungsstrategie für eine
Schleife liegt Faktor 6.

### SIMD und Threads sind Substitute

Beide greifen dieselbe Ressource an. Sobald acht Kerne am bandbreitengebundenen
Diffusionspass arbeiten, ist die Bandbreite ausgereizt: bei T=1 bringt SIMD
1.10×, bei T=8 exakt 1.00×, bei T=16 1.04×.

### Aufwand: Rust braucht mehr Zeremonie

C und C++ wählen die ISA mit `#ifdef __AVX512F__`, das `-march=native` setzt.
Rust hat `cfg!(target_feature = "avx512f")`, verlangt aber zusätzlich
`#[target_feature(enable = "avx512f")]` an der Funktion, die damit `unsafe`
aufzurufen ist. `std::simd` wäre portabler, ist aber weiterhin nightly-only.

---

## 7. GPU (Klasse G)

Drei Hosts: CUDA, ein GLSL-4.3-Compute-Shader aus C, und derselbe Shader aus
Python. Alle nur `deferred`, 100 Ticks.

| Host | tiny | small | medium | large | huge |
|---|---:|---:|---:|---:|---:|
| CUDA | 10 | 19 | **52** | 215 | 1214 |
| *MCUPS* | 2653 | 5658 | **8116** | 7811 | 5530 |
| GL 4.3, C-Host | 277 | 762 | 2839 | 11329 | 48057 |
| *MCUPS* | 95 | 138 | 148 | 148 | 140 |
| GL 4.3, Python-Host | 294 | 809 | 2928 | 11624 | 51142 |
| *MCUPS* | 89 | 130 | 143 | 144 | 131 |

### Klasse G misst nicht die Sprache — jetzt belegt

Der C-Host und der Python-Host fahren **denselben Shader**, und das ist
nachprüfbar statt behauptet: die GLSL liegt in
[`impl/glcompute/shaders/`](../impl/glcompute/shaders/), der C-Header wird
daraus generiert, und beide Hosts drucken einen FNV-32 ihrer kompilierten
Quelle — `0xB949F398` in beiden.

Die Zeiten liegen **3–6 % auseinander**, und jeder Grid-Hash stimmt überein —
**auch die vom Treiber abweichenden**. Der Python-Host reproduziert also die
ULP-Abweichung von Mesas D3D12-Pfad exakt, was ein stärkeres Ergebnis ist, als
wenn beide nur das richtige Ergebnis geliefert hätten.

Alles oberhalb des Shaders ist unabhängig implementiert: der Python-Host macht
seine eigene SPEC-1-3.3-Initialisierung in numpy, baut seine eigenen Puffer und
schreibt seine eigenen Uniforms. Rund 200 Zeilen gegen die 480 des C-Hosts.

### `medium` sättigt, alles darüber fällt ab

CUDAs Durchsatz steigt bis `medium` auf 8116 MCUPS und fällt danach — bei
`huge` (8192², 67 Mio. Zellen) ist er wieder auf dem Stand von `small`. Der
Speedup gegenüber einem C-Thread ist bei `large` am höchsten:

| Preset | CUDA | C, 1 Thread | Faktor |
|---|---:|---:|---:|
| small | 19 | 682 | 36× |
| medium | 52 | 5609 | 108× |
| large | 215 | 28584 | **133×** |

### CUDA ist bit-exakt

Geprüft gegen die C-Referenz bei allen fünf Presets, Grid- **und**
Agenten-Hash: identisch. Nötig dafür:

1. **`-fmad=false`** — sonst fusioniert nvcc `4.0f*c + acc`.
2. **`--prec-div=true`** (Default) — korrekt gerundete Division.
3. **Ganzzahlige Deposit-Atomics.** `atomicAdd(float*)` ist nicht
   deterministisch; die Reihenfolge der ankommenden Threads bestimmt die
   Rundung. Stattdessen zählt `atomicAdd(unsigned*)` die Treffer pro Zelle —
   ganzzahlige Addition ist exakt und reihenfolgeunabhängig — und die
   Multiplikation mit `deposit` passiert einmal danach.

Punkt 3 bringt dieselbe Einschränkung mit wie `private`: mit `--deposit 0.1`
weicht auch CUDA ab. Geprüft, nicht angenommen.

### GLSL: exakt auf einem Treiber, nicht auf dem anderen

Auf Mesas `llvmpipe` ist der GL-Pfad bit-exakt gegen C. Auf D3D12/NVIDIA weicht
er um **maximal 2 ULP** ab: `precise` verbietet in GLSL Umordnen und Fusion,
erzwingt aber keine korrekt gerundete Division — genau das, was CUDA über
`--prec-div=true` bekommt. Klasse G ist deshalb pro Backend einzustufen.

Auf dem Weg dahin: zuerst wich auch der *Agenten*-Hash ab, weil `precise` nur
auf dem Diffusions-Akkumulator stand. `x + cos*step` im Agenten-Pass wird
ebenfalls fusioniert, versetzt den Agenten um ein ULP und kippt irgendwann
einen Sensorvergleich. Dass ausgerechnet der Agenten-Hash brach, hat den Fehler
lokalisiert.

> Die GL-Zahlen messen nicht OpenGL, sondern die Mesa-D3D12-Übersetzung: drei
> Dispatches, drei `GL_ALL_BARRIER_BITS` und ein `glFinish` pro Tick, alles
> über GL → DXIL → D3D12. Der Durchsatz bleibt über vier Größenordnungen bei
> ~145 MCUPS konstant, was heißt, dass die Übersetzungsschicht und nicht die
> GPU der Flaschenhals ist. Auf einem nativen Linux-GL-Treiber wäre der Abstand
> zu CUDA mit ziemlicher Sicherheit deutlich kleiner.

### Warum numpy `serial` nicht kann

`serial` verlangt, dass Agent *i* den Deposit von Agent *i−1* aus demselben
Tick sieht — eine sequenzielle Abhängigkeit durch das Grid. Kein
numpy-Ausdruck bildet sie ab. Die Implementierung lehnt den Modus mit
Exit-Code 3 und Begründung ab, statt still etwas anderes zu rechnen.

In `deferred` gibt es die Abhängigkeit nicht, und `np.add.at` akkumuliert
ungepuffert in Indexreihenfolge — exakt die vorgeschriebene.

---

## 8. Rendering (Klasse R)

1024², `--freeze-sim` (Simulation angehalten, damit nur der Upload-Pfad
Grid → Textur → Bildschirm gemessen wird). Millisekunden pro Frame, Median.

![Rendering](charts/render.svg)

| Sprache | Bindung | SDL2 llvmpipe | SDL2 RTX 5080 | raylib llvmpipe | raylib RTX 5080 |
|---|---|---:|---:|---:|---:|
| C | direkt | 3.356 | 5.744 | 2.497 | 2.647 |
| C++ | direkt | 3.384 | 5.730 | 2.496 | 2.744 |
| Haskell | `sdl2` / `foreign import` | 3.323 | 5.610 | 2.572 | 2.676 |
| Rust | `sdl2` / `raylib` crate | **3.264** | **5.591** | 2.547 | **2.626** |
| Python | pygame / cffi | 6.594 | 5.771 | 5.455 | 5.247 |
| Perl | FFI::Platypus | 126.3 | 124.5 | 84.5 | 82.7 |

**raylib gewinnt überall, und auf der echten GPU deutlicher:** 1.3× auf
Software, **2.1×** auf der RTX 5080, in jeder kompilierten Sprache. Die Ursache
ist das Pixelformat, nicht die Bibliothek — raylib nimmt den
8-Bit-Graustufenpuffer direkt entgegen (`UNCOMPRESSED_GRAYSCALE`), SDL2 braucht
ARGB8888 und damit eine Expansionsschleife über eine Million Pixel pro Frame.

**Die vier kompilierten Sprachen liegen auf raylib innerhalb von 4 %**
(2.626–2.744 ms). Wenn das Backend und das Pixelformat feststehen, ist die
Sprache in dieser Klasse fast egal — was der interessanteste Befund der Tabelle
ist, weil er dem Klasse-S-Bild widerspricht.

**SDL2 ist auf der echten GPU langsamer als auf dem Software-Rasterizer**, in
allen vier kompilierten Sprachen (3.3 → 5.7 ms), während raylib auf beiden
gleich schnell bleibt. Beide Pfade sind bei 1024² CPU-gebunden; SDL2 zahlt auf
D3D12 zusätzlich für den `SDL_LockTexture`-Pfad durch die Übersetzungsschicht.
Für eine GPU-limitierte Messung bräuchte es ein deutlich größeres Grid.

**Python liegt 2× zurück, und der Backend-Unterschied verschwindet fast.** Der
Frame wird von der numpy-Konvertierung dominiert, nicht vom Upload.

**Perl liegt 30–50× zurück, zeigt den Backend-Unterschied aber am
deutlichsten** (126 gegen 85 ms). Hier hatte ich das Gegenteil erwartet: wenn
die Konvertierung den Frame dominiert, sollten beide Backends gleich
herauskommen, wie bei Python. Sie tun es nicht, weil die Konvertierung *selbst*
der Unterschied ist — raylib will ein Byte pro Pixel (`pack 'C*'`), SDL2 ein
geschobenes und verodertes 32-Bit-Wort (`pack 'L*'`), und in Perl kostet diese
Arithmetik mehr als alles andere im Frame zusammen.

### Zwei Bindungen, die nicht das Naheliegende sind

Für **Haskell/raylib** und **Perl/raylib** steht nicht das jeweilige
Ökosystem-Paket im Baum (`h-raylib`, `Raylib::FFI`), sondern
`foreign import ccall` bzw. `FFI::Platypus` gegen dasselbe
`/usr/local/lib/libraylib.so`, das C, C++, Rust und Python linken. Grund: beide
Pakete vendorn raylib und bauen eine eigene Kopie. Damit verglichen man eine
Sprache gegen einen *anderen Build* der Bibliothek, und Klasse R soll die
Sprache vergleichen.

Beide stoßen dabei auf dieselbe Grenze: raylib übergibt `Image`, `Texture2D`
und `Color` **by value**, was weder Haskells FFI noch Platypus kann. Die fünf
betroffenen Aufrufe gehen deshalb durch
[`impl/shim/raylib_shim.c`](../impl/shim/raylib_shim.c) — 30 Zeilen C, von
beiden geteilt. Dass zwei so verschiedene Sprachen an derselben Stelle denselben
Workaround brauchen, ist selbst ein Datenpunkt über C-ABIs.

---

## 9. Footprint

| Sprache | Binär KiB (gestrippt) | RSS MiB |
|---|---:|---:|
| C (gcc / clang) | **50** | 18 |
| C++ (clang++) | 59 | 18 |
| C++ (g++) | 62 | 18 |
| Rust (unchecked) | 441 | 18 |
| Rust (safe) | 470 | 18 |
| Haskell | 2779 | 29 |
| TypeScript / Python / Perl | – (interpretiert) | 18–81 |

Rust liegt beim Neunfachen von C, Haskell beim Sechsundfünfzigfachen — beides
Laufzeitsystem, nicht generierter Code. Fat LTO holt bei Rust 7 % Binärgröße
zurück und bringt hier zusätzlich 4 % Laufzeit (1774 → 1703 ms).

Der RSS ist über alle kompilierten Sprachen identisch, weil das Grid ihn
dominiert (2 × 4 MiB Puffer plus Agentendaten). Nur die Laufzeitumgebungen
fallen auf, Node am deutlichsten mit 81 MiB.

**Klasse P kostet Speicher, je nach Strategie sehr unterschiedlich:** `private`
braucht `T × W × H × 4` Byte — 512 MiB bei `medium` und 32 Threads — `binned`
dagegen `N × 4` Byte plus ein Zeilen-Histogramm, also 8 MiB unabhängig von der
Thread-Zahl.

---

## 10. Was nicht funktioniert hat

Vier Optimierungsversuche, ein brauchbares Ergebnis. Sie stehen hier, weil sie
dieselbe Arbeit gekostet haben wie die erfolgreichen.

### PGO: nichts bei gcc, −6 % bei clang

Die Vier-Wege-Verzweigung auf die drei Sensorwerte ist datenabhängig und nahezu
gleichverteilt. PGO kann nur *vorhersagbare* Verzweigungen verbessern und lernt
hier nichts, was der Hardware-Prädiktor nicht schon hat. Infrastruktur bleibt
im Baum (`impl/c/pgo.sh`).

### Parallele Präfixsumme: −18 % dort, wo es zählt

Jeder Thread kann seine `offsets`-Zeile allein aus `counts` ableiten — das
entfernt die serielle Sektion **und** eine von fünf Barrieren. Neun Läufe:
+9 % bei T=8, **−18 % bei T=16**, ±0 bei T=32. Die Verteilungen überlappen
nicht.

`counts` wurde gerade zeilenweise von allen T Threads *geschrieben*; lässt man
danach alle die ganze Matrix lesen, werden aus T² Additionen T²
Cache-Line-Transfers aus fremden Kernen. Bei T=16 (zwei CCDs, kein SMT) kostet
das mehr als die eingesparte Barriere. Verworfen.

### Lastausgleich für `binned`: +5,9 %, nicht mehr

Zeilenblöcke nach Agentenzahl statt nach Zeilenzahl aufteilen. Korrekt (der
Hash bleibt identisch, weil die Partition nur bestimmt, *welcher* Thread
deponiert), aber der Deposit-Pass ist nur 15 % der Laufzeit. Bleibt drin, weil
billig; abschaltbar mit `SLIMEBENCH_NO_REBALANCE=1`.

### Spin-Barriere: +7 % bei 16 Threads, −55 % bei 32

16 physische Kerne, 32 logische. Bei T=16 sitzt ein Thread pro Kern und Spinnen
kostet niemanden etwas. Bei T=32 nimmt jeder Spinner seinem SMT-Geschwister die
Ausführungsressourcen weg — die Barrierenzeit steigt von 2,45 auf 10,2 ms pro
Tick.

`hybrid` (spinnen, dann auf einem Futex parken) ist nie schlechter als
`pthread`. Default bleibt `pthread`; die Wahl ist ein Umgebungsschalter
(`SLIMEBENCH_BARRIER`).

Bemerkenswert, wie klein der Gewinn ist, obwohl Barrieren die halbe Laufzeit
ausmachen: **die Zeit steckt im Warten, nicht im Aufwecken.** Eine billigere
Barriere macht eine unausgeglichene Phase nicht kürzer.

---

## 11. Wo ich mich geirrt habe

Die Spec und der Buildplan sind mehrfach von Messungen widerlegt worden. Das
gehört dokumentiert, sonst liest sich das Projekt fehlerfreier als es war.

| Behauptung | Realität |
|---|---|
| Stufe-B-Toleranzen: einheitlich 1e-4 | Strukturell falsch. Erhaltungsgrößen bleiben bei 1e-9 (Toleranz jetzt **enger**, 1e-6), strukturempfindliche divergieren unter Chaos (2e-2). |
| Bit-Exaktheit kostet in Skriptsprachen zwei Größenordnungen | Gemessen 2,3× (Python) und 3,2× (Perl). |
| Thread-lokale Puffer + feste Reduktionsreihenfolge sind deterministisch | Nur *je Thread-Zahl*. Führte zu SPEC §5.6. |
| SIMD ⇒ Konformitätsstufe C | Stufe A. Keine Cross-Lane-Reduktion im Stencil. |
| GPU ⇒ Konformitätsstufe C | CUDA ist Stufe A. Bei GLSL hängt es am Treiber. |
| PGO ist der plausibelste verbleibende Gewinn | Bringt nichts, schadet clang. |
| `prefix` ist eine serielle O(T²)-Bremse | 0,000 ms Arbeit. Artefakt meiner Instrumentierung. |
| wgpu/WGSL als portabler GPU-Weg | Unter WSL2 nicht gangbar: die NVIDIA-Vulkan-ICDs zeigen auf Windows-DLLs. |
| Die Klasse-R-Zahlen sind GPU-Zahlen | Waren Software-Rendering (§8). |
| Idiomatisches Haskell kostet wenig | 3,8× gegen den Low-Level-Port (§4). |
| Der Haskell-Port ist so schnell, wie er sein kann | Vier Zeichen (`(!)` → `unsafeAt`) waren Faktor 1.45 (§4). |
| Perls Threads sind der Weg zu Klasse P | `threads::shared` kostet 7,6× pro Zugriff; `fork` mit gepackten Pipes gewinnt (§5). |
| In Perl kostet die Konvertierung so viel, dass beide Render-Backends gleich herauskommen | Die Konvertierung *ist* der Unterschied: raylib 1,5× schneller (§8). |
| Klasse R vergleicht Sprachen | Auf raylib liegen vier kompilierte Sprachen innerhalb von 4 % (§8). |
| `medium` lastet die GPU nicht aus | Doch — `medium` ist der Durchsatz-Peak, alles darüber fällt ab (§7). |
| **Die GL-Zahl für `medium` war 1298 ms** | **Der Diffusionspass lief gar nicht.** `glDispatchCompute` ist auf 65 535 Workgroups pro Dimension begrenzt, `medium` braucht 65 536. Der Treiber meldet das nicht. Korrekt sind 2839 ms, womit GL über D3D12 *langsamer* ist als C auf 16 Threads statt schneller. |

Ein Muster: **jede Vermutung über Performance, die ich nicht gemessen habe,
war falsch.** Die Vermutungen über *Korrektheit* — Operationsreihenfolge,
Trig-Tabelle, PRNG-Wahl — haben dagegen alle gehalten.

Und ein zweites: die beiden schlimmsten Fehler in dieser Liste — das
übersprungene Dispatch und das Software-Rendering — hatten gemeinsam, dass sie
eine *plausible Zahl* produzierten. Beide sind nur aufgefallen, weil eine
Skalierung nicht stimmte, nicht weil etwas kaputt aussah.

---

## 12. Offene Punkte

- **Ein nativer Linux-GL-Treiber.** Die GL-Zahlen messen Mesas
  D3D12-Übersetzung mit; der konstante Durchsatz von ~145 MCUPS über vier
  Größenordnungen sagt, dass sie und nicht die GPU der Flaschenhals ist.
- **Klasse R bei einer Grid-Größe, die die GPU auslastet.** Bei 1024² sind
  beide Pfade CPU-gebunden, und der Vergleich misst die Formatkonvertierung.
- **Klasse P für reines Python.** Mit `multiprocessing` würde es fast linear
  skalieren — aber bei `medium` wären das Stunden pro Datenpunkt. Ein
  freithreadiges CPython (3.13t) wäre der interessantere Vergleich und ist auf
  dieser Maschine nicht installiert.
- **`perf`** ist unter dem WSL2-Kernel nicht verfügbar (kein passendes
  `linux-tools`-Paket). Die Phasen-Timer und `hyperfine` ersetzen es
  teilweise, aber Cache-Miss-Zahlen fehlen.
- **Alles hier ist WSL2**, nicht natives Linux, auf einer Maschine, auf der
  nebenher Windows arbeitet. Innerhalb dieser einen Messreihe ist das
  unkritisch; bei Absolutwerten ist es zu bedenken.
