# slimebench — Normative Simulation Spec

**Version:** `SPEC-1`
**Status:** normativ. Jede Implementierung in `impl/` MUSS diesem Dokument entsprechen.

Dieses Dokument definiert das Physarum-Modell so präzise, dass **unabhängige
Implementierungen in verschiedenen Sprachen bit-identische Ergebnisse liefern**.
Wo eine Formulierung mehrdeutig wäre, ist die Mehrdeutigkeit hier bewusst aufgelöst
— auch dort, wo eine andere Auflösung "natürlicher" gewesen wäre.

Schlüsselwörter MUSS / SOLLTE / DARF nach RFC 2119.

---

## 0. Warum so pedantisch?

Physarum ist ein **chaotisches** System: Agenten folgen Gradienten, die sie selbst
erzeugen. Eine Abweichung von 1 ULP in der Sensorauswertung eines einzigen Agenten
in Tick 3 führt dazu, dass dieser Agent irgendwann anders abbiegt, dadurch woanders
deponiert, dadurch Nachbaragenten beeinflusst — nach ~50–200 Ticks sind zwei Läufe
makroskopisch verschieden.

Konsequenz: **"Sieht ähnlich aus" ist kein Korrektheitskriterium.** Ohne bit-exakte
Verifikation kannst du bei acht Ports nicht unterscheiden zwischen
"andere Sprache, gleiche Simulation" und "andere Sprache, subtil kaputter Port" —
und dann misst dein Benchmark Äpfel gegen Birnen.

Deshalb: exakt spezifizierte Operationsreihenfolge, exakt spezifizierter PRNG,
und Trigonometrie aus einer Tabelle statt aus `libm` (siehe §4).

---

## 1. Numerisches Modell

### 1.1 Datentyp

Das Pheromon-Grid und alle Agenten-Koordinaten sind **IEEE-754 binary32 (`f32`)**.

**Begründung** (die Alternative `f64` wurde verworfen):

| Kriterium | f32 | f64 |
|---|---|---|
| Speicherbandbreite Grid | 1× | 2× — und der Diffusionspass ist bandbreitenlimitiert |
| GPU (Consumer-NVIDIA) | volle Rate | 1/32 Rate → GPU-Tier wäre sinnlos |
| SIMD-Lanes pro Register | 8 (AVX2) / 16 (AVX-512) | 4 / 8 — halbe Vektorbreite |
| Browser | `Float32Array` nativ | `Float64Array`, aber Canvas will eh f32-Präzision |

Da GPU-Compute und SIMD explizit im Projektumfang sind, ist f32 die einzige
konsistente Wahl. Der Preis: Perl und reines Python können f32-Arithmetik nicht
nativ ausdrücken (beide rechnen intern in Doubles) und fallen deshalb in
Konformitätsstufe B (§7).

### 1.2 Arithmetik-Regeln

1. Jede Einzeloperation MUSS in `f32` ausgeführt und das Ergebnis nach `f32`
   gerundet werden (Rundungsmodus: round-to-nearest-even).
2. **Keine FMA-Kontraktion.** `a*b + c` MUSS als zwei gerundete Operationen
   ausgeführt werden. In C/C++: `#pragma STDC FP_CONTRACT OFF` bzw. `-ffp-contract=off`.
3. **Keine Reassoziation.** Die in §5 angegebene Klammerung ist verbindlich.
4. **Keine Reziprok-Substitution.** `x / 12.0f` MUSS eine Division sein, nicht
   `x * (1.0f/12.0f)` — die beiden Ergebnisse unterscheiden sich.
5. Keine erweiterte Zwischenpräzision. In C MUSS `FLT_EVAL_METHOD == 0` gelten
   (auf x86-64 mit SSE der Fall; x87 ist ausgeschlossen).

> **Hinweis zu `-ffast-math` / `-Ofast`:** Diese Flags verletzen Regel 2–4
> absichtlich. Builds damit sind **nicht** Stufe-A-konform und werden vom Harness
> in eine eigene Klasse einsortiert (§7.3). Das ist kein Fehler, sondern genau
> einer der Messwerte, um die es geht: *Was kostet Determinismus?*

### 1.3 Was NICHT gilt

- Kein Clamping, keine Sättigung. Pheromonwerte dürfen frei wachsen.
  (Der Steady-State liegt bei `deposit / (1 - decay)` ≈ 167 pro dauerhaft
  besuchter Zelle; Überlauf nach `inf` ist bei f32 praktisch ausgeschlossen.)
- Keine `NaN`-Behandlung. Bei korrekter Implementierung entstehen keine.

---

## 2. Grid

- Breite `W` und Höhe `H` MÜSSEN Zweierpotenzen sein.
  Das macht jedes Wrapping zu einer Bitmaske und ist Voraussetzung für die
  SIMD- und GPU-Varianten.
