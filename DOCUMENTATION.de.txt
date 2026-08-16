LOGCENTER.R4X
=============

LOGCENTER.R4X ist die Desktop-nahe Logansicht fuer R4OS.

Projektstruktur seit 0.51.18:
- `build.zig` baut die App als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad und Contract.

Build:

    cd Code\System\Software\LogCenter
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Software\LogCenter\zig-out\LOGCENTER.R4X

Contract:
- R4XStart-Entry: `logcenter_main`
- App-Klasse: `gui`
- R4L-Imports: `R4DESK:Query:1`, `R4DRAW:Query:1`
- Zielpfad im Image: `C:\R4OS\SOFTWARE\DESKTOP\LOGCENTER.R4X`

Console-Export:

    C:\R4OS\SOFTWARE\DESKTOP\LOGCENTER.R4X /EXPORT /CONSOLE

Schreibt die aktuelle Standardansicht nach `C:\LOGCTR.TXT`. Fuer gezielte
Exports akzeptiert der Console-Modus Filter:

    C:\R4OS\SOFTWARE\DESKTOP\LOGCENTER.R4X /EXPORT /CONSOLE /SOURCE=SERVICE /MIN=INFO /SEARCH=RDPSVC /OUT=C:\TEMP\RDPLOG.TXT

Fuer die 0.55.39-mstsc-Abnahme gibt es den Kurzmodus:

    C:\R4OS\SOFTWARE\DESKTOP\LOGCENTER.R4X /RDPTRACE /CONSOLE

Dieser exportiert Service-Logs mit `RDPSVC`-Suchfilter nach
`C:\TEMP\RDPTRACE.TXT`, damit nach einem manuellen mstsc-Abbruch die zuletzt
erreichte RDPSVC-Aktivierungsstage sichtbar bleibt. Der Pfad wird durch
`Run-LogCenterRdpTraceExport05539.ps1` headless geprueft: RDPSVC erzeugt im
Selftest einen klar markierten `trace stage=selftest`-Service-Record und
LOGCENTER exportiert genau diesen Datensatz aus LOGSVC.

`/CONSOLE` ist seit 0.59.12 der explizite Terminal-Launch-Hinweis fuer die
GUI-klassifizierte Anwendung. Terminal erkennt `/EXPORT` und `/RDPTRACE`
zusaetzlich kompatibel selbst; der explizite Schalter macht den gewuenschten
ownergebundenen Ausgabeweg in Skripten und Remote-Abnahmen sichtbar.
