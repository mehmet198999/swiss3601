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
    render-template.py [--mode OKTAL] [--env SCHLUESSEL]...
                       <vorlage> <ziel> [SCHLUESSEL=WERT ...]

  --mode 0640      Dateirechte des Ziels. Ohne Angabe werden die Rechte
                   einer bereits vorhandenen Zieldatei beibehalten,
                   sonst gilt 0644.

  --env SCHLUESSEL Den Wert NICHT von der Kommandozeile nehmen, sondern
                   aus der Umgebungsvariablen GG_TPL_<SCHLUESSEL>.

                   Das ist fuer Geheimnisse wichtig: /proc/<pid>/cmdline
                   ist auf Linux fuer jeden lokalen Benutzer lesbar, ein
                   Passwort in der Kommandozeile taucht also in "ps" auf.
                   /proc/<pid>/environ ist dagegen nur fuer den
                   Eigentuemer des Prozesses lesbar.

Exit 0 = geschrieben, 1 = Fehler.
"""

import io
import os
import re
import sys
import tempfile

PLACEHOLDER = re.compile(r"@[A-Z][A-Z0-9_]{2,}@")
ENV_PREFIX = "GG_TPL_"


def parse_args(argv):
    """Liefert (mode, values, template, target) oder wirft ValueError."""
    mode = None
    values = {}
    rest = []

    index = 1
    while index < len(argv):
        arg = argv[index]
        if arg == "--mode":
            if index + 1 >= len(argv):
                raise ValueError("--mode erwartet einen Wert, z.B. 0640")
            mode = int(argv[index + 1], 8)
            index += 2
        elif arg == "--env":
            if index + 1 >= len(argv):
                raise ValueError("--env erwartet einen Schluesselnamen")
            key = argv[index + 1]
            name = ENV_PREFIX + key
            if name not in os.environ:
                raise ValueError("Umgebungsvariable %s ist nicht gesetzt" % name)
            values[key] = os.environ[name]
            index += 2
        elif arg == "--":
            rest.extend(argv[index + 1:])
            break
        else:
            rest.append(arg)
            index += 1

    if len(rest) < 2:
        raise ValueError("Vorlage und Ziel muessen angegeben werden")

    template, target = rest[0], rest[1]
    for pair in rest[2:]:
        if "=" not in pair:
            raise ValueError("Ungueltiges Wertepaar (SCHLUESSEL=WERT): %s" % pair)
        key, value = pair.split("=", 1)
        values[key] = value

    return mode, values, template, target


def main(argv):
    try:
        mode, values, template, target = parse_args(argv)
    except ValueError as exc:
        sys.stderr.write("%s\n\n" % exc)
        sys.stderr.write(__doc__)
        return 1

    try:
        with io.open(template, "r", encoding="utf-8") as handle:
            text = handle.read()
    except OSError as exc:
        sys.stderr.write("Vorlage nicht lesbar: %s\n" % exc)
        return 1

    for key, value in values.items():
        text = text.replace("@%s@" % key, value)

    leftover = sorted(set(PLACEHOLDER.findall(text)))
    if leftover:
        sys.stderr.write(
            "Nicht ersetzte Platzhalter in %s: %s\n" % (template, " ".join(leftover))
        )
        return 1

    # Ohne ausdrueckliche Angabe die Rechte einer bereits vorhandenen
    # Zieldatei beibehalten - sonst wuerde ein erneuter Lauf eine bewusst
    # eng gesetzte Datei wieder oeffnen.
    if mode is None:
        try:
            mode = os.stat(target).st_mode & 0o7777
        except OSError:
            mode = 0o644

    directory = os.path.dirname(os.path.abspath(target))
    os.makedirs(directory, exist_ok=True)

    # mkstemp legt die Datei mit 0600 an. Die endgueltigen Rechte werden
    # erst unmittelbar vor dem Umbenennen gesetzt - so ist die Datei zu
    # keinem Zeitpunkt weiter geoeffnet als gewollt.
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".render-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, target)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
