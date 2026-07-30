> 🇩🇪 Deutsche Version · [English version](README.md)

# Redmine expert Helpdesk

[![CI](https://github.com/expertZentrale/redmine_expert_helpdesk/actions/workflows/ci.yml/badge.svg)](https://github.com/expertZentrale/redmine_expert_helpdesk/actions/workflows/ci.yml)
[![Docker image smoke test](https://github.com/expertZentrale/redmine_expert_helpdesk/actions/workflows/docker-image.yml/badge.svg)](https://github.com/expertZentrale/redmine_expert_helpdesk/actions/workflows/docker-image.yml)

E-Mail-zu-Ticket-Plugin für Redmine mit Microsoft-365-Anbindung über die
Microsoft Graph API (OAuth 2.0 Client-Credentials-Flow, App-Only).

Zwei CI-Workflows laufen bei jedem Push und Pull Request: die
[Testsuite](.github/workflows/ci.yml) (MiniTest gegen den Redmine-Quellcode für alle
unterstützten Versionen – 5.1, 6.0, 6.1, 7.0 – auf frischer MariaDB) und ein
[Docker-Image-Smoke-Test](.github/workflows/docker-image.yml), der das Plugin in den
**offiziellen `redmine`-Docker-Images** startet, mit denen wir deployen (Tags 5.1, 6.0, 6.1, 7.0) –
siehe [Tests ausführen](#tests-ausführen).

## Funktionen

- **E-Mail zu Ticket**: Mails aus Microsoft 365 oder beliebigen IMAP-Postfächern werden als Tickets angelegt;
  Antworten werden über `In-Reply-To` / `[#id]`-Betreff dem bestehenden Ticket
  zugeordnet (nutzt den Redmine-Standard-`MailHandler`, inkl. Anhänge).
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
- **Kundenantworten**: Antwort an den Kunden direkt von der Ticketseite, mit
  Header-/Footer-Vorlagen; Versand per MIME-basiertem Graph-API-Endpunkt aus
  dem Projektpostfach (landet in dessen „Gesendete Elemente"). Unterstützt
  Inline-Bilder (via CID), normale Anhänge sowie mehrere Empfänger in CC/BCC.
- **Autocomplete in Adressfeldern**: Beim Tippen in An/CC/BCC werden passende
  Kontakte des Projekts vorgeschlagen (ab 2 Zeichen, Dropdown mit Tastatur-
  und Mausnavigation, kommagetrennte Mehrfacheingabe). Display-Namen mit
  Komma werden automatisch RFC 2822-konform gequotet.
- **Kontakte**: Absender werden automatisch als Kontakte gespeichert;
  Kundenliste im Projekt (paginiert, konfigurierbare Einträge pro Seite),
  Kundeninfo-Panel mit früheren Tickets auf der Ticketseite.
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
sichtbaren Ordner werden dabei gleich mit aufgelistet.

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
   App-Passwort, sofern der Anbieter eines anbietet).
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
    └─ In-Reply-To/References auf den Ticket-Thread setzen, damit Antworten auch
       ohne [#id] im Betreff zugeordnet werden
        │
        ▼
  Redmine MailHandler ──────── abgelehnt ──────▶ Skipped-Ordner
    (Ticket anlegen oder        (z. B. eigene Adresse)
     Journal ergänzen)
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

| Wert | Versand über | Inline-Bilder |
|------|--------------|---------------|
| `provider` (Vorgabe für neue Postfächer) | das Backend des Postfachs — Graph-API oder eigener SMTP-Server | CID |
| `graph` | Microsoft Graph über die zentrale App-Registrierung | CID |
| `smtp` | globale SMTP-Einstellungen von Redmine aus der `configuration.yml` | Base64-Data-URI |

Der Autoresponder nutzt denselben Transport wie Antworten.

Die gespeicherten Empfängeradressen werden nach dem Seitenaufruf in den
Journalüberschriften als Badge eingeblendet (clientseitig per Timestamp-
Abgleich zwischen `HelpdeskMessage.sent_at` und `Journal.created_on`,
Toleranz 30 Sekunden).

**Automatische Feldaktualisierung nach dem Senden**: Optional können in den
Projekteinstellungen (*expert Helpdesk → Antwort-Einstellungen*) ein Ziel-Status
und die automatische Zuweisung an den Absender konfiguriert werden. Beide
werden nach erfolgreichem Versand gesetzt, bevor das Ticket-Formular
abgesendet wird.

## Kontakte / Kundenliste

Absender werden beim ersten Postfachabruf automatisch als `HelpdeskContact`
gespeichert und dem Projekt zugeordnet.

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

```bash
# Helpdesk-Tickets des Projekts 42 auflisten
curl -H "X-Redmine-API-Key: $KEY" \
     "https://redmine.example.de/projects/42/helpdesk/tickets.json"

# Ticket anlegen und Kunde per E-Mail zuordnen
curl -H "X-Redmine-API-Key: $KEY" -H "Content-Type: application/json" \
     -d '{"helpdesk_ticket":{"subject":"Drucker defekt","tracker_id":1,"contact_email":"jane@acme.example"}}' \
     "https://redmine.example.de/projects/42/helpdesk/tickets.json"
```

## Azure-App-Registrierung (einmalig)

Die folgenden Schritte können manuell über das Azure-Portal, per PowerShell
(Microsoft Graph PowerShell SDK + Exchange Online PowerShell) oder per
Terraform (Provider `hashicorp/azuread`) ausgeführt werden.

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

| Makro (Punkt-Notation) | Kurzform | Bedeutung |
|---|---|---|
| `{{issue.id}}` | `{{ticket_id}}` | Ticket-Nummer |
| `{{issue.subject}}` | `{{ticket_subject}}` | Ticket-Titel |
| `{{issue.url}}` | `{{ticket_url}}` | Link zum Ticket |
| `{{contact.name}}` | `{{contact_name}}` | Name des Kunden |
| `{{contact.email}}` | `{{contact_email}}` | E-Mail des Kunden |
| `{{user.name}}` | `{{user_name}}` | Name des antwortenden Benutzers |
| `{{project.name}}` | `{{project_name}}` | Projektname |

Standard-Betreff-Vorlage: `Re: [#{{issue.id}}] {{issue.subject}}`

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
> Helpdesk-Projekt. Nur Token – es werden noch keine Geldkosten berechnet.

**Zentrale Konfiguration** (*Administration → Plugins → Redmine expert Helpdesk*):
- **Anbieter** – OpenAI (Chat Completions), Anthropic (Messages) oder **Eigener Endpunkt**
  (beliebige OpenAI-kompatible Basis-URL, z. B. self-hosted Ollama / vLLM / LocalAI / LM Studio).
- **API-Key**, **Endpunkt** (leer = Anbieter-Standard; für „Eigener Endpunkt" erforderlich),
  **Modell**.
- **Standard-Prompt** (guter deutscher Default mitgeliefert) sowie Limits (max.
  Eingabezeichen / Ausgabe-Tokens / Timeout).

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

### Automatisierte Tests (GitHub Actions / CI)

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) führt die komplette Suite bei
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
