#!/usr/bin/env python3
"""Kleine Statusseite des GSM-Gateways.

    http://gsm-gateway.local

Bewusst minimal gehalten:
  * kein Webframework, nur die Python-Standardbibliothek
  * nur lesender Zugriff auf /run/gsm-gateway/status.json
    (die Datei erzeugt gsm-gateway-status.service als root)
  * keine Konfigurationsmoeglichkeit ueber das Web
  * Anfragen aus dem oeffentlichen Internet werden abgewiesen

Damit gibt es keine Weboberflaeche, ueber die sich am Gateway etwas
verstellen liesse - die Seite zeigt nur an.
"""

import html
import io
import ipaddress
import json
import os
import re
import socket
import socketserver
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

STATUS_FILE = "/run/gsm-gateway/status.json"
CONFIG_FILE = "/etc/gsm-gateway/gateway.conf"
TEMPLATE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "template.html")

DEFAULT_PORT = 80

STATE_ORDER = {"FAIL": 0, "WARN": 1, "PENDING": 2, "SKIP": 3, "OK": 4}


def read_config():
    """Liest die wenigen benoetigten Werte aus gateway.conf."""
    values = {}
    try:
        with io.open(CONFIG_FILE, "r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                key = key.strip()
                value = value.strip().strip('"').strip("'")
                values[key] = value
    except OSError:
        pass
    return values


def listen_port(config):
    try:
        port = int(config.get("GG_WEB_PORT", DEFAULT_PORT))
    except ValueError:
        return DEFAULT_PORT
    if port < 1 or port > 65535:
        return DEFAULT_PORT
    return port


def client_is_local(address):
    """Nur private bzw. lokale Adressen duerfen die Seite sehen."""
    try:
        ip = ipaddress.ip_address(address)
    except ValueError:
        return False
    if ip.version == 6 and ip.ipv4_mapped is not None:
        ip = ip.ipv4_mapped
    return bool(ip.is_private or ip.is_loopback or ip.is_link_local)


def load_status():
    try:
        with io.open(STATUS_FILE, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def badge_class(state):
    return {
        "OK": "ok",
        "WARN": "warn",
        "FAIL": "fail",
        "PENDING": "pending",
        "SKIP": "skip",
    }.get(state, "skip")


# Der Abschnitt mit der Anrufliste laesst sich komplett ausblenden,
# ohne die Vorlage zu aendern.
CALLS_SECTION = re.compile(
    r"<!--CALLS_START-->.*?<!--CALLS_END-->", re.S)


def render_call_rows(calls):
    """Baut die Zeilen der Anrufliste."""
    if not calls:
        return ('<tr><td class="detail" colspan="4">'
                "Noch keine Anrufe aufgezeichnet.</td></tr>")

    rows = []
    for call in calls:
        direction = str(call.get("direction", ""))
        css = {"eingehend": "dir-in", "ausgehend": "dir-out"}.get(direction, "")
        missed = bool(call.get("missed"))
        state = "fail" if missed else ("ok" if call.get("answered") else "skip")
        rows.append(
            '<tr>'
            '<td class="when">{when}</td>'
            '<td class="num {css}">{number}</td>'
            '<td class="dur">{duration}</td>'
            '<td><span class="badge {state}">{disposition}</span></td>'
            "</tr>".format(
                when=html.escape(str(call.get("when", ""))[:16]),
                css=css,
                number=html.escape(str(call.get("number", "?"))),
                duration=html.escape(str(call.get("duration", "-"))),
                state=state,
                disposition=html.escape(str(call.get("disposition", ""))),
            )
        )
    return "\n".join(rows)


def render_rows(items):
    rows = []
    for item in items:
        state = str(item.get("state", "SKIP")).upper()
        rows.append(
            '<tr><td class="label">{label}</td>'
            '<td><span class="badge {cls}">{state}</span></td>'
            '<td class="detail">{detail}</td></tr>'.format(
                label=html.escape(str(item.get("label", item.get("id", "?")))),
                cls=badge_class(state),
                state=html.escape(state),
                detail=html.escape(str(item.get("detail", ""))),
            )
        )
    return "\n".join(rows)


def render_page():
    try:
        with io.open(TEMPLATE_FILE, "r", encoding="utf-8") as handle:
            template = handle.read()
    except OSError:
        template = (
            "<html><body><h1>GSM Gateway</h1>@CHECK_ROWS@@MANUAL_ROWS@</body></html>"
        )

    config = read_config()
    if config.get("GG_WEB_SHOW_CALLS", "yes") != "yes":
        template = CALLS_SECTION.sub("", template)

    data = load_status()
    if data is None:
        return template.replace("@CHECK_ROWS@", (
            '<tr><td class="label">Status</td>'
            '<td><span class="badge pending">WARTEN</span></td>'
            '<td class="detail">Noch keine Statusdaten. '
            "gsm-gateway-status.service laeuft alle 60 Sekunden.</td></tr>"
        )).replace("@MANUAL_ROWS@", "").replace(
            "@CALL_ROWS@", render_call_rows([])
        ).replace(
            "@GENERATED@", "-"
        ).replace("@HOSTNAME@", html.escape(socket.gethostname()))

    cdr = data.get("cdr") or {}
    return (
        template.replace("@CHECK_ROWS@", render_rows(data.get("checks", [])))
        .replace("@MANUAL_ROWS@", render_rows(data.get("manual", [])))
        .replace("@CALL_ROWS@", render_call_rows(cdr.get("calls", [])))
        .replace("@GENERATED@", html.escape(str(data.get("generated", "-"))))
        .replace("@HOSTNAME@", html.escape(str(data.get("hostname", socket.gethostname()))))
    )


class StatusHandler(BaseHTTPRequestHandler):
    server_version = "gsm-gateway-status"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        # Jede Anfrage im Journal waere nur Rauschen.
        pass

    def _send(self, code, body, content_type="text/html; charset=utf-8"):
        payload = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'"
        )
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if not client_is_local(self.client_address[0]):
            self._send(403, "<h1>403</h1><p>Nur aus dem lokalen Netz erreichbar.</p>")
            return

        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            self._send(200, render_page())
        elif path == "/status.json":
            data = load_status()
            if data is None:
                self._send(503, json.dumps({"error": "keine Statusdaten"}),
                           "application/json; charset=utf-8")
            else:
                self._send(200, json.dumps(data, indent=1),
                           "application/json; charset=utf-8")
        elif path == "/health":
            self._send(200, "ok", "text/plain; charset=utf-8")
        else:
            self._send(404, "<h1>404</h1>")

    def do_POST(self):
        # Die Seite zeigt nur an - es gibt nichts zu senden.
        self._send(405, "<h1>405</h1><p>Nur Anzeige.</p>")


class DualStackServer(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    address_family = socket.AF_INET6

    def server_bind(self):
        try:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        except OSError:
            pass
        HTTPServer.server_bind(self)


def main():
    port = listen_port(read_config())
    try:
        server = DualStackServer(("::", port), StatusHandler)
    except OSError as exc:
        # Kein IPv6? Dann eben nur IPv4.
        if exc.errno not in (97, 99):
            sys.stderr.write("Kann Port %d nicht binden: %s\n" % (port, exc))
            return 1
        DualStackServer.address_family = socket.AF_INET
        try:
            server = DualStackServer(("0.0.0.0", port), StatusHandler)
        except OSError as exc2:
            sys.stderr.write("Kann Port %d nicht binden: %s\n" % (port, exc2))
            return 1

    sys.stderr.write("Statusseite laeuft auf Port %d\n" % port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
