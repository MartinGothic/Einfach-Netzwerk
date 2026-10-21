# Prüfung von Einfach Netzwerk 2.0.20

[Download und Übersicht](../README.md) · [Anleitung](ANLEITUNG.md)

## Repository-Aufbau ab 21. Oktober 2026

Die öffentlichen Quellen liegen unter `src/`, die Prüfskripte unter `tests/`, die Dokumentation unter `docs/` und die Entwicklungswerkzeuge unter `tools/`. `build.ps1` und `package.ps1` werden weiterhin im Repository-Hauptordner ausgeführt. Die Ausgabe bleibt unter `dist/`. Bereits veröffentlichte EXE-Dateien und ihre bestehenden Downloadadressen bleiben erhalten.

Die Ordnerumstellung verändert keine Programmlogik. Geprüft am 21. Oktober 2026:

- Der Hauptbuild bestand mit allen 25 eingebauten Selbsttests.
- Alle 35 Prüfskripte unter `tests/` wurden mit dem Windows-PowerShell-5.1-Parser geprüft: keine Syntaxfehler.
- 14 ausgewählte isolierte Prüfskripte bestanden insgesamt 1.339 Prüfungen. Die Verteilung ist unten dokumentiert.
- Das Quellcode-ZIP enthielt genau 110 erlaubte Dateien: 68 in `src/`, 35 in `tests/`, zwei in `docs/`, eine in `tools/` und vier im Hauptordner. Alle Dateien stimmten bytegenau mit dem Arbeitsstand überein. `downloads/`, `dist/`, `.git/` und interne QA-Dateien waren nicht enthalten.
- Das Quellcode-ZIP wurde unabhängig in einen anderen Ordner mit Leerzeichen entpackt. Aus einem fremden Arbeitsverzeichnis liefen ein frischer Build mit 25 bestandenen Selbsttests und die anschließende Paketierung erfolgreich. Die EXE meldet Version 2.0.20.0; alle drei eingebetteten Windows-Module stimmen bytegenau mit den Dateien unter `src/` überein.

| Isolierte Prüfung | Bestandene Prüfungen |
| --- | ---: |
| Backend | 28 |
| Netzwerkerkennung | 139 |
| Peer-Datenmeldung mit nachgebildetem Transport | 67 |
| Client-Zugriff | 102 |
| Netzwerkdienste | 92 |
| SMB-Verbindungsprüfung | 3 |
| Fortschritt | 71 |
| Lokale Richtlinien | 37 |
| Dienste im Assistenten | 33 |
| Client-Namenszugriff | 54 |
| Client-Dienstvorprüfung | 84 |
| Diagnosebericht | 235 |
| Client-Namensbericht | 157 |
| Empfängerbericht | 237 |

Diese Prüfungen haben keine echten Windows-Netzwerkeinstellungen oder Netzwerkverbindungen verändert. Die Zahlen werden nicht mit den früheren Oberflächenprüfungen zusammengerechnet. Nach der Ordnerumstellung wurden nicht sämtliche Oberflächen- oder Windows-Integrationstests erneut ausgeführt.

Die folgenden Ergebnisse dokumentieren die zuvor geprüfte Programmversion. Ein neuer Build erzeugt eine eigene EXE; der unten genannte SHA-256 bezeichnet ausschließlich die damals freigegebene Datei.

## Bisherige Programmprüfung vom 8. Oktober 2026

Geprüft am 8. Oktober 2026. Freie Zugangs- und Rechtewahl, sichtbare Nur-lesen-Frage, freiwillige Passwortfunktionen und drei getrennte Verbindungsnachweise. Ohne Passwort bleibt die Vorauswahl; Reparaturen erhalten die gespeicherten Rechte.