- Speicherlayout: **row-major**, dicht, Index `idx = (y << log2(W)) | x`.
- Randbehandlung: **toroidal** (Wrap in beide Achsen).

### 2.1 Index-Wrapping (ganzzahlig)

```
wrap_x(i) = i & (W - 1)
wrap_y(j) = j & (H - 1)
```

### 2.2 Koordinaten-Wrapping (Gleitkomma)

Positionen werden in `[0, W)` bzw. `[0, H)` gehalten:

```
wrapf(v, m):
    if v <  0.0f:  v = v + m
    if v >= m:     v = v - m
    return v
```

Ein einzelner Korrekturschritt genügt, weil kein Offset pro Tick betragsmäßig
größer als `sensor_distance` (9.0) ist und `m >= 512`.

> **Fallstrick:** `wrapf` kann durch Rundung exakt `m` zurückgeben (z.B.
> `-1e-7 + 1024.0f == 1024.0f`). Der Cast nach Integer MUSS daher **immer**
> zusätzlich maskiert werden (§2.1). Verlass dich nie allein auf `wrapf`.

---

## 3. Pseudo-Zufallszahlen

### 3.1 Generatoren

**SplitMix32** — nur für Seeding und Grid-Initialisierung:

```
splitmix32(state):            # state: u32, by reference
    state = state + 0x9E3779B9        # mod 2^32
    z = state
    z = (z XOR (z >> 16)) * 0x21F0AAAD
    z = (z XOR (z >> 15)) * 0x735A2D97
    return z XOR (z >> 15)
```

**xoshiro128++** — pro Agent, für Entscheidungen im Hot Loop:

```
rotl(x, k) = (x << k) | (x >> (32 - k))

xoshiro128pp(s):              # s: u32[4], by reference
    result = rotl(s[0] + s[3], 7) + s[0]
    t = s[1] << 9
    s[2] = s[2] XOR s[0]
    s[3] = s[3] XOR s[1]
    s[1] = s[1] XOR s[2]
    s[0] = s[0] XOR s[3]
    s[2] = s[2] XOR t
    s[3] = rotl(s[3], 11)
    return result
```

Alle Operationen sind **vorzeichenlose 32-Bit-Arithmetik mit Wraparound**.

> **Warum 32 Bit und nicht PCG64?** Ein 64-Bit-PRNG bräuchte in JavaScript
> `BigInt` (um Größenordnungen langsamer) und in WGSL/GLSL eine
> Emulation über zwei 32-Bit-Wörter. xoshiro128++ ist in *jeder* Zielsprache
> ein direkter Einzeiler und in Qualität mehr als ausreichend.

### 3.2 Uniform in [0, 1)

```
rnd01(u):    # u: u32
    return f32(u >> 8) / 16777216.0f
```

`u >> 8 < 2^24` ist in `f32` exakt darstellbar, und die Division durch `2^24`
ist exakt. Das Ergebnis ist damit in allen Sprachen bitgleich.

### 3.3 Initialisierung

**Grid** (ein eigener Strom, unabhängig von der Agentenzahl):

```
sm = seed XOR 0x5BF03635
for i in 0 .. W*H-1:
    grid[i] = rnd01(splitmix32(sm)) * 100.0f
```

**Agenten** (pro Agent ein unabhängiger Strom — dadurch ist die Initialisierung
parallelisierbar und unabhängig von der Reihenfolge):

```
for i in 0 .. N-1:
    sm = seed + 0x9E3779B9 * (i + 1)          # mod 2^32
    s[0] = splitmix32(sm)
    s[1] = splitmix32(sm)
    s[2] = splitmix32(sm)
    s[3] = splitmix32(sm)
    if s[0]|s[1]|s[2]|s[3] == 0: s[0] = 1     # xoshiro darf nicht Null sein

    ax[i]  = rnd01(xoshiro128pp(s)) * f32(W)
    ay[i]  = rnd01(xoshiro128pp(s)) * f32(H)
    adir[i] = xoshiro128pp(s) % NDIR
```

Die Modulo-Verzerrung bei `% NDIR` ist bekannt und akzeptiert — sie ist
deterministisch und damit für die Vergleichbarkeit irrelevant.

---

## 4. Richtungen und Trigonometrie

### 4.1 Das Problem

`sin()` und `cos()` sind **nicht** bit-identisch zwischen Implementierungen.
glibc, musl, Apples libm, V8s fdlibm-Port, Rusts `f64::sin` und die GPU-Intrinsics
liefern für dasselbe Argument teils unterschiedliche letzte Bits. In einem
chaotischen System reicht das, um jede Cross-Language-Verifikation unmöglich zu
machen.

### 4.2 Die Lösung: quantisierte Richtungen

Die Agentenrichtung ist **kein `f32`-Winkel, sondern ein ganzzahliger Index**:

```
NDIR = 1440            # Auflösung: 0.25° pro Schritt
adir ∈ [0, NDIR)
```

`sin`/`cos` kommen aus einer generierten Tabelle mit `NDIR` Einträgen:

```
COS[d] = f32(cos(2*PI * d / NDIR))
SIN[d] = f32(sin(2*PI * d / NDIR))
```

Die Tabelle wird **einmalig** von `spec/tools/gen_dirtable.py` erzeugt und als
**u32-Bitmuster** in Quelltext für jede Sprache emittiert (`spec/data/` und
`impl/*/dirtable.*`). Damit ist sie per Konstruktion in allen Sprachen
byteidentisch — kein Laufzeit-`sin()` beteiligt.

Der Generator ist Teil des Repos und reproduzierbar; das Harness prüft die
Tabellen-Prüfsumme beim Start jeder Implementierung.

### 4.3 Abgeleitete Konstanten

| Größe | Bogenmaß | NDIR-Schritte |
|---|---|---|
| Sensorwinkel | 0.2·π = 36° | **144** |
| Rotationswinkel | 0.2·π = 36° | **144** |

`NDIR = 1440` ist so gewählt, dass 36° exakt 144 Schritten entspricht — keine
Rundung in der Parametrisierung.

**Nebeneffekt:** Der Tabellen-Lookup ist auch schneller als `sinf`/`cosf`
(11.5 KB Tabelle, passt in L1d). Die Quantisierung ist also kein reiner Preis.

Wer kontinuierliche Winkel will, kann `--trig=libm` setzen — das ist
ausdrücklich **Stufe B** und nicht cross-language verifizierbar.

---

## 5. Simulationsschritt

### 5.1 Parameter (Defaults)

| Name | CLI | Default | Typ |
|---|---|---|---|
| Sensordistanz | `--sensor-dist` | `9.0` | f32 |
| Sensorwinkel | `--sensor-steps` | `144` | int (NDIR-Schritte) |
| Rotationswinkel | `--rot-steps` | `144` | int (NDIR-Schritte) |
| Schrittweite | `--step` | `1.0` | f32 |
| Deposit | `--deposit` | `10.0` | f32 |
| Decay | `--decay` | `0.94` | f32 |
| Diffusionskernel | fix | `[[1,1,1],[1,4,1],[1,1,1]] / 12` | — |

### 5.2 Reihenfolge pro Tick

```
1. Agenten-Pass  (§5.3)
2. Diffusions-/Decay-Pass  (§5.4)
```

Diese Reihenfolge folgt der Referenz (programmingchaos): Deposits eines Ticks
werden **im selben Tick** diffundiert und gedämpft.

### 5.3 Agenten-Pass

Agenten werden in **Indexreihenfolge 0 → N−1** verarbeitet.

```
sense(x, y, d):
    sx = wrapf(x + COS[d] * sensor_dist, W)
    sy = wrapf(y + SIN[d] * sensor_dist, H)
    return grid[ ((int(sy) & (H-1)) << log2W) | (int(sx) & (W-1)) ]

for i in 0 .. N-1:
    d = adir[i];  x = ax[i];  y = ay[i]

    dl = (d - sensor_steps + NDIR) mod NDIR
    dr = (d + sensor_steps)        mod NDIR

    FL = sense(x, y, dl)
    FC = sense(x, y, d)
    FR = sense(x, y, dr)

    if   FC >= FL and FC >= FR:  pass                       # geradeaus
    elif FC <  FL and FC <  FR:                             # Sackgasse: Zufall
        if xoshiro128pp(rng[i]) & 1: d = (d + rot_steps)        mod NDIR
        else:                        d = (d - rot_steps + NDIR) mod NDIR
    elif FL >  FR:               d = (d - rot_steps + NDIR) mod NDIR
    else:                        d = (d + rot_steps)        mod NDIR

    x = wrapf(x + COS[d] * step, W)
    y = wrapf(y + SIN[d] * step, H)

    idx = ((int(y) & (H-1)) << log2W) | (int(x) & (W-1))
    DEPOSIT_TARGET[idx] = DEPOSIT_TARGET[idx] + deposit      # siehe §5.5

    adir[i] = d;  ax[i] = x;  ay[i] = y
```

Beachte: Die Reihenfolge ist **erst rotieren, dann in die neue Richtung
bewegen**. Der PRNG wird **nur** im Sackgassen-Zweig konsumiert — dadurch hängt
der Zustand jedes Agenten-PRNG vom Simulationsverlauf ab. Das ist beabsichtigt
und Teil der Prüfsumme.

### 5.4 Diffusions- und Decay-Pass

Liest aus `src`, schreibt nach `dst` (getrennte Puffer, danach Tausch).
Die Summationsreihenfolge ist **verbindlich**:

