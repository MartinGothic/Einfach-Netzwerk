# Einfach Netzwerk 2.0.20

[Download und Übersicht](../README.md) · [Prüfstand](VERIFICATION.md)

Ein kleines Windows-Programm für Ordner und ganze Datenfestplatten im Heimnetz. Die einzelne EXE enthält den Assistenten, alle sieben Sprachen und die Windows-Module für Freigaben und den Zugriff auf andere PCs.

**Neu in 2.0.20:** Der Assistent startet weiterhin mit **Ohne Passwort**. Passwortzugang und ein selbst eingegebenes oder freiwillig erzeugtes Netzwerk-Passwort bleiben frei wählbar. Neue Freigaben beginnen mit **Nur lesen**. Der sichtbare Hinweis erklärt, dass Geräte Dateien öffnen und kopieren, aber noch nicht bearbeiten, hinzufügen oder löschen dürfen. Diese zusätzlichen Rechte lassen sich direkt einschalten und wieder ausschalten. Bereits gespeicherte Freigaberechte werden beim Reparieren beibehalten.

Im Passwortmodus stehen **Passwort erzeugen**, **Anzeigen** und **Kopieren** zur Verfügung. Eine Erzeugung erfolgt nur auf deinen Klick; die Auswahl wechselt dabei nicht automatisch vom Gastmodus zum Passwortmodus. Das Passwort wird nicht in Verbindungsangaben oder TXT-Berichte übernommen.

**Andere Computer** fasst die aktuelle Prüfung in drei klaren Zeilen zusammen: **Dieser PC vorbereitet**, **Anderer Computer erreichbar** und **Ordnerzugriff bestätigt**. Ein lokal vorbereiteter PC oder ein offener Port gilt weiterhin nicht als bestätigter Ordnerzugriff. Änderungen an Ziel, Freigabe oder Anmeldung verwerfen alte Verbindungsnachweise. Die vorhandene passende Reparaturaktion und die vollständigen Fehlerdetails bleiben erreichbar. Beim Programmstart wird weiterhin nicht gesucht.

**Neu in 2.0.19:** Nach „Alles zurücksetzen“ sind die gesicherten ursprünglichen Windows-Einstellungen wieder aktiv. Dadurch können Gastanmeldungen erneut gesperrt sein. Die konkreten Hinweise zu Gastzugriff und SMB-Signatur bleiben jetzt als behebbare Einstellungen sichtbar; eine zusätzliche allgemeine Fehlermeldung verdeckt sie nicht mehr.

**Dieses Problem beheben** öffnet bei diesen bestätigten Client-Blockaden direkt die lokale Vorbereitung: frisch prüfen, die erläuterte Gast-Kompatibilität bestätigen, die benötigten Einstellungen mit Sicherung und Windows-Administratorabfrage einrichten und erneut prüfen. Dafür werden kein Zielcomputer, Freigabename oder Netzwerk-Benutzer benötigt. Dieser Ablauf führt keine Heimnetzsuche oder Anmeldung auf einem anderen Computer aus. Die alten Ursachen bleiben sichtbar und werden nur nach passenden neuen Belegen als behoben markiert. Ein vorbereiteter Client bestätigt noch keinen Fernzugriff. Der Programmstart bleibt ohne Suche; die erfolgreiche Rücksetzung richtet die zurückgenommenen Einstellungen nicht ungefragt erneut ein.

**Korrektur in 2.0.18:** „Zurücksetzen vorbereiten“ kann die Datenfreigaben im normalen Benutzerkonto lesen. Die unnötige Administratorblockade aus Version 2.0.17 ist behoben. Erst das tatsächliche Zurücksetzen benötigt nach der Übersicht eine Bestätigung und Administratorrechte. Eine vollständig bestätigte Prüfung bleibt nicht mehr bei 99 % stehen; der Balken zeigt weiterhin jeden bestätigten Prozentwert einzeln.

Im Rücksetzfenster stehen kurze Erklärungen in der Übersicht. Die ausgewählte Zeile zeigt darunter ihre vollständige, umbrochene Erklärung. Kann Windows die Freigabenliste nicht bestätigen, steht dort keine vermeintlich bestätigte „0“. Der TXT-Bericht enthält den zusammenhängenden Rücksetzungsplan und die ursprüngliche Ursache mit Fehlercode.

**Automatisch prüfen und beheben** prüft die Rücksetzungsvoraussetzungen und repariert bestätigte, unterstützte Dienstblockaden mit gesicherten ursprünglichen Einstellungen. Danach werden Freigaben, Client und Dienste frisch gelesen. Die Aktion entfernt keine Freigaben und führt noch keine Rücksetzung aus. Bei nicht bestätigbarer Reparatur bleibt die konkrete Ursache sichtbar; es folgen keine endlosen Reparaturversuche.

Fehler aus den Programmaktionen erscheinen zusätzlich als kurze Meldung **Problem erkannt** mit passender Hilfe. **Probleme und Lösungen** zeigt bereits erkannte Ursachen ohne neue Suche. Bekannte Fehler führen direkt zum vorhandenen Reparaturablauf; unbekannte Fehler behalten Originalcode und TXT-Export. Eine passende neue Prüfung markiert den Befund als behoben und bewahrt seine ursprüngliche Ursache. Ein erfolgreicher Zugriff auf einen anderen Zielcomputer oder eine andere Anmeldung beseitigt den alten Befund nicht. Der Verlauf ist auf diese Programmsitzung begrenzt; für später bitte den TXT-Bericht speichern.

Auch der Freigabe-Assistent, der Zugriff auf andere Computer, die Dienstereparatur und die Freigabenübersicht behalten ihre ursprünglichen Befunde. Ein unterstützter Fehler hebt den passenden Button hervor. Im Ergebnis des Assistenten öffnet **Dieses Problem beheben** direkt den zugehörigen Reparaturablauf. Das erneute Lesen der Freigabenübersicht ist eine reine Prüfung; unbekannte Fehler bieten den Bericht statt einer geratenen Windows-Änderung an.

## Ganz einfacher Start

Die Startseite zeigt drei große Aufgaben mit einer kurzen Erklärung: **Freigabe erstellen**, **Meine Freigaben** und **Andere Computer**. Darunter bleiben **Fehler beheben**, **Weitere Einstellungen** und **Fehlerbericht exportieren** direkt erreichbar. **Prüfung & Reparatur**, **So verbinden sich deine Geräte** und **Auf deinem Gerät öffnen** starten geschlossen. Beim Öffnen der App läuft keine Diagnose oder Heimnetzsuche, kein Erkennungslistener und kein Reparaturangebot. Auch Laufwerksdaten werden erst beim Öffnen der Einstellungen geladen. Prüfungen starten erst mit einer passenden Aufgabe oder einem ausdrücklichen Klick. Eine abgeschlossene Gesamtsuche zeigt ihre Ergebnisse, ohne eine Reparaturbestätigung aufzurufen.

