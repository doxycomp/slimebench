#!/usr/bin/env python3
"""Keep each impl/*/README.md's inventory honest against the tree.

    bench/implmap.py --write      # fill the generated blocks
    bench/implmap.py --check      # fail if they have drifted

## Why this exists rather than a documentation generator

Sixteen languages would mean sixteen documentation toolchains -- haddock,
rustdoc, godoc, javadoc, doxygen, odoc, DocC, TypeDoc, docfx -- each one
another install, another pin in versions.env, another CI job and another
thing that goes stale. And they all produce API reference, which nobody needs
here: a headless benchmark has one entry point and no public API. The question
a reader actually has is "which file, and why is it written that way", and no
generator can answer that.

So the prose is written by hand and only the *inventory* is generated: which
files exist, how long they are, which are machine-generated, which targets
build from them, and one line per file saying what is in it.

## Where the one-line summaries come from

Not from a list kept here -- from the first prose line of each file's own
header comment. That makes the map a projection of the code rather than a
second copy of it: rewrite a module header and the README follows. It also
puts pressure in a useful direction, because a file with no header comment
shows up as a hole in its own README, and `--check` names it.

## What --check enforces

  1. every target in bench/targets.toml appears in exactly one README
  2. every source file appears in its README's file map
  3. every path a README mentions exists
  4. every implementation directory has a README at all

Numbers stay out of these files by design: measurements live in
docs/RESULTS.md under the one-run rule, and a copy in sixteen READMEs would be
sixteen new places to go stale. See the header of bench/tables.py -- this is
the same argument applied to a different kind of drift.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys
import tomllib

ROOT = pathlib.Path(__file__).resolve().parent.parent
IMPL = ROOT / "impl"

# Directories that hold build output rather than source. `web` is not in here:
# it is a checked-in artefact directory that the TypeScript README explains.
SKIP_DIRS = {
    "build", "target", "dist", "obj", "bin", "node_modules", "__pycache__",
    ".stack-work", "_build", ".libshim", "Packages", ".build", "publish",
}

# One entry per language the tree actually contains. The comment prefix is
# what has to come off the front of a line before the prose starts; block
# openers are handled separately because several languages lead with them.
SOURCE_EXT = {
    ".c": "//", ".h": "//", ".cpp": "//", ".hpp": "//", ".cu": "//",
    ".rs": "//", ".go": "//", ".java": "//", ".cs": "//", ".swift": "//",
    ".ts": "//", ".js": "//", ".comp": "//", ".glsl": "//", ".vert": "//",
    ".frag": "//", ".S": "//", ".s": "//",
    ".hs": "--", ".lean": "--",
    ".py": "#", ".pl": "#", ".pm": "#", ".sh": "#",
    ".f90": "!",
    ".ml": "(*", ".mli": "(*",
    ".html": "<!--",
}

# Files that are part of the build rather than the implementation. They are
# listed, but under their own heading, so the interesting files are not buried
# under twelve project files.
SUPPORT = {
    "build.sh", "Makefile", "makefile", "CMakeLists.txt", "Cargo.toml",
    "go.mod", "go.sum", "package.json", "tsconfig.json", "lakefile.lean",
    "lean-toolchain", "Package.swift", "dune-project", "dune", "cabal.project",
}

MARK = re.compile(r"<!-- sb:impl (\S+) -->\n(.*?)<!-- /sb:impl -->", re.S)

# Lines that may precede a header comment without ending it: shebangs,
# pragmas, preprocessor and shader-version directives, tool markers. Matched
# against the raw line, before any comment marker is stripped.
# Java and C# put the doc comment *after* the imports, which is the convention
# in both languages, so an import line cannot be taken to mean the header is
# over. Same for shebangs, pragmas and shader #version directives.
PREAMBLE = re.compile(
    r"^\s*(#!|\{-#|#\s*(version|pragma|include|define|ifndef|ifdef|if|endif|"
    r"else|nullable)\b|@|//\s*swift-tools-version|//\s*-\*-|#\s*-\*-|"
    r"#\s*coding[:=]|<!doctype\b)", re.I)

# Declarations that may sit before the header comment because that is the
# convention in the language: Java and C# put the doc comment after the
# imports. Separate from PREAMBLE because these are only preamble when they do
# not open a scope -- `namespace sb {` is the body starting, and treating it
# as preamble made this pick up the comment on the first helper function.
PREAMBLE_DECL = re.compile(
    r"^\s*(import|using|package|namespace|open|require)\b")

# Boilerplate inside the comment that is not the sentence worth quoting.
NOISE = re.compile(
    r"^((module|package|import|using|namespace|open|from|use|require|include|"
    r"layout|precision|extern|SPDX)\b|-{3,}$|={3,}$|\*+$|coding[:=]|"
    r"</?(summary|remarks|para)>$)")

# Openers, longest first so that "-- |" is not eaten by "--".
LINE_OPEN = ("--- |", "-- |", "--!", "//!", "///", "#!", "--", "//", "#", "!")
# (opener, closer) for comments that run across lines. Once one is open, the
# lines inside it carry no marker of their own, which is what broke the first
# version of this on Lean and on Python docstrings.
BLOCK_OPEN = (('"""', '"""'), ("'''", "'''"), ("/-!", "-/"), ("/-", "-/"),
              ("/**", "*/"), ("/*", "*/"), ("(*", "*)"), ("<!--", "-->"))


def is_generated(text: str) -> bool:
    head = "\n".join(text.splitlines()[:6]).upper()
    return "GENERATED" in head or "DO NOT EDIT" in head


def summary(path: pathlib.Path, text: str) -> str:
    """The first prose line of the file's own header comment.

    Deliberately dumb: strip the comment syntax, drop the boilerplate, take
    the first real sentence. A file whose header does not begin with a
    sentence about the file is a file whose header should be rewritten, and
    `--check` is what says so.
    """
    in_block = None
    prose: list[str] = []
    for raw in text.splitlines()[:40]:
        line = raw.strip()
        if not line:
            continue
        if in_block is None:
            if PREAMBLE.match(raw):
                continue
            if PREAMBLE_DECL.match(raw) and "{" not in raw:
                continue
            for opener, closer in BLOCK_OPEN:
                if line.startswith(opener):
                    in_block = closer
                    line = line[len(opener):].strip()
                    break
            else:
                for opener in LINE_OPEN:
                    if line.startswith(opener):
                        line = line[len(opener):].strip()
                        break
                else:
                    # No comment marker and not preamble: the file simply has
                    # no header comment, and that is the answer.
                    break
        elif line.startswith(in_block):
            break
        else:
            # Inside a block comment. Leading decoration only.
            line = line.lstrip("*").strip()
        if in_block and line.endswith(in_block):
            line = line[: -len(in_block)].strip()
        line = line.rstrip("*/-!").rstrip()
        if not line or NOISE.match(line):
            continue
        # "slimebench -- the thing" says "slimebench" in every one of 120
        # files; the reader is already in the repository.
        if not prose:
            line = re.sub(r"^slimebench\s*[-—]{1,2}\s*", "", line, flags=re.I)
        line = line.strip()
        if not line:
            continue
        prose.append(line)
        # A first sentence often wraps. Keep taking lines until one ends it,
        # or until there is plainly enough -- a file map wants a label, not a
        # paragraph.
        joined = " ".join(prose)
        if re.search(r"\.(\s|$)", joined) or len(joined) > 96 or len(prose) >= 4:
            break
    joined = " ".join(prose).strip()
    if not joined:
        return ""
    m = re.search(r"\.(\s|$)", joined)
    if m:
        joined = joined[:m.start()]
    joined = joined.strip().rstrip(".")
    if len(joined) > 96:
        joined = joined[:93].rsplit(" ", 1)[0] + "…"
    return joined[0].upper() + joined[1:] if joined else ""


def sources(d: pathlib.Path) -> list[pathlib.Path]:
    """What git has, not what the filesystem has.

    Asking git rather than walking the tree is the difference between a map of
    the implementation and a map of whatever happens to be lying around: build
    directories, .gitignored bundles, a Swift .build tree, node_modules. It
    also means .gitignore is the one place that decides, instead of a second
    exclusion list here that would drift away from it.
    """
    rel = d.relative_to(ROOT).as_posix()
    out = subprocess.run(["git", "ls-files", "-z", "--", rel],
                         cwd=ROOT, capture_output=True, text=True, check=True)
    files = []
    for name in out.stdout.split(chr(0)):
        if not name:
            continue
        p = ROOT / name
        if not p.is_file():
            continue
        if any(part in SKIP_DIRS for part in p.relative_to(d).parts[:-1]):
            continue
        if p.suffix in SOURCE_EXT or p.name in SUPPORT:
            files.append(p)
    return sorted(files)


_TRACKED: tuple[set[str], set[str]] | None = None


def tracked() -> tuple[set[str], set[str]]:
    """Every path git knows about, and every basename, computed once.

    Basenames as well as paths because a README legitimately writes
    `merge.comp` when the file is `shaders/merge.comp`, and demanding the full
    path in prose would make the prose worse to read in order to make this
    check simpler to write.
    """
    global _TRACKED
    if _TRACKED is None:
        out = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT,
                             capture_output=True, text=True, check=True)
        paths = {n for n in out.stdout.split(chr(0)) if n}
        # A path .gitignore names is a real thing the repository knows about,
        # it is just built rather than committed -- impl/web/app.js is named
        # in two READMEs precisely to say it is generated. Tracked or
        # deliberately ignored are both fine; anything else is a typo.
        ign = subprocess.run(["git", "ls-files", "-z", "--others", "--ignored",
                              "--exclude-standard", "--directory"],
                             cwd=ROOT, capture_output=True, text=True)
        paths |= {n.rstrip("/") for n in ign.stdout.split(chr(0)) if n}
        _TRACKED = (paths, {p.rsplit("/", 1)[-1] for p in paths})
    return _TRACKED


def load_targets() -> dict[str, list[dict]]:
    t = tomllib.loads((ROOT / "bench" / "targets.toml").read_text(encoding="utf-8"))
    by: dict[str, list[dict]] = {}
    for x in t["target"]:
        by.setdefault(x["dir"], []).append(x)
    return by


def table(headers: list[str], rows: list[list[str]], align: str) -> str:
    sep = {"l": "---", "r": "---:", "c": ":-:"}
    out = ["| " + " | ".join(headers) + " |",
           "|" + "|".join(sep[a] for a in align) + "|"]
    out += ["| " + " | ".join(r) + " |" for r in rows]
    return "\n".join(out) + "\n"


def block_files(d: pathlib.Path) -> tuple[str, list[str]]:
    """The file map, and the paths with no header comment to summarise."""
    main, support, holes = [], [], []
    for p in sources(d):
        rel = p.relative_to(d).as_posix()
        text = p.read_text(encoding="utf-8", errors="replace")
        n = len(text.splitlines())
        if p.name in SUPPORT and p.suffix not in (".sh",):
            support.append([f"`{rel}`", str(n), summary(p, text) or "—"])
            continue
        if is_generated(text):
            # The banner is not a description of the file, so say who wrote it
            # instead. That is the one fact a reader needs: where to make the
            # change that will survive the next regeneration.
            m = re.search(r"GENERATED by (\S+)", text[:400], re.I)
            what = (f"_Generated by `{m.group(1)}`_" if m
                    else "_Generated — do not edit_")
        else:
            what = summary(p, text)
            if not what:
                holes.append(rel)
                what = "—"
        main.append([f"`{rel}`", str(n), what])
    body = table(["File", "Lines", "What"], main + support, "lrl")
    return body, holes


def block_targets(d: pathlib.Path, targets: list[dict]) -> str:
    if not targets:
        return "_No benchmark target builds from this directory._\n"
    rows = []
    for x in sorted(targets, key=lambda t: (t.get("class", "Z"), t["id"])):
        profiles = ", ".join(f"`{p}`" for p in x.get("profiles", [])) or "—"
        ccs = ", ".join(x.get("compilers", [])) or "—"
        rows.append([f"`{x['id']}`", x.get("class", "?"),
                     x.get("backend", "—"), ccs, profiles])
    return table(["Target", "Class", "Backend", "Compilers", "Profiles"],
                 rows, "lclll")


def render(d: pathlib.Path, targets: list[dict]) -> tuple[dict[str, str], list[str]]:
    files, holes = block_files(d)
    return {"files": files, "targets": block_targets(d, targets)}, holes


def apply(readme: pathlib.Path, blocks: dict[str, str]) -> int:
    text = readme.read_text(encoding="utf-8")
    changed = 0

    def sub(m: re.Match) -> str:
        nonlocal changed
        name = m.group(1)
        want = blocks.get(name)
        if want is None:
            return m.group(0)
        if m.group(2) != want:
            changed += 1
        return f"<!-- sb:impl {name} -->\n{want}<!-- /sb:impl -->"

    out = MARK.sub(sub, text)
    if changed:
        readme.write_text(out, encoding="utf-8", newline="\n")
    return changed


def check(readme: pathlib.Path, blocks: dict[str, str],
          d: pathlib.Path) -> list[str]:
    text = readme.read_text(encoding="utf-8")
    bad = []
    seen = set()
    for m in MARK.finditer(text):
        seen.add(m.group(1))
        want = blocks.get(m.group(1))
        if want is None:
            bad.append(f"{readme.relative_to(ROOT)}: unknown block "
                       f"'{m.group(1)}'")
        elif m.group(2) != want:
            bad.append(f"{readme.relative_to(ROOT)}: block '{m.group(1)}' is "
                       f"out of date")
    for name in blocks:
        if name not in seen:
            bad.append(f"{readme.relative_to(ROOT)}: missing block '{name}'")
    # Every repo path a README names must exist. Backticked only, so prose
    # about `--agent-tile` or `IOUArray` is not mistaken for a file.
    paths, names = tracked()
    for m in re.finditer(r"`([A-Za-z0-9_./-]+\.[A-Za-z0-9]{1,6})`", text):
        rel = m.group(1)
        # An absolute path is the system's, not the repository's; a leading
        # dash is a flag; `/12.0f` is arithmetic. None of them are claims
        # about a file in the tree, so none of them are checkable here.
        if rel.startswith(("/", "http", "-")) or " " in rel:
            continue
        if pathlib.PurePosixPath(rel).suffix not in SOURCE_EXT \
                and rel.rsplit("/", 1)[-1] not in SUPPORT and "/" not in rel:
            continue
        joined = (d.relative_to(ROOT) / rel).as_posix()
        if joined in paths or rel in paths or rel.rsplit("/", 1)[-1] in names:
            continue
        bad.append(f"{readme.relative_to(ROOT)}: names `{rel}`, "
                   f"which is not a file in this repository")
    return bad


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--write", action="store_true")
    g.add_argument("--check", action="store_true")
    a = ap.parse_args()

    by_dir = load_targets()
    dirs = sorted(p for p in IMPL.iterdir() if p.is_dir())
    problems: list[str] = []
    covered: set[str] = set()
    touched = 0

    for d in dirs:
        rel = d.relative_to(ROOT).as_posix()
        readme = d / "README.md"
        targets = by_dir.get(rel, [])
        if not readme.exists():
            problems.append(f"{rel}: no README.md")
            continue
        blocks, holes = render(d, targets)
        covered.update(t["id"] for t in targets)
        if a.write:
            touched += apply(readme, blocks)
        else:
            problems += check(readme, blocks, d)
            problems += [f"{rel}/{h}: no header comment to summarise"
                         for h in holes]

    all_ids = {t["id"] for ts in by_dir.values() for t in ts}
    missing = all_ids - covered
    if missing:
        problems.append("targets with no README: " + ", ".join(sorted(missing)))

    if a.write:
        print(f"{touched} block(s) updated across {len(dirs)} directories")
        return 0
    for p in problems:
        print("  " + p)
    if problems:
        print(f"{len(problems)} problem(s). Run: bench/implmap.py --write")
        return 1
    print(f"impl/*/README.md: {len(dirs)} directories, {len(all_ids)} targets, "
          f"all in sync")
    return 0


if __name__ == "__main__":
    sys.exit(main())
