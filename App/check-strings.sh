#!/bin/bash
#
# Fails on any user-facing string literal that never goes through loc().
#
# The flow check compares the two string tables against each other and walks
# every label built from an enum, but neither can see a literal that was passed
# straight to a view — and four of those survived every other check, including
# the whole preferences sidebar and "Open at login" sitting in English beside
# Chinese content. The literals that were wrapped correctly look exactly like
# the ones that were not, so this is a job for a scanner rather than for
# reading.
#
#   ./App/check-strings.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - "$@" <<'PYTHON'
import pathlib
import re
import sys

# Views that take a user-visible string as their first argument.
CONSTRUCTORS = (
    "Text", "Toggle", "Button", "YunBadge", "YunStatusPill", "YunDetailRow",
    "YunEmptyState", "YunDisclosure", "YunCard",
)
PATTERN = re.compile(
    r"\b(" + "|".join(CONSTRUCTORS) + r")\(\s*\n?\s*(\"(?:[^\"\\\\]|\\\\.)+\")"
)
# Literals that carry no words: symbols, numbers, units, interpolation only.
WORDLESS = re.compile(r'"[\s\d%@.,:;·×→←+\-/()]*"')

failures = []
for directory in ("Sources/YunAudioApp", "Sources/YunDesign"):
    for path in sorted(pathlib.Path(directory).glob("*.swift")):
        source = path.read_text()
        for match in PATTERN.finditer(source):
            literal = match.group(2)
            if WORDLESS.fullmatch(literal):
                continue
            # An interpolation with no literal words is a value, not a label.
            if re.fullmatch(r'"\\\\\(.*\)"', literal):
                continue
            line = source[: match.start()].count("\n") + 1
            failures.append(f"{path}:{line}: {match.group(1)}({literal})")

if failures:
    print("user-facing literals not passed through loc():\n")
    for failure in failures:
        print(f"  {failure}")
    print(f"\n{len(failures)} found")
    sys.exit(1)

print("every user-facing literal goes through loc()")
PYTHON