```
for y in 0 .. H-1:
    ym = (y - 1) & (H-1);  yp = (y + 1) & (H-1)
    for x in 0 .. W-1:
        xm = (x - 1) & (W-1);  xp = (x + 1) & (W-1)

        acc =   src[ym][xm]
        acc = acc + src[ym][x ]
        acc = acc + src[ym][xp]
        acc = acc + src[y ][xm]
        acc = acc + 4.0f * src[y][x]
        acc = acc + src[y ][xp]
        acc = acc + src[yp][xm]
        acc = acc + src[yp][x ]
        acc = acc + src[yp][xp]

        dst[y][x] = (acc / 12.0f) * decay
```

`4.0f * v` ist exakt (Zweierpotenz) und darf als `v + v + v + v` **nicht**
ersetzt werden — das Ergebnis wäre zwar gleich, aber Regel §1.2.3 verbietet
Umformungen grundsätzlich, damit Reviews mechanisch prüfbar bleiben.

Die Division durch `12.0f` und die anschließende Multiplikation mit `decay`
sind **zwei** gerundete Operationen in genau dieser Reihenfolge.

### 5.5 Update-Modi

Es gibt zwei Modi, die **unterschiedliche Simulationen** sind und jeweils eigene
Referenz-Prüfsummen haben. Jede Implementierung MUSS beide unterstützen.

| Modus | `DEPOSIT_TARGET` | Eigenschaft |
|---|---|---|
| `serial` (Default) | `grid` selbst, in-place | Spätere Agenten sehen frühere Deposits desselben Ticks. Entspricht der Referenz. **Inhärent sequenziell.** |
| `deferred` | separater, pro Tick genullter Puffer `dep` | Alle Agenten sehen denselben Grid-Snapshot. Vor dem Diffusionspass gilt `grid[i] = grid[i] + dep[i]`. **Reihenfolgeunabhängig → parallelisierbar.** |

> **Das ist der wichtigste Design-Entscheid des Projekts.** Der `serial`-Modus
> ist die getreue Umsetzung der Vorlage, lässt sich aber prinzipiell nicht
> deterministisch parallelisieren — der Deposit eines Agenten verändert, was der
> nächste Agent misst. Wer die Agentenschleife über 32 Threads verteilt, bekommt
> bei jedem Lauf ein anderes Ergebnis.
>
> `deferred` löst das (und ist physikalisch sogar plausibler: gleichzeitige
> statt sequenzieller Aktualisierung), kostet aber einen zusätzlichen
> Grid-Durchlauf.
>
> **Vergleichsregel: `serial` nur gegen `serial`, `deferred` nur gegen
> `deferred`.** Die Benchmark-Klassen P/V/G (§8) nutzen ausschließlich `deferred`.

### 5.6 Determinismus bei Parallelisierung

Atomare `f32`-Additionen sind **nicht** zulässig — ihr Ergebnis hängt von der
Ausführungsreihenfolge ab. Darüber hinaus gilt pro Pass:

**Diffusionspass:** unbedingt reihenfolgeunabhängig. Jede Ausgabezelle wird
allein aus `src` berechnet, es gibt keine Abhängigkeit zwischen Ausgabezellen.
Eine Parallelisierung über Zeilen ist damit **garantiert bit-identisch** zum
seriellen Lauf, für jede Thread-Zahl.

**Agenten-Pass:** Sensorik, Rotation und Bewegung sind pro Agent unabhängig
(im `deferred`-Modus ist das Grid dabei read-only) und damit ebenfalls
garantiert bit-identisch. Kritisch ist allein die **Akkumulation der Deposits**.

Für eine Zelle, die von den Agenten `i₁ < i₂ < … < i_k` getroffen wird, schreibt
§5.3 die Summe `((0 + d) + d) + …` in Indexreihenfolge vor. Gleitkommaaddition
ist nicht assoziativ, also ist eine andere Gruppierung im Allgemeinen ein
anderes Ergebnis.

> **Wichtige Einschränkung, die in einer früheren Fassung dieser Spec fehlte:**
> Thread-lokale Deposit-Puffer mit anschließender Reduktion in fester
> Thread-Reihenfolge sind **nicht automatisch** bit-identisch zum seriellen
> Lauf. Sie ergeben `(d_Thread0) + (d_Thread1) + …`, also eine andere
> Klammerung als die serielle Kette. Garantiert ist damit nur Determinismus
> **für eine gegebene Thread-Zahl**, nicht Unabhängigkeit von ihr.

Deshalb definiert die Spec zwei Reduktionsstrategien, die getrennt ausgewiesen
werden:

| Strategie | `--deposit-reduce` | Garantie | Speicher |
|---|---|---|---|
| Thread-lokale Puffer | `private` | reproduzierbar **je Thread-Zahl** | `T × W × H × 4 Byte` |
| Räumliche Bündelung | `binned` | **bit-identisch zu T = 1**, für jede Thread-Zahl | `N × 4 Byte` |

