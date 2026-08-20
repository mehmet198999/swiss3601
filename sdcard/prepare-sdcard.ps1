<#
.SYNOPSIS
    Legt das GSM-Gateway-Projekt auf eine frisch geschriebene SD-Karte
    (Windows-Variante von prepare-sdcard.sh).

.DESCRIPTION
    REIHENFOLGE - bitte genau so:

      1. Raspberry Pi Imager: Raspberry Pi OS Lite auf die SD-Karte
         schreiben, inklusive Vorkonfiguration (Hostname, Benutzer,
         SSH, WLAN, Zeitzone).
      2. SD-Karte danach neu einstecken. Windows zeigt die
         Boot-Partition als Laufwerk mit config.txt und cmdline.txt.
         Die zweite (Linux-)Partition sieht Windows nicht - das ist
         normal und hier auch nicht noetig.
      3. Dieses Script in einer PowerShell ausfuehren.

    Das Script kopiert das Projekt nach <Laufwerk>\gsm-gateway und
    haengt sich in die firstrun.sh des Imagers ein.

.PARAMETER BootDrive
    Laufwerksbuchstabe oder Pfad der Boot-Partition, z.B. "E:".
    Ohne Angabe wird automatisch gesucht.

.PARAMETER DryRun
    Nur anzeigen, was passieren wuerde.

.EXAMPLE
    .\sdcard\prepare-sdcard.ps1

.EXAMPLE
    .\sdcard\prepare-sdcard.ps1 -BootDrive E: -DryRun
#>

[CmdletBinding()]
param(
    [string]$BootDrive = "",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$MarkerBegin = "# >>> gsm-gateway bootstrap >>>"

function Write-Info  { param($m) Write-Host "[prepare] $m" -ForegroundColor Cyan }
function Write-Ok    { param($m) Write-Host "[prepare] $m" -ForegroundColor Green }
function Write-Warn2 { param($m) Write-Host "[prepare] $m" -ForegroundColor Yellow }
function Fail        { param($m) Write-Host "[prepare] FEHLER: $m" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------------
#  Projektverzeichnis bestimmen
# ---------------------------------------------------------------------
$ProjectDir = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $ProjectDir "install\firstboot-install.sh"))) {
    Fail "Die Projektdateien wurden nicht gefunden. Bitte das Script aus dem Projektverzeichnis heraus starten."
}
Write-Info "Projektverzeichnis: $ProjectDir"

# ---------------------------------------------------------------------
#  Boot-Partition finden
# ---------------------------------------------------------------------
function Test-BootPartition {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    # Nicht bereite Laufwerke (leeres DVD-Laufwerk, getrennte
    # Netzlaufwerke) duerfen hier keinen Abbruch ausloesen.
    try {
        return (Test-Path (Join-Path $Path "config.txt")) -and
               (Test-Path (Join-Path $Path "cmdline.txt"))
    }
    catch {
        return $false
    }
}

if ([string]::IsNullOrWhiteSpace($BootDrive)) {
    $found = @()
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        $root = $drive.Root
        if (Test-BootPartition $root) { $found += $root }
    }
    if ($found.Count -eq 0) {
        Fail @"
Es wurde keine Raspberry-Pi-Boot-Partition gefunden.

Bitte pruefen:
  * Ist die SD-Karte eingesteckt?
  * Zeigt der Explorer ein Laufwerk mit den Dateien
    config.txt und cmdline.txt?
  * Notfalls das Laufwerk direkt angeben:
        .\sdcard\prepare-sdcard.ps1 -BootDrive E:
"@
    }
    if ($found.Count -gt 1) {
        Write-Warn2 "Mehrere Boot-Partitionen gefunden: $($found -join ', ')"
        Fail "Bitte die richtige mit -BootDrive angeben."
    }
    $BootDrive = $found[0]
}

if (-not (Test-BootPartition $BootDrive)) {
    Fail "In '$BootDrive' liegen keine config.txt und cmdline.txt - das ist keine Raspberry-Pi-Boot-Partition."
}
Write-Info "Boot-Partition: $BootDrive"

# ---------------------------------------------------------------------
#  Projektdateien kopieren
# ---------------------------------------------------------------------
$Target = Join-Path $BootDrive "gsm-gateway"
Write-Info "Kopiere Projektdateien nach $Target"

if (-not $DryRun) {
    if (Test-Path $Target) { Remove-Item -Recurse -Force $Target }
    New-Item -ItemType Directory -Path $Target -Force | Out-Null

    Get-ChildItem -Path $ProjectDir -Force |
        Where-Object { $_.Name -notin @(".git", ".github") } |
        ForEach-Object {
            Copy-Item -Path $_.FullName -Destination $Target -Recurse -Force
        }
}
Write-Ok "Projektdateien kopiert."

