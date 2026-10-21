using System;

namespace EinfachNetzwerk
{
    public static partial class I18n
    {
        private const string GuestConnectionHelp = "Ohne Passwort: „Anonym“ deaktivieren; den angezeigten Benutzernamen eintragen, Passwort leer lassen.";

        private static void AddGuestConnection()
        {
            Rows(@"Benutzername|Username|Nom d’utilisateur|Nombre de usuario|Nome utente|Nome de utilizador|Nazwa użytkownika
SMB-Zugriff vom PC geprüft|SMB access from this PC verified|Accès SMB depuis ce PC vérifié|Acceso SMB desde este PC verificado|Accesso SMB da questo PC verificato|Acesso SMB a partir deste PC verificado|Sprawdzono dostęp SMB z tego komputera
Windows-Einstellungen geprüft|Windows settings checked|Paramètres Windows vérifiés|Configuración de Windows comprobada|Impostazioni di Windows verificate|Definições do Windows verificadas|Sprawdzono ustawienia systemu Windows
Passwort leer lassen; Anonym deaktivieren.|Leave the password empty; turn off Anonymous.|Laisser le mot de passe vide ; désactiver Anonyme.|Deja la contraseña vacía; desactiva Anónimo.|Lascia vuota la password; disattiva Anonimo.|Deixe a palavra-passe vazia; desative Anónimo.|Pozostaw hasło puste; wyłącz opcję Anonimowo.
{0}; Passwort leer lassen; Anonym deaktivieren.|{0}; leave the password empty; turn off Anonymous.|{0} ; laisser le mot de passe vide ; désactiver Anonyme.|{0}; deja la contraseña vacía; desactiva Anónimo.|{0}; lascia vuota la password; disattiva Anonimo.|{0}; deixe a palavra-passe vazia; desative Anónimo.|{0}; pozostaw hasło puste; wyłącz opcję Anonimowo.
Benutzername kopieren|Copy username|Copier le nom d’utilisateur|Copiar nombre de usuario|Copia nome utente|Copiar nome de utilizador|Kopiuj nazwę użytkownika
Kopieren|Copy|Copier|Copiar|Copia|Copiar|Kopiuj
Einfach Netzwerk – Verbindung im Heimnetz|Einfach Netzwerk – home network connection|Einfach Netzwerk – connexion au réseau domestique|Einfach Netzwerk – conexión a la red doméstica|Einfach Netzwerk – connessione alla rete domestica|Einfach Netzwerk – ligação à rede doméstica|Einfach Netzwerk – połączenie z siecią domową
Ohne Passwort: „Anonym“ deaktivieren; den angezeigten Benutzernamen eintragen, Passwort leer lassen.|Without a password: turn off “Anonymous”; enter the displayed username and leave the password empty.|Sans mot de passe : désactiver « Anonyme », saisir le nom d’utilisateur affiché et laisser le mot de passe vide.|Sin contraseña: desactiva «Anónimo», introduce el nombre de usuario mostrado y deja la contraseña vacía.|Senza password: disattiva «Anonimo», inserisci il nome utente visualizzato e lascia vuota la password.|Sem palavra-passe: desative «Anónimo», introduza o nome de utilizador apresentado e deixe a palavra-passe vazia.|Bez hasła: wyłącz opcję „Anonimowo”, wpisz wyświetloną nazwę użytkownika i pozostaw hasło puste.");
        }

        private static void RunGuestConnectionSelfTest()
        {
            string saved = Language;
            try
            {
                foreach (LanguageItem item in Languages)
                {
                    Language = item.Code;
                    if (String.IsNullOrWhiteSpace(T(GuestConnectionHelp))) throw new InvalidOperationException("Guest connection instructions are missing.");
                    if (item.Code != "de" && T(GuestConnectionHelp) == GuestConnectionHelp) throw new InvalidOperationException("Guest connection instructions are not translated.");
                    WorkerResult source = new WorkerResult { LoginUserName = @"HOME-PC\VisitorAccount", ConnectionText = "Benutzer: HOME-PC\\VisitorAccount\r\nPasswort: keines" };
                    WorkerResult translated = TranslateResult(source);
                    if (translated.LoginUserName != source.LoginUserName || !translated.ConnectionText.Contains(source.LoginUserName)) throw new InvalidOperationException("Guest account name was changed by localization.");
                }
            }
            finally { Language = saved; }
        }
    }
}