`binned` erreicht die stärkere Garantie so: Der Agenten-Pass schreibt nur die
Zielzelle pro Agent in ein Array. Anschließend werden die Agenten per
**stabiler Counting-Sort** nach Zeilenblock gebündelt; jeder Thread besitzt
einen Zeilenblock und trägt dessen Deposits in aufsteigender Agenten-Index-
Reihenfolge ein. Pro Zelle entsteht damit exakt die serielle Kette.

Der Preis ist Lastungleichheit: Physarum-Agenten ballen sich per Konstruktion
auf den Filamenten, die Zeilenblöcke sind also unterschiedlich stark belegt.

> **Anmerkung zu den Default-Parametern.** Mit `deposit = 10.0` und realistischen
> Trefferzahlen pro Zelle bleibt jede Teilsumme `k · 10` unter 2²⁴ und ist damit
> in `f32` exakt darstellbar — die Addition ist dann *zufällig* auch bei
> `private` reihenfolgeunabhängig. Darauf darf sich keine Implementierung
> verlassen: mit `--deposit 0.1` gilt es nicht mehr. Das Harness prüft
> Bit-Identität gegen `T = 1`, statt sie anzunehmen.

---

## 6. Prüfsummen

### 6.1 SB-FNV32 (wortweise)

Kein Standard-FNV — eine wortweise Variante, damit sie in jeder Sprache schnell ist:

```
sbfnv32(words):
    h = 0x811C9DC5
    for w in words:
        h = h XOR w
        h = (h * 0x01000193) mod 2^32
    return h
```

### 6.2 Grid-Hash

Das Grid wird als Folge von `W*H` `u32`-Wörtern interpretiert (die
Little-Endian-Bitmuster der `f32`-Werte, in Indexreihenfolge) und durch
`sbfnv32` geschickt.

### 6.3 Agenten-Hash

Über die Folge `[bits(ax[0]), bits(ay[0]), u32(adir[0]), bits(ax[1]), ...]`.

Zwei getrennte Hashes, weil sie unterschiedliche Fehler lokalisieren:
Grid-Hash weicht ab, Agenten-Hash stimmt → Fehler im Diffusionspass.
Beide weichen ab → Fehler im Agenten-Pass (oder eine frühere Ursache).

### 6.4 Zwischenstände

Mit `--hash-every N` MUSS eine Implementierung nach jedem N-ten Tick eine
Hash-Zeile ausgeben. Damit lässt sich der **erste** divergierende Tick binär
eingrenzen — das ist beim Portieren das mit Abstand nützlichste Werkzeug.

---

## 7. Konformitätsstufen

### 7.1 Stufe A — bit-exakt

Grid- und Agenten-Hash stimmen **exakt** mit den Referenzvektoren
(`spec/testvectors/`) überein.

Erwartet für: **C, C++, Rust, Haskell, TypeScript** (`Float32Array` +
`Math.fround`), **Python mit NumPy** (`float32`).

### 7.2 Stufe B — numerisch äquivalent

Bit-Exaktheit ist erreichbar, aber unwirtschaftlich.

Wichtig zum Verständnis: Doubles **können** f32-Arithmetik exakt nachbilden.
Doppelrundung ist unschädlich, wenn das Zwischenformat mindestens `2p+2` Bits
hat, und `53 ≥ 2·24+2`. `round_f32(f64_op(a,b))` ist daher für `+ − × ÷`
identisch mit der f32-Operation. Genau darauf beruht die
TypeScript-Implementierung mit ihrem `Math.fround` um jede Operation — und die
ist nachweislich Stufe A.

Perl und reines Python haben nur kein billiges `fround`: die Rundung geht über
`pack`/`unpack` bzw. `struct`, also einen Funktionsaufruf pro Operation — der
Diffusionskernel allein braucht neun davon pro Zelle.

Deshalb: **Default ist Stufe B**, das Flag `--strict-f32` schaltet auf Stufe A.
Beide Implementierungen sind mit `--strict-f32` nachweislich bit-identisch mit
der C-Referenz.

Der Abstand zwischen beiden Läufen ist selbst ein Messergebnis — *was kostet
Bit-Exaktheit in dieser Sprache?* Gemessen bei 128×128 / 4096 Agenten:

| Sprache | Stufe B | Stufe A (`--strict-f32`) | Aufschlag |
|---|---:|---:|---:|
| Python (pur) | 9.44 ms/Tick | 21.88 ms/Tick | **2.3×** |
| Perl | 9.40 ms/Tick | 31.15 ms/Tick | **3.3×** |

Das ist deutlich billiger als erwartet, und das ist selbst der interessante
Befund: In einer Sprache, die pro Operation ohnehin einen Interpreter-Dispatch
zahlt, verschwinden neun zusätzliche C-Level-Aufrufe pro Zelle weitgehend im
schon vorhandenen Overhead. Die ursprüngliche Schätzung in dieser Spec lag bei
zwei Größenordnungen — sie war schlicht falsch.