1. `Einfach-Netzwerk.exe` öffnen und **Freigabe erstellen** anklicken.
2. Ordner oder Datenlaufwerk auswählen. Ein ganzes Laufwerk ausdrücklich bestätigen.
3. **Ohne Passwort** oder **Mit Passwort** wählen und die erlaubten Rechte festlegen.
4. Dein Heimnetz auswählen. Die Zusammenfassung erklärt, welche Daten und Windows-Einstellungen betroffen sind.
5. **Freigabe einrichten** anklicken und die Windows-Administratorabfrage bestätigen.

Zum Einrichten in einem Windows-Administratorkonto arbeiten und bei UAC dasselbe Konto verwenden. Windows 10/11, .NET Framework 4.8 und die integrierten SMB-/Windows-PowerShell-Komponenten werden vorausgesetzt. Die reine Diagnose braucht keine Administratorbestätigung.

## Bekannte Fehler im Assistenten und im Fehler-Fixer

**Neu in 2.0.17:** Im Schritt **Heimnetz** siehst du die aktivierten Punkte für Dienste, Erkennung, Port und Freigaberechte sowie die erweiterte Reparatur. Beim Einrichten werden Server, Arbeitsstation und Erkennungsdienste gestartet und passend eingerichtet. Ihre vorherigen Einstellungen werden für die Rücknahme gesichert; bestehende ältere Sicherungen werden erhalten.

Bei **Ohne Passwort** ist zusätzlich **Diesen PC auch für andere Gastfreigaben vorbereiten** ausgewählt. Dieses Häkchen lässt sich ausschalten. Die Zusammenfassung erklärt, dass es ausgehende SMB-Gastanmeldungen sowie nötige Signatur- und Verschlüsselungseinstellungen auf diesem Windows-PC betreffen kann. Erst nach erfolgreicher eigener Freigabeeinrichtung prüft das Programm den Client; nur tatsächlich festgestellte, reparierbare Gastblockaden werden mit eigener Sicherung angepasst und anschließend neu geprüft. Im Passwortmodus wird diese Gastvorbereitung nicht ausgeführt. Eine vorbereitete Clienteinstellung bestätigt noch keinen Zugriff auf einen fremden Ordner. Falls dieser Zusatzschritt scheitert, bleibt die eingerichtete Freigabe sichtbar; die App benennt den verbleibenden Clientfehler getrennt.

**Fehler beheben** öffnet ein eigenes Fenster ohne Scan. Acht kurz erklärte Aufgaben führen zur passenden Reparatur: anderer Computer nicht erreichbar, Netzwerkdienste, Gast-/SMB-Blockaden, Dateirechte, Computername, verweigerte Freigabenliste, Erkennung und eigene Freigabe. Änderungen laufen über die vorhandenen gezielten Abläufe mit Bestätigung, Windows-Administratorabfrage und Sicherung. Eine Freigabereparatur verwendet eine frisch gelesene konkrete eigene Freigabe; bei mehreren wählst du sie aus.

Unten startet **Alle Fehler suchen** ausdrücklich die Gesamtprüfung: lokale Freigaben und Netzwerke, Dienste, Clienteinstellungen und danach die begrenzte Heimnetzsuche. Die Ergebnisse erscheinen in einer Liste mit Originalcodes und passender Hilfe. Die Suche verändert keine Windows-Einstellungen. Die Prozentanzeige folgt den tatsächlich gemeldeten Schritten der jeweiligen Prüfphase. Ein erreichbarer Port 445 und eine gefundene Freigabe ersetzen keine erfolgreiche Anmeldung und Ordnerprüfung. **Fehlerbericht exportieren** speichert die Details als TXT, ohne Passwörter.

## Alles auf Standard zurücksetzen

Im **Fehler-Fixer** bleibt zusätzlich **Alles auf Standard zurücksetzen** erreichbar. Das Fehler-Fixer-Fenster bleibt hinter der Rücksetzungsübersicht geöffnet. Das neue Fenster startet keine Prüfung von selbst.

1. **Zurücksetzen vorbereiten** liest die normalen Freigaben und die vorhandenen eigenen Rücknahmesicherungen. Die Übersicht zeigt Ordner-/Laufwerksfreigaben und die gesicherten Client- und Dienständerungen.
   Meldet die Vorbereitung eine Blockade, hebt sie **Automatisch prüfen und beheben** direkt hervor. Der Button korrigiert unterstützte Dienst-Startfehler und prüft danach die Voraussetzungen erneut. Eine unlesbare Sicherung, unklare verwaltete Richtlinie oder mehrdeutige Netzwerkauswahl wird mit ihrem wirklichen Fehler gemeldet.
2. **Alles zurücksetzen** zeigt die konkrete Zusammenfassung. Erst nach deiner Bestätigung und der Windows-Administratorabfrage beginnt die Ausführung.
3. Das Programm prüft den Plan erneut und sichert zuerst die aktuellen Freigabedefinitionen, Freigaberechte, Ordner-Sicherheitsbeschreibungen und bekannten Netzwerkdaten. Die gesicherten Originaljournale bleiben im Backup enthalten. Fehlt die bestätigte Sicherung, wird keine Freigabe entfernt.
4. Normale Datenfreigaben werden entfernt, auch Freigaben außerhalb dieses Programms und normale versteckte Datenfreigaben. Bei verwalteten Freigaben nimmt die App ihre gesicherten eigenen Ordner-, Gast-, SMB-, Firewall- und Netzwerkeinstellungen zurück. Vorhandene eigene Client- und Dienstereparaturen werden ebenfalls zurückgenommen. Dateien bleiben erhalten; administrative Windows-Systemfreigaben gehören zum normalen Windows-Zustand und bleiben bestehen.
5. Erst eine frisch bestätigte leere Datenfreigabenliste meldet die Rücksetzung als abgeschlossen. Ein geänderter Plan, eine gescheiterte Rücknahme oder ein nicht bestätigbares Ergebnis bleibt mit dem ursprünglichen Fehler sichtbar und kann als TXT exportiert werden.

„Standard“ verwendet die gesicherten Zustände vor den Änderungen dieses Programms. Unbekannte frühere Windows-Einstellungen lassen sich daraus nicht als Werkszustand rekonstruieren. Spätere fremde Änderungen werden von den vorhandenen Rücknahmeroutinen erhalten. Der Button löscht keine Netzwerkadapter, VPN-Verbindungen oder Router-Einstellungen. Die vollständige Rücksetz-Sicherung liegt unter `%ProgramData%\EinfachNetzwerk\reset-backup-*.json`; der Bericht nennt den konkreten Pfad. Sie ist eine technische Sicherung, kein automatischer Import beliebiger Windows-Konfigurationen.