# ---------------------------------------------------------------------
#  firstrun.sh ergaenzen
# ---------------------------------------------------------------------
# WICHTIG: Shell-Scripts brauchen Unix-Zeilenenden (LF) und duerfen
# keine Byte-Order-Mark enthalten. Set-Content wuerde CRLF schreiben,
# deshalb wird hier direkt ueber .NET geschrieben.
function Write-UnixText {
    param([string]$Path, [string]$Text)
    $normalized = $Text -replace "`r`n", "`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $normalized, $utf8NoBom)
}

$Snippet = @'
# >>> gsm-gateway bootstrap >>>
# Von prepare-sdcard.ps1 eingefuegt. Kopiert das Gateway-Projekt nach
# /opt/gsm-gateway und aktiviert den First-Boot-Dienst.
# Das Ergebnis steht in <boot>/gsm-gateway/bootstrap.log.
# Ein Fehler darf die Erstkonfiguration des Imagers NICHT abbrechen -
# sonst startet der Pi ohne Benutzer und ohne SSH. Der Rueckgabewert
# wird deshalb protokolliert statt weitergereicht.
GG_SRC=""
for _gg_dir in /boot/firmware/gsm-gateway /boot/gsm-gateway; do
    if [ -f "$_gg_dir/install/bootstrap.sh" ]; then
        GG_SRC="$_gg_dir"
        break
    fi
done
if [ -n "$GG_SRC" ]; then
    /bin/bash "$GG_SRC/install/bootstrap.sh" > "$GG_SRC/bootstrap.log" 2>&1
    echo "bootstrap-exit=$?" >> "$GG_SRC/bootstrap.log"
else
    echo "gsm-gateway: Projektdateien auf der Boot-Partition nicht gefunden" >&2
fi
# <<< gsm-gateway bootstrap <<<
'@

$FirstRun = Join-Path $BootDrive "firstrun.sh"
$CmdLine  = Join-Path $BootDrive "cmdline.txt"

if (Test-Path $FirstRun) {
    $existing = [System.IO.File]::ReadAllText($FirstRun)
    if ($existing.Contains($MarkerBegin)) {
        Write-Info "firstrun.sh enthaelt den Bootstrap bereits - wird nicht doppelt eingefuegt."
    }
    else {
        Write-Info "Ergaenze die firstrun.sh des Imagers."
        if (-not $DryRun) {
            Copy-Item $FirstRun "$FirstRun.gsm-gateway-backup" -Force

            $lines = $existing -replace "`r`n", "`n" -split "`n"
            $head  = $lines[0]
            $rest  = if ($lines.Count -gt 1) { $lines[1..($lines.Count - 1)] -join "`n" } else { "" }
            Write-UnixText $FirstRun ($head + "`n`n" + $Snippet + "`n`n" + $rest)
        }
        Write-Ok "firstrun.sh ergaenzt (Sicherung: firstrun.sh.gsm-gateway-backup)."
    }
}
else {
    Write-Warn2 "Es gibt keine firstrun.sh - offenbar wurde der Raspberry Pi Imager"
    Write-Warn2 "ohne Vorkonfiguration verwendet. Es wird eine eigene angelegt."
    Write-Warn2 "ACHTUNG: Ohne die Imager-Vorkonfiguration gibt es keinen Benutzer"
    Write-Warn2 "und keinen SSH-Zugang. Besser: die Karte im Imager neu schreiben"
    Write-Warn2 "und dort Hostname, Benutzer und SSH konfigurieren."

    $own = @"
#!/bin/bash
# Von gsm-gateway/prepare-sdcard.ps1 angelegt.
set +e

$Snippet

rm -f /boot/firmware/firstrun.sh /boot/firstrun.sh
sed -i "s| systemd.run[^ ]*||g" /boot/firmware/cmdline.txt 2>/dev/null
sed -i "s| systemd.run[^ ]*||g" /boot/cmdline.txt 2>/dev/null
exit 0
"@
    if (-not $DryRun) {
        Write-UnixText $FirstRun $own

        $cmd = ([System.IO.File]::ReadAllText($CmdLine)).Trim()
        if ($cmd -notmatch "systemd\.run=") {
            Copy-Item $CmdLine "$CmdLine.gsm-gateway-backup" -Force
            $cmd = $cmd + " systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target"
            Write-UnixText $CmdLine ($cmd + "`n")
            Write-Info "cmdline.txt um den Aufruf der firstrun.sh ergaenzt."
        }
    }
    Write-Ok "Eigene firstrun.sh angelegt."
}

Write-Host @"

=======================================================
 SD-Karte vorbereitet
=======================================================

Naechste Schritte:

  1. SD-Karte in Windows sicher auswerfen
     (Rechtsklick auf das Laufwerk -> Auswerfen)
  2. SD-Karte in den Raspberry Pi stecken
  3. ASUS USB-BT500 einstecken
  4. Netzwerkkabel einstecken
  5. Strom anschliessen und warten

Der Pi installiert danach alles selbst. Je nachdem, ob Asterisk
gebaut werden muss, dauert das 30 Minuten bis mehrere Stunden.

Fortschritt ansehen (sobald SSH erreichbar ist):

    ssh gateway@gsm-gateway.local
    sudo tail -f /var/log/gsm-gateway/install.log

=======================================================

"@