> **Unterschied zwischen den beiden Stufe-B-Implementierungen:** Python legt das
> Grid in einem `array('f')` ab, rundet also bei *jedem Store* auf f32 und
> weicht nur in den Zwischenergebnissen ab. Ein Perl-Array speichert volle NVs,
> rundet also gar nicht. Perls Stufe B driftet deshalb stärker als Pythons.

Verifikation von Stufe B über Toleranzmetriken nach N Ticks. Die Toleranzen
sind **nach Metrik getrennt**, weil eine einheitliche Zahl für beide Sorten
falsch wäre:

| Metrik | Toleranz | Warum |
|---|---|---|
| Gesamtmasse `Σ grid` | rel. **1e-6** | Erhaltungsgröße |
| Mittelwert | rel. **1e-6** | Erhaltungsgröße |
| Standardabweichung | rel. **2e-2** | strukturempfindlich |
| Anteil Zellen > 1.0 | abs. **2e-2** | strukturempfindlich |

Begründung, gemessen an der Stufe-B-Python-Implementierung gegen die
C-Referenz (128×128, 4096 Agenten):

| Ticks | `sum`/`mean` | `stddev` | `frac>1` |
|---|---|---|---|
| 1 | 1.7e-10 | 1.8e-09 | 0 |
| 100 | 5.1e-09 | 2.6e-04 | 0 |
| 1000 | 8.6e-09 | 6.7e-04 | 7.3e-04 |

Gesamtmasse und Mittelwert sind nahezu erhalten: wie viel Pheromon im Grid
steht, folgt aus Depositrate und Decay und hängt praktisch nicht davon ab,
*wohin* die Agenten gelaufen sind. Sie bleiben bei 1e-9 — deshalb darf die
Toleranz hier **enger** sein als ursprünglich spezifiziert. Ein falscher
Decay-Wert, eine falsche Depositmenge oder eine falsch normierte Faltung
sprengt 1e-6 sofort.

Standardabweichung und der Anteil heller Zellen messen dagegen, *wo* die
Filamente liegen. Das divergiert unter Chaos zwangsläufig. Hielte man sie auf
1e-4, würde die Prüfung nur noch das Chaos melden und nie einen Bug.

Default für: **Perl** und **reines Python**.

### 7.3 Stufe C — fast-math / approximativ

Builds mit `-ffast-math`, `-Ofast`, `-funsafe-math-optimizations`, GPU-Backends
mit Fast-Math-Default, oder SIMD-Varianten mit umsortierter Reduktion.
Verifikation wie Stufe B. Werden im Report **getrennt** ausgewiesen und nie
gegen Stufe A in dieselbe Tabellenzeile gestellt.

---

## 8. Benchmark-Klassen

Jede Klasse wird separat ausgewiesen. Ein Vergleich über Klassengrenzen hinweg
ist bedeutungslos.

| Klasse | Bedeutung | Update-Modus | Threads |
|---|---|---|---|
| **S** | Skalar, ein Thread. **Die Sprach-Achse.** | `serial` | 1 |
| **P** | Multi-Thread, skalar | `deferred` | N |
| **V** | SIMD (explizit oder auto-vektorisiert) | beide | 1 |
| **PV** | SIMD + Multi-Thread | `deferred` | N |
| **G** | GPU-Compute | `deferred` | — |
| **R** | Rendering-Backend (§11.1) | — | 1 |

Klasse **S** ist die eigentliche Antwort auf "wie schnell ist Sprache X".
Alles andere misst, wie gut das Ökosystem der Sprache Parallelisierung
zugänglich macht — auch interessant, aber eine andere Frage.

### 8.1 Klasse V ist nicht automatisch Stufe C

Eine frühere Fassung dieser Spec behauptete, SIMD lande zwangsläufig in
Konformitätsstufe C, weil die Reduktion umsortiert werde. Das gilt für den
Diffusionskernel **nicht**.

Der Kernel hat gar keine Cross-Lane-Reduktion: jede Lane berechnet eine
Ausgabezelle und führt dabei exakt dieselbe Operationsfolge in derselben
Reihenfolge aus wie die skalare Schleife. Lane *i* produziert bitgenau, was
die skalare Version für Zelle *i* produziert.

Damit gilt: **eine elementweise Vektorisierung des Diffusionspasses ist
Stufe A**, sofern zwei Bedingungen eingehalten werden:

1. **Kein FMA.** `4.0f * c + acc` als eine gerundete Operation ist eine andere
   Zahl. Multiplikation und Addition bleiben getrennte Intrinsics.
2. **Echte Division.** `_mm*_div_ps` durch 12, nicht Multiplikation mit dem
   Kehrwert (§1.2.4).