**Neu in 2.0.16:** **Meine Freigaben** öffnet die vereinfachte Übersicht mit **Freigabe**, **Art**, **Zugriff** und **Status**. Wähle eine Zeile: Der lokale Pfad und die Zugangsart erscheinen direkt darunter. **Ordner / Laufwerk öffnen** und **Verbindung kopieren** stehen zusammen; **Freigabe entfernen** ist davon getrennt. Entfernen betrifft ausschließlich die ausgewählte Freigabe und löscht keine Dateien; die bestehende Bestätigung bleibt erhalten. **Details und Verbindungsdaten** startet geschlossen und enthält IP, Port, Netzwerkpfad, Konto und Rechte. Fehlende Freigaben und Diagnosehinweise bleiben auch bei geschlossenen Details sichtbar. Der Aero-Glasstil und alle sieben Sprachen bleiben erhalten.

## Zugriff auf andere Netzwerk-PCs reparieren

**Neu in 2.0.15:** Verweigert Windows nur die automatische **anonyme Freigabenliste** mit `NetShareEnum / Win32: 5`, erscheint dies als neutraler **Hinweis**. Es wird nicht als gescheiterter Ordnerzugriff dargestellt. Die Liste bleibt ungeprüft; der ursprüngliche Code ist in den Details und im TXT-Bericht erhalten. Andere Anmelde-, Passwort- und Ordnerfehler behalten ihren Fehlerstatus.

**Mit Netzwerk-Konto erneut prüfen** wiederholt diese Listenabfrage mit einem tatsächlichen Netzwerk-Benutzer. Ein selbst eingetragener Benutzer bleibt erhalten. Bei einem vom Programm gefundenen Computer kann die App auch das von Windows bestätigte Konto einer bereits bestehenden SMB-Verbindung übernehmen. Sie prüft dazu den genauen verbundenen Windows-Netzwerkpfad, die gleiche private Ziel-IP, den tatsächlichen Computernamen und die noch bestehende Verbindung. Der Vorschlag erscheint mit seiner Quelle und wird erst mit deinem Klick übernommen. Das Konto liefert kein Passwort und keine Aussage über die Zugangsart; der gewählte Modus bleibt erhalten. Fehlt ein bestätigtes Konto, führt der Button direkt zum Benutzerfeld. Ein bekannter Freigabename kann weiterhin direkt geprüft werden.

Ein bestätigter Ordnerzugriff und die separate automatische Freigabenliste werden unabhängig behandelt. Eine fehlende Liste bestätigt keine gesperrten Ordner. Ein früherer gültiger Ordnernachweis bleibt bei einem eng begrenzten optionalen Listenhinweis nur für exakt unverändertes Ziel, Ordner und Anmeldedaten erhalten. Änderungen dieser Angaben oder tatsächlich fehlgeschlagene Zugriffsprüfungen entwerten den Nachweis weiterhin.

**Neu in 2.0.14:** Der eigene Button **Zugriff auf Netzwerk-PCs reparieren** hilft auf dem Computer, der die Freigaben anderer Computer öffnen soll. Die Prüfung der eigenen angebotenen Ordner und der tatsächliche Zugriff auf einen anderen PC sind getrennte Aufgaben.

1. Auf dem zugreifenden PC den neuen Button anklicken. Zuerst läuft die Heimnetzsuche mit einem gezählten Ladebalken. Computer und Freigaben werden erst nach Abschluss oder Abbruch auswählbar. Eine begrenzte Suche behauptet nicht, alle Geräte gefunden zu haben.
2. Anschließend prüft das Programm den lokalen Arbeitsstationsdienst und die effektiven Windows-SMB-Clienteinstellungen, auch wenn noch kein Zielcomputer, Freigabename oder Benutzer eingetragen wurde.
3. Bei einer festgestellten Gastblockade **Diesen PC für Netzwerkzugriff einrichten** verwenden. Die Bestätigung erklärt die Windows-Änderungen; anschließend erscheint die Administratorabfrage. Das Programm sichert vorher die betroffenen Werte, passt nur die beobachteten Blockaden an und überprüft sie erneut. Es erlaubt Gastanmeldungen und entfernt, falls erforderlich, verpflichtende SMB-Signierung bzw. Verschlüsselung auf diesem Windows-Client. Diese Windows-Einstellungen gelten für alle SMB-Ziele, nicht nur für die gewählte Freigabe. Verwaltete Richtlinien werden nicht übergangen. **Client-Änderungen zurücknehmen** nutzt die eigene Sicherung und erhält spätere fremde Änderungen.
4. Nach erfolgreicher Vorbereitung startet die Suche erneut. Einen Computer auswählen. Fehlen dessen gemeldete Freigaben, liest das Programm seine Windows-Freigabenliste mit einer eigenen, getrennten Netzwerkanmeldung. Öffentlich gemeldete echte Kontodaten haben Vorrang; ohne ein bekanntes Konto versucht es im Gastmodus ausdrücklich eine leere anonyme Anmeldung. Das Programm rät keine Kontonamen und verwendet keine zufällig vorhandene Explorer-Anmeldung als Beweis. Bei Passwortzugang zuerst das tatsächliche Netzwerk-Konto und Passwort eingeben.
5. Eine gefundene Datenfreigabe auswählen. Erst die zusätzliche erfolgreiche Windows-Anmeldung und Ordnerprüfung bestätigen **Zugriff** und schalten **Freigabe öffnen** frei. Eine gelesene Freigabenliste oder ein vorbereiteter Client allein bestätigt noch keinen Ordnerzugriff.

Bleibt die Liste leer, zeigt die Prüfliste den tatsächlichen Fehlercode. Ein Windows-Server kann anonyme Listen ablehnen; dann werden dessen gemeldete oder selbst eingetragene reale Anmeldedaten benötigt. Für vollständige automatische Vorschläge die neue Version auf beiden Computern öffnen und auf dem freigebenden PC die konkret angebotene Aktualisierung der Heimnetz-Erkennung bestätigen. Fehlende Meldedaten auf dem anderen PC werden von einer Client-Reparatur nicht erfunden. Nicht erreichbarer Port 445, Standby, Router-Isolierung und Fehler auf dem anderen Computer werden getrennt angezeigt.

Der TXT-Fehlerbericht enthält den Zustand des Empfänger-PCs, seine Zustimmung und Sicherung, die gesondert bestätigte Freigabenliste sowie den noch unbestätigten oder tatsächlich geprüften Ordnerzugriff. Originalfehler bleiben erhalten; Passwörter und verschlüsselte Passwortwerte werden entfernt.

## Diagnose abschließen und Erkennung aktualisieren

