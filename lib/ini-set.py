#!/usr/bin/env python3
"""Setzt einen Schluessel in einer INI-artigen Konfigurationsdatei.

Wird fuer /etc/bluetooth/main.conf benutzt. BlueZ kennt keine
drop-in-Verzeichnisse, deshalb muss die Datei direkt bearbeitet werden.

Eigenschaften:
  * Kommentare und Reihenfolge bleiben erhalten
  * ein auskommentierter Schluessel (#Key = ...) wird aktiviert
  * fehlende Abschnitte werden am Ende angehaengt
  * schreibt nur, wenn sich tatsaechlich etwas aendert
    (Exit 0 = geaendert oder bereits korrekt, Exit 1 = Fehler)

Aufruf:
    ini-set.py <datei> <abschnitt> <schluessel> <wert>
"""

import os
import re
import sys
import tempfile


def main(argv):
    if len(argv) != 5:
        sys.stderr.write("Aufruf: ini-set.py <datei> <abschnitt> <schluessel> <wert>\n")
        return 2

    path, section, key, value = argv[1:5]

    if not os.path.exists(path):
        sys.stderr.write("Datei nicht gefunden: %s\n" % path)
        return 1

    with open(path, "r", encoding="utf-8", errors="surrogateescape") as handle:
        lines = handle.read().splitlines()

    section_re = re.compile(r"^\s*\[(?P<name>[^\]]+)\]\s*$")
    # Trifft "Key = wert" und "# Key = wert" / ";Key=wert".
    key_re = re.compile(
        r"^(?P<lead>\s*)(?P<comment>[#;]\s*)?(?P<key>%s)(?P<sep>\s*=\s*)(?P<value>.*)$"
        % re.escape(key)
    )

    desired = "%s = %s" % (key, value)
    in_section = False
    section_found = False
    written = False
    last_section_line = -1
    out = []

    for line in lines:
        match = section_re.match(line)
        if match:
            # Abschnitt verlassen, ohne den Schluessel gefunden zu haben?
            if in_section and not written:
                out.append(desired)
                written = True
            in_section = match.group("name").lower() == section.lower()
            if in_section:
                section_found = True
                last_section_line = len(out)
            out.append(line)
            continue

        if in_section and not written:
            key_match = key_re.match(line)
            if key_match:
                out.append(desired)
                written = True
                continue

        out.append(line)

    if in_section and not written:
        out.append(desired)
        written = True

    if not section_found:
        if out and out[-1].strip():
            out.append("")
        out.append("[%s]" % section)
        out.append(desired)
        written = True
    elif not written:
        out.insert(last_section_line + 1, desired)
        written = True

    new_text = "\n".join(out) + "\n"
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as handle:
        old_text = handle.read()

    if new_text == old_text:
        print("unchanged")
        return 0

    directory = os.path.dirname(os.path.abspath(path))
    stat = os.stat(path)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".ini-set-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape") as handle:
            handle.write(new_text)
        os.chmod(tmp, stat.st_mode & 0o7777)
        os.chown(tmp, stat.st_uid, stat.st_gid)
        os.replace(tmp, path)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    print("changed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
