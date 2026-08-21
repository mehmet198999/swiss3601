#!/usr/bin/env python3
"""Wertet die Asterisk-Anrufaufzeichnung (CDR) aus.

Asterisk schreibt jeden Anruf als Zeile nach
/var/log/asterisk/cdr-csv/Master.csv. Dieses Script macht daraus eine
lesbare Anrufliste - eingehend, ausgehend, verpasst.

Aufruf:
    cdr-report.py [Optionen]

    --file PFAD     andere CSV-Datei (Vorgabe: Master.csv)
    --limit N       nur die letzten N Anrufe (Vorgabe: 20)
    --missed        nur verpasste eingehende Anrufe
    --json          Ausgabe als JSON (fuer die Statusseite)
    --mask N        die letzten N Ziffern der Rufnummer durch x
                    ersetzen (Datenschutz auf der Statusseite)

Exit 0 = Liste erzeugt (auch wenn leer), 1 = Datei nicht lesbar.
"""

import csv
import io
import json
import os
import sys
from datetime import datetime

DEFAULT_FILE = "/var/log/asterisk/cdr-csv/Master.csv"

# Feldreihenfolge von cdr_csv. Weitere Felder am Ende (uniqueid,
# userfield) werden nicht gebraucht und einfach ignoriert.
FIELDS = [
    "accountcode", "src", "dst", "dcontext", "clid", "channel",
    "dstchannel", "lastapp", "lastdata", "start", "answer", "end",
    "duration", "billsec", "disposition", "amaflags",
]

# Asterisk-Ergebnis -> verstaendlicher Text
DISPOSITION_TEXT = {
    "ANSWERED": "angenommen",
    "NO ANSWER": "nicht angenommen",
    "BUSY": "besetzt",
    "FAILED": "fehlgeschlagen",
    "CONGESTION": "keine Verbindung",
}


def parse_args(argv):
    options = {
        "file": DEFAULT_FILE,
        "limit": 20,
        "missed": False,
        "json": False,
        "mask": 0,
    }
    index = 1
    while index < len(argv):
        arg = argv[index]
        if arg == "--file":
            options["file"] = argv[index + 1]
            index += 2
        elif arg == "--limit":
            options["limit"] = max(1, int(argv[index + 1]))
            index += 2
        elif arg == "--mask":
            options["mask"] = max(0, int(argv[index + 1]))
            index += 2
        elif arg == "--missed":
            options["missed"] = True
            index += 1
        elif arg == "--json":
            options["json"] = True
            index += 1
        elif arg in ("-h", "--help"):
            sys.stdout.write(__doc__)
            raise SystemExit(0)
        else:
            raise ValueError("Unbekannte Option: %s" % arg)
    return options


def mask_number(number, digits):
    if digits <= 0 or not number:
        return number
    if len(number) <= digits:
        return "x" * len(number)
    return number[:-digits] + "x" * digits


def format_duration(seconds):
    try:
        seconds = int(seconds)
    except (TypeError, ValueError):
        return "-"
    if seconds <= 0:
        return "-"
    minutes, rest = divmod(seconds, 60)
    if minutes >= 60:
        hours, minutes = divmod(minutes, 60)
        return "%d:%02d:%02d" % (hours, minutes, rest)
    return "%d:%02d" % (minutes, rest)


def clean_number(value):
    """Rufnummern aus dem Mobilfunknetz kommen manchmal mit Zusaetzen."""
    value = (value or "").strip()
    if value in ("", "s", "unknown", "<unknown>"):
        return ""
    return value


def classify(row):
    """Ermittelt Richtung und Gegenstelle eines Anrufs."""
    channel = row.get("channel", "") or ""
    dstchannel = row.get("dstchannel", "") or ""

    if channel.startswith("Mobile/"):
        # Der Anruf kam ueber das Mobiltelefon herein.
        number = clean_number(row.get("src")) or clean_number(row.get("clid"))
        return "eingehend", number
    if dstchannel.startswith("Mobile/"):
        # Vom Softphone hinaus ins Mobilfunknetz.
        return "ausgehend", clean_number(row.get("dst"))
    # Weder rein noch raus - z.B. der Echo-Test auf 600.
    return "intern", clean_number(row.get("dst"))