- 25 Selbsttests der EXE bestanden. Version 2.0.20.0, 2.393.088 Byte; SHA-256 `69CB28F1843448394B079F2C23DC9F6FE9830E7C0775779BE7B17F5C028BF2AE`. Alle drei eingebetteten Windows-Module stimmen bytegenau mit den unveränderten Quellen überein.
- 1.358 Assistentenprüfungen ohne Layoutbefunde bestanden: sieben Sprachen bei Mindestgröße, freie reversible Rechtewahl, Gast-Vorauswahl, manuelle und erzeugte Passwörter, Zurück/Weiter und Sprachwechsel. Zwei Einrichtungsergebnisse und sieben Kopieraktionen waren Speicher- bzw. Clipboard-Attrappen. Auch angezeigte Passwörter bleiben aus Berichten entfernt. Gast- und Passwortansicht wurden zusätzlich visuell geprüft.
- 900 Hauptfensterprüfungen bestanden. Neue Freigaben beginnen ohne Schreibrechte; die Rechtefrage reagiert auf beide Auswahlen. Sprachwechsel erhält die gewählten Rechte. Gespeicherte beschreibbare Freigaben bleiben beim bewussten Auswählen beschreibbar. Der Client-Reparaturbutton ist in der geöffneten Prüfung sichtbar und lesbar.
- 217 Prüfungen des ruhigen Programmstarts bestanden: echte Shown-Fenster in sieben Sprachen starten weder Worker noch Netzwerksuche.
- 240 vorbeugende Assistentenprüfungen mit vier synthetischen Einrichtungsergebnissen und 14 Prüfungen der Verbindungserklärung bestanden, ohne Layoutbefunde.
- 113 Berichts- und Eingabeprüfungen gegen die tatsächliche Assembly bestanden. Passwort und verschlüsselter Passwortwert bleiben entfernt; Ziel, Originalfehler und unveränderliche Ergebnisgeschichte bleiben erhalten. Dokumentierte Diagnosepfade für Sicherungen bleiben sichtbar.
- 166 Prüfungen der vorhandenen Empfänger-, Reparatur-, Einwilligungs- und Suchabläufe bestanden, ohne Layoutbefunde. Alle Netzwerksuchen und Worker-Ergebnisse waren injiziert; keine echte Anmeldung, Administratorabfrage oder Windows-Änderung wurde ausgeführt.
- 734 Prüfungen der Verbindungsübersicht bestanden: getrennte Nachweise, passende und widersprüchliche Identitäten, veraltete Ergebnisse, sieben echte Shown-Sprachansichten bei Mindestgröße sowie simulierte 150-%-Skalierung. Alle drei Textzeilen passen in ihre Karte. Laufende Prüfungen verhindern das vorzeitige Schließen; nach Abschluss funktionieren Ergebnisanzeige und Schließen. Übersicht bzw. passende Reparaturfrage werden nach abgeschlossenem Layout sichtbar; der Fokus springt zur passenden Aktion. Fünf Workeraufrufe und neun Suchergebnisse waren ausschließlich injiziert, echte Netzwerksuchen: null. Die deutsche vollständige Ergebnisansicht wurde zusätzlich visuell geprüft.

Lokale Vorbereitung, Port-Erreichbarkeit und tatsächlicher Ordnerzugriff bleiben getrennt. Eine über ihre genaue private IP bestätigte native Freigabenauflistung darf den gemeldeten Computernamen anzeigen, bestätigt aber noch keinen Ordnerzugriff.

Alle neuen Prüfungen verwenden isolierte Speicher-, Vorschau- oder injizierte UI-Ergebnisse. Es wurden keine echten Netzwerksuchen, Windows-Netzwerkeinstellungen, Freigaben oder Zwischenablageinhalte geändert. Die simulierte 150-%-Layoutprüfung ersetzt keinen Test der tatsächlichen Windows-DPI-Einstellung und keinen Fernzugriffsversuch auf anderen Computern.

## Prüfung der öffentlichen Quellen

Die bereinigte Quellfassung wurde am 8. Oktober 2026 mit dem bestehenden Buildskript unabhängig kompiliert. Alle 25 eingebauten Selbsttests bestanden. Konsistent bereinigte Erkennungstestdaten bestanden zuvor 139 isolierte Prüfungen; diese Testdaten und die betroffenen Erkennungskomponenten sind im endgültigen Quellstand unverändert. Persönliche Rechnernamen in Beispielen wurden durch synthetische Namen ersetzt. Die freigegebene Original-EXE und ihre eingebetteten Windows-Module bleiben bytegenau erhalten. Die öffentliche Ausgabe enthält keine persönlichen Diagnoseberichte, Laufzeitjournale, Zustandsdateien, JSON-Ergebnisse, Screenshots oder frühere reale Netzwerkepisoden.
