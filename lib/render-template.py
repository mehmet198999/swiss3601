#!/usr/bin/env python3
"""Ersetzt @PLATZHALTER@ in einer Vorlage.

Warum ein eigenes Script statt sed?
  * Werte duerfen mehrzeilig sein (z.B. mehrere ACL-Zeilen)
  * keine Probleme mit Sonderzeichen wie & | / \\ im Wert
    (Passwoerter enthalten so etwas regelmaessig)
  * es wird geprueft, ob am Ende noch ein Platzhalter uebrig ist -
    eine halb gerenderte Konfigurationsdatei waere schlimmer als ein
    klarer Abbruch

Aufruf:
    render-template.py <vorlage> <ziel> SCHLUESSEL=WERT [...]

Exit 0 = geschrieben, 1 = Fehler.
"""

import io
import os
import re
import sys
import tempfile

PLACEHOLDER = re.compile(r"@[A-Z][A-Z0-9_]{2,}@")


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 1

    template, target = argv[1], argv[2]
    pairs = argv[3:]

    try:
        with io.open(template, "r", encoding="utf-8") as handle:
            text = handle.read()
    except OSError as exc:
        sys.stderr.write("Vorlage nicht lesbar: %s\n" % exc)
        return 1

    for pair in pairs:
        if "=" not in pair:
            sys.stderr.write("Ungueltiges Wertepaar (SCHLUESSEL=WERT): %s\n" % pair)
            return 1
        key, value = pair.split("=", 1)
        text = text.replace("@%s@" % key, value)

    leftover = sorted(set(PLACEHOLDER.findall(text)))
    if leftover:
        sys.stderr.write(
            "Nicht ersetzte Platzhalter in %s: %s\n" % (template, " ".join(leftover))
        )
        return 1

    directory = os.path.dirname(os.path.abspath(target))
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".render-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(tmp, 0o644)
        os.replace(tmp, target)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
