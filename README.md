# Einfach Netzwerk

## Windows-Dateifreigaben einfach einrichten / Windows file sharing made simple

**[⬇ Programm für Windows herunterladen · Download Windows app (2.0.20)](https://github.com/MartinGothic/Einfach-Netzwerk/releases/download/v2.0.20/Einfach-Netzwerk-2.0.20.exe)**

[ZIP mit Anleitung / ZIP with instructions](https://github.com/MartinGothic/Einfach-Netzwerk/releases/download/v2.0.20/Einfach-Netzwerk-2.0.20.zip) · **[Immer die neueste Version / Latest release](https://github.com/MartinGothic/Einfach-Netzwerk/releases/latest)**

**Deutsch** · [English](#english) · [Anleitung](docs/ANLEITUNG.md) · [Prüfstand](docs/VERIFICATION.md)

## Deutsch

Ordner und Datenlaufwerke im Heimnetz freigeben, andere Windows-PCs finden und bekannte SMB-Zugriffsprobleme gezielt prüfen. **Einfach Netzwerk 2.0.20** führt durch die Einrichtung und bietet für unterstützte Fehler passende Reparaturen mit gesicherten Änderungen an.

### In drei Schritten starten

1. Die **EXE oben herunterladen und öffnen**. Eine Installation ist nicht nötig.
2. **Freigabe erstellen** wählen, Ordner und Heimnetz auswählen.
3. Zugangsart und Rechte festlegen, die Zusammenfassung prüfen und **Freigabe einrichten** bestätigen.

**Ohne Passwort** ist vorausgewählt. Neue Freigaben starten mit **Nur lesen**; ein sichtbarer Hinweis erklärt die Auswahl. **Bearbeiten und Löschen** lassen sich per Häkchen erlauben und wieder ausschalten. Passwortzugang ist freiwillig – mit eigener Eingabe oder einem auf Wunsch erzeugten Passwort.

### Was das Programm bietet

- **Meine Freigaben:** Freigaben ansehen, Verbindungsdaten kopieren und einzelne Freigaben entfernen.
- **Andere Computer:** Die Heimnetzsuche bei Bedarf starten und den tatsächlichen Ordnerzugriff prüfen.
- **Fehler beheben:** Unterstützte Dienst-, Erkennungs-, Gast-/SMB- und Zugriffsprobleme gezielt behandeln, etwa bei „Auf den Computer konnte nicht zugegriffen werden“ oder **0x80070035**.
- **Nachvollziehbare Ergebnisse:** Lokale Vorbereitung, erreichbarer Computer und bestätigter Ordnerzugriff bleiben getrennt; Fehlerdetails lassen sich als TXT speichern.
- **Rücknahme:** Eigene gesicherte Einstellungen wiederherstellen und Datenfreigaben nach Übersicht und Bestätigung entfernen.

Beim Start läuft **keine automatische Netzwerksuche**. Windows-Änderungen erfolgen im bestätigten Einrichtungs- oder Reparaturablauf mit Administratorabfrage. Das Programm kann unterstützte Ursachen beheben; ein schlafender Ziel-PC oder eine Router-Gerätetrennung muss am betroffenen Gerät korrigiert werden.

**Voraussetzungen:** Windows 10/11, .NET Framework 4.8 und die integrierten Windows-PowerShell-/SMB-Komponenten. Die Geräte müssen im erreichbaren Heimnetz sein. Verwendet wird SMB 2/3.

Sieben Oberflächensprachen: Deutsch, Englisch, Französisch, Spanisch, Italienisch, Portugiesisch und Polnisch.

[Ausführliche deutsche Anleitung](docs/ANLEITUNG.md) · [Prüfstand und Grenzen](docs/VERIFICATION.md)

## English

Share folders and data drives on your home network, discover other Windows PCs and diagnose known SMB access problems. **Einfach Netzwerk 2.0.20** guides you through setup and offers suitable repair workflows for supported causes, with backed-up changes.

### Get started in three steps

1. **Download and open the EXE above.** No installation is required.
2. Choose **Create a share**, then select a folder and your home network.
3. Select access mode and permissions, review the summary and confirm **Set up share**.

**Without a password** is selected by default. New shares start as **Read only**, with a visible explanation. **Editing and deleting** can be enabled or disabled with a checkbox. Password access is optional: enter your own password or generate one on request.

### Features

- **My shares:** View shares, copy connection details and remove individual shares.
- **Other computers:** Start a home-network search when needed and verify actual folder access.
- **Fix errors:** Diagnose supported service, discovery, guest/SMB and access problems, including “Windows cannot access this computer” and **0x80070035**.
- **Clear results:** Local preparation, computer reachability and confirmed folder access are separate results. Export error details as TXT.
- **Undo changes:** Restore settings previously backed up by the application and remove data shares after reviewing and confirming the action.

**No network scan runs at startup.** Windows changes occur within a confirmed setup or repair workflow, with an administrator prompt. The application repairs supported causes; sleeping target computers or router isolation require action on the affected device.

**Requirements:** Windows 10/11, .NET Framework 4.8 and the built-in Windows PowerShell/SMB components. Devices must be on a reachable home network. Uses SMB 2/3.

Seven interface languages: German, English, French, Spanish, Italian, Portuguese and Polish.

[Detailed instructions in German](docs/ANLEITUNG.md) · [Verification record and limits in German](docs/VERIFICATION.md)

## Quellcode und Build / Source and build

Für die Nutzung genügt die EXE. Die folgenden Ordner enthalten den öffentlichen Quellcode.  
The EXE is all you need to use the application. The folders below contain its public source.

| Pfad / Path | Inhalt / Contents |
| --- | --- |
| [`src/`](src/) | C#-Quellen, eingebettete Windows-Module, Manifest und Icon / C# sources, embedded Windows modules, manifest and icon |
| [`tests/`](tests/) | Prüfskripte / Test scripts |
| [`docs/`](docs/) | Anleitung und Prüfstand / Instructions and verification |
| [`tools/`](tools/) | Hilfswerkzeuge zur Entwicklung / Development utilities |
| [`downloads/`](downloads/) | Bestehende Download-Dateien für kompatible Links / Existing downloads retained for link compatibility |
| [`build.ps1`](build.ps1) · [`package.ps1`](package.ps1) | Bauen und ZIP-Pakete erstellen / Build and package |

Im **Repository-Hauptordner** mit Windows PowerShell 5.1 ausführen.  
Run from the **repository root** using Windows PowerShell 5.1:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

Der Build verwendet den .NET-Framework-Compiler mit C# 5 und führt den eingebauten Selbsttest aus.  
The build uses the .NET Framework compiler with C# 5 and runs the built-in self-test.

```powershell
# Ergebnis / Output: dist\Einfach-Netzwerk.exe
.\dist\Einfach-Netzwerk.exe --self-test .\dist\self-test.json
.\dist\Einfach-Netzwerk.exe --render-preview .\dist\preview.png

# Programm- und Quellcode-ZIP / Application and source ZIP
powershell -NoProfile -ExecutionPolicy Bypass -File .\package.ps1
```

Selbsttest und Vorschau richten keine Freigabe ein. `tests/Test-Live.ps1` und Prüfungen mit `-Live` sind gesonderte reale Tests, die Windows-Zustände lesen oder verändern können.  
Self-test and preview do not create shares. `tests/Test-Live.ps1` and tests using `-Live` are separate live tests that can inspect or change Windows state.

Herausgeber / Publisher: Rene Box · Kontakt / Contact: boxr82525@gmail.com