**Neu in 2.0.13:** Eine vollständig abgeschlossene Diagnose zeigt **100 %**, auch wenn sie ein Problem gefunden hat. Das bedeutet, dass die Prüfung fertig ist; die Prüfliste zeigt weiterhin, welche Einstellungen bereit sind und welche repariert werden müssen. Bei einem frühen Abbruch bleibt der tatsächliche Fortschritt erhalten.

`DISCOVERY_SETUP_REQUIRED` bedeutet: Für eine vorhandene eigene Freigabe fehlen noch aktuelle Erkennungsdaten oder die Firewallregel für die gerade gestartete Programmdatei. Bei der normalen Diagnose erscheint dies als ausstehende Aktualisierung. Der Hinweis allein bedeutet nicht, dass der SMB-Zugriff ausgefallen ist.

Wenn eine ausdrücklich gestartete Prüfung fehlende Erkennungsdaten feststellt, kannst du die betroffene Freigabe im Fehler-Fixer unter **Sichtbarkeit einrichten** aktualisieren. Die Bestätigung nennt Ordner, Freigabename, Heimnetz, gespeicherte Zugangsart und Rechte sowie die Änderungen an Windows. Danach folgt die Windows-Administratorabfrage. Die gesicherte Reparatur kann auch die gespeicherten Ordner-, Gast- und SMB-Einstellungen wiederherstellen.

Es erscheint kein Reparaturangebot beim Start oder nach der Gesamtsuche. Erkannte Probleme bleiben in der Prüfliste, bis du ihre Reparatur ausdrücklich öffnest. Beim Einrichten oder Reparieren einer ausgewählten Freigabe werden ihre benötigten Erkennungseinstellungen weiterhin geprüft.

## Computer und Freigaben automatisch finden

**Andere Computer** startet bei Bedarf die Suche nach SMB-Computern im aktiven privaten Heimnetz und zeigt ihre Datenfreigaben zur Auswahl. Du musst bekannte Verbindungsdaten nicht mehr abtippen: Computer und Freigabe auswählen, dann übernimmt das Programm gemeldete IP, Freigabename, Zugangsart und Netzwerk-Benutzer. Port **445** wird automatisch verwendet.

Für die vollständige Datenübernahme die neue Version auf **beiden Windows-PCs öffnen**. Auf dem freigebenden PC einen Ordner oder eine Datenfestplatte mit dem Assistenten einrichten oder **Meine Freigaben** öffnen. Erst nach dieser ausdrücklich gestarteten Bestandsprüfung wird die eigene Datenmeldung aktiv. Fehlende Erkennungsdaten oder eine Firewallregel für eine alte bzw. verschobene Programmdatei werden in der Prüfliste angezeigt und können unter **Sichtbarkeit einrichten** aktualisiert werden.

Die Datenmeldung läuft nur, solange die App geöffnet ist. Sie überträgt öffentlich lesbare Verbindungsdaten: Computername, Freigabename, Zugangsart und Kontoname. **Passwörter werden nicht veröffentlicht**, ebenso keine Dateien, lokalen Ordnerpfade oder Sicherungsjournale. Die Einrichtung erstellt dafür eine eigene UDP-Regel für Port **41671**, diese genaue Programmdatei, den ausgewählten privaten Adapter und dessen Heimnetz. Direkter SMB-Zugriff verwendet weiterhin TCP **445**. Die Erkennungsregel wird mit der eigenen Freigabeeinrichtung gesichert und zurückgenommen.

Die Suche prüft ausschließlich bestätigte private physische LAN-/WLAN-Verbindungen und bleibt zeitlich sowie in der Anzahl der Adressen und Detailabfragen begrenzt. Ein Profil- oder Adapterwechsel beendet weitere Kontakte im früheren Suchbereich. Bei einer begrenzten oder abgebrochenen Suche können weitere Geräte fehlen; ein bekanntes Ziel lässt sich weiterhin selbst eintragen. Ein Computer mit antwortendem Port oder gemeldeten Freigabedaten gilt zunächst als **Zugriff noch ungeprüft**. Erst eine erfolgreiche Windows-Anmeldung und Ordnerauflistung bestätigen den Zugang.

Bei einer ausgewählten Freigabe **ohne Passwort** prüft das Programm den angegebenen Gastzugang automatisch und versucht zusätzlich die Verbindung über den Computernamen. Erkennt es eine bekannte reparierbare Blockade, erscheint **Möchtest du das beheben?** mit dem Originalcode. Bei **Mit Passwort** wird das gemeldete Netzwerk-Konto übernommen; das Passwort selbst eingeben und **Zugriff prüfen** anklicken. Während der Passworteingabe versucht die App keine automatischen Anmeldungen. Sind die Anmeldedaten einer fremden Freigabe unbekannt, zeigt sie das ausdrücklich an.

Vor einer Anmeldung prüft die App außerdem den lokalen Arbeitsstationsdienst **LanmanWorkstation** auf dem zugreifenden PC. Ist er gestoppt, deaktiviert oder fehlt er, bleibt eine Anmeldung aus und die App bietet die vorhandene lokale Windows-Dienstereparatur an. Dieser Fehler betrifft den Empfänger-PC; er ist kein Beweis für eine Störung des freigebenden Computers. Scheitert bereits die Dienstabfrage, bleibt deren ursprünglicher Fehler im TXT-Bericht erhalten.

## „Der Serverdienst wurde nicht gestartet“ beheben

Dieser Fehler gehört zum Windows-Dienst **LanmanServer** auf dem betroffenen PC. Er kann zusätzlich einen ursprünglichen Windows-Code melden, zum Beispiel **2** bei einer fehlenden Dienstregistrierung. Die neue Prüfung liest Dienststatus, Starttyp, Abhängigkeiten und Originalcodes direkt aus der Windows-Dienstverwaltung.

**Automatisch reparieren** öffnet ohne ausgewählte Freigabe oder bei einem erkannten Dienstproblem den Bereich **Windows-Dienste reparieren**. Derselbe Bereich ist auch unter **Andere Computer** erreichbar. Dort zuerst **Dienste erneut prüfen**, dann **Automatisch reparieren** anklicken. Ein Ordner und ein Passwort werden dafür nicht benötigt.

Die Reparatur sichert ihre Änderungen, startet benötigte lokale Dienste und prüft sie anschließend samt lokalem TCP-Port **445** erneut. Bei fehlender SMB-Dienstregistrierung verwendet sie ausschließlich die passende geschützte Windows-Komponentendefinition und die überprüfte Microsoft-Datei `srvsvc.dll`. Für LanmanServer werden nur die beiden Dienst-DLL-Einträge wiederhergestellt; vorhandene Freigaben und SMB-Zugriffsregeln bleiben erhalten. Falls Windows-Originaldateien beschädigt sind oder eine verwaltete Richtlinie eingreift, zeigt das Programm die tatsächliche Ursache und ermöglicht einen TXT-Export.