Eine Vektorisierung des **Agenten-Passes** wäre etwas anderes: dort müssten
mehrere Agenten pro Vektor in dieselbe Zelle deponieren, was eine
Konfliktauflösung und damit eine Reihenfolgeentscheidung erfordert. Das wäre
Stufe C — und ist bisher nicht implementiert.

### 8.2 Klasse G ist ebenfalls nicht automatisch Stufe C

Dieselbe Annahme stand für GPU-Compute in dieser Spec und ist ebenfalls
widerlegt: die CUDA-Implementierung ist **bit-identisch** mit der C-Referenz.

Drei Dinge müssen dafür zusammenkommen:

1. **Keine FMA-Kontraktion.** `nvcc -fmad=false`. Ohne das fusioniert der
   Compiler `4.0f * c + acc` und der Diffusionspass weicht ab.
2. **Korrekt gerundete Division.** `--prec-div=true` (bei nvcc Default). Eine
   Reziprok-Näherung verletzt §1.2.4.
3. **Ganzzahlige Deposit-Atomics.** `atomicAdd` auf `float` ist *nicht*
   deterministisch — die Reihenfolge, in der Threads ankommen, bestimmt die
   Rundung. Stattdessen zählt ein `atomicAdd` auf `uint` die Treffer pro Zelle
   (ganzzahlige Addition ist exakt und reihenfolgeunabhängig), und die
   Multiplikation mit `deposit` passiert einmal danach.

   Das reproduziert die serielle Kette genau dann, wenn `k · deposit` exakt
   darstellbar bleibt — dieselbe Einschränkung wie bei der CPU-Strategie
   `private` in §5.6, und das Harness prüft sie, statt sie anzunehmen.

> **Aber es hängt am Treiber, nicht nur an der Sprache.** Derselbe
> GLSL-Compute-Kernel mit denselben `precise`-Qualifiern ist auf Mesas
> `llvmpipe` bit-exakt und auf Mesas D3D12-Backend um bis zu 2 ULP daneben.
> `precise` verbietet in GLSL Umordnen und Fusion, erzwingt aber **keine**
> korrekt gerundete Division — anders als CUDAs `--prec-div=true`. Klasse G
> ist deshalb pro Backend einzustufen, nicht pauschal.
>
> `precise` gehört dabei an mehr Stellen als man zuerst denkt: nur auf dem
> Diffusions-Akkumulator reichte nicht, weil auch `x + cos*step` im
> Agenten-Pass fusioniert wird und den Agenten um ein ULP versetzt.

---

## 9. Presets

| Preset | W × H | Agenten | Dichte | Ticks | Zweck |
|---|---|---|---|---|---|
| `tiny` | 512 × 512 | 65 536 | 25 % | 1 000 | CI, Smoke-Test, Konformität |
| `small` | 1024 × 1024 | 262 144 | 25 % | 1 000 | schneller Vergleich, auch für Perl erträglich |
| `medium` | 2048 × 2048 | 1 048 576 | 25 % | 1 000 | **Headline-Zahl** |
| `large` | 4096 × 4096 | 4 194 304 | 25 % | 500 | Bandbreiten-Stress |
| `browser` | 1024 × 1024 | 262 144 | 25 % | ∞ | interaktiv |

Agentendichte 25 % der Zellen. (Die Vorlage nutzt 0.6 Agenten pro *Zelle* bei
8 px Zellgröße — auf Pixelauflösung übertragen wäre das absurd viel.)

Referenz-Seed: **`12345`**.

---

## 10. CLI-Vertrag

Jede Implementierung MUSS diese Argumente akzeptieren. Unbekannte Argumente
MÜSSEN mit Exit-Code 2 und einer Fehlermeldung auf stderr abgelehnt werden
(stillschweigend ignorierte Flags haben schon mehr Benchmarks ruiniert als
jeder Compiler-Bug).

```
--preset NAME          tiny|small|medium|large|browser
--width N --height N   Zweierpotenzen
--agents N
--ticks N
--seed N               Default 12345
--update MODE          serial|deferred        (Default serial)
--threads N            Default 1
--sensor-dist F  --sensor-steps N  --rot-steps N
--step F  --deposit F  --decay F
--deposit-reduce MODE  private|binned  (nur bei --threads > 1, §5.6)
--simd / --no-simd     vektorisierter Diffusionspass (Klasse V, §8.1)
--headless             kein Fenster (Default für Benchmark-Binaries)
--render               Fenster öffnen
--freeze-sim           Simulation anhalten (nur Render-Benchmark, §11.1)
--json                 Ergebnis als JSON auf stdout (letzte Zeile)
--hash-every N         Zwischen-Hashes auf stderr
--dump-grid PATH       rohes f32-Grid am Ende schreiben (Debugging)
--warmup N             N Ticks vor der Zeitmessung (Default 0)
```

### 10.1 Ergebnis-JSON

