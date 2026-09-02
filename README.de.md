> 🇩🇪 Deutsche Version · [English version](README.md)

# Redmine expert Helpdesk

[![CI](https://github.com/expertZentrale/redmine_expert_helpdesk/actions/workflows/ci.yml/badge.svg)](https://github.com/expertZentrale/redmine_expert_helpdesk/actions/workflows/ci.yml)
[![Docker image smoke test](https://github.com/expertZentrale/redmine_expert_helpdesk/actions/workflows/docker-image.yml/badge.svg)](https://github.com/expertZentrale/redmine_expert_helpdesk/actions/workflows/docker-image.yml)

E-Mail-zu-Ticket-Plugin für Redmine. Jedes Postfach wählt sein eigenes Backend:
**Microsoft 365** über die Microsoft Graph API oder generisches **IMAP/SMTP** für Google
Workspace, Exchange on-premises, selbst gehostete Server und beliebige Hoster —
authentifiziert per OAuth2/XOAUTH2 oder, wo der Server kein OAuth2 kann, mit
Benutzername und Passwort über TLS.

Zwei CI-Workflows laufen bei jedem Push und Pull Request: die
[Testsuite](.github/workflows/ci.yml) (MiniTest gegen den Redmine-Quellcode für alle
unterstützten Versionen – 5.1, 6.0, 6.1, 7.0 – auf frischer MariaDB) und ein
[Docker-Image-Smoke-Test](.github/workflows/docker-image.yml), der das Plugin in den
**offiziellen `redmine`-Docker-Images** startet, mit denen wir deployen (Tags 5.1, 6.0, 6.1, 7.0) –
siehe [Tests](#tests).

## Inhalt

- [Funktionen](#funktionen)
- [Bildschirmfotos](#bildschirmfotos)
- [Mail-Anbieter](#mail-anbieter) — Backends, Zugangsdaten, Authentifizierung
  - [Rezept: Microsoft 365 über IMAP (nur Anwendung)](#rezept-microsoft-365-über-imap-nur-anwendung)
  - [Rezept: Google Workspace / Gmail (einmalige Zustimmung)](#rezept-google-workspace--gmail-einmalige-zustimmung)
  - [Rezept: selbst gehosteter Server (Dovecot, Zimbra, Hoster)](#rezept-selbst-gehosteter-server-dovecot-zimbra-hoster)
- [E-Mail-Verarbeitung](#e-mail-verarbeitung) — Abrufablauf, Antwortzuordnung, Antwortversand
- [Bisherigen Inhalt zitieren](#bisherigen-inhalt-zitieren)
- [Antwortvorlagen](#antwortvorlagen)
- [Kontakte / Kundenliste](#kontakte--kundenliste)
- [Mailabruf auslösen](#mailabruf-auslösen)
- [SLA-Prüfung auslösen](#sla-prüfung-auslösen)
- [Plugin-Einstellungen](#plugin-einstellungen)
- [REST-API](#rest-api)
- [KI-Zusammenfassungen](#ki-zusammenfassungen)
- [Vollständigkeitsprüfung eingehender Mails](#vollständigkeitsprüfung-eingehender-mails)
- [Wissensbasis (RAG)](#wissensbasis-rag)
- [Tests](#tests) — was die CI ausführt
- [Azure-App-Registrierung (einmalig)](#azure-app-registrierung-einmalig)
- [Installation](#installation)
- [Makros für Vorlagen](#makros-für-vorlagen)
- [Hinweise](#hinweise)
- [Tests ausführen](#tests-ausführen) — selbst ausführen
- [Lizenz](#lizenz)
- [Komponenten von Drittanbietern](#komponenten-von-drittanbietern)

## Funktionen

- **E-Mail zu Ticket**: Mails aus Microsoft 365 oder beliebigen IMAP-Postfächern werden als Tickets angelegt;
  Antworten werden über `In-Reply-To` / `[#id]`-Betreff dem bestehenden Ticket
  zugeordnet (nutzt den Redmine-Standard-`MailHandler`, inkl. Anhänge).
- **Eingebettete Bilder im Ticket**: Die Inline-Bilder einer Mail (Signaturlogos,
  Screenshots) erscheinen dort, wo die Mail sie zeigte, statt eine
  `[cid:…]`-Markierung zu hinterlassen — siehe [Eingebettete Bilder](#eingebettete-bilder).
- **Postfach pro Projekt**: Jedes Projekt konfiguriert seine Postfächer im
  Reiter *Helpdesk* der Projekteinstellungen (Quell-/Zielordner, Standardwerte
  für Tracker/Priorität/Status, Umgang mit unbekannten Absendern).
- **Beliebiger Mail-Anbieter**: Jedes Postfach wählt sein Backend — Microsoft 365
  über die Graph-API oder generisches **IMAP/SMTP** für Google Workspace, Exchange
  On-Premises, selbst gehostete Server (Dovecot, Zimbra) und beliebige Hoster. Die
  Anmeldung erfolgt standardmäßig über **OAuth2/XOAUTH2** (nur Anwendung, einmalige
  Zustimmung oder Dienstkonto); für Server ohne OAuth2 steht Benutzername/Passwort
  über TLS zur Verfügung. Siehe [Mail-Anbieter](#mail-anbieter).
- **Zentrale App-Registrierung**: Tenant-ID, Client-ID und Client-Secret werden
  einmalig unter *Administration → Plugins → Redmine expert Helpdesk* gepflegt;
  einzelne Postfächer können sie durch eigene Zugangsdaten ersetzen.
- **Autoresponder**: Konfigurierbare Bestätigungsmail bei neuen Tickets.
- **Vollständigkeitsprüfung**: Bewertet auf Wunsch die Erstmail eines neuen Tickets —
  regelbasiert oder KI-gestützt — und fragt beim Kunden automatisch die fehlenden Angaben nach.
- **Kundenantworten**: Antwort an den Kunden direkt von der Ticketseite, mit
  Header-/Footer-Vorlagen; Versand als vollständiges MIME aus dem Projektpostfach
  über dessen jeweiliges Backend — Graph oder der eigene SMTP-Server — und in beiden
  Fällen abgelegt in „Gesendete Elemente". Unterstützt Inline-Bilder (via CID),
  normale Anhänge sowie mehrere Empfänger in CC/BCC.
- **Zitieren und Antwortvorlagen**: Ein **Zitieren**-Button neben den
  Formatierungsicons des Notizfeldes fügt die originale Mail, den kompletten
  Verlauf oder nur den Mailwechsel ein — private Notizen nie. Ein
  **Antwortvorlagen**-Button fügt einen Textbaustein mit bereits ausgewerteten
  Makros ein. Siehe [Bisherigen Inhalt zitieren](#bisherigen-inhalt-zitieren)
  und [Antwortvorlagen](#antwortvorlagen).
- **Autocomplete in Adressfeldern**: Beim Tippen in An/CC/BCC werden passende
  Kontakte des Projekts vorgeschlagen (ab 2 Zeichen, Dropdown mit Tastatur-
  und Mausnavigation, kommagetrennte Mehrfacheingabe). Display-Namen mit
  Komma werden automatisch RFC 2822-konform gequotet.
- **Kontakte**: Absender werden automatisch als Kontakte gespeichert;
  Kundenliste im Projekt (paginiert, konfigurierbare Einträge pro Seite),
  Kundeninfo-Panel mit früheren Tickets auf der Ticketseite. Die Ticketliste
  bietet sortierbare Spalten **„Kunde" und „Kunden-E-Mail"** sowie einen
  Kundenfilter auf Name oder E-Mail.
- **Black-/Whitelist**: Absender- und Domainfilter je Postfach.
- **SLA**: Reaktions- und Lösungszeit-Ziele in Geschäftsminuten pro Projekt
  (Arbeitstage + Zeitspanne je Projekt konfigurierbar), optional je Priorität
  überschreibbar. Ampel-Anzeige am Ticket, Tracking von Erstreaktion und
  Lösungszeit, optionale Benachrichtigung bei Überschreitung an
  Eskalations-E-Mail und/oder Projekt-Benutzer (Auslösung über einen eigenen
  `helpdesk/sla_check`-CronJob-Endpunkt, gesichert per eigenem API-Key). Die
  Ticket-Liste bietet zudem **sortier- und filterbare Spalten „SLA Reaktion" /
  „SLA Lösung"** (farbige Status-Chips) für einen schnellen Überblick. Bei aktivem
  SLA zeigt ein Projekt-Reiter **„SLA-Statistik"** Kennzahlen und interaktive,
  responsive Diagramme (Chart.js, lokal gebundelt — kein CDN) für Ticketvolumen,
  Erfüllung, Ø-/Median-Reaktions- und -Lösungszeiten sowie Stoßzeiten nach
  Stunde/Wochentag, gruppierbar nach Tag/Woche/Monat/Jahr.
- **Phishing-Erkennung (PhishTank + Phishing.Database)**: Optionale, pro Projekt aktivierbare
  Prüfung der Links eingehender Mails gegen einen lokalen Spiegel der
  PhishTank-Datenbank und optional des Phishing.Database-Community-Feeds
  (periodischer Download, Intervall konfigurierbar).
  Microsoft SafeLinks werden lokal dekodiert. Bei Treffern werden Links
  entweder neutralisiert (Ticket wird mit Warnbanner und Journal-Notiz
  erstellt) oder die Mail wird in Quarantäne verschoben (Skipped-Ordner,
  kein Ticket) — pro Projekt einstellbar. Manueller Sync:
  `bundle exec rake redmine_expert_helpdesk:phishtank_sync`; automatischer
  Sync läuft huckepack über den `fetch_all`-Endpunkt.
- **Regeln**: Automatisierung nach Betreff/Absender (Priorität, Tracker,
  Kategorie, Zuweisung setzen oder Mail ignorieren).

## Bildschirmfotos

Alle Bildschirmfotos zeigen ein Demo-Projekt mit synthetischen Daten.

### Kundenliste

Jeder Absender wird als Kunde gepflegt – mit Ticketanzahl und letztem Kontakt.

![Kundenliste eines Helpdesk-Projekts: durchsuchbare, seitenweise Tabelle mit Name,
E-Mail-Adresse, Firma, Telefonnummer, Ticketanzahl und Datum des letzten
Tickets](docs/screenshots/de/03-contacts.png)

### Ticket mit Kundenkontext

Die Ticketseite zeigt, wer geschrieben hat, aus welchem Postfach und wie beide SLA-Uhren
stehen.

![Ticketseite mit Helpdesk-Infozeile: Absendername und -adresse, Ursprungspostfach sowie
zwei grüne SLA-Chips für Reaktions- und Lösungszeit](docs/screenshots/de/04-issue-detail.png)

Die Seitenleiste ergänzt die Kundenkarte, frühere Tickets des Kunden und – bei aktiver
Wissensbasis – Lösungsvorschläge aus ähnlichen gelösten Tickets.

![Seitenleiste eines Tickets mit Kundenkarte (Name, E-Mail, Firma, Telefon,
Ursprungspostfach, Liste früherer Tickets) und darunter der KI-Assistent mit
Lösungsvorschlägen aus ähnlichen gelösten Tickets samt
Trefferquote](docs/screenshots/de/05-issue-sidebar.png)

### Antwort an den Kunden

Antworten werden im gewohnten Redmine-Notizfeld geschrieben; das Helpdesk-Panel ergänzt
Empfänger und eine Vorschau der angehängten Signatur.

![Antwort-Panel im Bearbeiten-Formular eines Tickets: Auswahlfeld „Als E-Mail an Kunden
senden“ mit Empfänger, An/CC/BCC-Feldern und einer Vorschau der
Signatur](docs/screenshots/de/06-reply.png)

### SLA-Statistik

Reaktions- und Lösungszeiten je Projekt, gemessen ausschließlich in Geschäftszeiten.

![SLA-Statistik: Kennzahlen zu Tickets, offen, geschlossen und überschritten, ein
Balkendiagramm zur SLA-Erfüllung, das monatliche Ticketvolumen, Durchschnittszeiten im
Zeitverlauf sowie Stoßzeiten nach Stunden und
Wochentagen](docs/screenshots/de/01-sla-dashboard.png)

Derselbe SLA-Status steht als Spalte in der Ticketliste zur Verfügung und lässt sich
sortieren und filtern.

![Ticketliste mit den zusätzlichen Spalten Kunde, SLA Reaktion und SLA Lösung, wobei die
SLA-Zellen als grüne, rote und blaue Status-Chips dargestellt
sind](docs/screenshots/de/09-issue-list.png)

### KI-Nutzungsstatistik

Bei aktiven KI-Zusammenfassungen oder aktiver Wissensbasis wird jede Anfrage protokolliert
und ausgewertet.

![KI-Statistik: Anzahl Anfragen, Token-Verbrauch, Erfolgsquote und Antwortzeit sowie
Diagramme zu Anfragevolumen, Token-Verbrauch im Zeitverlauf, Erfolg gegen Fehler,
Anfragetyp, Anbieter-Modell und Stoßzeiten](docs/screenshots/de/02-ai-dashboard.png)

### Konfiguration

Postfächer, SLA-Ziele, KI- und Wissensbasis-Optionen werden je Projekt eingestellt.

![Helpdesk-Reiter in den Projekteinstellungen mit Abschnitten für Antwort-Einstellungen,
SLA-Ziele inklusive Übersteuerung je Priorität, KI-Zusammenfassung, Wissensbasis und der
Postfachliste](docs/screenshots/de/07-project-settings.png)

Jedes Postfach hat eigene Ordner, Standardwerte für neue Tickets, Absenderfilter,
Autoresponder und Antwortvorlagen.

![Formular zur Postfachkonfiguration mit Postfachadresse und Ordnern, Standardwerten für
neue Tickets, Wiedereröffnungsregeln, Absenderfilter, Auto-Reply-Filter, Autoresponder-Text
und Antwortvorlagen samt Signaturvorschau](docs/screenshots/de/08-mailbox-form.png)

## Mail-Anbieter

Jedes Postfach wählt sein Backend unter *Helpdesk → Postfach → Mail-Anbieter*:

| Anbieter | Eingang | Ausgang | Typischer Einsatz |
|----------|---------|---------|-------------------|
| `graph` (Vorgabe) | Microsoft Graph-API | Graph `sendMail` | Microsoft 365 / Exchange Online |
| `imap` | IMAP | SMTP | Google Workspace, Exchange On-Premises, Dovecot, Zimbra, beliebige Hoster |

Bestehende Postfächer behalten `graph` und benötigen **keine Änderung an der Konfiguration**.

### Woher die Zugangsdaten stammen

*Zugangsdaten* im Postfach-Formular ist ein expliziter Schalter, keine Fallback-Kette:

- **Aus den Plugin-Einstellungen** (`global`) — das Postfach nutzt die zentrale App-Registrierung
  unter *Administration → Plugins → Redmine expert Helpdesk*. Es gibt genau **eine**: die
  bisherigen Werte Tenant-ID / Client-ID / Client-Secret, die Graph seit jeher verwendet.
  IMAP/SMTP-Postfächer mit OAuth2 teilen sie sich, statt eine zweite Kopie vorzuhalten. Die dort
  gewählte Vorlage und das Verfahren entscheiden, welche der übrigen Felder überhaupt nötig sind;
  den Rest blendet die Seite aus.
- **Individuell für dieses Postfach** (`mailbox`) — das Postfach nutzt ausschließlich seine
  eigenen Felder. Das Postfach-Formular blendet sie aus, solange der Schalter auf *Aus den
  Plugin-Einstellungen* steht, denn dort haben sie keinerlei Wirkung.

Ein Postfach nutzt **genau eine Quelle**. Leere Felder werden bewusst *nicht* aus der jeweils
anderen Quelle ergänzt: Ein halb konfiguriertes Postfach, das sich stillschweigend gegen den
falschen Tenant anmeldet, ist genau der Fehlerfall, den das verhindert.

Zusätzlich zur Registrierung liefern die Plugin-Einstellungen einen **Standard-Host** für die
Vorlage *Andere / selbst gehostet* (IMAP/SMTP-Host, Port und Verschlüsselung) — praktisch, wenn
alle Postfächer auf demselben Server liegen. Microsoft- und Google-Postfächer ignorieren ihn, weil
ihre Vorlage die Hosts bereits kennt, und ein ausdrücklicher Wert am Postfach hat immer Vorrang.

Postfachbezogene Geheimnisse (Passwörter, Client-Secrets, Refresh-Tokens, Dienstkonto-Schlüssel)
werden mit dem `secret_key_base` von Rails verschlüsselt gespeichert. Ein leeres Geheimnisfeld
behält den gespeicherten Wert; ein einzelner `-` löscht ihn. **Ein Wechsel von `secret_key_base`
macht gespeicherte Geheimnisse unwiederbringlich** — sie müssen dann neu eingegeben und die
OAuth-Zustimmung erneut erteilt werden.

### Anmeldung

OAuth2 (XOAUTH2) ist die Vorgabe. Drei Verfahren stehen zur Verfügung:

| Verfahren | Zustimmung | Geeignet für |
|-----------|------------|--------------|
| Nur Anwendung (`client_credentials`) | keine | Microsoft 365 mit `IMAP.AccessAsApp` / `SMTP.SendAsApp` |
| Einmalige Zustimmung (`authorization_code`) | einmal je Postfach, Refresh-Token wird gespeichert | Gmail und beliebige andere Identity Provider |
| Dienstkonto (`jwt_bearer`) | keine | Google Workspace mit domainweiter Delegierung |

Benutzername/Passwort über TLS bleibt für Server wählbar, die überhaupt kein OAuth2 anbieten
(Dovecot, Zimbra, kleine Hoster). Microsoft 365 akzeptiert keine Basisauthentifizierung mehr.

Die im Formular angezeigte **Callback-URL** muss wortgleich als Redirect-URI beim Identity
Provider hinterlegt werden — es ist ein einziger fester Pfad (`/helpdesk/oauth/callback`), weil
Provider nur exakt registrierte URIs akzeptieren. Welches Postfach gerade verbunden wird, steckt
in einem signierten, zehn Minuten gültigen `state`-Parameter.

Mit **Verbindung testen** lassen sich Host, TLS und Anmeldung vor dem Speichern prüfen; die
sichtbaren Ordner werden dabei gleich mit aufgelistet. Schlägt der Test fehl, wird die Meldung des
Anbieters angezeigt, und **Meldung kopieren** legt sie vollständig in die Zwischenablage – solche
Meldungen sind lang und die Statuszeile bricht um, das auf dem Bildschirm Lesbare ist also nicht
immer das, was man in ein Ticket einfügen möchte. Bei Microsoft 365 enthält die Meldung den
Graph-Fehlercode, und der unterscheidet ein `ErrorAccessDenied` (der Exchange-RBAC-Scope deckt
dieses Postfach nicht ab) von einem `MailboxNotEnabledForRESTAPI` (das Postfach ist inaktiv,
vorläufig gelöscht oder liegt noch on-premises) – zwei 403er, die sonst nichts gemeinsam haben.

### Rezept: Microsoft 365 über IMAP (nur Anwendung)

Sinnvoll, wenn statt der Graph-API IMAP/SMTP genutzt werden soll, z. B. um für mehrere Anbieter
denselben Weg zu verwenden.

1. In Entra ID eine App registrieren und die **Anwendungsberechtigungen** `IMAP.AccessAsApp` und
   `SMTP.SendAsApp` erteilen (Administratorzustimmung erforderlich).
2. Den Dienstprinzipal in Exchange Online registrieren und auf das Postfach beschränken:

   ```powershell
   New-ServicePrincipal -AppId <client-id> -ObjectId <object-id>
   Add-MailboxPermission -Identity "helpdesk@example.com" -User <object-id> -AccessRights FullAccess
   ```

3. Im Postfach-Formular: Anbieter `IMAP / SMTP`, Vorlage **Microsoft 365**, Verfahren
   **Nur Anwendung**, dann Tenant-ID, Client-ID und Client-Secret eintragen (oder
   *Zugangsdaten* auf *Aus den Plugin-Einstellungen* stehen lassen, um die zentrale
   Registrierung weiterzuverwenden). Host und Port sind vorbelegt:
   `outlook.office365.com:993` und `smtp.office365.com:587`.

### Rezept: Google Workspace / Gmail (einmalige Zustimmung)

1. In der Google Cloud Console eine **OAuth-Client-ID** vom Typ *Webanwendung* anlegen und die
   Callback-URL des Plugins als autorisierte Redirect-URI eintragen.
2. Den Scope `https://mail.google.com/` freigeben und den OAuth-Zustimmungsbildschirm
   **veröffentlichen** — Refresh-Tokens, die im Status *Testing* ausgestellt werden, verfallen
   nach 7 Tagen.
3. Im Postfach-Formular: Anbieter `IMAP / SMTP`, Vorlage **Google Workspace / Gmail**, Verfahren
   **Einmalige Zustimmung**, Client-ID und Client-Secret eintragen, speichern, anschließend
   **Verbinden** drücken und die Google-Zustimmung abschließen.

Gmail bildet Ordner als Labels ab — das Verschieben einer Mail ändert ihr Label. Für die
Sonderordner die Pfade `[Gmail]/…` verwenden.

Für eine Workspace-Domain lässt sich stattdessen ein **Dienstkonto** mit domainweiter
Delegierung verwenden (Verfahren *Dienstkonto*, Scope `https://mail.google.com/`): Adresse des
Dienstkontos und dessen privaten PEM-Schlüssel eintragen, eine interaktive Zustimmung entfällt.

### Rezept: selbst gehosteter Server (Dovecot, Zimbra, Hoster)

1. Anbieter `IMAP / SMTP`, Vorlage **Andere / selbst gehostet**.
2. IMAP- und SMTP-Host, Port und Verschlüsselung eintragen (`SSL/TLS` auf 993/465, `STARTTLS`
   auf 143/587).
3. Anmeldung **Benutzername und Passwort**, dann Postfachbenutzer und Passwort (bzw. ein
   App-Passwort, sofern der Anbieter eines anbietet). Das SASL-Verfahren wird ausgehandelt: IMAP
   nutzt das Kommando `LOGIN`, sofern der Server nicht `LOGINDISABLED` anzeigt — dann meldet es
   sich mit `PLAIN` oder `LOGIN` an; SMTP nimmt das erste von `PLAIN`, `LOGIN`, `CRAM-MD5`, das
   der Server anbietet. Die meisten Server akzeptieren ein Passwort nur über TLS, deshalb
   `SSL/TLS` oder `STARTTLS` beibehalten.
4. *Zertifikat prüfen* nur bei einem selbst signierten Zertifikat in einem vertrauenswürdigen
   Netz deaktivieren — jede Nutzung wird als Warnung protokolliert.

### Wissenswertes zum IMAP-Verhalten

- Nachrichten werden durchgängig über ihre **UID** angesprochen, sodass paralleler Zugriff auf
  das Postfach keine Verwechslungen verursachen kann.
- Das Abrufen markiert eine Mail nicht von selbst als gelesen (`BODY.PEEK`); `\Seen` wird
  explizit gesetzt, wenn die Mail in den Zielordner verschoben wird. Für Umgebungen ohne
  Verschiebemöglichkeit gibt es *Nur ungelesene Mails abrufen*.
- Ordnernamen werden als lesbarer Text mit `/` als Trennzeichen eingetragen und auf dem
  Transportweg in modifiziertes UTF-7 sowie das Trennzeichen des Servers übersetzt, sodass Namen
  wie `Gelöschte Elemente` funktionieren.
- Verschoben wird mit `MOVE` (RFC 6851), sofern der Server es anbietet, sonst mit `COPY` +
  `\Deleted` + `UID EXPUNGE`. **Ein Server ohne `MOVE` und ohne `UIDPLUS` fällt auf ein einfaches
  `EXPUNGE` zurück, das auch andere bereits als gelöscht markierte Mails im Quellordner
  endgültig entfernt.**

## E-Mail-Verarbeitung

### Ablauf pro Postfachabruf

```
Graph API (Quellordner)
        │
        ▼
  Black-/Whitelist-Prüfung ──── abgelehnt ─────▶ Skipped-Ordner
        │
        ▼
  Ignorieren-Regeln ─────────── trifft zu ─────▶ Skipped-Ordner
        │
        ▼
  Rohes MIME herunterladen (Graph / IMAP BODY.PEEK)
        │
        ▼
  Auto-Reply-Filter ────────── Abwesenheit ────▶ Skipped-Ordner
        │                      (optional pro Postfach; Absender auf der
        │                       Whitelist werden trotzdem verarbeitet)
        ▼
  Phishing-Prüfung ─────── Treffer + „quarantine" ─▶ Skipped-Ordner (kein Ticket)
        │                  (optional pro Projekt; bei „neutralize" werden die
        │                   Links im Body ersetzt, die Verarbeitung läuft weiter)
        ▼
  MIME-Vorverarbeitung
    ├─ Thread-Header entfernen, wenn das referenzierte Ticket geschlossen und
    │  älter als reopen_max_age_days des Postfachs ist → erzwingt ein NEUES Ticket
    ├─ Auto-Submitted-Header bei NDR-/Bounce-Mails entfernen
    │  (MailHandler würde sie sonst als Auto-Reply ablehnen)
    ├─ In-Reply-To/References auf den Ticket-Thread setzen, damit Antworten auch
    │  ohne [#id] im Betreff zugeordnet werden
    └─ <img src="cid:…"> als [cid:…] markieren, wenn der Text aus dem HTML-Teil
       entsteht (nur diese Kopie – die unten archivierte .eml bleibt das Original)
        │
        ▼
  Redmine MailHandler ──────── abgelehnt ──────▶ Skipped-Ordner
    (Ticket anlegen oder        (z. B. eigene Adresse)
     Journal ergänzen)
        │
        ▼
  [cid:…]-Markierungen auf die gespeicherten eingebetteten Bilder zeigen lassen
        │
        ├─ neues Ticket: Regeln anwenden
        └─ Antwort:      Ticket wiedereröffnen, falls geschlossen
                         (Wiedereröffnungsstatus pro Postfach)
        │
        ▼
  Kontakt verknüpfen + HelpdeskTicketInfo (Kontakt, Herkunftspostfach, SLA-Uhren)
        │
        ▼
  HelpdeskMessage erstellen (direction=in) + Originalmail als .eml anhängen
        │
        ▼
  Autoresponder (nur bei neuen Tickets, wenn am Postfach aktiviert)
        │
        ▼
  Phishing-Hinweis (nur wenn Treffer oder Verdachtsfälle gefunden wurden)
        │
        ▼
  KI-Zusammenfassung einreihen (optional, asynchron – blockiert nie den Abruf)
        │
        ▼
  In den Processed-Ordner verschieben, als gelesen markieren


  Jede Exception während der Verarbeitung ──▶ Failed-Ordner,
  festgehalten in last_error / last_error_at des Postfachs
```

**Zielordner**: Der Ablauf nutzt drei getrennte Ziele – `processed_folder` für erfolgreich
verarbeitete Mails, `skipped_folder` für alles, was vor der Ticketerstellung abgelehnt wurde, und
`failed_folder` für Mails, bei denen eine Exception aufgetreten ist. Skipped und Failed fallen auf
`processed_folder` zurück, wenn sie leer sind; ist auch dieser leer, bleibt die Mail liegen und wird
lediglich als gelesen markiert. Abgelehnte Mails werden verschoben statt liegen gelassen, damit sie
nicht bei jedem Abruf erneut geprüft werden.

**Fehlerisolierung**: Jede Nachricht wird in einem eigenen `begin`/`rescue` verarbeitet – eine
einzelne fehlerhafte Mail bricht den Lauf also nie ab, sondern landet im Failed-Ordner, wird im
Ergebnis gezählt, und der Abruf setzt mit der nächsten Nachricht fort. Auch die optionalen Schritte
(Phishing, Autoresponder, KI) sind nicht fatal: Sie protokollieren den Fehler und laufen weiter,
statt die Verarbeitung abzubrechen.

### Zuordnung von E-Mail-Antworten zu bestehenden Tickets

Die Zuordnungsentscheidung selbst trifft **Redmines eigener `MailHandler`** – das Plugin stellt die
MIME-Daten bereit und wertet das Ergebnis aus. Es nimmt allerdings über die oben beschriebene
Vorverarbeitung Einfluss: Es setzt `In-Reply-To`/`References`, damit Antworten auch ohne `[#id]` im
Betreff zugeordnet werden, und entfernt genau diese Header wieder, wenn das referenzierte Ticket
geschlossen und älter als das Wiedereröffnungslimit des Postfachs ist – dann wird bewusst ein neues
Ticket erzeugt, statt einen längst abgeschlossenen Thread wiederzubeleben.

Der `MailHandler` prüft in dieser Reihenfolge:

1. **`In-Reply-To`- / `References`-Header**  
   Redmine speichert die Message-ID jeder ausgehenden Benachrichtigung. Findet
   der Handler eine übereinstimmende ID in diesen Headern, wird die Mail als
   Kommentar (Journal) an das entsprechende Ticket angehängt.

2. **`[#id]`-Muster im Betreff**  
   Enthält der Betreff ein Muster wie `[#42]`, wird Ticket #42 gesucht. Wird
   es gefunden, entsteht ein Journal; andernfalls wird ein neues Ticket
   angelegt.

3. **Kein Treffer**  
   Ein neues Ticket wird im konfigurierten Projekt erstellt, mit Standardwerten
   für Tracker, Priorität und Status aus der Postfachkonfiguration.

> **Hinweis**: Der `MailHandler` verwaltet auch Benutzeranlage und
> Berechtigungsprüfungen. `unknown_user_mode` am Postfach steuert, was bei
> unbekannten Absendern passiert (`accept`, `create`, `ignore`).

### Tickets, die auf Bearbeitung warten

Trifft eine eingehende Mail zu einem **bestehenden** Ticket ein, wird dieses Ticket als **Wartet
auf Bearbeitung** markiert – damit es nicht zwischen Tickets untergeht, auf die niemand wartet.
Dasselbe gilt, wenn eine Antwort ein geschlossenes Ticket wiedereröffnet; als Grund erscheint dann
*Wiedereröffnet* statt *Kunde hat geantwortet*, und die Wiedereröffnung wird in der Ticket-Historie
vermerkt.

Gespeichert wird der Zeitpunkt der **ältesten unbeantworteten** Kundenantwort – eine zweite Antwort
lässt ein seit Tagen wartendes Ticket also nicht wieder frisch aussehen. Die Markierung entfällt,
wenn

- ein Mitarbeiter eine **öffentliche** Notiz schreibt (eine private Notiz ist eine interne
  Anmerkung, keine Antwort), oder
- das Ticket geschlossen wird – auch per Sammelbearbeitung oder über die REST-API.

Vier Stellen zeigen sie an:

| Oberfläche | Was man sieht |
| --- | --- |
| Ticket-Liste | Spalte *Wartet auf Bearbeitung* (sortierbar, längste Wartezeit zuerst) und Filter |
| Zeilen der Ticket-Liste | Wartende Tickets erhalten einen Marker am linken Rand |
| Seitenleiste der Ticket-Liste | Zähler mit Link auf die gefilterte Liste |
| Meine Seite | Block *Helpdesk: Wartet auf Bearbeitung* – eigene wartende Tickets, älteste zuerst |

Zwei Hinweise:

- Ein Kunde, der Projektmitglied mit der Berechtigung *Kundenantworten senden* ist, gilt als
  Mitarbeiter – seine Mails markieren ein Ticket daher nie.
- Wird ein Ticket nach dem Schließen manuell wiedereröffnet, kehrt die Markierung nicht zurück;
  nur eine neue eingehende Mail setzt sie erneut.

Abschaltbar unter *Administration → Plugins → Redmine expert Helpdesk*.

### Eingebettete Bilder

Mailprogramme legen Bilder nicht in den Text, sondern verweisen von dort auf einen angehängten
Bildanhang – in Outlook als `[cid:image001.png@01DD2980.37ED1560]`, in Gmail als
`[image: logo.png]`, in HTML als `<img src="cid:…">`. Redmines `MailHandler` speichert das Bild
zwar als Ticket-Anhang, lässt den Text aber unverändert – eine Mailsignatur kam deshalb bisher als
Reihe von `[cid:…]`-Markierungen an.

Das Plugin lässt diese Markierungen auf den soeben gespeicherten Anhang zeigen, in der Bildsyntax
der eingestellten Textformatierung (`!image001.png!` bei Textile, `![](image001.png)` bei
Markdown/CommonMark) – das Ticket liest sich damit wie die Originalmail. Das gilt für die
Beschreibung eines neuen Tickets ebenso wie für die Notiz einer Antwort.

Wissenswert:

- Verlinkt werden nur Bildformate, die Redmine inline darstellen kann (`bmp`, `gif`, `jpg`, `jpe`,
  `jpeg`, `png`, `webp`). Eine Markierung ohne zugehöriges Bild – etwa weil es unter
  *Administration → Konfiguration → Eingehende E-Mails → Ausgeschlossene Dateinamen* aussortiert
  wurde – bleibt stehen, statt kommentarlos zu verschwinden.
- Erzeugt Redmine den Tickettext aus dem **HTML-Teil** (keine Text-Alternative vorhanden oder
  *Bevorzugter Nachrichtenteil* auf `html` gestellt), werden die `<img>`-Tags vor der Übergabe an
  den `MailHandler` in dieselbe Markierung umgeschrieben – Redmines HTML-zu-Text-Umwandlung würde
  Bilder sonst spurlos verwerfen. Verändert wird nur die Kopie für den `MailHandler`; die am Ticket
  archivierte `.eml` ist immer die unveränderte Originalmail.
- Die Bilder bleiben normale Ticket-Anhänge, an Download und Anhangsliste ändert sich nichts.

Abschalten lässt sich das unter
*Administration → Plugins → Redmine expert Helpdesk → Eingebettete Bilder*.

### EML-Anhang und Journalverlinkung

Jede verarbeitete Mail wird als `.eml`-Datei am Ticket gespeichert (Anhang mit
Beschreibung *Original E-Mail*). Die Datei ist über die Kundenkarte in der
Ticket-Seitenleiste erreichbar.

Bei **Antwortmails** (d. h. die Mail wird als Journal an ein bestehendes Ticket
angehängt) wird zusätzlich ein Download-Link am Anfang des Journalkommentars
eingefügt, sodass die originale Mail direkt aus dem Ticket-Verlauf geöffnet
werden kann.

### Kundenantworten aus Redmine heraus

Antwortet ein Bearbeiter über das Ticket-Formular („Als E-Mail an Kunden
senden"), wird die Antwort als vollständige MIME-Nachricht über den
Graph-API-Endpunkt `/users/{mailbox}/sendMail` (mit `Content-Type: text/plain`
+ Base64-kodiertem MIME-Body) versendet. Dieses Verfahren hält die
MIME-Struktur vollständig erhalten – insbesondere für CID-Inline-Bilder –
da Exchange Online das HTML-Body andernfalls beim JSON-Versand umschreibt.

Das Plugin speichert dabei:

- eine ausgehende `HelpdeskMessage` mit Empfänger-To/CC/BCC und Zeitstempel,
- der Mail-Body entspricht dem Redmine-Notizfeld (Wiki-Markup → HTML), ergänzt
  um das konfigurierte Header-/Footer-Template des Postfachs.

Der Betreff wird aus der Projekteinstellung *Betreff-Vorlage* generiert
(Standard: `Re: [#{{issue.id}}] {{issue.subject}}`).

**Inline-Bilder**: Bilder, die per Drag & Drop oder Einfügen in das
Notizfeld eingefügt werden, erscheinen im Empfänger-Postfach als eingebettete
Inline-Bilder (CID-Methode, nicht als Anhang).

**Transportwahl**: Jedes Postfach wählt einen von drei Antwort-Transporten:

| Wert | Versand über | Inline-Bilder | Kopie im Gesendet-Ordner |
|------|--------------|---------------|--------------------------|
| `provider` (Vorgabe für neue Postfächer) | das Backend des Postfachs — Graph-API oder eigener SMTP-Server | CID | ja |
| `graph` | Microsoft Graph über die zentrale App-Registrierung | CID | ja |
| `smtp` | globale SMTP-Einstellungen von Redmine aus der `configuration.yml` | Base64-Data-URI | nur IMAP-Postfächer |

**Abweichender Absender (From)**: Ein Postfach auf dem Weg `smtp` darf unter einer anderen
Adresse als der Postfach-Adresse senden — *Abweichender Absender (From)* im Postfach-Formular;
leer bedeutet „unter der Postfach-Adresse senden". Zwei Punkte dazu:

- `Reply-To` wird standardmäßig **nicht** gesetzt. Der übliche Grund für einen Override ist ein
  Verteiler, der zu einem Helpdesk-Postfach wurde: Die Verteiler-Adresse existiert weiter, dieses
  Postfach ist ihr einziges Mitglied, Antworten an den Verteiler kommen also ohnehin hier an — ein
  `Reply-To` würde nur die interne Adresse offenlegen. Stellt die Override-Adresse *nicht* in
  dieses Postfach zu, *Reply-To auf die Postfach-Adresse setzen* aktivieren; sonst finden
  Kundenantworten nicht ins Ticket zurück.
- Der Relay aus der `configuration.yml` muss für diese Adresse senden dürfen. Das ist eine
  SPF-/DMARC-Frage der Mail-Infrastruktur; das Plugin prüft nur die Syntax.

Für die Wege `provider` und `graph` blendet das Formular das Feld aus und das Modell ignoriert es:
Beide authentifizieren sich *als* das Postfach und lehnen einen fremden Absender ab.

`graph` wird **nur für ein Postfach angeboten, das Microsoft auch hostet** — ein Graph-Postfach
oder ein IMAP-Postfach, dessen **wirksame** OAuth2-Vorlage Microsoft ist („Microsoft 365 über
IMAP“). Wirksam heißt: die eigene Vorlage nur, wenn *Zugangsdaten* auf *Individuell für dieses
Postfach* steht, sonst die aus den Plugin-Einstellungen. Ein Gmail- oder Dovecot-Postfach auf Graph
zu stellen hieße, `sendMail` für eine Adresse aufzurufen, die es im Tenant nicht gibt; das Formular
blendet die Option deshalb aus und das Modell lehnt sie ab. Aus demselben Grund wird sie nur
angeboten, wenn die **zentrale App-Registrierung konfiguriert** ist — sonst wäre es ein Weg, der
erst beim Senden scheitert. (Ein Graph-Postfach ist von dieser zweiten Bedingung ausgenommen: sein
Backend ist ohnehin Graph, und die Forderung würde es unspeicherbar machen, solange die Azure-App
noch eingerichtet wird.)

Ausgehende Mails werden im **Gesendet-Ordner** des Postfachs abgelegt, damit das Postfach beide
Hälften der Unterhaltung enthält. Graph erledigt das selbst; bei IMAP legt das Plugin die Kopie
ab und nimmt den Ordner aus dem `\Sent`-Kennzeichen des Servers (RFC 6154), dann aus dem Feld
*Ordner für gesendete Mails*, dann aus der Vorlage. Lässt sich die Kopie nicht ablegen, wird die
Mail trotzdem versendet — protokolliert wird nur eine Warnung.

`smtp` ist der Weg, der **am Postfach überhaupt keine Mail-Zugangsdaten** braucht — praktisch,
wenn Redmine bereits ein funktionierendes Relay hat und das Postfach nur *empfangen* soll. Ein
IMAP-Postfach auf diesem Weg benötigt auch keinen SMTP-Host. Der Preis sind die Inline-Bilder:
Hier werden sie als data-URI eingebettet statt als CID-Anhang, was manche Clients nicht anzeigen.

Der Autoresponder nutzt denselben Transport wie Antworten.

**Jeder Versand wird protokolliert.** Da drei Transportwege und vier Absender (Agenten-Antwort,
Initialmail, Autoresponder, SLA-Benachrichtigung) am Ende alle nur "eine Mail hat Redmine
verlassen" bedeuten, schreibt jeder Versand eine Logzeile mit dem verwendeten Weg:

```
[helpdesk] mail sent: kind=reply via="mailbox SMTP (smtp.example.com:587)" mailbox=support@example.com \
  project=support issue=#4711 to="kunde@example.com" message_id=<...> subject="Re: [#4711] Drucker defekt"
```

Ein fehlgeschlagener Versand wird als `[helpdesk] mail FAILED: …` samt Exception protokolliert,
immer auf **error**-Level, und die Exception wird wie bisher weitergeworfen. Das Level der
Erfolgsmeldung ist unter *Administration → Plugins → Redmine expert Helpdesk → Protokollierung*
konfigurierbar (`debug` / `info` / `warn` / `error`, Standard `info`) — mit `debug` bleibt sie aus
einem Produktiv-Log heraus, das standardmäßig ab `info` schreibt.

Die gespeicherten Empfängeradressen werden nach dem Seitenaufruf in den
Journalüberschriften als Badge eingeblendet (clientseitig über die in
`helpdesk_messages.journal_id` gespeicherte Journal-Verknüpfung). Am Ende des
Badges steht der **Sendezeitpunkt** (`HelpdeskMessage.sent_at`) – genau wie
beim Badge eingehender Mails deren Sendezeitpunkt angezeigt wird. So lässt sich
der Schriftwechsel in beide Richtungen auf einer Zeitachse verfolgen,
unabhängig davon, wann der Journaleintrag selbst gespeichert wurde.

**Automatische Feldaktualisierung nach dem Senden**: Optional können in den
Projekteinstellungen (*expert Helpdesk → Antwort-Einstellungen*) ein Ziel-Status
und die automatische Zuweisung an den Absender konfiguriert werden. Beide
werden nach erfolgreichem Versand gesetzt, bevor das Ticket-Formular
abgesendet wird. Die Zuweisung greift nur, solange das Ticket **niemandem
gehört** — weder gespeichert (Benutzer oder Gruppe) noch im gerade abzusendenden
Formular ausgewählt —, überschreibt also nie eine bereits getroffene
Zuordnung.

### Tickets zuweisen

Wer ein Ticket bekommt, entscheiden drei Einstellungen in dieser Reihenfolge:

| Einstellung | Wo | Gilt für |
|-------------|----|----------|
| `Assigned to:`-Schlüsselwort in der Mail | die Mail selbst | Wird von Redmines eigenem `MailHandler` ausgewertet und hat Vorrang vor allem Folgenden. |
| Postfach-Regel *Zuweisen an* | *expert Helpdesk → Postfach → Regeln* | Nur wenn die Bedingung auf Betreff oder Absender passt. Ziel kann ein Benutzer **oder** eine Gruppe sein. |
| **Neue Tickets zuweisen an** | *Projekteinstellungen → expert Helpdesk → Antwort-Einstellungen* | Jedes neue Ticket, das die Postfächer dieses Projekts erzeugen. Voreinstellung: nicht zuweisen. |

**Neue Tickets zuweisen an** bietet die zuweisbaren Projektmitglieder an,
getrennt nach *Benutzern* und *Gruppen*. Gruppen erscheinen nur, solange unter
*Administration → Konfiguration → Ticket-Verfolgung* die Option *Zuweisung von
Tickets an Gruppen erlauben* aktiv ist — es ist dieselbe Liste wie im
Ticketformular, auswählbar ist also immer nur ein Bearbeiter, den Redmine auch
akzeptiert. Verliert der gewählte Benutzer bzw. die Gruppe später die Rolle oder
das Projekt, wird die Vorgabe still übersprungen, statt ungültige Tickets zu
erzeugen.

Alle drei gelten nur für **neue** Tickets. Eine Antwort weist ein Ticket nie neu
zu — außer über *Ticket nach Antwort mir zuweisen* (siehe oben), und das auch nur,
solange das Ticket niemandem gehört.

### Bisherigen Inhalt zitieren

Neben den Formatierungsicons des Notizfeldes steht ein **Zitieren**-Button mit
drei Einträgen. Jeder hängt seinen Text unten an das Notizfeld an, getrennt
durch eine Leerzeile — bereits Getipptes wird nicht überschrieben.

| Eintrag | Was zitiert wird |
|---------|------------------|
| Originale Mail | Die Ticketbeschreibung, also die Mail, aus der `MailHandler` das Ticket gemacht hat. Inline-Bilder sind zu diesem Zeitpunkt bereits aufgelöst, das Zitat entspricht also dem, was im Ticket steht. |
| Kompletter Verlauf | Die Beschreibung sowie alle öffentlichen Journal-Notizen, älteste zuerst, jeweils mit Verfasser und Zeitstempel. |
| Mail-Verlauf | Die Beschreibung sowie nur die Notizen, zu denen es eine tatsächlich vom oder an den Kunden gesendete Mail gibt. |

Drei Regeln, die man kennen sollte:

- **Private Notizen werden nie zitiert**, auch nicht für Bearbeiter mit
  `view_private_notes`. Das Ergebnis ist für einen Kunden bestimmt, also zählt
  allein, ob der Kunde es sehen darf. Private KI-Zusammenfassungen entfallen aus
  demselben Grund.
- **Die Buchungsnotizen des Plugins bleiben außen vor** — „Autoresponder
  versendet", „Phishing-Links entfernt". Sie sind öffentlich und vom anonymen
  Benutzer verfasst, tragen aber keine `HelpdeskMessage`; eine echte Kundenmail
  tut das immer, auch wenn `MailHandler` sie unter dem anonymen Benutzer ablegt.
- **Eine ausgehende Mail ohne Journal-Verknüpfung lässt sich nicht zitieren.**
  `helpdesk_messages` speichert keinen Nachrichtentext, ein Eintrag ohne
  `journal_id` — der Autoresponder und die initiale Mail eines ausgehenden
  Tickets — hat also keinen eigenen Text. Bei diesen Tickets *ist* die
  Beschreibung die versendete Mail, und die ist immer enthalten.

Zwischen den Einträgen steht eine Trennlinie (`---`), damit ein langer Verlauf
beim Scrollen überblickbar bleibt. Sehr lange Verläufe werden gekürzt
(50 Einträge / 60 000 Zeichen), damit das Notizfeld bedienbar bleibt; die
Werkzeugleiste weist darauf hin.

Im Text referenzierte Bilder – auch die, die ein Zitat aus der Ursprungsmail
mitbringt – werden als Inline-Teile der Mail versendet, der Kunde sieht also die
Bilder und kein leeres Kästchen.

### Antwortvorlagen

Da sich Supportfälle wiederholen, lassen sich Standardantworten als Vorlagen
hinterlegen und über einen **Antwortvorlagen**-Button neben dem Zitieren-Button
einfügen. Zuerst erscheinen die Vorlagen des Projekts, dann die globalen, jeweils
nach Position und Name; ein Projekt kann eine zentrale Formulierung also
überschreiben, indem es denselben Namen verwendet.

- **Globale Vorlagen**: *Administration → Plugins → Redmine expert Helpdesk →
  Antwortvorlagen*. Nur für Administratoren.
- **Projektvorlagen**: Projekteinstellungen, Reiter *expert Helpdesk*, Abschnitt
  *Antwortvorlagen*. Erfordert `manage_helpdesk`.

Der Inhalt versteht dieselben Makros wie Autoresponder-, Kopf-/Fußzeilen- und
Betreffvorlagen (siehe [Makros für Vorlagen](#makros-für-vorlagen)). Ausgewertet werden
sie beim Einfügen auf dem Server, denn ein Makro braucht das Ticket, dessen
Kunden und den handelnden Benutzer. Bei einem Ticket ohne zugeordneten Kunden
bleiben die Kontakt-Makros einfach leer — Vorlagen funktionieren dort trotzdem,
ebenso das Zitieren.

Zitate und Vorlagen einzufügen erfordert die Berechtigung `send_helpdesk_reply`,
dieselbe, die auch das Antwortformular schützt.

## Kontakte / Kundenliste

Absender werden beim ersten Postfachabruf automatisch als `HelpdeskContact`
gespeichert und dem Projekt zugeordnet.

### Ticketlisten-Spalten

Die Ticketliste bietet zwei optionale, sortierbare Spalten: **Kunde**
(Anzeigename des Kontakts) und **Kunden-E-Mail** (nur die E-Mail-Adresse —
nützlich, wenn Anzeigenamen lang oder unklar sind). Beide zeigen den Kunden
des Tickets: den beim Mail-Eingang verknüpften oder den vom Agenten
zugewiesenen Kontakt. Der Filter **Kunde** durchsucht Name oder E-Mail und
deckt beide Spalten ab. Tickets ohne Kunden (z. B. von Agenten ohne
Zuweisung erstellt) bleiben leer.

### Kundenliste (Projekt-Reiter „Kunden")

- Tabellarische Übersicht aller Kontakte mit Name, E-Mail, Firma, Telefon,
  Ticket-Anzahl und Datum der letzten Nachricht.
- **Paginierung**: Die Liste wird seitenweise angezeigt. Per-Seite-Wähler
  (10 / 25 / 50 / 100) oben rechts; Standardwert konfigurierbar unter
  *Administration → Plugins → Anzeigeeinstellungen → Einträge pro Seite*.

### Kundenprofil (Bearbeitungsansicht)

- Name, Firma, Telefon und interne Notizen bearbeitbar.
- Liste der zuletzt verknüpften Tickets (neueste zuerst).
  Die Anzahl der angezeigten Tickets ist unter
  *Administration → Plugins → Anzeigeeinstellungen → Max. Tickets im Kundenprofil*
  konfigurierbar (Standard: 10). Bei mehr Tickets erscheint ein Hinweis
  „Zeigt die N neuesten von insgesamt X Tickets".

![Kundenprofil: bearbeitbare Felder für Name, Firma, Telefon und Notizen, darunter eine
Tabelle der bisherigen Tickets des Kunden mit Nummer, Thema, Status und letzter
Aktualisierung](docs/screenshots/de/10-contact-profile.png)

### Kontaktanzeige auf der Ticketseite

- **Info-Leiste** unterhalb der Ticket-Felder: Name, E-Mail und Firma des
  Absenders, Link zur EML-Originaldatei.
- **Seitenleiste**: Kundenkarte mit vollständigem Profil, Link zum
  Kundenprofil sowie Verlauf der gesendeten Antworten (To/CC/BCC, Zeitstempel,
  Anhänge).

### Kunde einem bestehenden Ticket zuordnen

Jedem Ticket — auch einem ohne eingehende E-Mail von Hand angelegten — lässt sich
über die Seitenleiste ein Kunde zuordnen. Das Formular „Kunde zuordnen" dort
erlaubt:

- Kunden per E-Mail-Adresse suchen oder neu anlegen (mit Autovervollständigung).
- Optional eine erste E-Mail an den Kunden senden (der Mailtext entspricht
  standardmäßig der Ticketbeschreibung; die konfigurierbaren Header-/Footer-Vorlagen
  werden angewendet).
- Nur zuordnen, ohne zu senden (hinterlässt eine Nachricht mit `direction=init`
  als Kundenverknüpfung).

## Mailabruf auslösen

Es gibt bewusst keinen eingebauten Scheduler. Zwei Wege:

1. **Button**: *Projekteinstellungen → expert Helpdesk → „Mails jetzt abrufen"*
   (Berechtigung *Helpdesk-Mails abrufen*).
2. **HTTP-Endpunkt** für curl/CronJob (alle aktiven Postfächer):

   ```bash
   curl "https://redmine.example.de/helpdesk/fetch_all?key=API-KEY"
   ```

   Der API-Key wird in den Plugin-Einstellungen gepflegt. Ohne konfigurierten
   Key ist der Endpunkt deaktiviert. Antwort ist eine JSON-Zusammenfassung.

## SLA-Prüfung auslösen

Die SLA-Überschreitungsprüfung läuft über einen eigenen Endpunkt (unabhängig
vom Mailabruf) und kann so von einem separaten CronJob ausgelöst werden:

```bash
curl "https://redmine.example.de/helpdesk/sla_check?key=SLA-API-KEY"
```

Der Endpunkt ist per **eigenem** API-Key gesichert (Einstellung *API-Key
(SLA-Prüfung)*, getrennt vom Mailabruf-Key); ein leerer Key deaktiviert ihn.
Überlappende Läufe werden per Cache-Lock verhindert — ein paralleler Aufruf
liefert `{"skipped": true}` statt erneut zu prüfen. Antwort ist eine
JSON-Zusammenfassung (`{"checked_at": …, "notified": N}`).

## Plugin-Einstellungen

Unter *Administration → Plugins → Redmine expert Helpdesk* – oder als Abkürzung über den
Eintrag **expert Helpdesk** im Administrationsmenü, der direkt hierher verlinkt:

| Einstellung | Beschreibung |
|---|---|
| Tenant-ID | Azure-Verzeichnis-ID (GUID) — Graph-Postfächer |
| Client-ID | App-Registrierungs-ID (GUID) — Graph-Postfächer |
| Client-Secret | Geheimnis der App-Registrierung — Graph-Postfächer |
| Standard-Zugangsdaten für IMAP/SMTP-Postfächer | Vorlage, Verfahren, Tenant/Client/Secret, Autorisierungs- und Token-URL, Scope sowie IMAP-/SMTP-Standardhosts, -ports und -verschlüsselung. Gilt für jedes Postfach, dessen *Zugangsdaten* auf *Aus den Plugin-Einstellungen* stehen — siehe [Mail-Anbieter](#mail-anbieter). |
| API-Key (Mailabruf) | Sichert den globalen Abruf-Endpunkt ab |
| API-Key (SLA-Prüfung) | Sichert den `helpdesk/sla_check`-Endpunkt ab |
| Eingebettete Bilder im Ticket anzeigen | Ersetzt die `[cid:…]`-Markierungen einer eingehenden Mail durch das Bild selbst (Standard: an) – siehe [Eingebettete Bilder](#eingebettete-bilder) |
| Einträge pro Seite | Standard-Seitengröße der Kundenliste (Standard: 25) |
| Max. Tickets im Kundenprofil | Angezeigte Tickets in der Kundendetailansicht (Standard: 10) |

## REST-API

Eine REST-API (JSON und XML) für Automatisierungen, analog zur Redmine-Kern-API —
*Administration → Konfiguration → API* aktivieren, per `X-Redmine-API-Key`
authentifizieren und `.json`/`.xml` anhängen. **Vollständige Referenz mit allen
Parametern und Beispielen: [API.md](API.md).**

| Methode | Pfad |
|---------|------|
| GET / POST | `/projects/:id/helpdesk/contacts.{json,xml}` |
| GET / PUT / DELETE | `/helpdesk/contacts/:id.{json,xml}` |
| GET / POST | `/projects/:id/helpdesk/tickets.{json,xml}` |
| GET / PUT / DELETE | `/helpdesk/tickets/:id.{json,xml}` |
| GET / PUT | `/projects/:id/helpdesk/settings.{json,xml}` |
| GET / POST | `/projects/:id/helpdesk/mailboxes.{json,xml}` |
| GET / PUT / DELETE | `/helpdesk/mailboxes/:id.{json,xml}` |
| POST | `/helpdesk/mailboxes/:id/test_connection.{json,xml}` |

Postfächer erfordern zum Lesen wie zum Schreiben `manage_helpdesk`, denn ihre
Konfiguration legt Mail-Hosts, Benutzernamen und OAuth-Client-/Tenant-IDs offen. Ihre
Secrets (`mail_password`, `oauth_client_secret`, `oauth_sa_key`) sind **nur
schreibbar** — die Antworten melden lediglich, ob eines hinterlegt ist, und ein `"-"`
löscht es.

```bash
# Helpdesk-Tickets des Projekts 42 auflisten
curl -H "X-Redmine-API-Key: $KEY" \
     "https://redmine.example.de/projects/42/helpdesk/tickets.json"

# Ticket anlegen und Kunde per E-Mail zuordnen
curl -H "X-Redmine-API-Key: $KEY" -H "Content-Type: application/json" \
     -d '{"helpdesk_ticket":{"subject":"Drucker defekt","tracker_id":1,"contact_email":"jane@acme.example"}}' \
     "https://redmine.example.de/projects/42/helpdesk/tickets.json"
```

## KI-Zusammenfassungen

Bei aus eingehenden Mails erzeugten Tickets (optional auch bei Journal-Antworten) kann das
Plugin eine KI das eigentliche Anliegen des Kunden zusammenfassen lassen und die
Zusammenfassung als **private (interne) Journal-Notiz** ans Ticket hängen – hilfreich bei
schwer verständlichen Mails oder weitergeleiteten Verläufen mit verstreuten Informationen.
Standardmäßig deaktiviert, Opt-in pro Projekt.

> **KI-Nutzungsstatistik.** Da die KI-Funktionen externe APIs aufrufen und ein Kostenrisiko
> bergen, wird jeder KI-Aufruf (Zusammenfassungen, KB-Extraktion, Embeddings, RAG-Retrieval) in
> `helpdesk_ai_requests` protokolliert – inkl. Fehlversuchen und Antwortzeit. Ein projektbezogener
> Reiter **„KI-Statistik"** (gleiche Zeitraumauswahl und Kennzahlen-Übersicht wie die SLA-Statistik)
> schlüsselt die Nutzung nach Volumen, Token, Anfragetyp, Provider/Modell, Erfolgsquote und
> Stoßzeiten auf. Der Reiter ist über die **globale** Berechtigung `view_helpdesk_ai_statistics`
> geschützt: einer Rolle (z. B. *ai-admin*) gewähren, dann sehen diese Benutzer den Reiter in jedem
> Helpdesk-Projekt, in dem mindestens die KI-Funktionen oder die Wissensbasis aktiv sind – sind
> beide zentral abgeschaltet, ist der Reiter ausgeblendet und die Seite antwortet mit 403.
> Nur Token – es werden noch keine Geldkosten berechnet.

**Zentrale Konfiguration** (*Administration → Plugins → Redmine expert Helpdesk*):
- **Anbieter** – OpenAI (Chat Completions), Anthropic (Messages) oder **Eigener Endpunkt**
  (beliebige OpenAI-kompatible Basis-URL, z. B. self-hosted Ollama / vLLM / LocalAI / LM Studio).
- **API-Key**, **Endpunkt** (leer = Anbieter-Standard; für „Eigener Endpunkt" erforderlich),
  **Modell**.
- **Standard-Prompt** (guter deutscher Default mitgeliefert) sowie Limits (max.
  Eingabezeichen / Ausgabe-Tokens / Timeout).
- **Min. Eingabezeichen** (Standard 200) – kürzere Mails werden gar nicht erst an die KI
  geschickt, denn eine zweizeilige Mail fasst sich selbst zusammen. Die interne Notiz hält
  dann nur fest, dass die Zusammenfassung übersprungen wurde und warum (mit 🤖-Badge und
  0 Tokens). `0` deaktiviert die Prüfung.
- **Log-Level für KI-Diagnose** (Abschnitt *Logging*, Standard `debug`, `off` schaltet ab) –
  mit welchem Schweregrad die gemessene Eingabelänge und die Entscheidung geloggt werden:
  `[helpdesk][ai][debug] length issue=#42 chars=87 min=200 images=0 decision=skip`. Rails loggt
  in Produktion auf `info` und würde eine `debug`-Zeile verwerfen – deshalb wird die Zeile auf
  das Logger-Level angehoben und trägt ihren Schweregrad im Präfix. `debug` läuft damit nie
  ins Leere.

**Projekt-Konfiguration** (Projekt-*Einstellungen → expert Helpdesk*, sichtbar wenn KI zentral
aktiviert ist):
- Für das Projekt aktivieren; **Umfang** wählen (nur Erstmail oder Erstmail und Antworten).
- **Prompt-Modus** – zentralen Prompt *erben*, *erweitern* oder durch einen
  Projekt-Prompt *ersetzen*.
- **Anhänge** – unabhängig wählbar, was an die KI geht: Dateinamen/Metadaten, extrahierter
  Text (PDF via optionalem `pdf-reader`, Textdateien) und/oder Bilder (erfordert ein
  vision-fähiges Modell).
- **Ticketverlauf** – optional den gesamten Verlauf (Beschreibung + alle Notizen) statt nur
  der auslösenden Mail senden, optional inklusive **privater Notizen** (Standard aus; diese
  internen Notizen gehen dann ebenfalls an den Anbieter). Die eigenen KI-Zusammenfassungs-
  Notizen werden immer ausgeschlossen.

Die Zusammenfassung läuft **asynchron** (ActiveJob `HelpdeskAiSummaryJob`); KI-Latenz oder
-Fehler blockieren den Mailabruf nicht – scheitert der Call, wird das Ticket dennoch erzeugt
und der Fehler nur geloggt. Der **Token-Verbrauch** jeder Zusammenfassung wird als 🤖-Badge
im Journal-Header der Notiz angezeigt (Tooltip: Eingabe-/Ausgabe-Tokens und Modell) – analog
zu den An/CC/BCC-Empfänger-Badges. Eine Zusammenfassung lässt sich zudem manuell über die
Karte **„KI-Assistent"** in der Helpdesk-Seitenleiste des Tickets **neu erzeugen**
(*🤖 KI-Zusammenfassung neu erzeugen*) – eine eigene Karte unterhalb der Kundenkarte, die nur
erscheint, wenn KI/KB für das Projekt aktiv ist. Der Button erscheint nur, wenn
*KI-Zusammenfassungen für dieses Projekt erzeugen* aktiviert ist. Praktisch nach einem
fehlgeschlagenen Lauf oder für Tickets, die vor Aktivierung der Funktion eingingen.

> **Datenschutz:** Der Inhalt eingehender Mails und die gewählten Anhänge werden an den
> konfigurierten Anbieter übertragen. Für einen vollständig lokalen Betrieb den Anbieter
> **Eigener Endpunkt** mit einer self-hosted, OpenAI-kompatiblen URL verwenden. Die Funktion
> ist standardmäßig aus und pro Projekt zu aktivieren.

---

## Vollständigkeitsprüfung eingehender Mails

Ein Ticket, das als *„Drucker geht nicht“* hereinkommt — ohne Screenshot, ohne Fehlermeldung, ohne
Systemangabe — kostet den Bearbeiter den ersten Durchlauf allein für ein „Bitte teilen Sie uns mehr
mit“, und dieser Durchlauf läuft gegen die SLA. Das Plugin kann die **erste** Mail eines neuen
Tickets bewerten und dem Kunden automatisch eine Rückfrage aus einer Vorlage schicken, wenn sie zum
Loslegen nicht reicht.

**Was bei „nicht genug Informationen“ passiert:**

1. Eine Rückfrage-Mail geht an den Kunden und listet die fehlenden Angaben auf. Sie trägt
   `In-Reply-To`/`References` der Originalmail, sodass die Antwort wieder demselben Ticket
   zugeordnet wird.
2. Eine Journal-Notiz hält fest, dass die Rückfrage gesendet wurde und was erfragt wurde — öffentlich,
   damit Bearbeiter und Kunde dasselbe sehen.
3. Optional wird das Ticket auf einen konfigurierten Status gesetzt (z. B. *Warten auf Kunde*).

**Zwei Modi**, je Projekt wählbar:

| Modus | Wie entschieden wird | Braucht KI |
|---|---|---|
| **Regelbasiert** | Mindestlänge (Zeichen und/oder Wörter), „Anhang erforderlich“, eine Liste erwarteter Begriffe und eine Schwelle: wie viele dieser Regeln verletzt sein müssen, bevor nachgefragt wird. | Nein |
| **KI-gestützt** | Das Modell liefert ein Urteil samt der konkret fehlenden Angaben; diese wandern direkt in die Rückfrage-Mail. | Ja |

Zitierte Verläufe, Weiterleitungs-Header (`-----Ursprüngliche Nachricht-----`, `Am … schrieb …:`)
und Signaturen werden vor jeder Messung entfernt, damit eine Zwei-Wort-Antwort unter einem langen
zitierten Verlauf nicht als ausführliche Meldung durchgeht.

**Zentrale Konfiguration** (*Administration → Plugins → Redmine expert Helpdesk*):
- **Vollständigkeitsprüfung aktivieren** — der Hauptschalter. Standardmäßig aus; solange er aus ist,
  prüft kein Projekt, unabhängig von dessen Einstellung.
- **Betreff / Text der Rückfrage** — Vorlagen. Alle üblichen Makros funktionieren, dazu
  `{{missing_info}}`, das die aufbereitete Liste der fehlenden Angaben einfügt.
- **Prüf-Prompt** — der Standard-Prompt für den KI-Modus.

**Je Projekt** (*Projekt → Konfiguration → expert Helpdesk*):
- **Modus** — *Aus* (Standard), *Regelbasiert* oder *KI-gestützt*.
- Die Regelwerte: Mindestzeichen, Mindestwörter, „Anhang erforderlich“, erwartete Begriffe
  (einer je Zeile) und die Schwelle. Der Wert `0` schaltet eine einzelne Regel ab.
- **Prompt-Modus** für die KI-Prüfung — erben / erweitern / ersetzen, genau wie beim Prompt der
  KI-Zusammenfassung.
- **Betreff / Text** — optionale Übersteuerung der zentralen Vorlagen je Projekt.
- **Status nach der Rückfrage** — optional; leer lässt den Status unverändert.

**Wichtige Sicherheitseigenschaften:**

- **Nur neue Tickets.** Eine Antwort im laufenden Verlauf löst nie eine Rückfrage aus.
- **Höchstens eine Rückfrage je Ticket.** Ein erneuter Abruf, eine Wiedereröffnung oder ein
  manueller Neuanlauf können denselben Kunden nicht zweimal anschreiben — der Zähler steht auf
  `helpdesk_ticket_infos`.
- **Der KI-Modus fällt sicher aus.** Das Modell muss mit JSON antworten
  (`{"complete": true|false, "missing": [...]}`); alles Unlesbare, ein API-Fehler oder
  „unvollständig“ ohne eine einzige Begründung gelten als *vollständig* — eine kaputte Antwort
  schreibt also nie einen Kunden an.
- **Die Mailverarbeitung wird nie unterbrochen.** Die Prüfung läuft in einem Hintergrund-Job,
  nachdem die Mail verarbeitet wurde; jeder Fehler wird geloggt und geschluckt.
- Aufrufe im KI-Modus werden in `helpdesk_ai_requests` als Anfragetyp `completeness` protokolliert
  und erscheinen in der projektbezogenen KI-Statistik.

## Wissensbasis (RAG)

Aus gelösten Tickets lässt sich eine **projektbezogene Wissensbasis** aufbauen: ein KI-Aufruf
extrahiert je geschlossenem Ticket ein `{Problem, Lösung}`-Paar, bettet das Problem ein und legt
es in einer externen Vektor-Datenbank ab. Bei einer neuen Mail sucht der Zusammenfassungs-Job
**nur in der Wissensbasis dieses Projekts** nach ähnlichen gelösten Tickets und ergänzt – wenn
genügend über dem Schwellwert liegen – einen **Lösungsvorschlag** in der Zusammenfassung und/oder
ein Seitenleisten-Panel. Standardmäßig deaktiviert.

**Zentrale Konfiguration** (*Administration → Plugins*):
- **Vektor-Store** (`kb_backend`): **Qdrant** (REST, kein Zusatz-Gem) oder **Postgres + pgvector**
  (benötigt das `pg`-Gem im Deployment; `PgvectorStore` lädt es per gekapseltem `require`).
- **Embeddings**: Anbieter (OpenAI oder ein self-hosted OpenAI-kompatibler Endpunkt – Anthropic
  hat keine Embeddings-API), Modell, Endpunkt, Key (leer nutzt den Key der Zusammenfassung beim
  gleichen Anbieter).
- Extraktions-Prompt und Retrieval-Parameter (Top-K, Min. Score, Min. Treffer).

**Projekt-Konfiguration** (Projekt-*Einstellungen → expert Helpdesk*, sichtbar wenn die KB aktiv ist):
- **Beitrag** (`kb_ingest_mode`): aus / **auto** (beim Schließen, wenn eine Lösung erkannt wurde) /
  **manuell** (beim Schließen entsteht ein *pending*-Eintrag; Freigabe über die Ticket-Seitenleiste).
- **Lösungsvorschläge anzeigen** (`kb_proposal_display`): aus / Zusammenfassung / Seitenleiste / beides.

**Isolation:** jedes Projekt hat einen eigenen Vektor-Namensraum (Qdrant-Collection / erzwungener
`project_id`-Filter) – ein Projekt ruft nie das Wissen eines anderen ab.

**Batch:** `rake redmine_expert_helpdesk:kb_backfill` nimmt bestehende geschlossene Tickets auf;
`kb_reembed` baut die Vektoren nach einem Modellwechsel neu.

**Einrichtung:** einen von Redmine erreichbaren Vektor-Dienst betreiben – z. B. einen
`qdrant/qdrant`-Container (`http://qdrant:6333`) oder eine `pgvector/pgvector`-Postgres – und die
Plugin-Einstellungen darauf zeigen lassen.

> **Datenschutz:** Problem-/Lösungstext wird an den Embeddings-Anbieter übertragen und im
> Vektor-Store gespeichert. Für einen rein lokalen Betrieb einen self-hosted Embeddings-Endpunkt
> verwenden.

---

## Tests

Das Plugin bringt MiniTest-Unit- und -Integrationstests mit (`test/`). Sie benötigen eine
Redmine-Umgebung (sie laden Redmines eigenen Test-Helper und die Fixtures), laufen also
innerhalb eines Redmine-Checkouts mit dem Plugin unter `plugins/redmine_expert_helpdesk`:

```bash
# Alle Plugin-Tests
bundle exec rake redmine:plugins:test NAME=redmine_expert_helpdesk RAILS_ENV=test

# Eine einzelne Datei / ein einzelner Test
bundle exec ruby -Itest plugins/redmine_expert_helpdesk/test/unit/sla_test.rb
bundle exec ruby -Itest plugins/redmine_expert_helpdesk/test/unit/sla_test.rb -n test_reaction_deadline
```

**Kontinuierliche Integration:** [`.github/workflows/ci.yml`](.github/workflows/ci.yml) führt die komplette Suite bei
jedem Push und Pull Request aus. Eine Build-Matrix checkt jede unterstützte
Redmine-Version frisch aus, kopiert das Plugin hinein, migriert eine leere MariaDB
und startet die Tests – so werden alle Versionen in einem isolierten, reproduzierbaren
Zustand geprüft:

| Redmine | Ruby | Rails |
|---------|------|-------|
| 5.1-stable | 3.2 | 6.1 |
| 6.0-stable | 3.3 | 7.2 |
| 6.1-stable | 3.3 | 7.2 |
| 7.0-stable | 3.4 | 8.1 |

**Docker-Image-Smoke-Test:** [`.github/workflows/docker-image.yml`](.github/workflows/docker-image.yml)
startet das Plugin zusätzlich in den **offiziellen `redmine`-Docker-Images**, mit denen wir
deployen (Tags `5.1`, `6.0`, `6.1`, `7.0`). Pro Tag wird das offizielle Image gegen eine frische
MariaDB gestartet, das Plugin read-only eingehängt, via `REDMINE_PLUGINS_MIGRATE=1` migriert
und geprüft, dass Redmine `/login` (HTTP 200) mit geladenem Plugin ausliefert — fängt also
`init.rb`-Lade-, Migrations- oder Gem-Versionsprobleme ab, die nur im ausgelieferten Image
auftreten. `7.0`/`7` in die Matrix aufnehmen, sobald das offizielle Image einen Redmine-7-Tag
anbietet.

## Azure-App-Registrierung (einmalig)

Die folgenden Schritte können manuell über das Azure-Portal, per PowerShell
(Microsoft Graph PowerShell SDK + Exchange Online PowerShell) oder per
Terraform (Provider `hashicorp/azuread`) ausgeführt werden.

> 💡 `scripts/setup-azure-app.ps1` in diesem Repository führt die Schritte 1–4
> in einem Durchlauf aus (Repo-internes Werkzeug, nicht Teil der
> Release-Archive). Das Skript ist wiederholt ausführbar: vorhandene Ressourcen
> werden weiterverwendet, ein späterer Lauf nimmt weitere Postfächer in den
> RBAC-Scope aus Schritt 4 auf – siehe
> [Weitere Postfächer später aufnehmen](#weitere-postfächer-später-aufnehmen).
>
> [`scripts/README.de.md`](scripts/README.de.md) erläutert das Zusammenspiel der
> beiden Berechtigungsebenen und vergleicht die vier Varianten der Postfach-Auswahl –
> insbesondere, **wer das jeweils nächste Postfach aufnehmen kann**: von „eine Exchange-
> Administratorin muss das Skript ausführen“ bis „wer das freigegebene Postfach anlegt,
> setzt ein Attribut mit“. Vor der Wahl in Schritt 4b lesenswert.

---

### Schritt 1 – App registrieren

**PowerShell**

```powershell
Connect-MgGraph -Scopes "Application.ReadWrite.All"

$app = New-MgApplication `
  -DisplayName    "redmine-helpdesk" `
  -SignInAudience "AzureADMyOrg"   # Single Tenant

# Service Principal anlegen (wird für Admin Consent benötigt)
$sp = New-MgServicePrincipal -AppId $app.AppId

Write-Host "AppId (Client-ID):     $($app.AppId)"
Write-Host "Object-ID (SP):        $($sp.Id)"
Write-Host "Tenant-ID:             $((Get-MgContext).TenantId)"
```

**Terraform**

```hcl
terraform {
  required_providers {
    azuread = { source = "hashicorp/azuread", version = "~> 3.0" }
  }
}

data "azuread_client_config" "current" {}

resource "azuread_application" "redmine_helpdesk" {
  display_name     = "redmine-helpdesk"
  sign_in_audience = "AzureADMyOrg"
}

resource "azuread_service_principal" "redmine_helpdesk" {
  client_id = azuread_application.redmine_helpdesk.client_id
}
```

---

### Schritt 2 – API-Berechtigungen vergeben und Admin Consent erteilen

Benötigte Application Permissions (nicht Delegated):
- `Mail.ReadWrite` – Mails lesen, verschieben
- `Mail.Send` – Autoresponder / Kundenantworten senden

**PowerShell**

```powershell
# Variante A: Mit Cloud Application Administrator Rolle in Entra ID
# Benötigt: "Application.ReadWrite.All" + "AppRoleAssignment.ReadWrite.All"
Connect-MgGraph -Scopes "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All"

# Bekannte App-Role-IDs für Microsoft Graph
$graphAppId      = "00000003-0000-0000-c000-000000000000"
$mailReadWriteId = "e2a3a72e-5f79-4c64-b1b1-878b674786c9"
$mailSendId      = "b633e1c5-b582-4048-a93e-9f11b44c7e96"

# Berechtigungen an der App-Registrierung eintragen
Update-MgApplication -ApplicationId $app.Id `
  -RequiredResourceAccess @(
    @{
      ResourceAppId  = $graphAppId
      ResourceAccess = @(
        @{ Id = $mailReadWriteId; Type = "Role" }
        @{ Id = $mailSendId;      Type = "Role" }
      )
    }
  )

# Admin Consent erteilen (direkte Role-Zuweisung am Service Principal)
$graphSp = Get-MgServicePrincipal -Filter "AppId eq '$graphAppId'"

New-MgServicePrincipalAppRoleAssignment `
  -ServicePrincipalId $sp.Id `
  -PrincipalId        $sp.Id `
  -ResourceId         $graphSp.Id `
  -AppRoleId          $mailReadWriteId

New-MgServicePrincipalAppRoleAssignment `
  -ServicePrincipalId $sp.Id `
  -PrincipalId        $sp.Id `
  -ResourceId         $graphSp.Id `
  -AppRoleId          $mailSendId
```

**Oder: Azure CLI** (Alternative, wenn keine Cloud Application Administrator Rolle verfügbar)

```bash
az login
az ad app permission admin-consent --id <APPLICATION-ID>
```

**Oder: Azure Portal** (ohne Rollen-Voraussetzung)

1. Azure Portal → *Entra ID → App registrations* → `redmine-helpdesk`
2. *API permissions* → *Grant admin consent for [Tenant]* → Bestätigung


**Terraform** (Erweiterung von Schritt 1)

```hcl
data "azuread_application_published_app_ids" "well_known" {}

data "azuread_service_principal" "msgraph" {
  client_id = data.azuread_application_published_app_ids.well_known.result.MicrosoftGraph
}

resource "azuread_application" "redmine_helpdesk" {
  display_name     = "redmine-helpdesk"
  sign_in_audience = "AzureADMyOrg"

  required_resource_access {
    resource_app_id = data.azuread_application_published_app_ids.well_known.result.MicrosoftGraph

    resource_access {
      id   = data.azuread_service_principal.msgraph.app_role_ids["Mail.ReadWrite"]
      type = "Role"
    }
    resource_access {
      id   = data.azuread_service_principal.msgraph.app_role_ids["Mail.Send"]
      type = "Role"
    }
  }
}

# Admin Consent
resource "azuread_app_role_assignment" "mail_readwrite" {
  app_role_id         = data.azuread_service_principal.msgraph.app_role_ids["Mail.ReadWrite"]
  principal_object_id = azuread_service_principal.redmine_helpdesk.object_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}

resource "azuread_app_role_assignment" "mail_send" {
  app_role_id         = data.azuread_service_principal.msgraph.app_role_ids["Mail.Send"]
  principal_object_id = azuread_service_principal.redmine_helpdesk.object_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}
```

---

### Schritt 3 – Client-Secret anlegen

**PowerShell**

```powershell
$secret = Add-MgApplicationPassword -ApplicationId $app.Id `
  -PasswordCredential @{
    DisplayName = "redmine-helpdesk-secret"
    EndDateTime = (Get-Date).AddYears(1)
  }

# Wert wird nur einmalig angezeigt – sofort sicher speichern!
Write-Host "Client-Secret: $($secret.SecretText)"
```

**Terraform**

```hcl
resource "azuread_application_password" "redmine_helpdesk" {
  application_id = azuread_application.redmine_helpdesk.id
  display_name   = "redmine-helpdesk-secret"
  end_date       = "2027-06-16T00:00:00Z"  # bei Rotation anpassen
}

output "tenant_id"     { value = data.azuread_client_config.current.tenant_id }
output "client_id"     { value = azuread_application.redmine_helpdesk.client_id }
output "client_secret" { value = azuread_application_password.redmine_helpdesk.value; sensitive = true }
```

---

### Schritt 4 – Zugriff einschränken (wichtig!)

`New-ApplicationAccessPolicy` ist veraltet. Verwenden Sie stattdessen
**Exchange Online Application RBAC** (Exchange Online PowerShell als Exchange
Administrator). Terraform wird für Exchange Online RBAC nicht unterstützt.

**PowerShell**

```powershell
Connect-ExchangeOnline

# 4a. Service Principal in Exchange Online anlegen.
#     AppId    = "Application ID"  aus Entra ID → Enterprise applications
#     ObjectId = "Object ID"       aus Entra ID → Enterprise applications
#     (NICHT die IDs aus "App registrations" – die sind unterschiedlich!)
New-ServicePrincipal `
  -AppId       "<CLIENT-ID>" `
  -ObjectId    "<ENTERPRISE-OBJECT-ID>" `
  -DisplayName "Redmine Helpdesk"

# 4b. Management Scope auf die Helpdesk-Postfächer einschränken.
#
#     Variante A: alle Postfächer, deren Adresse auf @helpdesk.example.com endet.
New-ManagementScope `
  -Name "Redmine-Helpdesk-Postfaecher" `
  -RecipientRestrictionFilter "PrimarySmtpAddress -like '*@helpdesk.example.com'"
#
#     Variante B: Mitglieder einer Mail-aktivierten Sicherheitsgruppe
#     (Distinguished Name der Gruppe mit Get-Group ermitteln).
#     $dn = (Get-Group "helpdesk-postfaecher@example.com").DistinguishedName
New-ManagementScope `
  -Name "Redmine-Helpdesk-Postfaecher" `
  -RecipientRestrictionFilter "MemberOfGroup -eq '<DN-DER-GRUPPE>'"
#
#     Variante C: Custom Empfaengerattribute (z. B. CustomAttribute1)
#     Beispiel: alle Postfaecher mit CustomAttribute1 = Redmine
New-ManagementScope `
  -Name "Redmine-Helpdesk-Postfaecher" `
  -RecipientRestrictionFilter "CustomAttribute1 -eq 'Redmine'"

# 4c. Rollen zuweisen.
$sp = Get-ServicePrincipal -Identity "Redmine Helpdesk"
New-ManagementRoleAssignment `
  -App  $sp.ObjectId `
  -Role "Application Mail.ReadWrite" `
  -CustomResourceScope "Redmine-Helpdesk-Postfaecher"
New-ManagementRoleAssignment `
  -App  $sp.ObjectId `
  -Role "Application Mail.Send" `
  -CustomResourceScope "Redmine-Helpdesk-Postfaecher"

# 4d. Zugriff testen (InScope muss true sein).
Test-ServicePrincipalAuthorization `
  -Identity "Redmine Helpdesk" `
  -Resource helpdesk@example.com | Format-Table
```

> ⚠️ **Wichtig – Entra-Berechtigungen entfernen**: Nach der EXO-RBAC-Zuweisung
> müssen die Graph-Berechtigungen `Mail.ReadWrite` und `Mail.Send` in Entra ID
> (Schritt 2) **widerrufen** werden. Andernfalls sind beide Grants additiv und
> die Scope-Einschränkung greift **nicht** – die App kann dann auf alle
> Postfächer im Tenant zugreifen, unabhängig vom definierten Scope.

**PowerShell – Entra App-Berechtigungen entfernen**

```powershell
Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All"

$sp = Get-MgServicePrincipal -Filter "DisplayName eq 'redmine-helpdesk'"

# Bekannte App-Role-IDs fuer Microsoft Graph
$mailReadWriteId = "e2a3a72e-5f79-4c64-b1b1-878b674786c9"
$mailSendId      = "b633e1c5-b582-4048-a93e-9f11b44c7e96"

# Nur Mail.ReadWrite und Mail.Send entfernen
Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id |
  Where-Object { $_.AppRoleId -in @($mailReadWriteId, $mailSendId) } |
  ForEach-Object {
    Remove-MgServicePrincipalAppRoleAssignment `
      -ServicePrincipalId    $sp.Id `
      -AppRoleAssignmentId   $_.Id
  }

Write-Host "Fertig. Entra-Berechtigungen entfernt."
```

Anschließend im Azure-Portal unter *App registrations → redmine-helpdesk →
API permissions* prüfen: Die Einträge sollten als *Not granted* erscheinen
oder gänzlich fehlen. Ab diesem Zeitpunkt gilt ausschließlich der
EXO-RBAC-Scope aus Schritt 4.

Vollständige Dokumentation: [Exchange Online Application RBAC](https://learn.microsoft.com/en-us/exchange/permissions-exo/application-rbac)

---

### Schritt 5 – Zugangsdaten in Redmine eintragen

In Redmine unter *Administration → Plugins → Redmine expert Helpdesk*
Tenant-ID, Client-ID und Client-Secret eintragen.

---

### Weitere Postfächer später aufnehmen

Mit jedem neuen Projekt kommt ein weiteres Helpdesk-Postfach hinzu. Wachsen
muss dabei nur der RBAC-Scope aus Schritt 4 – App-Registrierung, Client-ID und
Client-Secret bleiben unverändert, an der Redmine-Konfiguration ändert sich
also nichts.

Mit dem Skript (empfohlen – es liest den aktuellen Scope, ergänzt die neue
Adresse und lässt alle übrigen Ressourcen unangetastet):

```powershell
# Erst die Vorschau: zeigt alten und neuen Filter, schreibt nichts
./scripts/setup-azure-app.ps1 -MailboxEmailList "sales@example.com" -WhatIf

./scripts/setup-azure-app.ps1 -MailboxEmailList "sales@example.com"

# und um den Zugriff auf ein Postfach wieder zu entziehen
./scripts/setup-azure-app.ps1 -RemoveMailboxEmailList "sales@example.com"
```

Namen sind hier nicht nötig, auch wenn die eigene Einrichtung unter anderen
angelegt wurde: Das Skript taggt die App-Registrierung
(`RedmineExpertHelpdesk`) und findet sie über dieses Tag, löst den Service
Principal über die AppId auf und liest den zu erweiternden Scope aus den
vorhandenen Rollenzuweisungen der App. Eine von Hand nach den Rezepten oben
angelegte Einrichtung wird beim ersten Lauf des Skripts nachträglich markiert –
dafür bei diesem ersten Lauf `-AppDisplayName` mitgeben, damit klar ist, welche
App gemeint ist. Siehe
[`scripts/README.de.md`](scripts/README.de.md#wie-ein-erneuter-lauf-die-installation-findet).

Eine eigene Installation für einen Dev-Stack (mit eigener App-Registrierung,
damit das Dev-Plugin nicht an die Live-Postfächer kommt) ist `-Environment DEV`:
daraus leiten sich eigenes Tag, eigener App-Name und eigener Scope-Name ab –
nichts kollidiert, und die Live-Installation bleibt unberührt:

```powershell
./scripts/setup-azure-app.ps1 -Environment DEV `
    -MailboxEmailList "helpdesk-dev@example.com" -TestMailbox "helpdesk-dev@example.com"
```

Von Hand hängt es von der in Schritt 4b gewählten Variante ab: bei
**Variante A** (Domain-Suffix) ist nichts zu tun, solange das neue Postfach in
dieser Domain liegt. Bei **Variante B** (Sicherheitsgruppe) oder **Variante C**
(CustomAttribute1) bleibt der Scope selbst unverändert – aufgenommen wird nur
das Postfach:

```powershell
Add-DistributionGroupMember -Identity "helpdesk-mailboxes@example.com" -Member "sales@example.com"
# oder
Set-Mailbox -Identity "sales@example.com" -CustomAttribute1 "Redmine"
```

Zählt der Scope die Adressen einzeln auf (die Voreinstellung des Skripts), muss
der Filter neu geschrieben werden. `Set-ManagementScope` *ersetzt* ihn, daher
zuerst den aktuellen auslesen und die vorhandenen Adressen wieder mit angeben:

```powershell
Get-ManagementScope -Identity "Redmine-Helpdesk-Mailboxes" | Format-List RecipientFilter

Set-ManagementScope -Identity "Redmine-Helpdesk-Mailboxes" `
  -RecipientRestrictionFilter "PrimarySmtpAddress -eq 'helpdesk@example.com' -or PrimarySmtpAddress -eq 'sales@example.com'"
```

Anschließend das neue Postfach prüfen – Exchange Online braucht einen Moment,
bis die Änderung repliziert ist, ein `InScope: False` direkt nach der
Aktualisierung ist also noch kein Fehler:

```powershell
Test-ServicePrincipalAuthorization -Identity <object-id> -Resource "sales@example.com" | Format-Table
```

> ⚠️ Beim Aufnehmen eines Postfachs die Entra-Berechtigungen aus Schritt 2
> **nicht** erneut vergeben. Sie wirken additiv zum RBAC-Scope, die App käme
> damit wieder an jedes Postfach des Tenants. Genau deshalb überspringt das
> Skript Schritt 2 bei einer bereits vorhandenen App-Registrierung.

---

## Installation

### Aus einem Release (empfohlen)

Die neueste `redmine_expert_helpdesk-<version>.zip` (oder `.tar.gz`) von der
[**Releases**](https://github.com/expertZentrale/redmine_expert_helpdesk/releases)-Seite des
Repos herunterladen und in das `plugins/`-Verzeichnis der Redmine-Installation entpacken (das
Archiv enthält bereits den Top-Level-Ordner `redmine_expert_helpdesk/`), dann migrieren und neu
starten:

```bash
cd /pfad/zu/redmine/plugins
unzip redmine_expert_helpdesk-<version>.zip          # → plugins/redmine_expert_helpdesk/
cd /pfad/zu/redmine
bundle exec rake redmine:plugins:migrate NAME=redmine_expert_helpdesk RAILS_ENV=production
# Redmine neu starten
```

### Aus dem Quellcode (Deploy-Repo)

Plugin liegt in `plugins/redmine_expert_helpdesk` und wird über das
Dockerfile in das Image kopiert. Migrationen laufen beim Containerstart
automatisch, wenn `REDMINE_PLUGINS_MIGRATE=1` gesetzt ist, sonst manuell:

```bash
bundle exec rake redmine:plugins:migrate RAILS_ENV=production
```

### Release veröffentlichen (Maintainer)

Releases sind **Tag-gesteuert**; `init.rb` ist die Single Source of Truth für die Version. Zuerst
die Version in `init.rb` setzen und committen, dann einen passenden semver-Tag pushen:

```bash
# 1. `version '1.2.0'` in init.rb setzen, dann:
git commit -am "release 1.2.0" && git push origin main
# 2. denselben Commit taggen und Tag pushen:
git tag v1.2.0 && git push origin v1.2.0
```

Der [`release.yml`](.github/workflows/release.yml)-Workflow **prüft** daraufhin, dass die
`init.rb`-Version zum Tag passt (und bricht sonst ab), baut die `.zip`/`.tar.gz`-Archive und
veröffentlicht ein GitHub-Release mit Notizen aus den seit dem letzten Tag hinzugekommenen
CHANGELOG-Einträgen. CHANGELOG aktuell halten, damit die Notizen vollständig sind. Bei normalen
Pushes wird nichts veröffentlicht – nur auf Tags.

Danach im Projekt das Modul **expert Helpdesk** aktivieren und die Berechtigungen
den Rollen zuordnen:

| Berechtigung | Beschreibung |
|---|---|
| Helpdesk-Postfächer verwalten | Postfachkonfiguration, Ordner, Regeln |
| Helpdesk-Mails abrufen | Button „Mails jetzt abrufen" |
| Kundenantworten senden | Antwortformular + Kontakt-Autocomplete |
| Kundeninformationen anzeigen | Info-Leiste und Seitenleiste auf der Ticketseite |
| Kontakte verwalten | Kundenliste und Kundenprofil |

Keine zusätzlichen Gems erforderlich (nur Ruby-Standardbibliothek).

## Makros für Vorlagen

In Autoresponder-, Antwort- und Betreff-Vorlagen verwendbar. Beide
Schreibweisen werden akzeptiert:

### Ticket

| Makro | Kurzform | Bedeutung |
|---|---|---|
| `{{issue.id}}` | `{{ticket_id}}` | Ticket-Nummer |
| `{{issue.subject}}` | `{{ticket_subject}}` | Ticket-Titel |
| `{{issue.url}}` | `{{ticket_url}}` | Link zum Ticket |
| `{{issue.status}}` | – | Status-Name |
| `{{issue.priority}}` | – | Priorität |
| `{{issue.tracker}}` | – | Tracker |
| `{{issue.author}}` | – | Autor |
| `{{issue.assignee}}` | – | Bearbeiter (leer, wenn nicht zugewiesen) |
| `{{issue.category}}` | – | Kategorie |
| `{{issue.version}}` | – | Zielversion |
| `{{issue.start_date}}` | – | Beginn, im Datumsformat des Benutzers |
| `{{issue.due_date}}` | – | Fälligkeitsdatum |
| `{{issue.created_on}}` | – | Erstellt am |
| `{{issue.updated_on}}` | – | Zuletzt geändert |
| `{{issue.done_ratio}}` | – | Fortschritt, z. B. `40%` |
| `{{issue.description}}` | – | Ticket-Beschreibung |
| `{{issue.parent_id}}` | – | Nummer des übergeordneten Tickets |

### Kunde

| Makro | Kurzform | Bedeutung |
|---|---|---|
| `{{contact.name}}` | `{{contact_name}}` | Name des Kunden |
| `{{contact.email}}` | `{{contact_email}}` | E-Mail des Kunden |

### Antwortender Agent

Wird aus dem Benutzer aufgelöst, der die Antwort tatsächlich versendet — damit
lassen sich Signaturen bauen.

| Makro | Kurzform | Bedeutung |
|---|---|---|
| `{{user.name}}` | `{{user_name}}` | Anzeigename |
| `{{user.firstname}}` | – | Vorname |
| `{{user.lastname}}` | – | Nachname |
| `{{user.login}}` | – | Anmeldename |
| `{{user.mail}}` | – | E-Mail-Adresse |

### Projekt

| Makro | Kurzform | Bedeutung |
|---|---|---|
| `{{project.name}}` | `{{project_name}}` | Projektname |
| `{{project.identifier}}` | – | Projekt-Kennung |

### Benutzerdefinierte Ticket-Felder

Benutzerdefinierte Felder stehen **nicht** automatisch zur Verfügung. Ein
Administrator schaltet sie einzeln unter *Administration → Plugins → Helpdesk →
Benutzerdefinierte Felder als Makros* frei; nur freigeschaltete Felder werden
ersetzt. Jedes Feld ist auf zwei Arten ansprechbar:

| Schreibweise | Beispiel | Hinweis |
|---|---|---|
| Über die Id | `{{issue.cf.42}}` | Übersteht das Umbenennen des Feldes |
| Über den Namen | `{{issue.cf.vertragsnummer}}` | Kleinbuchstaben, jede Folge von Sonderzeichen wird zu `_` |

Zusätzlich zur Freigabe gilt die Redmine-Sichtbarkeit des Feldes: Darf der
antwortende Agent das Feld nicht sehen, bleibt das Makro leer. So gerät ein
internes Feld nicht über eine geteilte Vorlage in eine Kundenmail.

Standard-Betreff-Vorlage: `Re: [#{{issue.id}}] {{issue.subject}}`

Alles, was nicht aufgelöst werden kann — unbekanntes Makro, nicht
freigeschaltetes Feld, leerer Wert — wird zu einer leeren Zeichenkette; eine
Vorlage scheitert nie an einem Makro.

## Hinweise

- **Doppelte Mails vermeiden**: Wenn der Autoresponder aktiv ist, sollte
  *Redmine-Benachrichtigungen unterdrücken* am Postfach aktiviert werden,
  sonst erhält der Kunde ggf. zusätzlich die Redmine-Standardmail.
- **Zielordner**: Verarbeitete Mails werden in den konfigurierten Ordner
  verschoben (Standard: `Verarbeitet`; muss im Postfach existieren). Ohne
  Zielordner bleiben Mails im Posteingang und würden erneut verarbeitet.
- **Client-Secret**: Wird in der Redmine-Datenbank (Tabelle `settings`)
  gespeichert. DB-Zugriff entsprechend absichern; Rotation über die
  Plugin-Einstellungen.
- **MIME-Versand (Graph)**: Der `sendMail`-Endpunkt erwartet den Aufruf mit
  `Content-Type: text/plain` und einem Base64-kodierten MIME-String im Body.
  Dieses Verfahren ist notwendig, da Exchange Online beim JSON-basierten
  Versand den HTML-Body transformiert und dabei CID-Inline-Referenzen von den
  Anhängen entkoppelt.
- **Kundenantworten**: Antwort an den Kunden direkt von der Ticketseite; für
  Details siehe Abschnitt *Kundenantworten aus Redmine heraus*.

---

## Tests ausführen

Das Plugin enthält Minitest-Unit-Tests unter `test/unit/`. Sie laufen in der
Redmine-Testumgebung und setzen voraus, dass das Plugin installiert und alle
Migrationen ausgeführt wurden.

### Voraussetzungen

Die Tests müssen aus dem **Redmine-Anwendungsverzeichnis** heraus ausgeführt
werden (nicht aus dem Plugin-Verzeichnis). Die Testdatenbank muss angelegt und
migriert sein:

```bash
bundle exec rake db:create RAILS_ENV=test
bundle exec rake db:migrate RAILS_ENV=test
bundle exec rake redmine:plugins:migrate NAME=redmine_expert_helpdesk RAILS_ENV=test
```

> **Neben RedmineUP-Plugins schlägt `rake db:create` fehl**: der Task bootet Rails, und
> `redmine_contacts` ruft beim Laden seiner Modelle `table_exists?` auf — gegen genau die
> Datenbank, die es noch nicht gibt. Die Datenbank vorher mit dem Datenbank-Client anlegen
> und nur die beiden `migrate`-Tasks laufen lassen. Im Deploy-Repository ist das bereits
> als Compose-Service hinterlegt:
> `docker-compose --profile test run --build --rm redmine-test`.

### Alle Plugin-Tests ausführen

```bash
bundle exec rake redmine:plugins:test NAME=redmine_expert_helpdesk RAILS_ENV=test
```

### Einzelne Testdatei ausführen

```bash
bundle exec ruby -Itest plugins/redmine_expert_helpdesk/test/unit/helpdesk_rule_test.rb
```

### Alle Unit-Testdateien des Plugins ausführen

```bash
bundle exec ruby -Itest \
  plugins/redmine_expert_helpdesk/test/unit/helpdesk_rule_test.rb \
  plugins/redmine_expert_helpdesk/test/unit/mail_processor_filter_test.rb \
  plugins/redmine_expert_helpdesk/test/unit/template_renderer_test.rb \
  plugins/redmine_expert_helpdesk/test/unit/helpdesk_message_test.rb \
  plugins/redmine_expert_helpdesk/test/unit/helpdesk_contact_test.rb \
  plugins/redmine_expert_helpdesk/test/unit/helpdesk_project_setting_test.rb
```

### Wann Tests ausgeführt werden sollten

- Vor und nach jeder Code-Änderung am Plugin.
- Nach einem Redmine-Versionsupdate.
- Nach `bundle update`, um Gem-Kompatibilitätsprobleme zu erkennen.
- In CI/CD als Schritt nach `redmine:plugins:migrate`.


### Container-Workflow

Da in diesem Projekt kein `docker exec` verwendet wird, werden Tests über ein
dediziertes Test-Image ausgeführt. Eine `docker-compose.test.yml` (oder ein
`test`-Service in der bestehenden Compose-Datei) setzt `RAILS_ENV=test` und
überschreibt den Entrypoint mit dem Test-Rake-Task:

```yaml
# docker-compose.test.yml (Beispiel)
services:
  redmine-test:
    build:
      context: .
      dockerfile: Dockerfile.dev
    environment:
      RAILS_ENV: test
      REDMINE_PLUGINS_MIGRATE: "1"
    command: >
      bash -c "bundle exec rake db:migrate &&
               bundle exec rake redmine:plugins:migrate NAME=redmine_expert_helpdesk &&
               bundle exec rake redmine:plugins:test NAME=redmine_expert_helpdesk"
    depends_on:
      - db
```

```bash
docker compose -f docker-compose.test.yml run --rm redmine-test
```

---

## Lizenz

Copyright (C) 2026 Dennis Buehring

Dieses Programm ist freie Software; Sie können es unter den Bedingungen der
**GNU General Public License, Version 2 oder (nach Ihrer Wahl) jeder späteren Version**
weitergeben und/oder verändern — also unter derselben Lizenz, die auch Redmine selbst nutzt.
Den vollständigen Text finden Sie in [`LICENSE`](LICENSE).

Das Plugin wird in den Redmine-Prozess geladen und patcht Redmine-Kernklassen; es ist damit ein
abgeleitetes Werk von Redmine und wird entsprechend unter GPL-kompatiblen Bedingungen verteilt.

Die Veröffentlichung erfolgt in der Hoffnung, dass es nützlich ist, jedoch **OHNE JEDE GEWÄHRLEISTUNG**
— sogar ohne die implizite Gewährleistung der MARKTREIFE oder der EIGNUNG FÜR EINEN BESTIMMTEN ZWECK.

## Komponenten von Drittanbietern

Das Plugin bringt die folgenden Komponenten unter deren eigenen Lizenzen mit. Die Lizenz-Header
bleiben in den ausgelieferten Dateien erhalten.

| Komponente | Version | Lizenz | Pfad |
|------------|---------|--------|------|
| [Chart.js](https://www.chartjs.org) | 4.4.6 | MIT | `assets/javascripts/chart.umd.min.js` |
| [chartjs-plugin-datalabels](https://chartjs-plugin-datalabels.netlify.app) | 2.2.0 | MIT | `assets/javascripts/chartjs-plugin-datalabels.min.js` |

Beide werden lokal aus den Plugin-Assets ausgeliefert — zur Laufzeit erfolgt **kein** CDN-Aufruf.
Geladen werden sie nur auf den Seiten der SLA- und der KI-Statistik.

Zusätzliche Ruby-Gems werden nicht benötigt (nur die Ruby-Standardbibliothek).