**Dienständerungen zurücknehmen** verwendet die eigene geschützte Sicherung und erhält spätere fremde Änderungen. Laufende Dienste werden dafür nicht erzwungen beendet. „Lokale Dienste geprüft“ bedeutet, dass die Dienste und der Port auf diesem PC bereit sind. Den tatsächlichen Zugriff auf einen anderen PC prüfst du anschließend mit **Andere Computer**.

## Fehler als TXT speichern

Wenn eine Freigabe, eine Prüfung oder eine andere Programmaktion scheitert, klicke auf **Fehlerbericht exportieren**. Der Button ist direkt auf der Startseite, im Assistenten, in der Freigabenübersicht und beim Ändern des Computernamens erreichbar. Wähle anschließend den Speicherort für die `.txt`-Datei. Diese Datei kannst du später zur Fehlersuche im Chat anhängen.

Der Bericht enthält die Programm- und Windows-Version, die letzte Aktion, vorhandene Originalfehlercodes, Fehlermeldungen und Aufruflisten sowie Netzwerk- und Freigabeinformationen. Kennwörter und verschlüsselte Kennwortwerte werden entfernt. IP-Adressen, Computernamen, Benutzernamen und ausgewählte lokale Pfade bleiben zur Diagnose enthalten; Dateien aus deinen Freigabeordnern werden nicht gelesen oder in den Bericht übernommen.

Die letzten 20 Fehler und Warnungen bleiben während derselben Sitzung erhalten, auch wenn eine spätere Prüfung erfolgreich ist. Speichere den Bericht vor dem Schließen des Programms. Gespeichert wird erst nach deinem Klick und deiner Dateiauswahl; es wird nichts automatisch verschickt. Bei unerwarteten Oberflächenfehlern bietet das Programm den TXT-Export ebenfalls an. Während einer laufenden Einrichtung wartet der Export bis zum Ergebnis.

## Freigaben auf einen Blick

Der zusätzliche Button **Freigabenübersicht** im Hauptfenster liest die aktuellen Datenfreigaben frisch aus Windows und öffnet ein eigenes Übersichtsfenster. Die Liste zeigt den Freigabenamen, den lokalen Pfad, **Ordner** oder **Ganzes Laufwerk**, den Status und die Verwaltung durch dieses Programm oder Windows/andere Programme. Vom Programm gespeicherte Zugangsarten erscheinen als **Ohne Passwort** oder **Mit Passwort**. Bei fremden Freigaben steht **Windows-Berechtigungen**, weil ihre Anmeldedaten nicht bekannt sind.

Eine Zeile auswählen, um IP-Adresse, Port, Windows-/SMB-Pfad und gegebenenfalls den gespeicherten Benutzernamen zu sehen. **Verbindung kopieren** kopiert diese Daten für eine vorhandene Freigabe. Windows-Systemfreigaben wie `C$`, `ADMIN$` und `IPC$` sind ausgeblendet; selbst angelegte versteckte Datenfreigaben mit einem `$` am Ende bleiben sichtbar.

Seit Version 2.0.5 lassen sich ausgewählte Ordner und Laufwerke direkt hier öffnen und ihre Freigabe entfernen:

- **Ordner / Laufwerk öffnen** öffnet den ausgewählten lokalen Ordner oder das Laufwerk im Windows-Explorer. Das funktioniert auch bei **Nicht mehr freigegeben**, solange der Ordner noch vorhanden und erreichbar ist.
- **Freigabe entfernen** entfernt nach Bestätigung und der Windows-Administratorabfrage genau die ausgewählte Netzwerkfreigabe. Das funktioniert auch bei Freigaben, die Windows oder andere Programme angelegt haben. Dateien, Ordnerrechte, Konten, Firewallregeln und das Änderungsjournal bleiben erhalten. Weitere Freigaben desselben Ordners oder Laufwerks bleiben bestehen.
- Die Übersicht liest die Liste anschließend frisch aus Windows. Fehler werden angezeigt. Hat sich der Freigabepfad inzwischen geändert, wird die Freigabe nicht entfernt; die Übersicht muss zuerst aktualisiert werden. Windows-Systemfreigaben werden nicht entfernt.

**Freigegeben** bedeutet, dass Windows diese SMB-Freigabe aktuell eingerichtet hat. Die Übersicht prüft nicht für jeden Eintrag eine Anmeldung oder die Erreichbarkeit von anderen Geräten. Passende Zugriffsrechte und eine Verbindung im Heimnetz sind weiterhin erforderlich. Ein nur noch im Änderungsjournal vorhandener Eintrag wird als **Nicht mehr freigegeben** angezeigt und zählt nicht zu den aktuellen Freigaben. Seine gespeicherten Daten bleiben für Reparatur oder Rücknahme erhalten. In der sicheren Vorschau starten diese Aktionen weder den Explorer noch eine Freigabeänderung.

## Von Windows auf einen anderen Computer zugreifen

Öffne **Andere Computer** auf dem PC, von dem aus du eine Freigabe öffnen möchtest. Der Freigabe-Assistent auf dem anderen PC richtet dessen Ordner ein; der Verbindungsdialog prüft zusätzlich die Verbindung vom zugreifenden Windows-PC.

1. Oben einen gefundenen **Computer** und seine **Freigabe** auswählen. Öffentlich gemeldete Verbindungsdaten werden automatisch ergänzt. Fehlt das Ziel, **Erneut suchen** verwenden oder **Zielcomputer / IP** und **Freigabename** aus der Freigabenübersicht des anderen PCs eintragen. Beispiel: IP `192.168.178.21`, Freigabe `Desktop`. Der Port ist automatisch `445`.
2. Die gemeldete Zugangsart und den Netzwerk-Benutzer kontrollieren. Bei **Ohne Passwort** bleibt das Passwort leer und der ausgewählte Gastzugang wird automatisch geprüft. Bei **Mit Passwort** das Netzwerk-Passwort eingeben und **Zugriff prüfen** anklicken; keine Windows-PIN verwenden. Unbekannte Konten werden nicht geraten.
3. **Zugriff prüfen** prüft die genaue Datenfreigabe mit dem echten Windows-SMB-Client. Erst eine erfolgreiche Anmeldung und Ordnerauflistung ergeben einen bestätigten Zugriff. Die Diagnose öffnet keine Dateien und verändert keine Windows-Einstellungen. Die automatische Gastverbindung stellt zusätzlich eine Verbindung für deine aktuelle Windows-Sitzung her.
4. **Freigabe öffnen** verbindet die bestätigte Freigabe für deinen aktuellen Windows-Benutzer. Bei bestätigtem Namenszugriff öffnet es den Namenspfad, sonst den geprüften direkten IP-Pfad im Explorer.
5. Bei einer erkannten Blockade **Automatisch beheben** verwenden. Erkennt Windows einen konkreten Gastzugriffs-, Signierungs- oder Verschlüsselungsfehler, kann das Programm auf einem privaten, nicht verwalteten PC nach Auswahl der erklärten Gast-Kompatibilitätsoption die betroffenen SMB-Client-Einstellungen sichern, anpassen und erneut prüfen. Für diese Einstellung ist die Windows-Administratorbestätigung nötig. Die Option ist zunächst ausgeschaltet. Sie betrifft den SMB-Client dieses PCs auch bei anderen künftigen SMB-Verbindungen; ein Zugriff mit Netzwerk-Passwort benötigt diese Lockerung nicht.

