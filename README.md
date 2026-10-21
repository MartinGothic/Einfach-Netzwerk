# Einfach Netzwerk – Windows-Dateifreigaben / Windows File Sharing

**Deutsch** · [English](#english)

**Download 2.0.20:** [Windows EXE](https://github.com/MartinGothic/Einfach-Netzwerk/raw/refs/heads/main/downloads/v2.0.20/Einfach-Netzwerk-2.0.20.exe) · [Programm-ZIP / Application ZIP](https://github.com/MartinGothic/Einfach-Netzwerk/raw/refs/heads/main/downloads/v2.0.20/Einfach-Netzwerk-2.0.20.zip) · [Quellcode / Source code](https://github.com/MartinGothic/Einfach-Netzwerk/raw/refs/heads/main/downloads/v2.0.20/Einfach-Netzwerk-Quellcode-2.0.20.zip)

## Deutsch

Einfach Netzwerk 2.0.20 ist ein Windows-Programm zum Freigeben von Ordnern und Datenlaufwerken im Heimnetz. Der Freigabe-Assistent führt durch Zugangsart, Berechtigungen und Einrichtung. Das Programm sucht auf Wunsch nach anderen Computern, prüft den tatsächlichen SMB-Zugriff und bietet für erkannte, unterstützte Netzwerkfehler einen passenden Reparaturablauf an.

Die Oberfläche verwendet einen Aero-Glasstil und unterstützt sieben Sprachen: Deutsch, Englisch, Französisch, Spanisch, Italienisch, Portugiesisch und Polnisch.

### Herunterladen und starten

Lade die einzelne **EXE** oder das **Programm-ZIP** über die Direktlinks oben herunter. Die EXE enthält alle Programm- und Windows-Module; eine Installation ist nicht nötig.

Voraussetzungen: **Windows 10 oder Windows 11**, **.NET Framework 4.8** und die integrierten Windows-PowerShell-/SMB-Komponenten. Das Programm verwendet **SMB 2/3**. Die beteiligten Geräte müssen sich in einem erreichbaren Heimnetz befinden. Windows-Einstellungen werden erst im bestätigten Einrichtungs- oder Reparaturablauf mit Administratorabfrage geändert.

### Funktionen

- **Freigabe erstellen:** Ordner oder Datenlaufwerk auswählen, Passwort- oder Gastzugang wählen, die Rechte bei Bedarf um Bearbeiten und Löschen erweitern und die Einrichtung bestätigen.
- **Meine Freigaben:** Freigaben anzeigen, den lokalen Ordner öffnen, Verbindung kopieren oder eine einzelne Freigabe entfernen.
- **Andere Computer:** Das Heimnetz ausdrücklich durchsuchen und Anmeldung sowie Ordnerzugriff auf einer gewählten Freigabe prüfen.
- **Fehler beheben:** Bekannte Dienst-, Gast-/SMB-, Erkennungs- und Zugriffsprobleme gezielt prüfen und unterstützte Ursachen mit gesicherten Änderungen reparieren. Kurze Erklärung, ursprünglicher Fehlercode und TXT-Export bleiben erhalten.
- **Alles auf Standard zurücksetzen:** Datenfreigaben entfernen und die vom Programm gesicherten ursprünglichen Einstellungen wiederherstellen. Dateien bleiben erhalten; eine konkrete Übersicht und Bestätigung gehen der Aktion voraus.

Beim Programmstart läuft keine automatische Netzwerksuche. Eine eingerichtete Freigabe, ein erreichbarer Port 445 und ein tatsächlich bestätigter Zugriff werden getrennt angezeigt. Das Programm veröffentlicht keine Ordner im Internet.

**Neu in 2.0.20:** Der Assistent startet weiterhin mit Gastzugang **Ohne Passwort**. Neue Freigaben erlauben zunächst **Nur lesen**; die Rechte lassen sich im Assistenten auf Bearbeiten und Löschen erweitern. Passwortzugang bleibt eine freiwillige Alternative. Bei diesem Modus kann der Assistent auf Wunsch einen Passwortvorschlag erzeugen, das Passwort anzeigen und kopieren.

**Andere Computer** zeigt drei getrennte Nachweise: **Dieser PC vorbereitet**, **Anderer Computer erreichbar** und **Ordnerzugriff bestätigt**. Sie beschreiben die lokale Clientvorbereitung, die Erreichbarkeit des gewählten Zielcomputers und den bestätigten tatsächlichen Zugriff auf die gewählte Freigabe. Eine erfolgreiche lokale Prüfung allein gibt keinen Fernzugriff als bestätigt aus.

Weiterhin führen nach einer Rücksetzung bestätigte Gast-/SMB-Clientblockaden direkt zu **Dieses Problem beheben**. Der lokale Ablauf benötigt keinen gefundenen Zielcomputer: frisch prüfen, Änderungen erklären, Zustimmung einholen, betroffene Werte sichern und nach der Reparatur erneut prüfen. Die neuen Auswahl- und Passwortfunktionen lockern keine zusätzlichen Windows-Netzwerkeinstellungen.

### Häufige Windows-Netzwerkfehler

- **0x80070035 – Der Netzwerkpfad wurde nicht gefunden:** Die Diagnose unterscheidet unter anderem Zielerreichbarkeit, Port 445, Dienste, Computernamen und SMB-Zugriff. Unterstützte lokale Ursachen führen zur passenden Reparatur. Der Fehlercode allein bestimmt keine einzelne Ursache; ausgeschaltete Geräte oder Router-Isolierung benötigen eine Korrektur am betroffenen Gerät.
- **Auf einen anderen Computer konnte nicht zugegriffen werden:** **Andere Computer** prüft den gewählten Rechner, die Freigabe und die Anmeldung. Client-Einstellungen und tatsächlicher Ordnerzugriff bleiben getrennt. Ein gefundenes Gerät gilt noch nicht als erfolgreich verbunden.
- **Der Serverdienst wurde nicht gestartet:** Die Dienstprüfung liest den Zustand der benötigten Windows-Netzwerkdienste. Der Reparaturablauf kann unterstützte Start-/Konfigurationsfehler mit Sicherung korrigieren und prüft das Ergebnis erneut. Die Prüfung findet auf dem Computer statt, auf dem das Programm läuft.
- **Gastzugriff oder SMB-Signatur blockiert die Verbindung:** Die lokale Clientprüfung erkennt beobachtete Gast-/Signaturblockaden. Nach erklärter Zustimmung kann der vorhandene Ablauf die benötigten Kompatibilitätseinstellungen sichern und anpassen. Verwaltete Richtlinien werden nicht übergangen; eine lokale Vorbereitung bestätigt noch keinen Fernzugriff.

Unbekannte Ursachen bleiben mit ihrem Originalcode sichtbar und können als TXT-Bericht exportiert werden. Es wird keine erfolgreiche Reparatur jedes möglichen Netzwerkfehlers versprochen.

### Selbst bauen

Unter Windows mit Windows PowerShell 5.1 im Quellordner ausführen:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

Der Build verwendet den vorhandenen .NET-Framework-Compiler mit C# 5 und führt den eingebauten Selbsttest aus. Die fertige EXE liegt unter `dist\Einfach-Netzwerk.exe`.

```powershell
.\dist\Einfach-Netzwerk.exe --self-test bericht.json
.\dist\Einfach-Netzwerk.exe --render-preview vorschau.png
```

Selbsttest und Vorschau richten keine Freigabe ein. `Test-Live.ps1` und Tests mit `-Live` sind gesonderte reale Tests, die Windows-Zustände lesen oder verändern können.

[Vollständige deutsche Anleitung](ANLEITUNG.md) · [Aktueller Prüfstand](VERIFICATION.md)

## English

Einfach Netzwerk 2.0.20 is a Windows application for sharing folders and data drives on a home network. Its sharing wizard guides you through access mode, permissions and configuration. On request, it discovers other computers, checks actual SMB access and offers suitable repair workflows for detected, supported network problems.

The Aero glass interface supports seven languages: German, English, French, Spanish, Italian, Portuguese and Polish.

### Download and run

Download the standalone **EXE** or **application ZIP** using the direct links above. The EXE includes the application and its Windows modules; no installation is required.

Requirements: **Windows 10 or Windows 11**, **.NET Framework 4.8**, and the built-in Windows PowerShell/SMB components. The application uses **SMB 2/3**. Devices must be on a reachable home network. Windows settings change only within a confirmed setup or repair workflow, with an administrator prompt.

### Features

- **Create a share:** Choose a folder or data drive, select password or guest access and extend the initially read-only permissions if needed, then confirm the setup.
- **My shares:** View shares, open the local folder, copy connection information or remove an individual share.
- **Other computers:** Start a home-network search explicitly and check authentication and folder access for a selected share.
- **Fix errors:** Diagnose known service, guest/SMB, discovery and access problems. Repair supported causes with backed-up changes. A short explanation, the original error code and TXT export remain available.
- **Reset to original settings:** Remove data shares and restore original settings previously backed up by the application. Files remain intact; a concrete overview and confirmation precede the action.

No network scan runs at application startup. A configured share, a reachable port 445 and verified access are separate results. The application does not publish folders on the internet.

**New in 2.0.20:** The wizard still starts with guest access **Without a password**. New shares initially allow **Read only**; permissions can be extended to editing and deleting in the wizard. Password access remains an optional alternative. In this mode, the wizard can generate a password suggestion, show the password and copy it on request.

**Other computers** shows three separate results: **This PC prepared**, **Other computer reachable** and **Folder access confirmed**. They describe local client preparation, reachability of the selected target computer and verified actual access to the selected share. A successful local check alone does not confirm remote access.

Confirmed guest/SMB client blocks after a reset still lead directly to **Fix this problem**. The local workflow does not require a discovered target computer: inspect current settings, explain changes, request consent, back up affected values and verify again after repair. The new permission and password controls do not loosen additional Windows network settings.

### Common Windows network errors

- **0x80070035 – The network path was not found:** Diagnostics distinguish target reachability, port 445, services, computer names and SMB access. Supported local causes lead to the appropriate repair. This code does not identify one universal cause; sleeping devices or router isolation require a correction on the affected device.
- **Cannot access another computer:** **Other computers** checks the selected computer, share and authentication. Client settings and actual folder access remain separate. Discovering a device does not confirm a working connection.
- **The server service has not been started:** Service diagnostics read the required Windows network services. The repair workflow can correct supported startup/configuration problems with a backup and verify the result. It checks the computer running the application.
- **Guest access or SMB signing blocks a connection:** Local client diagnostics detect observed guest/signing blocks. After explained consent, the existing workflow can back up and adjust the necessary compatibility settings. Managed policies are not overridden; local preparation does not confirm remote access.

Unknown causes retain their original codes and can be exported as a TXT report. A successful repair of every possible network error is not guaranteed.

### Build from source

Run this command in the source directory using Windows PowerShell 5.1:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

The build uses the installed .NET Framework compiler with C# 5 and runs the built-in self-test. The executable is generated at `dist\Einfach-Netzwerk.exe`.

```powershell
.\dist\Einfach-Netzwerk.exe --self-test report.json
.\dist\Einfach-Netzwerk.exe --render-preview preview.png
```

The self-test and preview do not create a share. `Test-Live.ps1` and tests using `-Live` are separate real tests that can inspect or change Windows state.

[Full instructions in German](ANLEITUNG.md) · [Current verification record in German](VERIFICATION.md)

Publisher / Herausgeber: Rene Box · Contact / Kontakt: boxr82525@gmail.com
