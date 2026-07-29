#!/bin/bash
#
# Fails on any user-facing string literal that never goes through loc().
#
# The flow check compares the two string tables against each other and walks
# every label built from an enum, but neither can see a literal that was passed
# straight to a view or assigned to something the interface reads — and nine of
# those survived every other check, including the whole preferences sidebar and
# every error message the router can produce. The literals that were wrapped
# correctly look exactly like the ones that were not, so this is a job for a
# scanner rather than for reading.
#
#   ./App/check-strings.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PYTHON'
import pathlib
import re
import sys

# Views that take a user-visible string as their first argument.
CONSTRUCTORS = (
    "Text", "Toggle", "Button", "YunBadge", "YunStatusPill", "YunDetailRow",
    "YunEmptyState", "YunDisclosure",
)
CONSTRUCTED = re.compile(
    r"\b(" + "|".join(CONSTRUCTORS) + r")\(\s*\n?\s*(\"(?:[^\"\\]|\\.)+\")"
)

# Assignments to something the interface displays. Five user-facing error
# messages sat in English behind these for the life of the project, because an
# assignment is not a view argument and the constructor scan could not see them.
LABELS = r"\w*[Ee]rror|\w*[Mm]essage|\w*[Tt]itle|\w*[Ss]ubtitle|\w*[Dd]etail|value"
ASSIGNED = re.compile(r"\b(" + LABELS + r")\s*=\s*(\"(?:[^\"\\]|\\.)+\")")

# Named arguments carrying a literal. "none captured" sat in the menu bar panel
# in English behind `subtitle:` for the life of the project, because a colon is
# not an equals sign and the assignment scan could not see it either.
ARGUMENT = re.compile(r"\b(" + LABELS + r")\s*:\s*(\"(?:[^\"\\]|\\.)+\")")

INTERPOLATION = re.compile(r"\\\((?:[^()]|\([^()]*\))*\)")

# Units and proper nouns read the same in both languages, so wrapping them buys
# a table entry and nothing else.
UNITS = {"ch", "hz", "khz", "db", "dbfs", "ms", "ppm", "f", "mit", "wav", "aac", "rec"}


def carries_words(literal):
    """True when what is left after the values is something a person reads."""
    # An interpolated value is not a label: "\(count) items" is one, "×\(count)"
    # is not, and the difference is whether any letters survive the strip.
    text = INTERPOLATION.sub("", literal[1:-1])
    words = re.findall(r"[A-Za-z]+", text)
    return any(word.lower() not in UNITS for word in words)


# The verification harnesses print for whoever is running them, not for the
# person using the app, so their strings are deliberately not translated.
HARNESSES = {"WindowCapture.swift", "PanelRenderer.swift", "UIFlowCheck.swift"}

failures = []
for directory in ("Sources/YunAudioApp", "Sources/YunDesign"):
    for path in sorted(pathlib.Path(directory).glob("*.swift")):
        if path.name in HARNESSES:
            continue
        source = path.read_text()
        for pattern in (CONSTRUCTED, ASSIGNED, ARGUMENT):
            for match in pattern.finditer(source):
                literal = match.group(2)
                if not carries_words(literal):
                    continue
                line = source[: match.start()].count("\n") + 1
                failures.append(f"{path}:{line}: {match.group(1)} {literal}")

# A key written twice is not a warning from anything: the last one silently
# wins, so a translation can be overridden by a different translation of the
# same word and the only symptom is a label that reads oddly. Six of these had
# accumulated — "Pitch" meaning both the effect and the musical quantity,
# "None" meaning both "no voice preset" and "nothing" — and each was one
# English word doing two jobs.
for table in sorted(pathlib.Path("Sources").glob("**/*.lproj/Localizable.strings")):
    seen = {}
    for number, line in enumerate(table.read_text().splitlines(), start=1):
        match = re.match(r'^"((?:[^"\\]|\\.)*)"\s*=', line)
        if not match:
            continue
        key = match.group(1)
        if key in seen:
            failures.append(
                f"{table}:{number}: duplicate key {key!r}, first seen on line {seen[key]}")
        else:
            seen[key] = number