Die Reparatur prüft den Zugriff zuerst und ändert bei einer bereits funktionierenden Verbindung nichts. Gast-Kompatibilität wird nur bei den konkreten Windows-Kennungen `1272`, `0xC05D0003` oder `0xC05D0004` angeboten. Andere Fehler erhalten passende Hinweise: unerreichbarer Port, falsche Anmeldung, fehlender Freigabename, Ordnerrechte oder ein bereits verwendetes anderes Windows-Konto. Ein fehlgeschlagener Nachtest nimmt die eigenen neu geänderten Einstellungen wieder zurück. **Client-Änderungen zurücknehmen** stellt später gespeicherte eigene Einstellungen wieder her, auch wenn der andere PC offline ist. Bestehende Freigaben, Dateien und andere Windows-Verbindungen bleiben erhalten.

Die Verbindung ist auf eine genaue Datenfreigabe eines privaten IPv4-Ziels im selben aktiven physischen Heimnetz beschränkt. Computername und aufgelöste Ziel-IP bleiben getrennt sichtbar. Die erste Anmeldung verwendet die geprüfte IP; eine zusätzliche Namensanmeldung ist ausschließlich im Gastmodus mit leerem Passwort möglich. Ein Verbindungsversuch hat ein Zeitlimit von 30 Sekunden. Dieses Programmlimit wird als `APP: CLIENT_NATIVE_TIMEOUT` ausgewiesen; echte Windows-Fehler bleiben mit ihrer Originalkennung erhalten. **Fehlerbericht exportieren** speichert auch diese Verbindungstests als TXT.

### Computer sichtbar, Zugriff über seinen Namen scheitert

Bei **Ohne Passwort** ist **Auch über den Computernamen verbinden** vorausgewählt. Öffne auf dem zugreifenden PC **Andere Computer** und wähle Computer und Freigabe aus. Das Programm übernimmt gültig gemeldete Anmeldedaten und prüft den Gastzugang automatisch. Bei einem erkannten Fehler den angebotenen Reparaturschritt verwenden. Falls du die Daten selbst eintragen musst, lautet das Notebook-Beispiel: `TEST-NOTEBOOK`, `Desktop`, `TEST-NOTEBOOK\Gast`; Passwort leer lassen.

Das Programm stellt zuerst die ausgewählte Anmeldung für die genaue IP-Freigabe in deiner aktuellen Windows-Sitzung her. Dann liest es den tatsächlichen Computernamen am IP-Ziel und prüft dessen Zuordnung im privaten Heimnetz. Es verbindet denselben angegebenen Gastzugang über diesen Namen und prüft **beides**: den ausgewählten Ordner und die vollständige Windows-Freigabenliste. Erst danach wird **Computer öffnen** aktiv. Damit lässt sich der Fall beheben, dass die IP-Freigabe erreichbar ist, Windows beim Computereintrag aber eine anonyme Anmeldung ablehnt.

Diese Anmeldung braucht keine Administratorbestätigung und verändert keine Sicherheitsrichtlinien. Scheitert bereits die IP-Anmeldung mit einer bekannten Gastblockade, ist eine Richtlinienreparatur weiterhin nur mit der gesondert ausgewählten Gast-Kompatibilitätsoption möglich. Nach dieser Reparatur verbindet das Programm erneut im ursprünglichen Windows-Benutzerkonto. Bestehende Verbindungen werden nicht pauschal getrennt; bei einem Kontokonflikt bleibt der ursprüngliche Windows-Code sichtbar.

Ein funktionierender IP-Zugriff bleibt nutzbar, wenn die zusätzliche Namensprüfung scheitert. Der TXT-Bericht trennt IP-Zugriff und Namenszugriff samt Originalcodes. Die Namensanmeldung gilt für die aktuelle Windows-Sitzung; das Programm speichert dafür kein Kennwort. Es prüft und behebt den Zugriff über seine Buttons und überwacht keine außerhalb des Programms geöffneten Explorer-Fehlerfenster.

Ein ausgeschalteter oder schlafender anderer PC, Router-Gerätetrennung oder eine dortige Firewall muss am betroffenen Gerät korrigiert werden. Domänen-/Geräteverwaltungsrichtlinien werden nicht umgangen. Die Freigabenübersicht zeigt eine eingerichtete Freigabe; das ist noch kein Beweis, dass jedes andere Gerät sie erreichen kann. Der Assistent bezeichnet seine eigene Prüfung deshalb ausdrücklich als **SMB-Zugriff lokal geprüft**.

## Andere Geräte richtig verbinden

Die App zeigt die aktuelle IP, Port und den Freigabenamen separat. Für das gezeigte SMB-Dialogfenster:

- **Host / Server:** nur die angezeigte IP, zum Beispiel `192.168.178.24`.
- **Port:** `445` in ein separates Portfeld, falls die Handy-App eines anbietet. Niemals `\445` an den Host anhängen.
- **Ohne Passwort:** **Anonym deaktivieren**. Den im Programm angezeigten Benutzernamen verwenden, zum Beispiel `TEST-PC\Gast`. Nur das Passwort leer lassen. Der Kontoname kann auf anderen PCs anders heißen; deshalb den Kopierbutton verwenden.
- **Mit Passwort:** Anonym deaktivieren; das angezeigte Netzwerk-Konto und dessen Passwort verwenden. Die Windows-PIN ist kein Netzwerk-Passwort.
- Der Anzeigename ist frei wählbar. Danach die gewünschte Freigabe öffnen.

PC und Gerät müssen im selben Heimnetz sein. Der PC muss eingeschaltet und wach bleiben. Die Gerätehilfe erklärt Windows, Samsung/Android, iPhone/iPad, macOS und Linux. Die Dateien-App auf dem anderen Gerät benötigt SMB 2 oder SMB 3.

## Automatisch Blockaden beheben

Die automatische Reparatur ist im Assistenten standardmäßig ausgewählt. Sie prüft und korrigiert benötigte Windows-Dienste, SMB 2/3, privates Netzwerkprofil, eigene Heimnetz-Firewallregeln und SMB-Adapterbindung. Bei eigenen Freigaben behält sie den gespeicherten Zugriffsmodus und findet eine eindeutige aktuelle Heimnetzverbindung wieder, wenn sich der frühere Adapter geändert hat.

