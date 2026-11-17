#!/usr/bin/env python3
"""Tankard's string catalog tooling.

Resources/Localizable.xcstrings is the source of truth for every
translatable string. The Command Line Tools have no xcstringstool, so
SwiftPM can't compile a .xcstrings file here (or on the macOS 14 VM); this
script turns the catalog into <lang>.lproj/Localizable.strings files under
Sources/TankardApp/Resources/Localizations, which SwiftPM processes as
ordinary localized resources and Scripts/bundle-app.sh copies into the
app's main bundle (SwiftUI's Text("...") and String(localized:) both look
in Bundle.main).

  Scripts/l10n.py extract            build with -emit-localized-strings and
                                     add new keys to the catalog (existing
                                     translations are kept; keys no longer
                                     in the source are reported as stale)
  Scripts/l10n.py import LANG FILE   merge a JSON {key: translation} map
  Scripts/l10n.py compile            write the .lproj/Localizable.strings
                                     (and Localizable.stringsdict for keys
                                     with plural variations)
  Scripts/l10n.py missing [LANG]     list keys without a translation
  Scripts/l10n.py prune              drop stale keys (marked by extract)
"""
import glob
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "Resources", "Localizable.xcstrings")
OUT = os.path.join(ROOT, "Sources", "TankardApp", "Resources", "Localizations")
LANGS = ["de", "fr", "es", "ja", "zh-Hans", "pt-BR", "it", "ko"]
SPEC = re.compile(r"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:ll|l|h|hh|z|t|j|L|q)?[@dDiuUxXoOfeEgGcCsSpaA]")


def load():
    if not os.path.exists(CATALOG):
        return {"sourceLanguage": "en", "strings": {}, "version": "1.0"}
    with open(CATALOG, encoding="utf-8") as f:
        return json.load(f)


def save(cat):
    cat["strings"] = dict(sorted(cat["strings"].items(), key=lambda kv: kv[0]))
    with open(CATALOG, "w", encoding="utf-8") as f:
        json.dump(cat, f, ensure_ascii=False, indent=2, sort_keys=False)
        f.write("\n")


def specifiers(s):
    """The format specifiers in s, ignoring positions (%1$@ is %@)."""
    return sorted(re.sub(r"^%\d+\$", "%", m) for m in SPEC.findall(s.replace("%%", "")))


def positional(key, value):
    """Translations may put the arguments in another order. Without
    positions (%2$@), the arguments would be read in the source's order, so
    a %lld and a %@ that swap places would misformat or crash. Each of
    value's plain specifiers gets the position of the first unused source
    argument of the same type."""
    src = SPEC.findall(key.replace("%%", ""))
    dst = SPEC.findall(value.replace("%%", ""))
    if src == dst or any("$" in x for x in dst):
        return value
    used = set()
    out, pos = [], 0
    for m in SPEC.finditer(value):
        if value[max(0, m.start() - 1):m.start()] == "%" and value[max(0, m.start() - 2):m.start()] != "%%":
            continue
        spec = m.group(0)
        i = next(i for i, x in enumerate(src) if x == spec and i not in used)
        used.add(i)
        out.append(value[pos:m.start()] + "%" + f"{i + 1}$" + spec[1:])
        pos = m.end()
    return "".join(out) + value[pos:]


def extract():
    tmp = tempfile.mkdtemp(prefix="tankard-strings-")
    # Every source file has to be compiled with the flag; an incremental
    # build skips unchanged files and so misses their strings. A throwaway
    # scratch path makes it a full build.
    scratch = os.path.join(tmp, "build")
    try:
        subprocess.run(["swift", "build", "--product", "TankardApp", "--scratch-path", scratch,
                        "-Xswiftc", "-emit-localized-strings",
                        "-Xswiftc", "-emit-localized-strings-path", "-Xswiftc", tmp],
                       cwd=ROOT, check=True)
        # Older SwiftPM writes the .stringsdata files to the given path,
        # the newer build system next to the object files.
        found = glob.glob(os.path.join(tmp, "**", "*.stringsdata"), recursive=True)
        datas = []
        for path in found:
            with open(path, encoding="utf-8") as f:
                datas.append(json.load(f))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    keys = {}
    for data in datas:
        for table, entries in data.get("tables", {}).items():
            if table != "Localizable":
                continue
            for e in entries:
                if e["key"].strip():
                    keys.setdefault(e["key"], e.get("comment", ""))
    if not keys:
        sys.exit("extract: no strings found (was anything recompiled?)")
    cat = load()
    strings = cat["strings"]
    added = 0
    for k, comment in keys.items():
        if k not in strings:
            strings[k] = {}
            added += 1
        entry = strings[k]
        entry.pop("extractionState", None)
        if comment:
            entry["comment"] = comment
    stale = [k for k in strings if k not in keys]
    for k in stale:
        strings[k]["extractionState"] = "stale"
    save(cat)
    print(f"extract: {len(keys)} keys in source, {added} new, {len(stale)} stale")


