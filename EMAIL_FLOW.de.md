# Mailfluss – redmine_expert_helpdesk

> 🇩🇪 Deutsche Version · [English version](EMAIL_FLOW.md)

Wie eine Mail durch den Helpdesk läuft: vom Postfach ins Ticket und vom Ticket zurück zum Kunden.
Jedes Diagramm nennt die Einstellungen, die seinen Weg verändern, und die
[Einstellungsübersicht](#8-einstellungsübersicht) am Ende listet alle mit dem Ort, an dem sie
gepflegt werden.

**So liest man die Diagramme**: Rechtecke sind Schritte, Rauten Entscheidungen, und der Zusatz an
einem Schritt nennt die Einstellung, die ihn steuert (*kursiv*). Die Farben zeigen, wo eine Mail
landet:

```mermaid
flowchart LR
  N([Neues Ticket]):::new
  R([Notiz an einem bestehenden Ticket]):::reply
  S[(Ordner übersprungen)]:::skip
  F[(Ordner Fehler)]:::fail
  classDef new fill:#d8efe1,stroke:#1f7a4d,color:#10301f
  classDef reply fill:#dbe7f5,stroke:#2f5d8a,color:#13283d
  classDef skip fill:#f6ead6,stroke:#9a6412,color:#3d2806
  classDef fail fill:#f8e4e2,stroke:#b23a3a,color:#3d1414
```

## Inhalt

1. [Das Gesamtbild](#1-das-gesamtbild)
2. [Abruf](#2-abruf)
3. [Filter: Wird die Mail überhaupt verarbeitet?](#3-filter-wird-die-mail-überhaupt-verarbeitet)
4. [Antwort oder neues Ticket?](#4-antwort-oder-neues-ticket)
5. [Was mit dem Ticket passiert](#5-was-mit-dem-ticket-passiert)
6. [Eine Mail, mehrere Projekte](#6-eine-mail-mehrere-projekte)
7. [Ausgehende Mails](#7-ausgehende-mails)
8. [Einstellungsübersicht](#8-einstellungsübersicht)

---

## 1. Das Gesamtbild

Ein Postfach gehört zu genau einem Projekt. Der Abruf liest seinen Quellordner, jede Nachricht
durchläuft dieselbe Pipeline und wird danach in einen von drei Ordnern verschoben. In Redmine
geschriebene Antworten verlassen den Helpdesk über den Versandweg des Postfachs, und die Antwort
des Kunden kommt wieder im Quellordner an.

```mermaid
flowchart LR
  T["Abruf<br/>Button oder Cron"] --> MB["Postfach<br/>(ein Projekt)"]
  MB --> P["Pipeline<br/>Abschnitte 3 bis 5"]
  P --> N([Ticket oder Notiz]):::new
  P --> S[(Ordner übersprungen)]:::skip
  P --> F[(Ordner Fehler)]:::fail
  N --> A["Bearbeiter antwortet<br/>in Redmine"]
  A --> O["Versandweg<br/>Abschnitt 7"]
  O --> C["Kunde"]
  C -- antwortet --> MB
  classDef new fill:#d8efe1,stroke:#1f7a4d,color:#10301f
  classDef skip fill:#f6ead6,stroke:#9a6412,color:#3d2806
  classDef fail fill:#f8e4e2,stroke:#b23a3a,color:#3d1414
```

---

## 2. Abruf

Das Plugin hat keinen eigenen Zeitplaner. Ein Abruf startet über den Button in den
Projekteinstellungen oder über den Cron-Endpunkt `GET /helpdesk/fetch_all?key=…`, der zusätzlich
die SLA-Prüfung und den Abgleich der Phishing-Feeds anstößt.

```mermaid
flowchart TD
  T["Abruf-Button<br/>oder /helpdesk/fetch_all"] --> M{"Mailabruf pausiert?<br/><i>Mailabruf pausieren</i>"}
  M -- ja --> X["Es wird nichts abgerufen"]
  M -- nein --> L["Für jedes aktive Postfach<br/>in einem aktiven Projekt mit Helpdesk-Modul"]
  L --> Q["Bis zu 25 Nachrichten aus dem Quellordner lesen<br/><i>Quellordner</i><br/><i>Nur ungelesene Mails abrufen</i> (IMAP)"]
  Q --> E["Jede Nachricht verarbeiten<br/>Abschnitte 3 bis 5"]
  E --> W{"Mailabruf inzwischen<br/>pausiert?"}
  W -- ja --> STOP["Aktuelle Nachricht fertig verarbeiten,<br/>Rest beim nächsten Abruf"]
  W -- nein --> E
```

- **IMAP** liest alle Nachrichten des Quellordners, oder nur ungelesene, wenn *Nur ungelesene Mails
  abrufen* gesetzt ist. Microsoft Graph liest immer nur ungelesene Nachrichten.
- Eine verarbeitete Mail wird als gelesen markiert und verschoben, sie wird also nie zweimal
  abgeholt.

---

## 3. Filter: Wird die Mail überhaupt verarbeitet?

Bevor ein Ticket angefasst wird, können fünf Prüfungen eine Mail direkt in den Ordner für
übersprungene Mails schicken. Sie laufen in dieser Reihenfolge, die günstigste zuerst.

```mermaid
flowchart TD
  IN["Nachricht aus dem Quellordner"] --> B{"Absender erlaubt?<br/><i>Whitelist</i> / <i>Blacklist</i>"}
  B -- nein --> S[(Ordner übersprungen)]:::skip
  B -- ja --> R{"Eine Automatisierungsregel mit<br/>Aktion Mail ignorieren greift?<br/><i>Automatisierungsregeln</i>"}
  R -- ja --> S
  R -- nein --> D{"Hat dieses Projekt die<br/>Message-ID schon erhalten?"}
  D -- ja --> S
  D -- nein --> AR{"Automatische Antwort?<br/><i>Auto-Reply-Filter aktiv</i><br/><i>Absender- / Header-Ausnahmen</i>"}
  AR -- ja --> S
  AR -- nein --> PH{"Phishing-Treffer?<br/><i>PhishTank-Integration aktiv</i> (zentral)<br/><i>Phishing-Prüfung</i> (Projekt)"}
  PH -- "Treffer, Mail in Quarantäne" --> S
  PH -- "Treffer, Links neutralisieren" --> NZ["Links ersetzt,<br/>Hinweis folgt später"]
  PH -- kein Treffer --> NEXT["Weiter mit Abschnitt 4"]
  NZ --> NEXT
  classDef skip fill:#f6ead6,stroke:#9a6412,color:#3d2806
```

- **Whitelist / Blacklist**: eine Adresse oder Domain pro Zeile. Eine gepflegte Whitelist lässt
  *nur* ihre Absender zu; die Blacklist entfernt danach Absender aus dem Rest.
- **Schon erhalten**: Dieselbe Mail an zwei Postfächer eines Projekts (An und CC) wird einmal
  verarbeitet. Ein anderes Projekt, das sie erhält, ist kein Duplikat, siehe
  [Abschnitt 6](#6-eine-mail-mehrere-projekte).
- **Auto-Reply-Filter**: Abwesenheitsnotizen und ähnliche Mails werden an ihren Headern erkannt.
  Unzustellbarkeitsberichte (NDRs) werden nie gefiltert, denn eine fehlgeschlagene Zustellung muss
  ein Bearbeiter sehen.
- **Ordner übersprungen** fällt auf den Ordner für verarbeitete Mails zurück, wenn er leer ist. Sind
  beide leer, bleibt die Mail im Quellordner und wird nur als gelesen markiert.

---

## 4. Antwort oder neues Ticket?

Das Plugin übergibt die Mail an Redmines eigenen `MailHandler`, der die endgültige Entscheidung
trifft. Vorher passt das Plugin die *Thread-Marker* der Mail an, also die Teile einer Mail, die
sagen, zu welchem Ticket sie gehört:

| Marker | Wo | Beispiel |
| --- | --- | --- |
| Ticket-Tag | Betreff | `AW: [#123] Drucker defekt`, `[Projekt - Fehler #123]` |
| Redmine-Benachrichtigungs-ID | `In-Reply-To` / `References` | `<redmine.issue-123.20261014…@example.com>` |
| Protokollierte Helpdesk-Message-ID | `In-Reply-To` / `References` | ID einer Kundenmail oder Bearbeiterantwort, die der Helpdesk gespeichert hat |
| Forum-Antwort-Tag | Betreff | `AW: [Forum - msg45] …` – wird immer entfernt, ein Helpdesk-Postfach schreibt nie in ein Forum |

```mermaid
flowchart TD
  IN["Mail nach den Filtern"] --> SW{"<i>Antworten nur im Projekt<br/>des Postfachs zuordnen</i> an?"}
  SW -- ja --> SC["Marker entfernen, die auf ein Ticket eines<br/>ANDEREN Projekts oder auf kein Ticket zeigen<br/>(Unterprojekte zählen als andere Projekte)"]
  SW -- "nein (Standard)" --> AGE
  SC --> AGE{"Referenziertes Ticket dieses Projekts<br/>geschlossen und älter als das Limit?<br/><i>Max. Alter (Tage)</i>"}
  AGE -- ja --> STRIP["Alle Marker entfernen"]
  AGE -- nein --> TAG{"Mail antwortet auf eine protokollierte<br/>Helpdesk-Mail, Betreff ohne Ticket-Tag?"}
  TAG -- ja --> ADD["Ticket-Tag in den Betreff setzen"]
  TAG -- nein --> MH
  ADD --> MH
  STRIP --> MH{"Redmine MailHandler:<br/>Marker eines bestehenden Tickets gefunden?"}
  MH -- ja --> RE([Notiz an diesem Ticket]):::reply
  MH -- nein --> NEW(["Neues Ticket im Projekt des Postfachs<br/><i>Standardwerte für neue Tickets</i>"]):::new
  MH -- "abgelehnt<br/><i>Unbekannte Absender: Ignorieren</i>" --> S[(Ordner übersprungen)]:::skip
  classDef new fill:#d8efe1,stroke:#1f7a4d,color:#10301f
  classDef reply fill:#dbe7f5,stroke:#2f5d8a,color:#13283d
  classDef skip fill:#f6ead6,stroke:#9a6412,color:#3d2806
```

- **Nur das eigene Projekt des Postfachs** (experimentell, standardmäßig aus). Ohne diesen Schritt
  folgt der `MailHandler` einem Marker in jedes Projekt, und jeder, der eine Ticketnummer kennt, kann
  in dieses Ticket schreiben – so verhält es sich, solange der Schalter aus ist. Marker des eigenen
  Projekts bleiben erhalten, die normale Antwort des Kunden findet ihr Ticket also weiterhin. Ein
  Ticket, das über dieses Postfach eröffnet und später in ein anderes Projekt verschoben wurde, zählt
  ebenfalls als eigenes Projekt. Ein Betreff mit mehr als 20 Ticketnummern, mehr als fünf Ebenen
  Verschachtelung oder mehr als 998 Zeichen verliert alle Tags und Klammern,
  `In-Reply-To`/`References` mit mehr als 50 Message-IDs werden verworfen. Die
  am Ticket angehängte `.eml` behält Betreff und Header genau so, wie
  sie angekommen sind.
- **Max. Alter (Tage)** erzwingt ein neues Ticket für eine Antwort auf ein seit Langem
  geschlossenes Ticket. `0` oder leer schaltet das Limit ab.
- **Unbekannte Absender** bestimmt, was der `MailHandler` mit einer Adresse ohne Redmine-Konto macht:
  *Akzeptieren (anonym)*, *Benutzerkonto anlegen* oder *Ignorieren* (die Mail wird übersprungen).
- Der `MailHandler` lehnt außerdem Mails von Redmines eigenem *E-Mail-Absender* ab und wendet
  Redmines Einstellungen unter *Eingehende E-Mails* an (*Schneide E-Mails nach einer dieser Zeilen
  ab*, *Anhänge nach Namen ausschließen*).

---

## 5. Was mit dem Ticket passiert

Nachdem der `MailHandler` das Ticket oder die Notiz angelegt hat, erledigt das Plugin den Rest. Die
beiden Zweige unterscheiden sich nur am Anfang.

```mermaid
flowchart TD
  NEW(["Neues Ticket"]):::new --> AS["Standard-Zuweisung, falls der MailHandler keine gesetzt hat<br/><i>Neue Tickets zuweisen an</i> (Projekt)"]
  AS --> RU["Automatisierungsregeln in ihrer Reihenfolge<br/><i>Automatisierungsregeln</i>: Priorität, Tracker,<br/>Kategorie, Zuweisung"]
  RE([Notiz an einem Ticket]):::reply --> ST{"Ticket geschlossen?"}
  ST -- ja --> RS["Status bei Antwort auf geschlossenes Ticket<br/><i>Status (geschlossenes Ticket)</i>"]
  ST -- nein --> OS["Status bei Antwort auf offenes Ticket<br/><i>Status (offenes Ticket)</i>"]
  RS --> AW["Markierung: wartet auf Bearbeitung<br/><i>Tickets markieren, die auf Bearbeitung warten</i>"]
  OS --> AW
  RU --> COM
  AW --> COM["Eingebettete Bilder anzeigen, gesperrte Anhänge entfernen<br/><i>Eingebettete Bilder im Ticket anzeigen</i>, <i>Gesperrte Anhänge</i>"]
  COM --> CT["Kontakt verknüpfen, Originalmail als .eml anhängen"]
  CT --> REL["Mit Tickets anderer Projekte in Beziehung setzen<br/>siehe Abschnitt 6"]
  REL --> AU{"Neues Ticket?"}
  AU -- ja --> AR["Autoresponder<br/><i>Autoresponder aktiv</i>"]
  AU -- nein --> PN
  AR --> PN["Phishing-Hinweis, falls Links ersetzt wurden"]
  PN --> AI["KI-Zusammenfassung im Hintergrund<br/>Antworten nur, wenn das Projekt sie einschließt<br/><i>KI-Zusammenfassungen</i> (zentral + Projekt)"]
  AI --> CC["Vollständigkeitsprüfung, nur neue Tickets<br/><i>Vollständigkeitsprüfung</i> (zentral + Projekt)"]
  CC --> DONE[(Ordner verarbeitet)]
  classDef new fill:#d8efe1,stroke:#1f7a4d,color:#10301f
  classDef reply fill:#dbe7f5,stroke:#2f5d8a,color:#13283d
```

- **Status bei einer Antwort**: Bleibt einer der beiden Status leer, bleibt der Status des Tickets
  unverändert. Ein geschlossenes Ticket, das in einem offenen Status landet, gilt als
  *wiedereröffnet*.
- **Wartet auf Bearbeitung** wird nicht gesetzt, wenn die Mail von einem Bearbeiter stammt.
- Die **KI-Zusammenfassung** läuft für neue Tickets und für Antworten nur, wenn der Umfang im Projekt
  sie einschließt. Die **Vollständigkeitsprüfung** läuft nur für neue Tickets. Beide laufen im
  Hintergrund und halten den Abruf nie auf.
- **Jeder Fehler** in dieser Pipeline verschiebt die Mail in den **Ordner für Fehler**, und der Abruf
  macht mit der nächsten Nachricht weiter. Der Fehler wird am Postfach angezeigt (*letzter Fehler*).

---

## 6. Eine Mail, mehrere Projekte

Kunden schreiben oft an mehrere Helpdesk-Adressen gleichzeitig (An, CC oder BCC), und Kollegen in
einem Projekt wissen nicht unbedingt, dass ein anderes Projekt beteiligt ist. Mit *Antworten nur
im Projekt des Postfachs zuordnen* behandelt jedes Postfach seine Kopie nur für sein eigenes
Projekt. Alles in diesem Abschnitt gilt nur dann; solange der Schalter aus ist, folgt jede Kopie
ihren Markern in das referenzierte Ticket, wie bisher.

```mermaid
flowchart LR
  M["Eine Mail<br/>An: helpdesk-a@… CC: helpdesk-b@…<br/>Betreff: AW: [#123] Drucker"] --> MA["Postfach von Projekt A"]
  M --> MB["Postfach von Projekt B"]
  MA --> A1(["#123 in A erhält eine Notiz<br/>Tag gehört zu A, bleibt"]):::reply
  MB --> SB["Tag #123 gehört zu A:<br/>entfernt"]
  SB --> B1(["Neues Ticket in B"]):::new
  B1 <-. "verwandt mit<br/><i>Ticket-Beziehungen zwischen Projekten erlauben</i>" .-> A1
  classDef new fill:#d8efe1,stroke:#1f7a4d,color:#10301f
  classDef reply fill:#dbe7f5,stroke:#2f5d8a,color:#13283d
```

| Situation | Ergebnis |
| --- | --- |
| Kunde schreibt an A und B | Ein Ticket in A, eines in B, miteinander verknüpft |
| Mail an B mit `[#123]` aus Projekt A | Neues Ticket in B, Beziehung zu #123 |
| Antwort auf eine A-Konversation, an B gesendet | Neues Ticket in B, Beziehung zum A-Ticket |
| Bearbeiter aus A antwortet mit der Adresse von B in CC | Neues Ticket in B; nichts kommt zurück nach A |
| Fremder nennt ein Ticket eines Projekts ohne Helpdesk | Neues Ticket, keine Beziehung |
| Dieselbe Mail erreicht zwei Postfächer eines Projekts | Ein Ticket; die zweite Kopie wird übersprungen |

**Wie die Projekte voneinander erfahren**

- **Beziehung *verwandt mit***: wird ohne Historieneintrag und ohne Benachrichtigung angelegt.
  Redmine zeigt sie nur Benutzern, die beide Tickets sehen dürfen. Ein entfernter Ticket-Tag führt
  nur dann zu einer Beziehung, wenn das Projekt dieses Tickets das Helpdesk-Modul hat, denn eine
  Ticketnummer kann jeder in einen Betreff schreiben. Setzt Redmines *Ticket-Beziehungen zwischen
  Projekten erlauben* voraus; ohne die Einstellung werden die Tickets angelegt, aber nicht verknüpft.
- **Seitenleiste *Auch zugestellt an***: die anderen Helpdesk-Adressen aus An und CC. Der
  Projektname erscheint nur für Betrachter, die das Projekt sehen dürfen. Per BCC erreichte
  Postfächer bleiben unsichtbar.

---

## 7. Ausgehende Mails

Vier Arten von Mails verlassen den Helpdesk, und alle nehmen den Versandweg des Postfachs:

| Mail | Ausgelöst durch |
| --- | --- |
| Bearbeiterantwort | *Antworten* auf der Ticketseite |
| Initialmail | Zuordnen eines Kontakts zu einem Ticket, oder *Neues Helpdesk-Ticket* |
| Autoresponder | Ein neues Ticket, wenn *Autoresponder aktiv* |
| Rückfrage der Vollständigkeitsprüfung | Die Vollständigkeitsprüfung findet die Erstmail unvollständig |

```mermaid
flowchart TD
  OUT["Bearbeiterantwort, Initialmail,<br/>Autoresponder, Rückfrage"] --> SV{"<i>Versandweg</i>"}
  SV -- "Backend des Postfachs" --> PR{"Postfachtyp"}
  PR -- IMAP --> MS["Eigener SMTP-Server des Postfachs"]
  PR -- "Microsoft Graph" --> GR["Microsoft Graph sendMail"]
  SV -- "Microsoft Graph API" --> GR
  SV -- "SMTP (Redmine-Standard)" --> RS["Globales SMTP von Redmine<br/><i>Abweichender Absender (From)</i><br/><i>Reply-To auf die Postfach-Adresse setzen</i>"]
  GR --> SENT1["Exchange legt die Kopie in Gesendet selbst ab"]
  MS --> SENT2["IMAP-Postfächer: Kopie in den Ordner für gesendete Mails<br/><i>Ordner für gesendete Mails</i>"]
  RS --> SENT2
  SENT1 --> C["Kunde"]
  SENT2 --> C
```

- ***Versandweg* Microsoft Graph API** wird nur angeboten für ein Graph-Postfach oder ein
  IMAP-Postfach bei Microsoft 365, wenn die zentrale App-Registrierung eingerichtet ist.
- **SMTP (Redmine-Standard)** bettet Inline-Bilder als Data-URIs ein. Die beiden anderen Wege
  schicken sie als Anhänge, auf die das HTML verweist.

**Wie die Antwort des Kunden ihr Ticket wiederfindet**

```mermaid
flowchart LR
  R["Bearbeiterantwort<br/>Betreff: <i>Betreff-Vorlage</i><br/>Standard Re: [#123] …"] --> LOG["Ihre Message-ID wird<br/>am Ticket protokolliert"]
  LOG --> C["Kunde antwortet"]
  C --> T1{"Betreff hat den<br/>Tag noch?"}
  T1 -- ja --> M([Notiz an #123]):::reply
  T1 -- "nein, aber In-Reply-To<br/>nennt die protokollierte ID" --> M
  classDef reply fill:#dbe7f5,stroke:#2f5d8a,color:#13283d
```

- Die **Betreff-Vorlage** der Projekteinstellungen bildet den Betreff; die Standardvorlage enthält
  den Ticket-Tag. Eine Vorlage ohne `{{issue.id}}` funktioniert trotzdem, denn die Message-ID der
  Antwort wird gespeichert und das Mailprogramm des Kunden schickt sie in `In-Reply-To` zurück.
- Der **Autoresponder** verweist auf die erste Mail des Kunden (`In-Reply-To`), eine Antwort darauf
  landet also ebenfalls am Ticket.
- **Kopfzeile** und **Fußzeile** des Postfachs rahmen den Antworttext ein. Der *Fußzeilen-Modus*
  entscheidet zwischen der Fußzeile des Postfachs und der zentralen Fußzeile.
- Ausgehende Mails behalten ihre Marker, auch wenn die Helpdesk-Adresse eines anderen Projekts
  Empfänger ist. Das Postfach jenes Projekts entfernt sie beim Eingang
  ([Abschnitt 6](#6-eine-mail-mehrere-projekte)).

---

## 8. Einstellungsübersicht

**Wo sie zu finden sind**

- **Zentral**: *Administration → Plugins → Redmine expert Helpdesk → Konfigurieren*
- **Projekt**: *Projekt → Einstellungen → Helpdesk*
- **Postfach**: *Projekt → Einstellungen → Helpdesk → Postfächer → (Postfach)*
- **Redmine**: *Administration → Konfiguration*

| Einstellung | Wo | Wirkung | Abschnitt |
| --- | --- | --- | --- |
| Mailabruf pausieren | Zentral | Blockiert jeden Abruf (Wartungsmodus) | [2](#2-abruf) |
| Aktiv | Postfach | Postfach wird überhaupt abgerufen | [2](#2-abruf) |
| Quellordner | Postfach | Ordner, aus dem gelesen wird | [2](#2-abruf) |
| Nur ungelesene Mails abrufen | Postfach (IMAP) | Nur ungelesene statt aller Mails lesen | [2](#2-abruf) |
| Zielordner (verarbeitet / übersprungen / Fehler) | Postfach | Wohin eine Mail danach verschoben wird | [3](#3-filter-wird-die-mail-überhaupt-verarbeitet), [5](#5-was-mit-dem-ticket-passiert) |
| Whitelist / Blacklist | Postfach | Absender, die verarbeitet / übersprungen werden | [3](#3-filter-wird-die-mail-überhaupt-verarbeitet) |
| Automatisierungsregeln, Aktion *Mail ignorieren* | Postfach | Mails nach Betreff oder Absender überspringen | [3](#3-filter-wird-die-mail-überhaupt-verarbeitet) |
| Auto-Reply-Filter aktiv, Absender- / Header-Ausnahmen | Postfach | Abwesenheitsnotizen und Ähnliches überspringen | [3](#3-filter-wird-die-mail-überhaupt-verarbeitet) |
| PhishTank-Integration aktiv | Zentral | Phishing-Feeds werden gespiegelt und geprüft | [3](#3-filter-wird-die-mail-überhaupt-verarbeitet) |
| Phishing-Prüfung für dieses Projekt aktivieren, Aktion bei Phishing-Treffer | Projekt | Links prüfen; *Mail in Quarantäne* überspringt, *Links neutralisieren* ersetzt | [3](#3-filter-wird-die-mail-überhaupt-verarbeitet) |
| Max. Alter (Tage) | Postfach | Antwort auf ein lange geschlossenes Ticket wird ein neues Ticket | [4](#4-antwort-oder-neues-ticket) |
| Unbekannte Absender | Postfach | *Akzeptieren (anonym)*, *Benutzerkonto anlegen* oder *Ignorieren* | [4](#4-antwort-oder-neues-ticket) |
| Standardwerte für neue Tickets (Tracker, Priorität, Status) | Postfach | Attribute eines neuen Tickets | [4](#4-antwort-oder-neues-ticket) |
| Redmine-Benachrichtigungen unterdrücken | Postfach | Keine Redmine-Benachrichtigungen für angelegte Tickets und Notizen | [4](#4-antwort-oder-neues-ticket) |
| Neue Tickets zuweisen an | Projekt | Zuweisung eines neuen Tickets (Benutzer oder Gruppe) | [5](#5-was-mit-dem-ticket-passiert) |
| Automatisierungsregeln (Priorität, Tracker, Kategorie, Zuweisung) | Postfach | Ein neues Ticket nach Betreff oder Absender ändern | [5](#5-was-mit-dem-ticket-passiert) |
| Status (geschlossenes Ticket) / Status (offenes Ticket) | Postfach | Status nach einer Kundenantwort | [5](#5-was-mit-dem-ticket-passiert) |
| Tickets markieren, die auf Bearbeitung warten | Zentral | Tickets mit unbeantworteter Kundenantwort markieren | [5](#5-was-mit-dem-ticket-passiert) |
| Eingebettete Bilder im Ticket anzeigen | Zentral | Eingebettete Bilder erscheinen im Tickettext statt `[cid:…]`-Markierungen | [5](#5-was-mit-dem-ticket-passiert) |
| Gesperrte Anhänge | Projekt, Einträge über die Ticketseite | Bekannte Logos und Tracking-Pixel entfernen | [5](#5-was-mit-dem-ticket-passiert) |
| Autoresponder aktiv, Betreff, Text | Postfach | Bestätigungsmail für ein neues Ticket | [5](#5-was-mit-dem-ticket-passiert), [7](#7-ausgehende-mails) |
| KI-Zusammenfassungen aktivieren, KI-Zusammenfassungen für dieses Projekt erzeugen | Zentral + Projekt | Zusammenfassung als Notiz im Hintergrund | [5](#5-was-mit-dem-ticket-passiert) |
| Vollständigkeitsprüfung aktivieren, Modus | Zentral + Projekt | Rückfrage, wenn der Erstmail Informationen fehlen | [5](#5-was-mit-dem-ticket-passiert), [7](#7-ausgehende-mails) |
| Antworten nur im Projekt des Postfachs zuordnen | Zentral, *Experimentell* | Eine Mail setzt nur Tickets im Projekt des empfangenden Postfachs fort; fremde Marker werden entfernt, die Tickets verknüpft | [4](#4-antwort-oder-neues-ticket), [6](#6-eine-mail-mehrere-projekte) |
| Ticket-Beziehungen zwischen Projekten erlauben | Redmine, *Tickets* | Tickets verschiedener Projekte können verknüpft werden | [6](#6-eine-mail-mehrere-projekte) |
| Versandweg | Postfach | *Backend des Postfachs*, *Microsoft Graph API* oder *SMTP (Redmine-Standard)* | [7](#7-ausgehende-mails) |
| Abweichender Absender (From), Reply-To auf die Postfach-Adresse setzen | Postfach (SMTP-Weg) | Absenderadresse beim Versand über *SMTP (Redmine-Standard)* | [7](#7-ausgehende-mails) |
| Ordner für gesendete Mails | Postfach (IMAP) | Wo die Kopie einer gesendeten Mail abgelegt wird | [7](#7-ausgehende-mails) |
| Betreff-Vorlage | Projekt | Betreff von Bearbeiterantworten | [7](#7-ausgehende-mails) |
| Kopfzeile, Fußzeile, Fußzeilen-Modus | Postfach (+ zentrale Fußzeile) | Rahmen um den Antworttext | [7](#7-ausgehende-mails) |
| E-Mail-Absender | Redmine, *Mailbenachrichtigung* | Mails von dieser Adresse werden abgelehnt | [4](#4-antwort-oder-neues-ticket) |
| Schneide E-Mails nach einer dieser Zeilen ab, Anhänge nach Namen ausschließen | Redmine, *Eingehende E-Mails* | Wendet der `MailHandler` auf jede Mail an | [4](#4-antwort-oder-neues-ticket) |