Mit der erweiterten Reparatur können benötigte Rechte im ausgewählten Datenordner entsperrt werden. Bei geerbten Verbotsregeln wird die Vererbung ausschließlich an diesem Datenordner getrennt und die übrigen geerbten Rechte werden erhalten. Der übergeordnete Ordner wird nicht verändert. Auf persönlichen PCs kann auch die lokale Netzwerksperre der Gruppe Gäste aufgehoben bzw. der Anmeldemodus von „Nur Gast“ auf Benutzeranmeldung mit Passwort korrigiert werden. Diese lokalen Anmeldeeinstellungen betreffen den gesamten PC; sie werden vor Änderungen gesichert.

Anschließend folgen bis zu drei tatsächliche lokale Wirksamkeitsprüfungen mit gezielter Nachbesserung. Seit Version 2.0.2 prüft das Programm außerdem eine eigene echte SMB-Verbindung: TCP-Port 445, Anmeldung mit dem angezeigten Konto, Öffnen der Freigabe und Auflisten des Ordners. Eine fehlgeschlagene Verbindung wird mit dem betroffenen Schritt und der Servermeldung angezeigt; die neue Einrichtung wird dann zurückgenommen. Beim Passwortmodus wird ein serverseitiger Gast-Fallback abgelehnt. Ohne das bestehende Passwort kann dessen Anmeldung bei einer Reparatur nicht geprüft werden; das Ergebnis sagt dann ausdrücklich, dass nur die Windows-Einstellungen geprüft wurden.

Der Verbindungstest läuft von diesem PC zu seiner Heimnetz-IP. Unternehmensrichtlinien, Sicherheitssoftware, Router-Geräteisolierung und Einstellungen des anderen Geräts können weiterhin den Zugriff verhindern. Das Programm kann deshalb nicht garantieren, dass jedes Gerät unter allen Bedingungen verbindet, und kann unbekannte Passwörter nicht wiederherstellen.

**Gastzugang** aktiviert das eingebaute Gastkonto und lockert bei Bedarf die eingehende SMB-Signaturpflicht des PCs. Die allgemeine Sperre für andere Konten mit leeren Passwörtern bleibt aktiv. **Passwortzugang** verwendet ein eigenes normales Netzwerk-Konto. Vorhandene fremde Konten und Passwörter werden erhalten. Für ein neues Passwort einen neuen Netzwerk-Benutzernamen wählen.

Die Windows-Firewall bleibt erhalten; eigene Regeln gelten für den ausgewählten Heimnetzadapter. Es werden keine Internet-Portweiterleitungen oder SMB1 eingerichtet. Ganze Datenfestplatten sind möglich. Auf dem Windows-Systemlaufwerk bitte einen Datenordner wählen; Windows-/Programmverzeichnisse werden nicht vollständig geöffnet. Geschützte Unterordner können gesonderte Grenzen behalten. Überlappende vom Programm verwaltete Freigaben werden gemeldet, damit ihre Rechte und Rücknahmedaten nicht gegeneinander arbeiten.


Seit Version 2.0.1 werden fehlende Konfigurationen der Windows-Erkennungsdienste `FDResPub` und `fdPHost` vor der Einrichtung automatisch wiederhergestellt, wenn die automatische Blockaden-Reparatur aktiviert ist. Die Definitionen stammen aus den geschützten Originalmanifesten dieses installierten Windows. Die installierte Dienst-DLL muss zum SHA-256 des Manifests passen und zusammen mit dem Diensthost eine gültige Microsoft-Signatur haben. Vor der Reparatur wird der beschädigte Zustand gesichert; anschließend werden die Dienstkonfiguration und der Laufzustand geprüft. Andere Dienste, bestehende Freigaben und eigene Dateien werden dadurch nicht ersetzt.

Das Programm prüft außerdem vor den Freigabeänderungen, ob das geschützte Änderungsjournal sowohl erstellt als auch aktualisiert werden kann. Die Rücknahme verändert einzelne gespeicherte Registrywerte und erhält vorhandene Dienstwerte sowie Unterordner. Firewall-Adressen werden auch in der von Windows gelieferten Netzmaskenschreibweise erkannt. Die Prüfliste zeigt Fehlerursachen direkt in einer eigenen Spalte und darunter vollständig an.

## Computername und Design

**Computername ändern** zeigt den aktuellen Namen und akzeptiert einen leicht merkbaren Namen mit 1 bis 15 Buchstaben, Ziffern oder Bindestrichen. Der neue Name gilt nach einem Windows-Neustart. Die App startet Windows nicht automatisch neu. Bis dahin verwendet die Verbindungshilfe den aktiven Namen.

Das Design folgt dem Windows-7-Aero-Stil: helle Glasverläufe, glänzende Schaltflächen, Licht- und Hovereffekte sowie eine animierte Netzwerkdarstellung. Animationen lassen sich abschalten, beachten die Windows-Einstellungen und pausieren bei verstecktem/minimiertem Fenster. Seit Version 2.0.3 aktualisiert die Kopfanimation ausschließlich den kleinen Lichtpunkt; Titel und Einstellungen werden dabei nicht neu gezeichnet. Die Buttons zeichnen Hintergrund, abgerundeten Aero-Rand, Glanz, Hover und gedrückten Zustand gemeinsam in einem Puffer. Version 2.0.4 aktiviert zusätzlich das Hintergrundzeichnen des angepassten Buttons (`ControlStyles.Opaque = false`), damit auch beim normalen Zeichnen im echten Fenster die äußeren Ecken mit dem Elternhintergrund gefüllt werden. So werden die verbliebenen schwarzen Pixel an den unteren Buttonkanten beseitigt. Hoher Kontrast und Tastaturbedienung werden unterstützt.

Seit Version 2.0.7 ist der Aero-Glass-Look deutlich kräftiger: mehrschichtige cyanblaue Glasflächen, diagonale Lichtreflexe, abgerundete Karten, helle Innenkanten und spiegelnde Schaltflächen. Beim Darüberfahren folgen ein sanftes Leuchten und ein Lichtband; beim Klicken erscheint eine kurze Lichtwelle. Das Netzwerksymbol zeigt wandernde Datenpulse, Bildschirmreflexe und funkelnde Lichtpunkte. Die drei Informationsbereiche öffnen und schließen sich weich, während der Pfeil mitdreht. Ein Glanzband bewegt sich im Ladebalken ausschließlich innerhalb des bereits gezählten Füllstands und nur während eines laufenden Vorgangs.