def parse_time(value):
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M:%S.%f"):
        try:
            return datetime.strptime(value.strip(), fmt)
        except (ValueError, AttributeError):
            continue
    return None


def read_calls(path, limit, missed_only, mask):
    if not os.path.exists(path):
        return None

    calls = []
    with io.open(path, "r", encoding="utf-8", errors="replace", newline="") as handle:
        for raw in csv.reader(handle):
            if not raw or len(raw) < len(FIELDS):
                continue
            row = dict(zip(FIELDS, raw))

            direction, number = classify(row)
            disposition = (row.get("disposition") or "").strip()
            billsec = row.get("billsec", "0")
            answered = disposition == "ANSWERED"

            started = parse_time(row.get("start", ""))
            calls.append({
                "when": row.get("start", "").strip(),
                "sort_key": started.timestamp() if started else 0.0,
                "direction": direction,
                "number": mask_number(number, mask) or "unbekannt",
                "duration": format_duration(billsec),
                "duration_seconds": int(billsec) if str(billsec).isdigit() else 0,
                "disposition": DISPOSITION_TEXT.get(disposition, disposition or "unbekannt"),
                "answered": answered,
                "missed": direction == "eingehend" and not answered,
            })

    calls.sort(key=lambda c: c["sort_key"], reverse=True)
    if missed_only:
        calls = [c for c in calls if c["missed"]]
    calls = calls[:limit]
    for call in calls:
        call.pop("sort_key", None)
    return calls


def render_text(calls, missed_only):
    if not calls:
        if missed_only:
            return "Keine verpassten Anrufe.\n"
        return ("Noch keine Anrufe aufgezeichnet.\n"
                "Die Liste fuellt sich, sobald das erste Gespraech gefuehrt wurde.\n")

    lines = []
    header = "%-19s  %-10s  %-18s  %8s  %s" % (
        "Zeitpunkt", "Richtung", "Nummer", "Dauer", "Ergebnis")
    lines.append(header)
    lines.append("-" * len(header))
    for call in calls:
        marker = " *" if call["missed"] else ""
        lines.append("%-19s  %-10s  %-18s  %8s  %s%s" % (
            call["when"][:19],
            call["direction"],
            call["number"][:18],
            call["duration"],
            call["disposition"],
            marker,
        ))
    missed = sum(1 for c in calls if c["missed"])
    lines.append("")
    if missed:
        lines.append("* = verpasster Anruf  (%d in dieser Liste)" % missed)
    return "\n".join(lines) + "\n"


def main(argv):
    try:
        options = parse_args(argv)
    except (ValueError, IndexError) as exc:
        sys.stderr.write("%s\n\n" % exc)
        sys.stderr.write(__doc__)
        return 1

    calls = read_calls(options["file"], options["limit"],
                       options["missed"], options["mask"])

    if calls is None:
        message = (
            "Es gibt noch keine Anrufaufzeichnung (%s).\n"
            "Moegliche Gruende:\n"
            "  * es wurde noch kein Gespraech gefuehrt\n"
            "  * die Aufzeichnung ist abgeschaltet (GG_CDR_ENABLE)\n"
            "  * Asterisk laeuft noch nicht\n" % options["file"]
        )
        if options["json"]:
            sys.stdout.write(json.dumps({"available": False, "calls": []}) + "\n")
            return 0
        sys.stderr.write(message)
        return 1

    if options["json"]:
        sys.stdout.write(json.dumps({"available": True, "calls": calls}) + "\n")
    else:
        sys.stdout.write(render_text(calls, options["missed"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