def translations(entry):
    """lang -> value. A plural entry gives its "other" form (the .strings
    fallback; the forms themselves go to Localizable.stringsdict)."""
    out = {}
    for lang, loc in entry.get("localizations", {}).items():
        if "stringUnit" in loc:
            out[lang] = loc["stringUnit"]["value"]
        elif "other" in plural_forms(loc):
            out[lang] = plural_forms(loc)["other"]
    return out


def plural_forms(loc):
    """{"one": ..., "other": ...} of a localization with plural variations
    (Xcode's catalog shape: variations.plural.<category>.stringUnit.value)."""
    return {cat: v["stringUnit"]["value"]
            for cat, v in loc.get("variations", {}).get("plural", {}).items()
            if "stringUnit" in v}


PLURAL_CATEGORIES = ["zero", "one", "two", "few", "many", "other"]


def stringsdict_entry(key, forms):
    """One key's stringsdict dict: the whole sentence varies by the first
    number in the key (the plural's argument)."""
    nums = [m for m in SPEC.findall(key.replace("%%", "")) if m[-1] in "dDiuUxXoO"]
    if not nums:
        sys.exit(f"compile: plural key without a number: {key!r}")
    spec = re.sub(r"^%(?:\d+\$)?", "", nums[0])
    d = {"NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": spec}
    for cat in PLURAL_CATEGORIES:
        if cat in forms:
            d[cat] = forms[cat]
    return {"NSStringLocalizedFormatKey": "%#@n@", "n": d}


def import_(lang, path):
    with open(path, encoding="utf-8") as f:
        mapping = json.load(f)
    cat = load()
    n, bad, unknown = 0, [], 0
    for k, v in mapping.items():
        if k not in cat["strings"]:
            unknown += 1
            continue
        if specifiers(k) != specifiers(v):
            bad.append(k)
            continue
        v = positional(k, v)
        cat["strings"][k].setdefault("localizations", {})[lang] = {
            "stringUnit": {"state": "translated", "value": v}}
        n += 1
    save(cat)
    print(f"import {lang}: {n} translations, {unknown} unknown keys, {len(bad)} rejected for format specifiers")
    for k in bad:
        print(f"  specifier mismatch: {k!r} -> {mapping[k]!r}")


def escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")


def compile_():
    cat = load()
    live = {k: e for k, e in cat["strings"].items() if e.get("extractionState") != "stale"}
    nplural = 0
    for lang in ["en"] + LANGS:
        d = os.path.join(OUT, f"{lang}.lproj")
        os.makedirs(d, exist_ok=True)
        lines = ["/* Generated from Resources/Localizable.xcstrings by Scripts/l10n.py compile. Do not edit. */"]
        for k, e in live.items():
            v = translations(e).get(lang, k) if lang == "en" else translations(e).get(lang)
            if v is None:
                continue
            lines.append(f'"{escape(k)}" = "{escape(v)}";')
        with open(os.path.join(d, "Localizable.strings"), "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        subprocess.run(["plutil", "-lint", "-s", os.path.join(d, "Localizable.strings")], check=True)
        # Plural variations: Foundation reads Localizable.stringsdict before
        # Localizable.strings for the same key.
        plurals = {}
        for k, e in live.items():
            forms = plural_forms(e.get("localizations", {}).get(lang, {}))
            if forms:
                if "other" not in forms:
                    sys.exit(f"compile: {lang} plural of {k!r} has no 'other' form")
                for v in forms.values():
                    if specifiers(v) != specifiers(k):
                        sys.exit(f"compile: {lang} plural of {k!r}: specifier mismatch in {v!r}")
                plurals[k] = stringsdict_entry(k, {c: positional(k, v) for c, v in forms.items()})
        sd = os.path.join(d, "Localizable.stringsdict")
        if plurals:
            with open(sd, "wb") as f:
                plistlib.dump(plurals, f, sort_keys=True)
            subprocess.run(["plutil", "-lint", "-s", sd], check=True)
            nplural = len(plurals)
        elif os.path.exists(sd):
            os.remove(sd)
    print(f"compile: {len(live)} keys ({nplural} with plural forms), {len(LANGS) + 1} languages -> {os.path.relpath(OUT, ROOT)}")


def missing(langs):
    cat = load()
    out = {}
    for k, e in cat["strings"].items():
        if e.get("extractionState") == "stale":
            continue
        have = translations(e)
        for lang in langs:
            if lang not in have:
                out.setdefault(lang, []).append(k)
    return out


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    cmd = args[0]
    if cmd == "extract":
        extract()
    elif cmd == "import":
        import_(args[1], args[2])
    elif cmd == "compile":
        compile_()
    elif cmd == "missing":
        m = missing(args[1:] or LANGS)
        if len(args) == 2:
            json.dump(m.get(args[1], []), sys.stdout, ensure_ascii=False, indent=1)
            print()
        else:
            for lang in LANGS:
                print(f"{lang}: {len(m.get(lang, []))} missing")
    elif cmd == "prune":
        cat = load()
        before = len(cat["strings"])
        cat["strings"] = {k: e for k, e in cat["strings"].items() if e.get("extractionState") != "stale"}
        save(cat)
        print(f"prune: removed {before - len(cat['strings'])} stale keys")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