# Format specifiers have to survive translation.
#
# `String(format:)` reads the *translated* string, so a translation that drops a
# `%@` or turns a `%.1f` into a `%d` does not produce a worse sentence — it
# reads the wrong argument off the stack and prints rubbish, or crashes. It is
# also invisible to every other check here, because both files are perfectly
# well-formed.
#
# Positional forms are counted as equal to their plain equivalents: `%1$@` and
# `%2$@` in the translation of a string that has two `%@` is a *correct*
# translation reordering the arguments, which is the entire reason the syntax
# exists. What is compared is the multiset of conversions, not the order.
SPECIFIER = re.compile(
    r"%(?:(\d+)\$)?[-+ #0]*[\d.*]*(?:hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfeEgGcCsSpaAn%])")


def conversions(text):
    return sorted(match.group(2) for match in SPECIFIER.finditer(text) if match.group(2) != "%")


# Every line of a table has to be a line a table can have.
#
# A whitelist rather than a search for anything in particular, because of what
# happened without one: a merge left `<<<<<<< HEAD`, `=======` and `>>>>>>>` in
# both files and every check here went on passing, because the checks read the
# tables with a regular expression that simply skipped the lines it did not
# recognise. The system's own parser does not skip them — it stops. Measured on
# the committed file: 565 key lines present, 531 keys parsed, so the whole OBS
# panel and eight other strings rendered in English in a Chinese interface with
# nothing anywhere saying why.
#
# The rule is therefore about what a line *is*, not about markers: the next
# thing to land in the middle of one of these files will not be a conflict
# marker.
KEY_VALUE = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')

tables = {}
for path in sorted(pathlib.Path("Sources").glob("**/*.lproj/Localizable.strings")):
    language = path.parent.name.split(".")[0]
    table = {}
    in_comment = False
    for number, line in enumerate(path.read_text().splitlines(), 1):
        text = line.strip()
        if in_comment:
            if "*/" in text:
                in_comment = False
            continue
        if not text or text.startswith("//"):
            continue
        if text.startswith("/*"):
            if "*/" not in text:
                in_comment = True
            continue
        match = KEY_VALUE.match(text)
        if match is None:
            failures.append(
                f"{language}: line {number} is neither a comment nor a "
                f'"key" = "value"; pair, and the system\'s parser stops at it, '
                f"silently dropping every entry below — {text[:48]!r}")
            continue
        table[match.group(1)] = match.group(2)
    tables[language] = table
if "en" in tables:
    for language, table in tables.items():
        if language == "en":
            continue
        for key, english in tables["en"].items():
            if key not in table:
                failures.append(f"{language}: no translation for {key!r}")
            elif conversions(english) != conversions(table[key]):
                failures.append(
                    f"{language}: {key!r} has {conversions(english)} in English "
                    f"and {conversions(table[key])} translated")
        for key in table:
            if key not in tables["en"]:
                failures.append(f"{language}: {key!r} is not in the English table")

# A translation that is just the English again.
#
# `loc()` falls back to the key when a table has no entry, so a heading nobody
# translated renders in English beside translated ones and nothing complains —
# the key is present in both files, the format specifiers match, every check
# here passes. It was found by looking at a screenshot, which is not a check.
#
# Units and proper nouns are the same in both languages and are named rather
# than guessed at, because a rule that silently allows anything short would let
# a real heading through.
SAME_IN_BOTH = {
    "YunAudio", "LUFS", "dBFS", "MIT", "MIDI", "OBS", "dB", "Hz", "ms", "kHz",
    "cents", "frames", "CC", "PID",
}

if "en" in tables:
    for language, table in tables.items():
        if language == "en":
            continue
        for key, value in table.items():
            if key != value:
                continue
            # Only where there is something to translate. Format specifiers are
            # not words, and a key whose remaining words are *all* names that
            # are the same in both languages — a product, a unit — has nothing
            # to translate either. Generalised rather than listing "OBS %@"
            # beside "OBS": the next one would be "MIDI %d".
            words = re.findall(r"[A-Za-z]{2,}", re.sub(r"%[-+ #0-9.]*[a-zA-Z@]", "", key))
            if not words or all(word in SAME_IN_BOTH for word in words):
                continue
            failures.append(
                f"{language}: {key!r} is the English again — untranslated, "
                f"and loc() will show it beside translated text")

if failures:
    print("user-facing literals not passed through loc():\n")
    for failure in failures:
        print(f"  {failure}")
    print(f"\n{len(failures)} found")
    sys.exit(1)

print("every user-facing literal goes through loc()")
PYTHON
