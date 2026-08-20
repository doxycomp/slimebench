# Messdaten

```
run-YYYYmmdd-HHMM/    eine vollständige Messreihe
archive/              die Einzelmessungen, aus denen das Projekt entstanden ist
```

## `run-*/` — die aktuellen Zahlen

Jedes Verzeichnis ist **ein** Lauf über die ganze Matrix, erzeugt mit

```bash
bench/full-run.sh          # nativ, oder von /mnt/c mit dem 9p-Vorbehalt
scripts/stage-wsl.sh && bench/full-run.sh   # WSL2, für saubere Build-Zeiten
```

Alle Tabellen und Diagramme in [`docs/RESULTS.md`](../docs/RESULTS.md) stammen
aus dem jeweils jüngsten davon — derzeit `run-20260820-0330` — erzeugt mit `bench/tables.py` und
`bench/charts.py`. `environment.txt` hält Maschine, Toolchain-Versionen und
Commit fest — eine Messung, die sich keiner Revision zuordnen lässt, ist ein
Transkript.

| Datei | Inhalt |
|---|---|
| `A-crosslang-{serial,deferred}.jsonl` | Klasse S, alle Sprachen, 256² |
| `C-compiler-matrix.jsonl` | Compiler × Profil, 1024²/300 |
| `G-simd.jsonl` | Klasse V (Intrinsics), 1024²/300 |
| `V-asm-kernels.jsonl` | Klasse V, Diffusionskerne skalar/Intrinsics/Assembler |
| `M-haskell-style.jsonl` | Die Stilachse: C-Referenz und drei Haskell-Fassungen |
| `P-parallel.jsonl` | Klasse P, Thread-Sweep pro Sprache |
| `P-gil-matrix.jsonl` | CPython 3.12 gegen 3.14t × Threads gegen Prozesse |
| `H-gpu.jsonl` | Klasse G, alle fünf Presets, drei Hosts |
| `Q-render.jsonl` | Klasse R, beide Backends × beide Renderer |
| `environment.txt` | Maschine, Toolchains, Commit |
| `run.log` | Der vollständige Konsolenmitschnitt des Laufs |

## `archive/` — wie es dazu kam

Die Buchstabendateien sind die Einzelmessungen aus den Sitzungen, in denen die
jeweiligen Befunde entstanden sind. Sie sind **nicht** untereinander
vergleichbar: verschiedene Tage, verschiedener Maschinenzustand, teils
verschiedene Quellstände. Genau das war der Anlass für `full-run.sh`.

Sie bleiben im Baum, weil einige Befunde in RESULTS.md nur hier belegt sind und
im Gesamtlauf nicht wiederholt werden — die Barrieren-Varianten, die verworfene
parallele Präfixsumme, die PGO-Messung, der `threads::shared`-Vergleich für
Perl. Wer eine dieser Zahlen nachrechnen will, findet sie hier; wer Sprachen
vergleichen will, nimmt `run-*/`.

Eine Datei ist bewusst falsch und bleibt es: `H-gpu.jsonl` enthält die
GL-Compute-Zahlen von vor dem 2D-Dispatch-Fix, bei denen der Diffusionspass
still übersprungen wurde. Sie steht als Beleg für den Eintrag in
[RESULTS.md §12](../docs/RESULTS.md#12-wo-ich-mich-geirrt-habe) da.

Ältere `run-*/` bleiben liegen. Sie sind in sich konsistent und damit weiter
brauchbar; sie sind nur nicht mehr die, aus denen das Dokument zitiert.

Im Wurzelverzeichnis liegen daneben ein paar Einzelmessungen, die keiner Reihe
angehören und das auch nicht sollen: `V-asm-kernels-reps9.jsonl` etwa ist die
Kontrollmessung mit neun statt drei Wiederholungen, mit der geprüft wurde, ob
der Vorsprung des Assembler-Kerns Rauschen ist (§7).