Über **Animationen** kannst du die Bewegungen abschalten. Die Windows-Einstellungen für reduzierte Animationen und hohen Kontrast werden berücksichtigt. Versteckte oder minimierte Fenster pausieren die Effekte. Die Startansicht bleibt aufgeräumt und die Informationsbereiche beginnen weiterhin geschlossen. Die Glasoptik wird im Programm gezeichnet; Windows selbst erhält kein neues Systemtheme. Titel und Hintergrund sind statisch zwischengespeichert, Texte bewegen oder verblassen beim Aufklappen nicht. Der echte Prozentwert des Ladebalkens bleibt unverändert.

Sprachen: Deutsch, English, Français, Español, Italiano, Português und Polski. Sprachwechsel erhält Ordner, Zugangsdaten und Auswahl.

**Prüfung & Reparatur**, **So verbinden sich deine Geräte** und **Auf deinem Gerät öffnen** stehen untereinander und lassen sich einzeln auf- und zuklappen. Dazu den Pfeil oder die jeweilige Überschrift anklicken; mit der Tastatur funktionieren Enter und Leertaste. Ab Version 2.0.6 starten alle drei Bereiche geschlossen. Die gewählte Ansicht bleibt beim Sprachwechsel und bei einer neuen Prüfung erhalten; Eingabewerte bleiben beim Auf- und Zuklappen unverändert. Die Freigabenübersicht trägt dasselbe Netzwerksymbol wie das Hauptfenster.

## Fortschritt beim Prüfen und Einrichten

Der Ladebalken zählt tatsächlich erledigte Arbeitsschritte und zeigt den zugehörigen Prozentwert. Die Anzeige beginnt bei **0 %**, solange noch kein Schritt abgeschlossen ist, und füllt sich anschließend in einzelnen Prozentschritten bis zum bestätigten Stand. Größere abgeschlossene Arbeitsschritte werden flüssig nachgezeichnet, ohne einen angezeigten Prozentwert zu überspringen. **100 %** erscheint erst, nachdem ein erfolgreiches Ergebnis vorliegt.

Die Prozentzahl beschreibt abgeschlossene Arbeitsschritte, nicht die verbleibende Zeit. Während eines längeren einzelnen Schritts kann der Balken deshalb stehen bleiben; der aktuelle Schritt und die verstrichenen Sekunden bleiben sichtbar. Weder die Laufzeit noch ein Schätzwert erzeugen zusätzliche Prozente. Bei einem Fehler oder einer abgebrochenen Administratorabfrage erreicht der Balken keine 100 %; die Ursache wird angezeigt.

## Sicherung und Rücknahme

**Prüfen** verändert keine Windows-Einstellungen. **Freigabe entfernen** in der Freigabenübersicht entfernt nur die ausgewählte Netzwerkfreigabe und erhält die übrige Einrichtung einschließlich ihrer Rücknahmedaten. Bei eigenen Freigaben erscheint der gespeicherte Eintrag danach als **Nicht mehr freigegeben**.

Die bisherigen Aktionen im Hauptfenster arbeiten dagegen mit der gesamten verwalteten Einrichtung: **Freigabe entfernen** entfernt dort die eigene Freigabe und nimmt ihre gespeicherten Ordnerrechte und eigenen Firewallregeln zurück; nicht mehr benötigte eigene Konten und gemeinsame Einstellungen werden im Rahmen der vorhandenen Rücknahme geprüft. **Einrichtung zurücknehmen** stellt zusätzlich eine vor der Einrichtung bereits vorhandene Freigabe wieder her. Dateien bleiben erhalten. Konflikte mit späteren Änderungen werden gemeldet.

Geschützte Journale liegen unter `%ProgramData%\EinfachNetzwerk`. Passwörter werden dort nicht gespeichert. Kurzlebige Aufträge in `%LocalAppData%\EinfachNetzwerk\Sessions` enthalten nur Windows-DPAPI-geschützte Passwörter; die Auftragsdatei wird anschließend gelöscht.

## Build und Prüfungen

Die öffentlichen Quellen sind nach Aufgaben geordnet: `src/` enthält die C#-Dateien, eingebetteten Windows-Module, Manifest und Icon. `tests/` enthält die Prüfskripte und `tools/` die Hilfswerkzeuge. `build.ps1` und `package.ps1` bleiben im Hauptordner des Repositorys. Alle folgenden Befehle dort mit Windows PowerShell 5.1 ausführen; nicht aus `docs/` oder `src/`.

Build: `powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1` (nur dieser Prozess). Die Ausgabe liegt unter `dist\Einfach-Netzwerk.exe`; die Anleitung wird nach `dist\Anleitung.md` und `dist\Anleitung.txt` kopiert.

Selbsttest: `.\dist\Einfach-Netzwerk.exe --self-test .\dist\bericht.json`

Sichere Vorschau: `.\dist\Einfach-Netzwerk.exe --render-preview .\dist\vorschau.png`

Assistentenvorschau: `.\dist\Einfach-Netzwerk.exe --render-wizard-preview .\dist\assistent.png de`

ZIP-Pakete: `powershell -NoProfile -ExecutionPolicy Bypass -File .\package.ps1`. Das Programm-ZIP enthält EXE und Anleitung. Das Quellcode-ZIP erhält die Ordnerstruktur und die Startskripte im Hauptordner; nach dem Entpacken funktioniert derselbe Buildbefehl.

Prüfbericht: [VERIFICATION.md](VERIFICATION.md). Selbsttest, Vorschau und Probeläufe richten keine echte Freigabe ein. `tests/test-network-discovery.ps1`, `tests/test-discovery-peer.ps1`, `tests/test-discovery-setup.ps1` und `tests/test-client-service-preflight.ps1` prüfen die Netzwerksuche, Datenmeldung, gezielte Freigabeeinrichtung und lokale Dienstprüfung mit isolierten Transport-/Windows-Doubles. Die isolierte Inventarprüfung `tests/test-share-inventory.ps1` prüft aktive und fehlende Einträge sowie Abfragefehler ohne Windows-Änderungen. `tests/test-remove-listed-share.ps1` prüft mit nachgebildeten Windows-Funktionen die gezielte Entfernung, geänderte Pfade und den Schutz der Systemfreigaben. Ein lokaler SMB-Verbindungstest ersetzt keine Prüfung der Verbindung vom jeweiligen anderen Gerät.

`tests/Test-Live.ps1` und Prüfungen mit `-Live` sind gesonderte reale Tests und können Windows-Zustände lesen oder verändern. Sie gehören nicht zur normalen Buildprüfung.

Grundlagen: [SMB-Gastzugang](https://learn.microsoft.com/en-us/windows-server/storage/file-server/enable-insecure-guest-logons-smb2-and-smb3), [SMB-Signaturen](https://learn.microsoft.com/en-us/windows-server/storage/file-server/smb-signing), [Netzwerkerkennung](https://learn.microsoft.com/en-us/windows-server/storage/file-server/troubleshoot/smbv1-not-installed-by-default-in-windows), [Computername ändern](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/rename-computer).

Version 2.0.20 · Rene Box