Die **letzte Zeile** von stdout bei `--json` MUSS exakt dieses Schema haben:

```json
{
  "schema": 1,
  "impl": "c",
  "backend": "headless",
  "class": "S",
  "preset": "medium",
  "width": 2048, "height": 2048, "agents": 1048576,
  "ticks": 1000, "seed": 12345, "update": "serial", "threads": 1,
  "grid_hash": "0x1a2b3c4d",
  "agent_hash": "0x5e6f7a8b",
  "dirtable_hash": "0x9c0d1e2f",
  "ms_total": 12345.678,
  "ms_agents": 8000.0,
  "ms_diffuse": 4345.678,
  "ms_per_tick_mean": 12.345678,
  "ms_per_tick_median": 12.3,
  "ms_per_tick_p99": 13.1,
  "maups": 84.9,
  "mcups": 339.5
}
```

- `maups` = Millionen Agenten-Updates pro Sekunde = `agents * ticks / ms_total / 1000`
- `mcups` = Millionen Zell-Updates pro Sekunde = `width * height * ticks / ms_total / 1000`
- Zeiten MÜSSEN mit einer monotonen Uhr gemessen werden.
- Init und Hash-Berechnung zählen **nicht** in `ms_total`.

RSS, Binärgröße und Buildzeit misst das Harness von außen — nicht die
Implementierung selbst.

---

## 11. Rendering (normativ, damit alle Backends gleich aussehen)

```
u8 = clamp( int( grid[idx] * 255.0f / display_max ), 0, 255 )     # display_max = 100.0
pixel = RGBA(u8, u8, u8, 255)
```

Optionale Farbpaletten sind erlaubt, MÜSSEN aber hinter einem Flag liegen und
sind nie Teil eines Benchmarks. Rendering wird in `--headless` **nie** ausgeführt.

### 11.1 Render-Benchmark (Klasse R)

Ein Rendering-Backend-Vergleich misst den Upload-Pfad
Grid → Textur → Bildschirm. Läuft die Simulation dabei weiter, dominiert sie
den Frame und die Backends sind ununterscheidbar.

Deshalb: **`--freeze-sim`** hält die Simulation an; jeder Frame lädt dasselbe
Grid erneut hoch. `--ticks N` bedeutet dann *N Frames*.

Gemessen wird von `sb_render_gray` bis einschließlich Present/EndDrawing.
Eventverarbeitung liegt außerhalb des Messfensters.

Backends DÜRFEN das Pixelformat wählen, das ihre API am günstigsten
entgegennimmt — ein erzwungenes gemeinsames Format würde genau den
Unterschied wegnormieren, um den es geht. Das gewählte Format gehört
dokumentiert.

Ergebnis-JSON bei `--json`, letzte Zeile auf stdout:

```json
{
  "schema": 1,
  "impl": "c", "backend": "raylib", "class": "R",
  "preset": "small", "width": 1024, "height": 1024,
  "frames": 300,
  "ms_render_mean": 2.107395,
  "ms_render_median": 2.046034,
  "ms_render_p99": 2.591799,
  "fps_equiv": 488.75,
  "mpixels_per_s": 512.5
}
```

Klasse-R-Ergebnisse werden **nie** gegen Klasse-S-Ergebnisse gestellt.

---

## 12. Referenzvektoren

`spec/testvectors/SPEC-1.json` enthält Grid-Hash, Agenten-Hash und die
Stufe-B-Metriken für drei Größen × beide Update-Modi × mehrere Tick-Stände,
erzeugt von der C-Referenzimplementierung (`impl/c`, gcc, `-O2 -ffp-contract=off`).

| Größe | Dimensionen | Ticks | Zweck |
|---|---|---|---|
| `micro` | 128×128, 4 096 Agenten | 1, 10, 100 | auch für Perl und reines Python in Sekunden durchführbar |
| `tiny` | 512×512, 65 536 Agenten | 1, 10, 100, 1000 | Standardfall |
| `small` | 1024×1024, 262 144 Agenten | 1, 10, 100 | andere Cache- und Wrapping-Verhältnisse |

Langsame Implementierungen deklarieren in `bench/targets.toml`
`conformance_set = "micro"` und prüfen nur die kleinste Größe. Sie prüfen
damit dieselben Vektoren wie alle anderen — nur weniger davon.

Erzeugt und geprüft mit:

```bash
python3 bench/run.py conformance --write   # neu erzeugen (nur aus der Referenz)
python3 bench/run.py conformance           # alle Targets prüfen
```

Wenn ein neuer Port abweicht, ist **im Zweifel der Port falsch**, nicht die
Referenz. Wenn sich herausstellt, dass die Referenz falsch ist, wird die
Spec-Version auf `SPEC-2` erhöht und *alle* Vektoren werden neu erzeugt —
niemals einzelne Vektoren "angepasst".
