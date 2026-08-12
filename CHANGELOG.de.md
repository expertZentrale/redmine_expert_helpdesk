# Changelog – redmine_expert_helpdesk

> 🇩🇪 Deutsche Version · [English version](CHANGELOG.md)
>
> Die englische `CHANGELOG.md` ist maßgeblich und wird synchron gehalten. Diese deutsche Fassung
> enthält zusätzlich die vollständige Historie vor dem 2026-07-24 (Einträge, die es nur auf Deutsch gibt).

## [Unreleased]

### Hinzugefügt

- **An Kunden gesendete Mails zeigen ihren Sendezeitpunkt jetzt auch in der Journalüberschrift** –
  so wie eingehende Mails das bereits taten. Das Badge einer ausgehenden Notiz endet mit
  `HelpdeskMessage.sent_at` (Tooltip *Gesendet am*), womit sich der gesamte Schriftwechsel auf
  einer Zeitachse verfolgen lässt, statt die ausgehende Seite am Zeitstempel des Journaleintrags
  ablesen zu müssen – der sagt, wann die Notiz gespeichert wurde, nicht wann die Mail rausging.
- **`scripts/README.md` + `scripts/README.de.md` beschreiben das Berechtigungsmodell in
  Microsoft 365.** Wie die tenantweiten Entra-Anwendungsberechtigungen und der
  Exchange-Online-RBAC-Scope zusammenwirken (und warum das Setup erst vollständig ist, wenn
  Erstere wieder entfernt sind), dazu ein Vergleich der vier Varianten der Postfach-Auswahl
  entlang der Frage, die tatsächlich zwischen ihnen entscheidet: wer das nächste Postfach
  aufnehmen kann und was er oder sie dafür braucht – von „eine Exchange-Administratorin führt
  das Skript aus“ (`EmailList`) bis „wer das freigegebene Postfach anlegt, setzt ein Attribut
  mit“ (`CustomAttribute`). Mit Migrationspfad zwischen den Varianten und einem Abschnitt zur
  Fehlersuche.

### Geändert

- **`scripts/setup-azure-app.ps1` kann Postfächer in ein bestehendes Setup aufnehmen.** Bisher
  brach das Skript ab, sobald eine App-Registrierung mit dem angegebenen Namen existierte – ein
  weiteres Projekt anzubinden hieß deshalb, entweder das gesamte Tenant-Setup abzuräumen und neu
  aufzubauen (mit neuem Client-Secret und entsprechender Änderung in Redmine) oder den Exchange
  Online Management-Scope von Hand zu bearbeiten. Das Skript ist jetzt durchgängig wiederholt
  ausführbar: vorhandene App-Registrierung, Service Principal, Client-Secret, EXO-Service-Principal,
  Management-Scope und Rollenzuweisungen werden weiterverwendet statt doppelt angelegt, und ein
  Lauf mit einer neuen Adresse in `-MailboxEmailList` nimmt diese in den bestehenden RBAC-Scope
  auf. Client-ID und Client-Secret bleiben gültig, unter *Administration → Plugins → Redmine
  expert Helpdesk* ändert sich also nichts.
- **`-MailboxEmailList` wirkt jetzt ergänzend.** Der Parameter beschrieb bisher den vollständigen
  Scope; er beschreibt jetzt die Adressen, die im Scope enthalten sein müssen, bereits vorhandene
  bleiben erhalten. Das alte Verhalten („genau diese Liste“) liefert das neue
  `-ReplaceMailboxList`, den Zugriff auf ein Postfach entzieht `-RemoveMailboxEmailList`.
- **Ein erneuter Lauf vergibt die Entra-Graph-Berechtigungen nicht noch einmal.**
  `Mail.ReadWrite`/`Mail.Send` wirken additiv zum RBAC-Scope, Schritt 5 des Setups entfernt sie
  bewusst wieder; sie beim Aufnehmen eines Postfachs erneut zu vergeben, gäbe der App
  stillschweigend wieder Zugriff auf jedes Postfach des Tenants. Vergeben werden sie deshalb nur
  noch, wenn der Lauf die App-Registrierung selbst angelegt hat oder das neue
  `-EnsureEntraGraphPermissions` es ausdrücklich verlangt. Aus demselben Grund legt ein erneuter
  Lauf ohne `-NewClientSecret` kein zweites Client-Secret an.
- **Weitere Ergänzungen im Skript:** `-WhatIf` zeigt eine Scope-Änderung vorab an (alter Filter,
  neuer Filter, aufgenommene und entfernte Adressen), ohne zu schreiben; `-TestMailbox` nimmt
  mehrere Adressen und verwendet standardmäßig die im Lauf hinzugekommenen; die Prüfung der
  Berechtigung wiederholt sich mehrfach, weil Exchange Online einen Moment braucht, bis eine
  Scope-Änderung repliziert ist, ein sofortiges `InScope: False` also noch kein Fehler ist;
  `-RbacScopeName` ist ein Parameter wie schon in `delete-app-registration.ps1`; und `-SelfTest`
  führt die Prüfungen des Scope-Filters offline aus, ohne Verbindung zu einem Tenant.

  Das Skript vergibt Zugriff auf Postfächer, es legt sie nicht an – die Postfächer müssen weiterhin
  im Tenant vorhanden sein.

- **Die Einrichtungsskripte finden ihre Ressourcen über eine Markierung statt über Namen.**
  Anzeigenamen waren der einzige Anker an einer Installation – eine von Hand unter einem anderen
  Namen als der Skriptvorgabe angelegte Einrichtung wurde damit gar nicht gefunden, und das Skript
  legte dann stillschweigend eine zweite, parallele App-Registrierung samt Scope an, statt die erste
  zu erweitern. `setup-azure-app.ps1` taggt die App-Registrierung jetzt (`Tags` enthält
  `RedmineExpertHelpdesk`, über `-ResourceTag` einstellbar) und sucht sie über dieses Tag; der
  Service Principal wird über die AppId aufgelöst; und welcher Management-Scope erweitert wird,
  steht in den vorhandenen Rollenzuweisungen der App – ein anders benannter Scope wird also
  erweitert statt verdoppelt. Installationen aus der Zeit vor dem Tag werden beim nächsten Lauf
  nachträglich markiert, das repariert sich also von selbst. `-AppDisplayName` und `-RbacScopeName`
  braucht es damit nur noch für die Ersteinrichtung oder zur Abgrenzung, und
  `delete-app-registration.ps1` findet sein Ziel auf demselben Weg. Mehrere Installationen in einem
  Tenant hält `-Environment` auseinander (siehe unten).
- **`-Environment` richtet eine Dev-Installation neben der Live-Installation ein.** Ein Dev-Stack
  braucht eine eigene App-Registrierung, damit seine Plugin-Instanz nicht an die
  Live-Helpdesk-Postfächer kommt – die beiden auseinanderzuhalten hieß bisher, bei jedem einzelnen
  Lauf passenden Anzeigenamen und Scope-Namen mitzugeben. `-Environment DEV` leitet jetzt alle drei
  Kennungen auf einmal ab – Tag `RedmineExpertHelpdesk:DEV`, App `redmine-expert-helpdesk-dev`,
  Scope `Redmine-expert-Helpdesk-Mailboxes-DEV` –, damit nichts kollidiert und ein Dev-Lauf nur noch
  `-Environment DEV` ist. Die Bezeichnung ist frei wählbar (`TEST`, `STAGING`, …) und
  Groß-/Kleinschreibung spielt keine Rolle; `delete-app-registration.ps1` nimmt sie ebenfalls, das
  Abräumen allein der Dev-Seite ist also `-Environment DEV`. Die Vorgabe `LIVE` erzeugt exakt die
  bisher verwendeten Namen, abgesichert durch einen Selbsttest, damit bestehende Installationen
  weiterhin gefunden werden. Jede Installation trägt zusätzlich das schlichte Tag
  `RedmineExpertHelpdesk`, über das sich unabhängig von der Umgebung alle Installationen eines
  Tenants auflisten lassen.

### Behoben

- **Den Parameter einer Scope-Variante anzugeben, ohne die Variante zu nennen, wurde stillschweigend
  ignoriert.** `-MailboxCustomAttributeValue "…"` ließ `-MailboxScopeOption` auf der Vorgabe
  `EmailList` stehen, der Parameter blieb also wirkungslos und der Lauf brach mit der Aufforderung
  nach `-MailboxEmailList` ab – dem Parameter einer anderen als der offensichtlich gemeinten
  Variante. Die Variante ergibt sich jetzt aus dem angegebenen Postfach-Parameter; Parameter zweier
  Varianten anzugeben oder einen, der einem ausdrücklichen `-MailboxScopeOption` widerspricht, ist
  ein Fehler statt einer stillschweigenden Entscheidung. Die `EmailList`-Meldung nennt außerdem die
  Parameter der übrigen Varianten, und die `-TestMailbox`-Meldung sagt, welchen Scope sie prüft.
- **Ein Apostroph in `-AppDisplayName` machte die Suche nach der App-Registrierung kaputt** – in
  beiden Skripten. Einfache Anführungszeichen begrenzen Zeichenketten in einem OData-Filter und
  müssen zum Maskieren verdoppelt werden; unmaskiert lief ein solcher Name entweder auf einen Fehler
  oder fragte stillschweigend etwas anderes ab – in `setup-azure-app.ps1` hätte das eine doppelte
  App-Registrierung bedeutet, in `delete-app-registration.ps1` eine nicht gefundene und damit nicht
  entfernte App.

## [0.2.4] - 2026-08-07

### Behoben

- **Der Reiter „KI-Statistik“ erscheint nicht mehr, wenn die KI abgeschaltet ist.** Er wurde in
  jedem Helpdesk-Projekt angezeigt, sobald jemand die globale Berechtigung *KI-Nutzungsstatistik
  ansehen* hatte – auch bei deaktivierten KI-Funktionen und deaktivierter Wissensbasis, wo er
  ausschließlich zu einer leeren Seite führte. Der Reiter erscheint jetzt, sobald mindestens eine
  der beiden Funktionen aktiv ist (die Seite weist sowohl KI-Zusammenfassungen als auch
  Wissensbasis-Anfragen aus, jede der beiden allein macht sie also sinnvoll); die Seite selbst
  antwortet bei beidem aus mit 403, statt über die direkte URL erreichbar zu bleiben.

- **Doppelte DOM-IDs bei jeder Checkbox in den Plugin-Einstellungen und im Postfach-Formular.**
  Vor jeder Checkbox steht ein verstecktes Feld mit ihrem Aus-Wert, und Rails leitete aus dem
  gemeinsamen Feldnamen für beide dieselbe ID ab – `getElementById` lieferte damit das unsichtbare
  versteckte Feld statt der Checkbox. Die versteckten Felder haben jetzt keine ID mehr (12
  Checkboxen in *Administration → Plugins → Redmine expert Helpdesk* und im Postfach-Formular).
  Das Absenden der Formulare war nie betroffen, weshalb es bisher nicht auffiel.

### Geändert

- **Nur noch eine Stelle entscheidet, ob die KI-Funktionen aktiv sind.** Die Prüfung auf
  `ai_enabled` / `kb_enabled` lag in acht Controllern, Jobs, Patches, Views und Rake-Tasks als
  Kopie vor – und fehlte beim Reiter „KI-Statistik“ vollständig, was zu obigem Fehler führte. Alle
  Stellen nutzen jetzt die neuen Prädikate in `RedmineExpertHelpdesk::AiFeatures`. Abgesehen von
  der Fehlerbehebung ändert sich das Verhalten nicht.

## [0.2.3] - 2026-08-06

### Added

- **Tickets, die auf Bearbeitung warten, sind jetzt sofort erkennbar.** Wenn ein Kunde per Mail
  geantwortet hat – oder eine Antwort ein geschlossenes Ticket wiedereröffnet hat – war nirgends
  markiert, dass das Ticket Aufmerksamkeit braucht; Mitarbeiter mussten sich mit dem SLA-Status
  behelfen. Ein Ticket wird nun als **Wartet auf Bearbeitung** markiert, sobald eine eingehende
  Antwort zu einem bestehenden Ticket eintrifft. Die Markierung entfällt, sobald ein Mitarbeiter
  öffentlich antwortet oder das Ticket schließt. Vier Oberflächen zeigen sie an: eine sortierbare
  Spalte **Wartet auf Bearbeitung** samt Filter in der Ticket-Liste, eine hervorgehobene Zeile,
  ein Zähler in der Seitenleiste der Ticket-Liste und ein Block *Helpdesk: Wartet auf Bearbeitung*
  für „Meine Seite". Private Notizen löschen die Markierung bewusst nicht – eine interne Notiz ist
  keine Antwort an den Kunden. Abschaltbar unter *Administration → Plugins → Redmine expert
  Helpdesk*.

- **Kurze Mails kosten keinen KI-Aufruf mehr.** Ein zweizeiliges „Bitte rufen Sie zurück" fasst
  sich selbst zusammen, trotzdem ging jede eingehende Mail an den Anbieter. Die neue zentrale
  Einstellung **Min. Eingabezeichen** (*Administration → Plugins → Redmine expert Helpdesk*,
  Standard 200) legt die Schwelle fest: darunter überspringt `HelpdeskAiSummaryJob` den Anbieter
  (und das Wissensbasis-Retrieval) und legt eine interne Notiz an, die festhält, dass die
  Zusammenfassung übersprungen wurde und warum. Die Notiz wird wie jede andere KI-Notiz
  protokolliert und behält damit ihr 🤖-Badge im Journal (0 Tokens); der eingesparte Aufruf
  taucht in der Nutzungsstatistik auf. Vor der Messung werden
  Leerzeichen normalisiert, damit Quoted-Printable-Umbrüche die Länge nicht aufblähen; Mails mit
  Bildern gehen immer an die KI, und `0` deaktiviert die Prüfung.
- **KI-Diagnose hat ein eigenes Log-Level.** Das neue `RedmineExpertHelpdesk::AiLogger`
  (Gegenstück zu `MailLogger`) schreibt die gemessene Eingabelänge und die Entscheidung als
  `[helpdesk][ai] length issue=#… chars=… min=… images=… decision=skip|summarize` – mit dem
  Schweregrad aus **Log-Level für KI-Diagnose** (*Logging*, Standard `debug`, `off` schaltet ab).
  Rails loggt in Produktion auf `:info` und würde eine `debug`-Zeile verschlucken – die
  Einstellung sähe kaputt aus –, deshalb wird eine Zeile unterhalb der Logger-Schwelle auf diese
  angehoben und trägt ihren Schweregrad stattdessen im Präfix. Ohne die Zeile ließe sich die
  Schwelle nur raten.

### Fixed

- **Die automatische Wiedereröffnung erscheint jetzt in der Ticket-Historie.** Der `MailProcessor`
  setzte den Wiedereröffnungs-Status per `save(validate: false)` ohne Journal – der Status sprang
  also von geschlossen auf offen, ohne Spur in Historie oder Aktivitäten. Der Statuswechsel wird
  nun als Detail an dem Journal vermerkt, das die eingehende Antwort ohnehin anlegt: ein
  Historien-Eintrag statt zwei, und keine zusätzliche Benachrichtigungsmail.

- **Graph wurde als Versandweg für IMAP-Postfächer angeboten, für die er nicht funktionieren kann.**
  Ein IMAP-Postfach über die zentrale Graph-Registrierung senden zu lassen, ist bei „Microsoft 365
  über IMAP" legitim (und in Tenants ohne SMTP-AUTH der einzige funktionierende Weg) — die Regel las
  dafür aber die **Spalte** `oauth_preset` des Postfachs, die gar nicht wirksam ist, wenn die
  Zugangsdaten aus den Plugin-Einstellungen kommen (Standard). Ein Postfach mit globalen
  Zugangsdaten wurde damit an einem Wert gemessen, den niemand benutzt: leer (die REST-API füllt ihn
  nie nach) verbot Graph für ein echtes Microsoft-Postfach, ein veraltetes `microsoft` erlaubte ihn
  auf einer Installation mit globaler Vorlage „Google". Zusätzlich wurde nie geprüft, ob überhaupt
  eine zentrale App-Registrierung existiert — auf einer reinen IMAP-Installation ließ sich `graph`
  auswählen und speichern und scheiterte erst beim Senden. `HelpdeskMailbox#microsoft_hosted?` fragt
  jetzt `MailboxCredentials.preset_for` nach der **wirksamen** Vorlage, und das neue
  `#graph_transport_available?` verlangt zusätzlich konfigurierte zentrale Zugangsdaten (ein
  Graph-Postfach bleibt ausgenommen — sein Backend ist ohnehin Graph, und die Forderung würde es
  unspeicherbar machen, solange die Azure-App noch eingerichtet wird). Das Postfach-Formular wendet
  dieselbe Regel an, die Option erscheint also nicht mehr, wo sie nicht funktionieren kann.

### Changed

- **Der Versandweg steht jetzt neben dem Mail-Anbieter im Postfach-Formular.** "Versandweg" saß im
  Abschnitt *Antwortvorlagen* zwischen Kopfzeile, Fußzeile und Signaturvorschau — eine technische
  Transportentscheidung unter Textbausteinen, und eine, die Antworten, Initialmails und den
  Autoresponder gleichermaßen betrifft, nicht nur Antworten. Er steht jetzt direkt unter
  *Anbieter* am Kopf des Formulars, wo "wie kommt Mail rein" und "wie geht Mail raus"
  zusammen gelesen werden. Gespeicherte Werte und Feldname (`reply_transport`) bleiben unverändert,
  es muss nichts neu konfiguriert werden.

### Added

- **Jede ausgehende Mail wird mit ihrem Transportweg protokolliert.** Ausgehende Mail verlässt das
  Plugin über drei Transportwege (Graph `sendMail`, eigener SMTP-Server des Postfachs, globales
  ActionMailer-SMTP von Redmine) aus vier Stellen (Agenten-Antwort, Initialmail, Autoresponder,
  SLA-Benachrichtigung) — bei einer vermissten Mail stand im Log nirgends, *auf welchem Weg* sie
  versendet wurde. Alle Sendestellen laufen jetzt über `RedmineExpertHelpdesk::MailLogger`, der pro
  Mail eine Zeile mit Route (inkl. SMTP-Host/Port), Postfach, Projekt, Ticket, Empfängern,
  Message-ID und Betreff schreibt. Fehlgeschlagene Sendungen werden auf **error**-Level samt
  Exception protokolliert und weitergeworfen, die bestehende Fehlerbehandlung bleibt unverändert.
  Das Log-Level der Erfolgsmeldung ist unter *Administration → Plugins → Redmine expert Helpdesk →
  Protokollierung* konfigurierbar (`mail_log_level`, Standard `info`; `debug` hält sie aus einem
  Produktiv-Log heraus).

## [0.2.2] - 2026-08-04

### Added

- **Postfächer in der REST-API.** Mit der generischen IMAP/SMTP-Unterstützung ist die
  Konfiguration eines Postfachs deutlich gewachsen (Backend-Auswahl, IMAP-/SMTP-Hosts,
  OAuth2-Grants und -Presets, Gesendet-Ordner) — erreichbar war davon über die API nichts:
  Postfächer waren reine UI-Angelegenheit, und die eingebettete Postfach-Referenz an einem Ticket
  verriet nicht einmal, über welches Backend die Mail hereingekommen war. Es gibt jetzt eine
  vollständige CRUD-Ressource: `GET`/`POST /projects/:id/helpdesk/mailboxes` und
  `GET`/`PUT`/`DELETE /helpdesk/mailboxes/:id`, dazu
  `POST /helpdesk/mailboxes/:id/test_connection`, um die gespeicherte Konfiguration zu prüfen und
  die Ordner aufzulisten. Lesen erfordert wie Schreiben `manage_helpdesk`, denn die Konfiguration
  legt Hosts, Benutzernamen und OAuth-Client-/Tenant-IDs offen. **Secrets sind
  schreibgeschützt-einseitig**: `mail_password`, `oauth_client_secret` und `oauth_sa_key` lassen
  sich setzen, werden aber nie zurückgeliefert — stattdessen enthalten die Antworten Booleans wie
  `mail_password_set` —, und ein `"-"` löscht ein gespeichertes Secret, genau wie das maskierte
  Feld in der Oberfläche. Der interaktive OAuth-Consent bleibt in der UI; `oauth_connected` zeigt
  einem API-Client, wenn er noch aussteht. Die eingebettete Postfach-Referenz an Tickets und
  Nachrichten führt jetzt `provider` mit. Siehe `API.md`.
- **KI- und Wissensbasis-Einstellungen in der Projekteinstellungs-API.** `GET`/`PUT
  /projects/:id/helpdesk/settings` hat sämtliche `ai_*`- und `kb_*`-Felder stillschweigend
  ausgelassen, KI-Zusammenfassung und RAG-Wissensbasis waren also nur über die Oberfläche
  konfigurierbar. Beide werden jetzt wie die SLA- und Phishing-Einstellungen gelesen und
  geschrieben.
- **`docs/redmine_org/` — gepflegte Vorlagen für das Plugin-Verzeichnis auf redmine.org.** Der
  Eintrag unter <https://www.redmine.org/plugins/redmine_expert_helpdesk> wird in Textile
  gerendert, nicht in Markdown. Die Beschreibung musste deshalb bei jeder Aktualisierung von Hand
  umgesetzt werden und war unbemerkt veraltet: Sie warb noch mit „nur Microsoft O365 wird
  unterstützt“, nachdem 0.2.0 längst das generische IMAP/SMTP-Backend mitbrachte.
  `description.textile`, `installation.textile` (das Verzeichnis führt beide in getrennten
  Feldern) und `releases/<version>.textile` enthalten nun den aktuellen Text, ohne Nacharbeit
  einfügbar. Das Aktualisieren gehört zum Erstellen
  eines Releases (dokumentiert in `CLAUDE.md` und `.github/copilot-instructions.md`); `docs/` ist
  von den Release-Archiven ausgenommen, es wird also nichts davon ausgeliefert.

### Fixed

- **Beide READMEs hatten kein Inhaltsverzeichnis.** Sie umfassen über 1150 Zeilen mit rund 20
  Hauptabschnitten; um herauszufinden, ob das Plugin etwa die Wissensbasis oder den
  Release-Prozess dokumentiert, musste man die ganze Datei durchscrollen. Beide beginnen jetzt
  mit einer Inhaltsübersicht in Dokumentreihenfolge, die drei Anbieter-Rezepte eingerückt unter
  *Mail-Anbieter*.
- **`README.de.md` war von der englischen Struktur abgewichen**, die die Sprachrichtlinie
  synchron halten möchte. Die Abschnitte zu KI-Zusammenfassung und Wissensbasis standen am Ende
  statt hinter der REST-API; die CI-Beschreibung war ein Unterabschnitt von *Tests ausführen*,
  wo das Englische ihr einen eigenen Abschnitt *Tests* gibt; und *Kunde einem bestehenden Ticket
  zuordnen* fehlte in der deutschen Datei komplett. Abschnittsreihenfolge und Anzahl der
  Unterabschnitte stimmen jetzt eins zu eins überein.
- **Die redmine.org-Quellen erwähnten die REST-API nicht.** `description.textile` führte jede
  andere Funktion auf, ließ die API aber bei einem blanken Link am Ende, und
  `installation.textile` dokumentierte nur die beiden per Schlüssel gesicherten
  Cron-Endpunkte — nirgends stand also, dass der REST-Webservice unter *Administration →
  Konfiguration → API* aktiviert sein muss oder dass die Postfach-Endpunkte auch zum Lesen
  `manage_helpdesk` verlangen. Beides ist jetzt beschrieben.
- **Die README hat das Plugin weiterhin als reine Microsoft-365-Lösung vorgestellt.** Der
  Einleitungssatz — „E-Mail-zu-Ticket-Plugin für Redmine mit Microsoft-365-Anbindung über die
  Microsoft Graph API" — stammte aus der Zeit vor dem generischen IMAP/SMTP-Backend; der
  Absatz, den die meisten Leser als einzigen sehen, widersprach damit der Funktionsliste
  direkt darunter. Es ist dieselbe stille Drift, die schon
  `docs/redmine_org/description.textile` nach dem Release von 0.2.0 noch „only Microsoft O365
  is supported" verkünden ließ. Ebenfalls korrigiert: der Punkt *Kundenantworten*, der den
  Graph-`sendMail`-Weg als einzigen Versandweg beschrieb, sowie ein Hinweis unter
  *Voraussetzungen*, dass `rake db:create RAILS_ENV=test` neben den RedmineUP-Plugins nicht
  funktionieren kann (der Task bootet Rails, und `redmine_contacts` ruft `table_exists?` gegen
  die noch nicht existierende Datenbank auf).
- **Die Phishing-Erkennung lief unter Ruby 4.0 (Redmine-7-Images) auf einen Fehler.** Der
  `PhishingScanner` hat mit `CGI.parse` das eingepackte Ziel aus Microsoft SafeLinks und anderen
  Redirect-Links geholt; Ruby 4.0 hat diese Methode entfernt. Jeder Link mit Query-String löste
  damit `NoMethodError: undefined method 'parse' for class CGI` aus — SafeLinks wurden nicht mehr
  aufgelöst und Redirect-Links nie markiert. Query-Strings werden jetzt über einen kleinen Helfer
  `query_pairs` mit `URI.decode_www_form_component` zerlegt. Bewusst nicht mit
  `URI.decode_www_form`: das wirft bei einem Segment ohne `=` und verwirft dann den ganzen
  Query-String samt der gültigen Paare, während `CGI.parse` tolerant war — und genau die
  Redirect-Links, für die dieser Code existiert, sind selten sauber gebaut.

## [0.2.1] - 2026-08-04

### Changed

- **Die Ordnerfelder im Postfach-Formular sind jetzt echte Auswahlfelder.** Alle fünf (Quelle,
  verarbeitet, übersprungen, fehlerhaft, gesendet) waren `<input list="…">` an einer gemeinsamen
  `<datalist>`. Browser zeichnen dieses Popup genau wie ihren eigenen Ausfüllverlauf — kein
  erkennbares Aufklapp-Element, nicht gestaltbar und in mehreren Browsern nur Präfix-Treffer —, ein
  wirklich aus dem Postfach gelesener Ordner war also nicht von einem früher eingetippten Wert zu
  unterscheiden. Jedes Feld hat nun einen `▾`-Schalter, der die vollständige Liste öffnet, beim
  Tippen nach Teilzeichenfolge filtert (`arbeit` findet also `Verarbeitet`) und Pfeiltasten, Enter,
  Escape sowie Mausauswahl unterstützt. Freitext bleibt gültig: ein noch nicht vorhandener Ordner
  wird als `+ "…" anlegen` angeboten und weiterhin beim Speichern erzeugt, der bestehende Ablauf
  bleibt also unverändert. Reines JavaScript, keine neue Abhängigkeit
  (`assets/stylesheets/helpdesk_mailbox_form.css`).

## [0.2.0] - 2026-08-04

### Added

- **Issue-Vorlagen für GitHub.** Fehlermeldungen und Feature-Wünsche werden jetzt über
  YAML-Formulare in `.github/ISSUE_TEMPLATE/` erfasst. Damit sind die Angaben, die bisher in den
  meisten Meldungen fehlten — Plugin-Version, die Tabelle aus Administration → Information und der
  betroffene Bereich — von vornherein Pflicht. Freie Issues sind deaktiviert; `config.yml`
  verweist stattdessen auf die README und `API.md`.
- **Generische IMAP/SMTP-Postfächer mit moderner Authentifizierung.** Bisher konnte das Plugin
  Mails ausschließlich über die Graph-API aus Microsoft 365 abholen — Google Workspace, Exchange
  On-Premises, selbst gehostete Dovecot-/Zimbra-Server und gewöhnliche Hoster waren damit außen
  vor. Ein Postfach wählt sein Backend jetzt über die neue Spalte `provider` (`graph` —
  unveränderte Vorgabe — oder `imap`). Eingehende Mails kommen über IMAP
  (`lib/redmine_expert_helpdesk/imap_client.rb`), ausgehende gehen über den eigenen SMTP-Server des
  Postfachs (`smtp_sender.rb`); beides kapselt `imap_provider.rb`. Migrationen `034` und `035`.
- **OAuth2 (XOAUTH2) als Standard-Anmeldung mit drei Verfahren.** `client_credentials`
  (nur Anwendung; Microsoft-IMAP benötigt `IMAP.AccessAsApp` / `SMTP.SendAsApp` im Tenant),
  `authorization_code` (einmalige interaktive Zustimmung, Refresh-Token verschlüsselt gespeichert —
  für Gmail und beliebige Identity Provider) und `jwt_bearer` (Google-Dienstkonto mit domainweiter
  Delegierung; die Assertion wird mit `OpenSSL::PKey::RSA` signiert, ein `jwt`-/`googleauth`-Gem
  ist also nicht nötig). Umgesetzt in `oauth_token_provider.rb`, der gemeinsame SASL-String liegt
  in `xoauth2.rb`. Benutzername/Passwort über TLS bleibt als zweite `auth_method` für Server ohne
  OAuth2 erhalten. **Keine neuen Gems** — `net/imap` und `net/smtp` sind bereits
  Laufzeitabhängigkeiten des von Redmine mitgelieferten `mail`-Gems.
- **OAuth-Zustimmungsablauf.** Neuer `HelpdeskOauthController` mit *einer festen* Callback-URL
  (`/helpdesk/oauth/callback`), weil Identity Provider nur exakt registrierte Redirect-URIs
  akzeptieren; die Postfach-ID steckt in einem signierten, zehn Minuten gültigen `state`
  (`Rails.application.message_verifier`) statt im Pfad. Das Postfach-Formular zeigt die URL
  schreibgeschützt neben einer Schaltfläche „Verbinden“/„Neu verbinden“ und dem Verbindungsdatum.
- **Verbindungsvorlagen** für Microsoft 365, Google Workspace und generische Server
  (`provider_presets.rb`) füllen Hosts, Ports, Endpunkte und Scopes vor. Sie greifen sowohl im
  Formular als auch serverseitig in `HelpdeskMailbox#apply_preset!`, damit auch über die API
  angelegte Postfächer sie erhalten, und **überschreiben nie einen manuell eingetragenen Wert**.
- **Schaltfläche „Verbindung testen“** im Postfach-Formular
  (`HelpdeskMailboxesController#test_connection`) meldet das Ergebnis der Anmeldung und listet die
  sichtbaren Ordner — für beide Provider.
- **Verschlüsselte Geheimnisse.** Postfach-Passwörter, Client-Secrets, Refresh-Tokens und
  Dienstkonto-Schlüssel werden über `secret_box.rb` gespeichert (`ActiveSupport::MessageEncryptor`
  auf Basis von `secret_key_base` — `ActiveRecord::Encryption` gibt es erst ab Rails 7, dieses
  Plugin unterstützt weiterhin Redmine 5.1). Werte tragen das Präfix `enc:v1:`; alles ohne dieses
  Präfix wird unverändert zurückgegeben, sodass bestehender Klartext lesbar bleibt und keine
  Datenmigration nötig ist. Achtung: Ein Wechsel von `secret_key_base` macht gespeicherte
  Geheimnisse unwiederbringlich — sie müssen dann neu eingegeben werden.
- **Ausgehende Mails werden als Kopie im Gesendet-Ordner des Postfachs abgelegt.** Graphs
  `sendMail` erledigt das von selbst, reines SMTP nicht — ein IMAP-Helpdesk-Postfach zeigte
  deshalb nur die eingehende Hälfte jeder Unterhaltung. `ImapClient#append_sent` legt die
  Nachricht jetzt als gelesen ab, unabhängig vom Versandweg — auch beim globalen Redmine-Relay,
  das nirgends etwas ablegt. Der Ordner stammt aus dem `\Sent`-Kennzeichen des Servers nach
  RFC 6154, dann aus der neuen Spalte `sent_folder`, dann aus der Vorlage (`Sent Items` /
  `[Gmail]/Sent Mail` / `Sent`); „Verbindung testen“ nennt den erkannten Ordner. **Ein
  fehlgeschlagenes APPEND wird protokolliert und verschluckt** — der Kunde hat die Mail zu diesem
  Zeitpunkt bereits, und ein Ablageproblem darf nie wie ein Versandfehler aussehen.

### Changed

- **`MailProcessor` ist jetzt providerneutral.** Er spricht mit einem `MailProvider` statt mit dem
  `GraphClient` und verarbeitet ein normalisiertes `MailProvider::MessageMeta`-Struct statt roher
  Graph-JSON-Schlüssel (`meta['subject']`, `meta.dig('from','emailAddress','address')`, …). Ein
  kompletter Abrufzyklus läuft in einem einzigen `provider.with_session`-Block, IMAP öffnet also
  eine Verbindung pro Abruf statt einer pro Nachricht. `GraphProvider` kapselt den **unveränderten**
  `GraphClient`; `GraphClient::GraphError` erbt nun von `MailProvider::ProviderError`, wodurch die
  bestehenden `rescue`-Stellen in `HelpdeskFetchController` und `HelpdeskRepliesController` ohne
  weiteren Umbau mitziehen.
- **Der Antwort-Transport kennt jetzt die Option `provider`** (`REPLY_TRANSPORTS`) und nutzt sie als
  Vorgabe für neue Postfächer: Antworten gehen über das, wofür das Postfach selbst konfiguriert ist
  — Graph oder eigener SMTP-Server. Die bisherigen Werte `graph` und `smtp` (globale
  ActionMailer-Einstellungen von Redmine) verhalten sich unverändert. Verdrahtet in
  `HelpdeskRepliesController` und `InitMailer#send_provider_mime`.
- **Die Herkunft der Zugangsdaten ist jetzt explizit.** `credentials_source` (`global` | `mailbox`)
  entscheidet, woher ein Postfach seine Zugangsdaten liest; leere Felder werden bewusst **nicht**
  aus der jeweils anderen Quelle ergänzt, weil ein halb gefülltes Postfach, das sich stillschweigend
  gegen den falschen Tenant anmeldet, genau der Fehlerfall ist, der zwei Wahrheitsquellen unhaltbar
  macht. `graph` + `global` verhält sich identisch zu vorher. Globale Vorgaben für
  IMAP/SMTP-Postfächer wurden in die Einstellungs-Partial und `init.rb` aufgenommen.
- **Der Cache-Schlüssel des Graph-Access-Tokens enthält jetzt einen Fingerabdruck der
  Zugangsdaten.** Ein gewechseltes Client-Secret hinterließ bisher bis zu eine Stunde lang ein
  veraltetes Token im Cache.

### Fixed

- **Das Wechseln eines OAuth2-Client-Secrets verwarf das zwischengespeicherte Access-Token nicht.**
  Der Kommentar an `OauthTokenProvider#cache_key` versprach, dass „jede Änderung an den
  Zugangsdaten den Schlüssel ändert“ — der Fingerabdruck enthielt aber nur `client_id`,
  `tenant_id`, `token_url`, `scope` und das Grant, und keines davon ändert sich, wenn allein das
  Secret rotiert wird. Das zum abgelösten Secret ausgestellte Token blieb dadurch bis zu seinem
  Ablauf in Gebrauch (bis zu `expires_in - 120` Sekunden). Die Secrets sind jetzt Teil des
  Fingerabdrucks, der ein SHA-256-Digest ist — in den Cache-Schlüssel selbst gelangt also nichts
  Sensibles. Der vorhandene Test konnte das nie aufdecken: Redmines Testumgebung verwendet einen
  Null-Cache, das „zwischengespeicherte“ Token wurde stillschweigend verworfen und jeder Zugriff
  sah aus wie eine frische Anfrage.
- **Presets und globale Verbindungsvorgaben konnten weder Port noch Verschlüsselung setzen.**
  `HelpdeskMailbox#apply_preset!` weist nur dort zu, wo `self[attr].blank?` gilt. Migration `034`
  hatte `imap_port` / `imap_security` / `smtp_port` / `smtp_security` aber Spaltenvorgaben
  mitgegeben (993 / `ssl` / 587 / `starttls`), und eine Spaltenvorgabe ist nie leer — die Zuweisung
  wurde also jedes Mal übersprungen. Nur `imap_host` und `smtp_host`, die keine Spaltenvorgabe
  haben, funktionierten überhaupt. Die in `apply_preset!` dokumentierte Rangfolge (ein benanntes
  Preset schlägt die globalen Vorgaben, das Preset `generic` weicht ihnen) war damit für vier von
  sechs Feldern toter Code. Aufgefallen ist das nie, weil die Presets `microsoft` und `google`
  selbst 993/587 verwenden. Migration `037` entfernt die vier Vorgaben und gibt die Entscheidung an
  `apply_preset!` zurück; `ImapClient#port` und `SmtpSender#port` greifen bei leerer Spalte ohnehin
  je nach Sicherheitsmodus auf sinnvolle Werte zurück. Gespeicherte Werte bleiben unangetastet.
- **Ein neues IMAP-Postfach startete auf einem Antwort-Transport, den die eigene Validierung
  ablehnt.** `reply_transport` hatte die Vorgabe `graph` (Migration `014`, als Graph das einzige
  Backend war), während `#available_reply_transports` `graph` ausschließlich
  `microsoft_hosted?`-Postfächern anbietet — ein reines IMAP-Postfach musste den Wert also erst
  vom Formular überschreiben lassen, bevor es speicherbar war. Migration `037` ändert die Vorgabe
  auf `provider` („das eigene Backend dieses Postfachs“), das für jedes Postfach gültig ist; bei
  einem Graph-Postfach löst `#outgoing_route` es unmittelbar wieder nach `graph` auf.
- **Der Autoresponder ignorierte den Antwort-Transport des Postfachs.**
  `MailProcessor#send_autoresponder` rief bedingungslos `GraphClient#send_mail_mime` auf; ein auf
  SMTP eingestelltes Postfach verschickte seine automatischen Eingangsbestätigungen also trotzdem
  über die Graph-API — und ein IMAP-Postfach hätte sie überhaupt nicht versenden können. Jetzt wird
  wie bei allen anderen ausgehenden Pfaden der Provider des Postfachs verwendet.
- **Härtung: Die Ordner-AJAX-Endpunkte vertrauten einem beliebigen Parameter `mailbox_address`.**
  `HelpdeskMailboxesController#folders` / `#create_folder` / `#ensure_mailbox_folders` bauten daraus
  direkt einen `GraphClient`, sodass jede Person mit `manage_helpdesk` in irgendeinem Projekt die
  Ordner **jedes** Postfachs auflisten oder anlegen konnte, das die zentrale Azure-App-Registrierung
  erreicht. Der Provider wird nun aus dem übermittelten Formularzustand im Kontext des aktuellen
  Projekts oder aus dem gespeicherten Datensatz aufgebaut — dessen Geheimnisse nie an den Browser
  zurückwandern.
- **Startabbruch und ein wirkungsloser OAuth-Controller, beide durch das Autoloading verursacht.**
  `oauth_token_provider.rb` definierte `OAuthTokenProvider`, während Zeitwerk aus diesem Dateinamen
  `OauthTokenProvider` erwartet — Redmine brach beim Start mit einem `Zeitwerk::NameError` ab.
  Unabhängig davon hieß der neue Controller `HelpdeskOauthController`, genau wie der bereits in
  RedmineUPs `redmine_contacts_helpdesk` enthaltene; da sich alle Plugins einen Autoload-Pfad
  teilen, wurde ausschließlich deren Klasse geladen und das Postfach-Formular scheiterte an
  `undefined method 'callback_url'`. Unserer heißt jetzt `ExpertHelpdeskOauthController` mit den
  Route-Helfern `expert_helpdesk_oauth_*`. Der öffentliche Callback-Pfad
  `/helpdesk/oauth/callback` bleibt unverändert, beim Identity Provider muss also nichts neu
  hinterlegt werden.

- **Redundante und wirkungslose globale Einstellungen.** Die Plugin-Einstellungen boten *zwei*
  App-Registrierungen an — die seit jeher vorhandene `tenant_id`/`client_id`/`client_secret` und
  ein zweites Tripel `default_oauth_tenant_id`/`_client_id`/`_client_secret` — im Microsoft-Fall
  also dieselbe Entra-App, mit einer Vorrangregel, die auf dem Bildschirm nirgends erklärt war.
  Das zweite Tripel entfällt; es gibt jetzt genau eine zentrale Registrierung, die sich Graph und
  OAuth2-IMAP/SMTP teilen. Umgekehrt wurden `default_imap_host`/`_port`/`_security` und
  `default_smtp_host`/`_port`/`_security` zwar gespeichert, aber von keiner Codestelle gelesen —
  sie dienen jetzt als Rückfallwert der Vorlage „Andere / selbst gehostet“, sodass ein Betreiber
  mit einem einzigen Mailserver diesen einmal zentral statt an jedem Postfach einträgt. Eine
  benannte Vorlage (Microsoft, Google) hat weiterhin Vorrang, ein ausdrücklicher Wert am Postfach
  vor beidem.
- **„Netzwerkfehler“ statt Ordnerliste bei jedem gespeicherten Postfach.** Der gehärtete
  Ordner-Endpunkt schickt das gesamte Formular per `new FormData(form)` — auf einer
  Bearbeiten-Seite also samt Rails' verstecktem Feld `_method=put`. Rails wertete es aus, machte
  aus dem POST ein PUT auf die Member-Route und führte `#update` mit `id="folders"` aus: ein 404,
  an dessen HTML-Rumpf anschließend der JSON-Parser scheiterte, weshalb das Formular einen
  Netzwerkfehler meldete. Das Feld wird jetzt aus der Anfrage entfernt, und eine Antwort ohne JSON
  nennt ihren tatsächlichen HTTP-Status statt pauschal „Netzwerkfehler“. Betroffen waren „Ordner
  laden“, „Ordner anlegen“ und „Verbindung testen“ bestehender Postfächer; neue Postfächer
  funktionierten, weil ihr Formular kein `_method` enthält.

- **Die Passwort-Anmeldung für einfache IMAP/SMTP-Server handelt ihr Verfahren jetzt aus.** Beide
  Protokolle waren auf genau eines festgelegt: IMAP schickte immer das Kommando `LOGIN`, SMTP
  verlangte immer `AUTH LOGIN`. Ein Server, der `LOGINDISABLED` anzeigt (RFC 3501 verlangt das auf
  ungeschützten Verbindungen, Dovecot setzt es entsprechend) oder nur `PLAIN` bzw. `CRAM-MD5`
  anbietet, wies damit völlig korrekte Zugangsdaten wie einen Anmeldefehler ab. `ImapClient`
  weicht jetzt auf `AUTHENTICATE PLAIN`/`LOGIN` aus, wenn das einfache Kommando abgelehnt wird,
  und `SmtpSender` wählt das erste von `PLAIN`, `LOGIN`, `CRAM-MD5`, das der Server tatsächlich
  anbietet. Ist keines nutzbar, sagt die Fehlermeldung das und verweist auf die Verschlüsselung,
  statt falsche Zugangsdaten zu behaupten.
- **Die IMAP-Capability-Liste wird nach der Anmeldung neu gelesen.** Sie stammte aus der Antwort
  vor der Anmeldung, und `MOVE` sowie `UIDPLUS` werden häufig erst danach angezeigt — der Client
  konnte deshalb den destruktiven Weg über ein einfaches `EXPUNGE` gehen, obwohl der Server beides
  beherrscht.

- **Der Autoresponder ignorierte auch den Versandweg `smtp`.** Die vorige Korrektur löste ihn von
  seinem fest verdrahteten Graph-Aufruf und stellte ihn auf das Backend des Postfachs um — richtig
  für die Wege `provider` und `graph`, aber weiterhin an *SMTP (Redmine-Standard)* vorbei: Ein
  Postfach, das über Redmines eigene ActionMailer-Konfiguration versendet, schickte seine
  automatischen Eingangsbestätigungen trotzdem über die Graph-API oder den eigenen SMTP-Server.
  `MailProcessor#deliver_autoresponder` folgt jetzt derselben Dreiteilung wie Antworten und
  Erstmails, und `graph` meint auch dann die zentrale Registrierung, wenn die Mail über IMAP kam.

- **Ein IMAP-Postfach ließ sich auf den Versand über Microsoft Graph stellen.** Die Auswahl bot
  jedem Postfach alle drei Werte an, sodass ein Gmail- oder Dovecot-Postfach auf
  `POST /users/{adresse}/sendMail` gegen die zentrale Azure-Registrierung zeigen konnte — ein 404,
  der erst beim Versand auffiel, während die Antwort an den Kunden verloren war. `graph` wird
  jetzt nur noch für ein Postfach angeboten und akzeptiert, das Microsoft auch hostet: ein
  `graph`-Postfach oder ein `imap`-Postfach mit der Microsoft-Vorlage (das legitime Szenario
  „Microsoft 365 über IMAP“). Das Formular blendet die Option aus, und `HelpdeskMailbox` prüft
  dieselbe Regel, sodass auch die API sie nicht speichern kann.
- **Jeder Ausgangsweg entschied für sich, welcher Provider versendet.** Der Replies-Controller,
  `InitMailer` und `MailProcessor` hielten je eine eigene Kopie dieser Verzweigung, und jede war
  mindestens einmal falsch — zuletzt der Autoresponder. Es gibt jetzt genau ein
  `MailProvider.outgoing_for(mailbox)`, und `effective_reply_transport` heißt `outgoing_route`,
  denn es steuert Antworten, Erstmails und den Autoresponder gleichermaßen, nicht nur Antworten.

### Changed (Konfigurationsoberfläche)

- **Die Einstellungsseite zeigt nur noch die Felder, die der gewählte Anbietertyp wirklich
  braucht.** Die Vorlage steht an erster Stelle und steuert den Rest: die Tenant-ID erscheint nur
  bei Microsoft, die Authorize-/Token-URLs, der Scope und die IMAP/SMTP-Hosts nur bei „Andere /
  selbst gehostet“, die Callback-URL nur beim Verfahren „Einmalige Zustimmung“ und die
  Azure-Hinweise nur bei Microsoft. Die API-Keys der Cron-Endpunkte stehen jetzt in einem eigenen
  Abschnitt, denn mit Mail-Zugangsdaten haben sie nichts zu tun.
- **Das Postfach-Formular blendet seine eigenen Zugangsdaten-Felder aus, wenn das Postfach die
  Plugin-Einstellungen nutzt.** In diesem Modus werden sie vollständig ignoriert; sie stehen zu
  lassen, zeigte einen zweiten Satz Werte ohne jede Wirkung. Für die Tenant-ID und das Trio aus
  URLs und Scope gelten dieselben Vorlagenregeln wie oben. Der Knopf „Verbinden“ bleibt in beiden
  Fällen sichtbar — das Refresh-Token gehört zum Postfach, nicht zur App-Registrierung.

- **„Verbindung testen“ prüft den Weg, über den das Postfach tatsächlich versendet**, statt immer
  SMTP zu prüfen: SMTP beim eigenen Server, Graph beim Graph-Weg und nichts beim Redmine-Relay,
  dessen Zustand Redmines eigene Sache ist.

### Migration

- `036_add_sent_folder_to_helpdesk_mailboxes.rb` — `sent_folder`. Leer bedeutet „den Server
  fragen“, es ist also keine Konfiguration nötig.
- `034_add_provider_to_helpdesk_mailboxes.rb` — `provider`, `credentials_source`, `imap_host`,
  `imap_port`, `imap_security`, `imap_username`, `imap_verify_ssl`, `imap_unseen_only`,
  `imap_timeout`, `smtp_host`, `smtp_port`, `smtp_security`, `smtp_username`, `smtp_verify_ssl`,
  `auth_method`, `mail_password_enc`.
- `035_add_oauth_tokens_to_helpdesk_mailboxes.rb` — `oauth_preset`, `oauth_grant`,
  `oauth_tenant_id`, `oauth_client_id`, `oauth_client_secret_enc`, `oauth_authorize_url`,
  `oauth_token_url`, `oauth_scope`, `oauth_refresh_token_enc`, `oauth_token_expires_at`,
  `oauth_connected_at`, `oauth_sa_email`, `oauth_sa_key_enc`.
- Beide sind idempotent (`unless column_exists?`). Bestehende Postfächer erhalten
  `provider = 'graph'` und `credentials_source = 'global'`, es ist also **keine Änderung an der
  Konfiguration** bestehender Installationen nötig.

### Hinweise zum IMAP-Verhalten

- Durchgängig werden UIDs verwendet (`UID SEARCH`/`FETCH`/`STORE`/`MOVE`); Sequenznummern
  verschieben sich, sobald parallel auf das Postfach zugegriffen wird.
- Abrufe nutzen `BODY.PEEK[...]`, nie `BODY[...]` — letzteres würde stillschweigend `\Seen` setzen.
- Ordnernamen werden als lesbares UTF-8 mit `/` gespeichert und auf dem Transportweg in
  modifiziertes UTF-7 sowie das Trennzeichen des Servers übersetzt — deutsche Ordnernamen wie
  `Gelöschte Elemente` hängen davon ab.
- Verschoben wird mit `MOVE` (RFC 6851), sofern der Server es anbietet, sonst mit `COPY` +
  `\Deleted` + `UID EXPUNGE` (UIDPLUS). Server, die keines von beidem können, fallen auf ein
  einfaches `EXPUNGE` zurück, das auch **andere** bereits als `\Deleted` markierte Nachrichten im
  Quellordner entfernt; das wird als Warnung protokolliert und in der Oberfläche benannt.

## [Unreleased] 2026-07-24 (85)

### Added
- **Dokumentation: „Ablauf pro Postfachabruf" wieder mit `MailProcessor` synchronisiert.** Das
  Diagramm war veraltet: Es fehlten der Auto-Reply-Filter, die Phishing-Prüfung
  (quarantine vs. neutralize), die MIME-Vorverarbeitung (Thread-Header-Entfernung für das
  Wiedereröffnungs-Alterslimit, `Auto-Submitted`-Entfernung bei NDRs, Setzen von
  `In-Reply-To`/`References`), die Wiedereröffnung bei Antworten, die `HelpdeskTicketInfo`-
  Verknüpfung sowie das asynchrone Einreihen der KI-Zusammenfassung. Außerdem war von einem
  einzigen „Zielordner" die Rede, während der Code drei verwendet
  (`processed_folder` / `skipped_folder` / `failed_folder`, mit Fallbacks). Ergänzt Hinweise zu
  Zielordnern und zur Fehlerisolierung pro Nachricht. In `README.md` gespiegelt.
- **`LICENSE`-Datei (GPL-2.0-or-later)** – das Plugin steht nun ausdrücklich unter der GNU General
  Public License v2 oder später, also unter derselben Lizenz wie Redmine selbst. Ergänzt einen
  Copyright-/Lizenz-Header in `init.rb` sowie die Abschnitte **Lizenz** und **Komponenten von
  Drittanbietern** in `README.md` / `README.de.md` (dokumentiert das mitgelieferte, MIT-lizenzierte
  Chart.js 4.4.6 und chartjs-plugin-datalabels 2.2.0, beide lokal ausgeliefert – zur Laufzeit kein
  CDN-Aufruf).
- **KI-Nutzungsstatistik**: ein projektbezogener Reiter **„KI-Statistik"** (analog zur SLA-Statistik
  – Zeitraumauswahl, Kennzahlen auf einen Blick, Chart.js-Diagramme) mit Anfragevolumen, Token-
  Verbrauch, Aufteilung nach Anfragetyp/Provider-Modell, Erfolg/Fehler, Antwortzeit und Stoßzeiten.
  Grundlage ist ein neues, einheitliches **KI-Nutzungsprotokoll** (`helpdesk_ai_requests`, Migration
  033), das **jeden** KI-Aufruf erfasst – Zusammenfassungen, KB-Extraktion, Embeddings und RAG-
  Retrieval – inkl. Fehlversuchen (bislang nur geloggt) und Embedding-Token (bislang verworfen).
  Der Zugriff ist über eine neue **globale** Berechtigung `view_helpdesk_ai_statistics` geschützt
  (einer Rolle, z. B. „ai-admin", gewähren, um den Reiter in allen Helpdesk-Projekten zu sehen).
  Nur Token – noch keine Kosten/Preise.
- **Administrationsmenü**-Eintrag („expert Helpdesk", mit Headset-Icon), der direkt auf die
  Plugin-Einstellungen verlinkt – die Konfiguration ist so mit einem Klick über die
  Administrations-Sidebar und die Administrations-Übersicht erreichbar, statt über den Umweg
  *Plugins → Konfigurieren*. Das Icon ist versionsabhängig: SVG-Sprite-Icon aus dem Plugin auf
  Redmine 6/7, klassisches `icon-*`-CSS-Icon auf Redmine 5 (`init.rb`, `assets/images/icons.svg`).

### Fixed
- Ticket-Listenansicht: Der per JavaScript eingefügte Button **„Neues Helpdesk-Ticket"**
  (neben „Neues Ticket") wurde unter Redmine 7 „zerhackt" dargestellt – er nutzte noch die alte
  `icon icon-*`-CSS-Klasse, die Redmine 7 entfernt hat, sodass kein Icon mehr geliefert wurde.
  Der Button stellt jetzt – wie die übrigen JS-erzeugten Buttons – das SVG-Sprite-Icon über
  `window.hdSpriteIcon('email')` voran (Fallback auf reines Label, wenn nicht verfügbar)
  (`lib/redmine_expert_helpdesk/hooks.rb`).

### Changed
- **Dokumentationsbeispiele verwenden jetzt neutrale Platzhalter**: Die Microsoft-Graph-/Exchange-
  Beispiele in `README.md`, `README.de.md` und `scripts/setup-azure-app.ps1` nutzen durchgängig
  `helpdesk.example.com` / `@example.com`, und der Abschnitt zum Entwicklungs-Workflow in
  `CLAUDE.md` verweist relativ auf das Repository-Wurzelverzeichnis statt über einen absoluten
  Pfad. Damit sind die Beispiele für jede Installation direkt übernehmbar –
  `-MailboxDomainSuffix` / `-MailboxEmailList` sind ohnehin installationsspezifische Parameter
  und mussten immer gesetzt werden. Keine funktionale Änderung.
- **Bildschirmfotos in beiden READMEs**: `README.md` und `README.de.md` beginnen jetzt mit einer
  kurzen Galerie der wichtigsten Ansichten (SLA-Statistik, KI-Statistik, Kundenliste, Ticketseite)
  und enthalten Bildschirmfotos in den Abschnitten zu Kunden, KI-Zusammenfassungen und
  Wissensbasis – so lässt sich das Plugin beurteilen, ohne es vorher zu installieren. Die Bilder
  liegen unter `docs/screenshots/{en,de}/` und sind **aus den Release-Archiven ausgeschlossen**
  (`--exclude='docs'` in `.github/workflows/release.yml`), das Installationspaket wächst also nicht.
- **Neue Hilfsskripte** `scripts/seed_screenshot_demo.rb` und `scripts/teardown_screenshot_demo.rb`
  erzeugen und entfernen das synthetische Demo-Projekt, aus dem die Bildschirmfotos stammen
  (Kontakte, Tickets mit realistischer SLA-Verteilung, KI-Protokoll, Wissensbasis-Einträge). Beide
  arbeiten ausschließlich innerhalb eines Projekts, schreiben keine globalen Einstellungen und sind
  – wie der übrige `scripts/`-Ordner – nicht Teil der Release-Archive.

## [Unreleased] 2026-07-23 (84)

### Added
- Tag-gesteuerte GitHub-Releases (`.github/workflows/release.yml`): Beim Pushen eines
  semver-Tags (`git tag vX.Y.Z && git push origin vX.Y.Z`) baut ein Workflow das Plugin als
  `redmine_expert_helpdesk-<version>.zip` **und** `.tar.gz` (Top-Level-Ordner
  `redmine_expert_helpdesk/`, Dev-/CI-Dateien ausgeschlossen) und veröffentlicht ein
  GitHub-Release mit diesen Archiven. Die Version wird in `init.rb` gepflegt (Single Source of
  Truth); vor dem Tag setzt der Maintainer `version '...'` in `init.rb`, der Workflow **prüft**
  nur, dass die init.rb-Version zum Tag passt (sonst bricht er ab). Die Release-Notes stammen aus
  den seit dem letzten Tag neu hinzugekommenen CHANGELOG-Einträgen. Releases entstehen
  ausschließlich auf Tags, nicht bei normalen Pushes/PRs.

## [Unreleased] 2026-07-23 (83)

### Changed
- Ticket-Seitenleiste: Die KI-/Wissensbasis-Bedienelemente (🤖 KI-Zusammenfassung neu erzeugen,
  💡 KB-Lösungsvorschläge und manuelle KB-Kuratierung) sind nicht mehr in die Kundenkarte
  eingebettet, sondern stehen in einer eigenen Karte **„KI-Assistent"** direkt unterhalb der
  Kundenkarte (sie beziehen sich auf das Ticket, nicht auf den Kunden). Die Karte erscheint nur,
  wenn für das Projekt tatsächlich KI/KB aktiv ist. Der **🤖-Neu-erzeugen-Button** berücksichtigt
  jetzt zusätzlich den projektbezogenen Schalter *KI-Zusammenfassungen für dieses Projekt erzeugen*
  (`ai_summary_enabled`) – nicht mehr nur den globalen `ai_enabled`
  (`app/views/helpdesk/_issue_sidebar.html.erb`, neuer i18n-Key `label_helpdesk_ai_assistant`).

## [Unreleased] 2026-07-23 (82)

### Fixed
- Kompatibilität mit RedmineUP `redmine_contacts_helpdesk`: In Umgebungen mit diesem Plugin
  führte das Öffnen der Projekteinstellungen zu **HTTP 500**
  („super: no superclass method 'project_settings_tabs'"). Ursache war die Kollision unseres
  `prepend`/`super`-Patches mit deren `alias_method_chain`-Patch derselben Methode.
  `ProjectsHelperPatch` erweitert `project_settings_tabs` jetzt per **UnboundMethod-Capture**
  (statt prepend/super) und koexistiert reihenfolgeunabhängig mit alias_method_chain-Plugins
  (`lib/redmine_expert_helpdesk/patches/projects_helper_patch.rb`, `init.rb`).
- Kompatibilität mit RedmineUP `redmine_contacts_helpdesk` (Fortsetzung): Bei aktivem RedmineUP-
  Helpdesk-Modul im Projekt schlug die **Ticket-Liste mit HTTP 500** fehl
  („super: no superclass method 'column_content'") — dieselbe prepend/super-vs-alias_method_chain-
  Kollision auf `QueriesHelper#column_content`. `QueriesHelperPatch` nutzt jetzt ebenfalls
  **UnboundMethod-Capture**; die SLA-Ampel-Spalten koexistieren mit RedmineUPs Spalten-Rendering
  (`lib/redmine_expert_helpdesk/patches/queries_helper_patch.rb`, `init.rb`).
- Namenskollisionen mit RedmineUP behoben: beide Plugins meldeten einen Einstellungs-Reiter namens
  `helpdesk` an (gleiche DOM-ID → nur ein Reiter zeigte den korrekten Inhalt), und beide zeigten
  Modul **und** Reiter mit dem identischen Anzeigenamen „Helpdesk". Behoben:
  - Reiter-Name jetzt **`expert_helpdesk`** (interne Redirects in
    `helpdesk_fetch`/`helpdesk_mailboxes`/`helpdesk_project_settings` angepasst).
  - Anzeigenamen jetzt **„expert Helpdesk"** für den Reiter (neuer i18n-Key
    `label_expert_helpdesk`) und das Projektmodul (`project_module_helpdesk`), damit sie sich vom
    RedmineUP-„Helpdesk" unterscheiden. Der Modul-Bezeichner bleibt `:helpdesk` (kein Daten-
    Migrationsbedarf; RedmineUP nutzt `:contacts_helpdesk`).
  (`lib/redmine_expert_helpdesk/patches/projects_helper_patch.rb`, `config/locales/{en,de}.yml`).

## [Unreleased] 2026-07-23 (81)

### Changed
- SLA-Statistik: **fertige Zeitraum-Auswahl** (Letzte 7/30/90 Tage, 6/12 Monate, 5 Jahre,
  Benutzerdefiniert). Die Datumsfelder erscheinen nur noch bei „Benutzerdefiniert". Der
  Gruppierungswechsel verengt breite Presets weiterhin auf ein passendes Fenster (ersetzt die
  bisherige Datums-Klemme). Server berechnet die Daten aus dem Preset; explizite Datums-Links
  gelten weiterhin als „Benutzerdefiniert" (`helpdesk_sla_statistics_controller.rb`,
  `index.html.erb`, `helpdesk_sla_stats.js`).

## [Unreleased] 2026-07-23 (80)

### Fixed
- SLA-Statistik: Beim Wechsel der Gruppierung (Tag/Woche/Monat/Jahr) wurde der zuvor gewählte
  (breite) Zeitraum übernommen — z. B. zeigte „Tag" nach der Monatsansicht ein ganzes Jahr an
  Tagesbalken. Der Zeitraum wird beim Gruppierungswechsel jetzt auf ein passendes Fenster
  begrenzt (Tag 30 Tage, Woche 12 Wochen, Monat 12 Monate, Jahr 5 Jahre; Enddatum bleibt); eine
  bereits engere Auswahl bleibt erhalten (`assets/javascripts/helpdesk_sla_stats.js`).

## [Unreleased] 2026-07-23 (79)

### Changed
- Docker-Image-Smoke-Test (`.github/workflows/docker-image.yml`): **Redmine 7.0** in die Matrix
  aufgenommen (offizielles Image `redmine:7.0` ist jetzt veröffentlicht) – getestet werden nun die
  Tags `5.1`, `6.0`, `6.1`, `7.0`. README-Tag-Listen entsprechend ergänzt.

## [Unreleased] 2026-07-22 (78)

### Added
- **Wissensbasis (RAG) aus KI-Zusammenfassungen.** Aus geloesten Tickets wird per KI ein
  `{Problem, Loesung}`-Paar extrahiert, als Embedding in einem **externen Vektor-Store**
  abgelegt und bei kuenftigen Zusammenfassungen fuer **Loesungsvorschlaege** aus aehnlichen
  frueheren Faellen genutzt.
  - **Vektor-Store zentral waehlbar** (`kb_backend`): **Qdrant** (reines HTTP, kein Zusatz-Gem)
    oder **Postgres + pgvector** (benoetigt das `pg`-Gem im Deployment; `PgvectorStore` laedt es
    LoadError-gekapselt). Beide hinter einer `KnowledgeStore`-Schnittstelle
    (`lib/redmine_expert_helpdesk/knowledge_store.rb`).
  - **Strikte Projekt-Isolation:** Qdrant eine Collection je Projekt (`helpdesk_kb_p<id>`),
    pgvector ein zwingendes `WHERE project_id = $1` – ein Projekt sieht nie das Wissen eines anderen.
  - **Pro-Projekt-Optionen:** Beitrag `kb_ingest_mode` = off/auto/**manual** (manuell: beim
    Schliessen entsteht ein `pending`-Eintrag, Freigabe per Seitenleisten-Button) und Anzeige
    `kb_proposal_display` = off/summary/sidebar/both.
  - **Aufnahme** beim Schliessen (via `Issue#after_save` in `patches/issue_patch.rb`, damit auch
    Sammel-Updates (Bulk) und API-/Skript-Aenderungen erfasst werden – nicht nur Einzel-Updates;
    async `HelpdeskKnowledgeIngestJob`) und per Batch-Rake `redmine_expert_helpdesk:kb_backfill`;
    `kb_reembed` baut die Vektoren nach Modellwechsel neu.
  - **Embeddings** zentral konfiguriert (OpenAI oder self-hosted OpenAI-kompatibel – Anthropic
    hat keine Embeddings-API; Fallback auf den Chat-Key bei gleichem Anbieter). Neuer
    `AiClient#embed`, `KnowledgeExtractor`, Modelle `HelpdeskKnowledgeEntry`/`HelpdeskKbProposal`,
    Migrationen `030`–`032`, i18n (de/en), Unit-Tests. Default **deaktiviert**; Datenschutz-Hinweis
    (Problem-/Loesungstext geht an den Embeddings-Anbieter – self-hosted fuer rein lokalen Betrieb).

## [Unreleased] 2026-07-21 (77)

### Added
- Projekt-KI-Einstellungen: Option **„Kompletten Ticketverlauf einbeziehen"** – statt nur der
  auslösenden Mail wird der gesamte Verlauf (Beschreibung + Notizen) an die KI gegeben; die
  eigenen KI-Zusammenfassungs-Notizen werden ausgeschlossen (keine Rekursion). Zusätzliche
  Unteroption **„Auch private Notizen einbeziehen"** (Standard aus; Datenschutz-Hinweis: private
  Notizen gehen dann ebenfalls an den Anbieter). Migration `029`
  (`ai_include_journal`, `ai_include_private_notes`).

## [Unreleased] 2026-07-21 (76)

### Fixed
- KI-Zusammenfassung mit OpenAI **GPT-5-/o-Modellen** (z. B. `gpt-5-nano`) schlug mit
  `HTTP 400 – Unsupported parameter: 'max_tokens' ... Use 'max_completion_tokens' instead`
  fehl. Der OpenAI-Provider sendet jetzt `max_completion_tokens` (funktioniert auch für
  ältere Modelle wie `gpt-4o-mini`); der `custom`-Provider bleibt bei `max_tokens`
  (self-hosted Ollama/vLLM/LocalAI verstehen meist nur diesen Parameter).
- KI-Fehler protokollieren jetzt zusätzlich den **Antwort-Body des Providers** (gekürzt) –
  dort steht der eigentliche Grund (falsches Modell, nicht unterstützter Parameter,
  Kontextlänge …), statt nur „HTTP 400".

### Added
- Button **„KI-Zusammenfassung neu erzeugen"** in der Ticket-Seitenleiste
  (`HelpdeskAiController#regenerate`, Berechtigung `send_helpdesk_reply`): stößt die
  Zusammenfassung der Erstmail manuell an (`force`, unabhängig von der projektspezifischen
  Aktivierung/Umfang) – nützlich für Tickets, deren KI-Lauf zuvor fehlschlug oder die vor
  Aktivierung der Funktion eingingen. Erzeugt eine neue private Notiz inkl. Token-Badge.
- **Modell-Hinweis** in den zentralen Einstellungen: empfohlene, schnelle/günstige Modelle je
  Provider (OpenAI `gpt-4o-mini`/`gpt-5-nano`, Anthropic `claude-haiku-4-5`, self-hosted
  `llama3.1`), Vision-Hinweis und Hinweis, bei Reasoning-Modellen „Max. Ausgabe-Tokens" nicht zu
  niedrig zu setzen.

## [Unreleased] 2026-07-21 (75)

### Added
- **KI-Zusammenfassungen eingehender Mails (pro Projekt).** Bei aus eingehenden Mails
  erzeugten Tickets (optional auch bei Journal-Antworten) fasst eine KI das Anliegen des
  Kunden zusammen – hilfreich bei schwer verständlichen Mails oder weitergeleiteten
  Verläufen mit verstreuten Informationen. Die Zusammenfassung wird als **private
  (interne) Journal-Notiz** ans Ticket gehängt.
  - **Zentrale Konfiguration** (*Administration → Plugins*): Anbieter (OpenAI /
    Anthropic / Eigener OpenAI-kompatibler Endpunkt für self-hosted wie Ollama, vLLM,
    LocalAI, LM Studio), API-Key, Endpunkt, Modell, Standard-Prompt (guter Default
    mitgeliefert) sowie Limits (Eingabezeichen / Ausgabe-Tokens / Timeout).
  - **Projekt-Konfiguration** (Helpdesk-Tab): aktivieren, Umfang (nur Erstmail vs. auch
    Antworten), Prompt erben/erweitern/ersetzen, und **pro Projekt wählbar**, welche
    Anhänge an die KI gehen: Dateinamen/Metadaten, extrahierter Text (PDF via optionalem
    `pdf-reader`, Textdateien) und/oder Bilder (Vision-Modell nötig).
  - **Asynchron** via ActiveJob (`HelpdeskAiSummaryJob`) – KI-Latenz/-Fehler blockieren
    den Mailabruf nicht; scheitert der Call, wird das Ticket dennoch erzeugt (Fehler wird
    nur geloggt). Neuer `lib/redmine_expert_helpdesk/ai_client.rb`, Migration `027`,
    Einstellungs- und Projekt-UI, i18n (de/en). Default **deaktiviert** (Opt-in pro
    Projekt); Datenschutz-Hinweis in READMEs (Mailinhalt + gewählte Anhänge gehen an den
    Anbieter – Eigener Endpunkt ermöglicht rein lokalen Betrieb).
  - **Token-Verbrauch** wird je Zusammenfassung protokolliert (neues Modell/Tabelle
    `HelpdeskAiSummary`, Migration `028`) und – analog zu den Empfänger-Badges (An/CC/BCC) –
    als 🤖-Badge im Journal-Header der Zusammenfassungs-Notiz angezeigt (Tooltip:
    Eingabe-/Ausgabe-Tokens + Modell). `AiClient#last_usage` liest die `usage`-Angaben der
    Provider (OpenAI/kompatibel: `prompt_tokens`/`completion_tokens`; Anthropic:
    `input_tokens`/`output_tokens`).

## [Unreleased] 2026-07-21 (74)

### Added
- Zweite CI-Workflow-Datei `.github/workflows/docker-image.yml`: Smoke-Test gegen die
  **offiziellen Redmine-Docker-Images** (https://hub.docker.com/_/redmine) — also die
  Images, mit denen wir deployen. Matrix über die aktuell veröffentlichten Tags
  `5.1`, `6.0`, `6.1`. Pro Tag wird das offizielle Image mit frischer MariaDB gestartet,
  das Plugin read-only eingehängt und via `REDMINE_PLUGINS_MIGRATE=1` migriert; ein
  erfolgreiches `/login` (HTTP 200) beweist, dass Plugin-`init.rb` und alle Migrationen im
  Produktions-Image sauber laden. Zusätzliche Prüfung, dass das Plugin wirklich erkannt/
  migriert wurde. Ergänzt die quellbasierte `ci.yml` (Unit-/Integrationstests). CI-Badge in
  `README.md` / `README.de.md` ergänzt. ('7.0'/'7' ergänzen, sobald das offizielle Image
  Redmine 7 anbietet.)

## [Unreleased] 2026-07-16 (73)

### Fixed
- Testsuite unter CI grün gemacht (der erste CI-Lauf deckte 6 Failures + 4 Errors auf,
  identisch über alle Redmine-Versionen — die CI-Umgebung selbst war korrekt):
  - **Bugfix Code:** `PhishingDatabaseSync#build_rows` änderte den Feed-String per
    `force_encoding` in-place und scheiterte an eingefrorenen Strings
    (`can't modify frozen String`). Jetzt wird vor der Verarbeitung dupliziert
    (`lib/redmine_expert_helpdesk/phishing_database_sync.rb`).
  - **Testfix:** `TemplateRendererTest` und `HelpdeskRuleTest` nutzten Mocha
    `mock(attr => val)` (erwartet *genau ein* Aufruf) für Felder, die der Code
    berechtigterweise mehrfach bzw. wegen Kurzschluss gar nicht liest (`issue.id`,
    `issue.project`, `project.trackers`, `user.id`). Auf tolerante `stubs` umgestellt.
  - **Testfix:** `HelpdeskApiTest#test_api_disabled_rejects_key` erwartete 401; Redmine
    antwortet bei deaktivierter REST-API in `require_login` (format.api) jedoch mit
    403 Forbidden. Erwartung auf `:forbidden` korrigiert.

## [Unreleased] 2026-07-16 (72)

### Added
- GitHub-Actions-CI (`.github/workflows/ci.yml`): führt die MiniTest-Suite (unit +
  integration) bei jedem Push und Pull Request gegen **alle aktuell unterstützten
  Redmine-Versionen** in sauberer Umgebung aus. Build-Matrix: Redmine 5.1-stable (Ruby 3.2),
  6.0-stable (Ruby 3.3), 6.1-stable (Ruby 3.3), 7.0-stable (Ruby 3.4). Pro Matrix-Eintrag
  wird Redmine frisch ausgecheckt, das Plugin einkopiert, eine leere MariaDB (utf8mb4,
  READ-COMMITTED, wie in Produktion) migriert und danach `redmine:plugins:migrate` +
  `redmine:plugins:test` gestartet. CI-Badge und Test-/CI-Abschnitt in `README.md` /
  `README.de.md` ergänzt.

## [Unreleased] 2026-07-16 (71)

### Added
- GitHub-Copilot-Instructions-Datei (`.github/copilot-instructions.md`): dieselben
  Projektregeln und Architektur-Orientierung wie in `CLAUDE.md`, damit auch GitHub Copilot
  die harten Vorgaben kennt (kein `docker exec`; Änderungen erfordern CHANGELOG-/README-Pflege;
  deutsche Kommentare/i18n; keine ausgelieferten Migrationen editieren; Rebuild via
  `docker-compose ... up --build`, da das Plugin ins Image kopiert wird). `CLAUDE.md` und
  `.github/copilot-instructions.md` sind synchron zu halten.

## [Unreleased] 2026-07-13 (70)

### Added
- „Antworten"-Button jetzt auch am Seitenende — inline in der **unteren Kontextleiste**
  (`div.contextual` unter dem Verlauf, neben „Bearbeiten"/„Aufwand buchen"/…), genau wie
  oben, statt als separate randumrahmte Leiste. Nach dem Durchlesen des Verlaufs muss man
  nicht mehr nach oben scrollen. Aktiviert wie oben die Mail-Antwort und scrollt zum
  Antwort-Panel (`app/views/helpdesk/_reply_in_edit.html.erb`).

### Changed
- Aktivitäts-Feed: Icon ausgehender Helpdesk-Mails ist jetzt hellblau (`#4a90c7`)
  statt rot (`assets/stylesheets/helpdesk_activity.css`).

## [Unreleased] 2026-07-13 (69)

### Fixed
- **„Neues Helpdesk-Ticket": hochgeladene Datei-Anhaenge wurden nicht mitgeschickt.** Die
  initiale Mail (`InitMailer`) band nur inline eingefuegte Bilder ein; regulaere Anhaenge
  des Tickets (PDFs/Dokumente/nicht inline referenzierte Bilder) fehlten. Jetzt werden alle
  nicht-inline Issue-Anhaenge mitgesendet — analog zum Antwort-Flow, in beiden Transporten:
  - `lib/redmine_expert_helpdesk/init_mailer.rb` neue `regular_attachments`-Ermittlung;
    SMTP haengt sie via `Mail#add_file` an, Graph-MIME umschliesst multipart/related mit
    multipart/mixed und fuegt die Anhaenge (`Content-Disposition: attachment`) hinzu.
  - Die versendeten Dateien werden zudem auf der `HelpdeskMessage` gespeichert
    (`sent_attachments`) und in der Info-Leiste des Tickets angezeigt
    (`app/views/helpdesk/_issue_header_bar.html.erb`, „Gesendet an"), wie bei Antworten.

### Fixed
- **Redmine 5.1 bootete nicht mehr** (`uninitialized constant ApplicationRecord`): Redmine 5.x
  kennt `ApplicationRecord` nicht. Behoben durch die versionsabhaengige Basisklasse
  `HelpdeskApplicationRecord` (siehe (66)); Plugin bootet nun unter Redmine 5.1, 6.x und 7.x.
- **Journal-Badges (Empfänger An/CC/BCC, EML-Links) fehlten unter Redmine 6/7.** Redmine 6
  hat das Journal-DOM geändert: die Notiz liegt jetzt in `<div id="change-<journal.id>">` mit
  `<h4 class="journal-header">` statt `#journal-<id>-notes` / `<h4 class="note-header">`. Die
  JavaScript-Injektion in `app/views/helpdesk/_issue_sidebar.html.erb` (`noteHeaderFor`) fand
  den Header nicht mehr und hängte keine Badges an. Jetzt versionsuebergreifend: Redmine 6/7
  über `#change-<journal.id>` + `h4.journal-header`, Redmine 5 weiterhin über
  `#journal-<id>-notes` + `h4.note-header`. Das Badge wird unter Redmine 6/7 in
  `.journal-info` (neben Autor/Zeit) eingehängt statt ganz rechts (Flex-Layout).

## [Unreleased] 2026-07-13 (67)

### Fixed
- **Aktivitäts-Feed: kaputte/gekachelte Richtungsicons unter Redmine 6/7.** Redmine 6
  rendert Aktivitäts-Icons als SVG-Sprite (`activity_event_type_icon` → `sprite_icon`),
  während die alten `icon icon-*`-CSS-Klassen bestehen bleiben. Die früheren
  `background-image`-Regeln kachelten dadurch über die ganze Zeile.
  - `init.rb` registriert den Aktivitäts-Provider ab Redmine 6 mit
    `:plugin => 'redmine_expert_helpdesk'`, damit `Redmine::Activity.plugin_name` greift
    und die Icons aus dem Plugin-Sprite geladen werden.
  - Sprite von `assets/icons.svg` nach `assets/images/icons.svg` verschoben, damit
    Redmine es als `plugin_assets/redmine_expert_helpdesk/icons.svg` ausliefert
    (nur `assets/{stylesheets,javascripts,images}` werden gemappt).
  - `assets/stylesheets/helpdesk_activity.css` alte `background-image`-Klassen entfernt;
    stattdessen Richtungsfarbe je Uhr (grün eingehend / rot ausgehend / grau Erstkontakt)
    auf das `fill`-basierte Sprite-Icon.

### Changed
- **Redmine 7 / Ruby 4 Vorbereitung: `base64` explizit deklariert.** `base64` ist ab
  Ruby 4.0 kein Default-Gem mehr und steht in Redmines 7-Gemfile nicht; das Plugin nutzt
  `Base64.*` (Graph-Client, Antwort-/Initial-Mail-MIME). Neue `PluginGemfile` mit
  `gem 'base64'` (von Redmine automatisch geladen; unter Redmine 5/6 auf Ruby 3.x
  unschädlich).
- **Redmine 7 Icons: Umstellung von den entfernten `icon-*`-CSS-Klassen auf den
  SVG-`sprite_icon`-Helper.** In Redmine 7 wurden die alten `icon-*`-Klassen entfernt;
  Buttons/Icons blieben sonst leer.
  - `app/helpers/helpdesk_icons_helper.rb` (neu) `hd_icon_label(icon, label)` nutzt
    `sprite_icon` (Redmine 6/7) und faellt unter Redmine 5 auf das reine Label zurueck
    (dort liefert die `icon icon-*`-Klasse noch das Icon). In `ApplicationHelper`
    eingebunden (Redmine setzt `include_all_helpers = false`), damit in allen Views verfuegbar.
  - Alle server-gerenderten Icon-Buttons/-Spans/-Links auf `hd_icon_label` umgestellt.
  - `lib/redmine_expert_helpdesk/hooks.rb` stellt ab Redmine 6 einen JS-Helfer
    `window.hdSpriteIcon(name)` bereit (SVG aus dem Icon-Sprite), damit auch per
    JavaScript erzeugte Icons (Antwort-Button, Kunden-Seitenleiste) korrekt erscheinen.

## [Unreleased] 2026-07-10 (65)

### Fixed
- **Redmine 6 Kompatibilität: Boot-Absturz `undefined method 'acts_as_event' for
  class HelpdeskMessage`.** Redmine 6 bindet die `acts_as_*`-DSLs (event,
  activity_provider, positioned …) nicht mehr in `ActiveRecord::Base`, sondern in
  `ApplicationRecord` ein (`Rails.application.reloader.to_prepare`). Die Plugin-Modelle
  erbten direkt von `ActiveRecord::Base` und verloren dadurch diese Methoden beim
  Zeitwerk-Eager-Load.
  - Alle Modelle erben jetzt von einer gemeinsamen abstrakten Basis
    `HelpdeskApplicationRecord` (`app/models/helpdesk_application_record.rb`), die
    versionsabhaengig `ApplicationRecord` (Redmine 6/7, dort liegen die `acts_as_*`)
    oder `ActiveRecord::Base` (Redmine 5.x, das `ApplicationRecord` **nicht** kennt)
    waehlt. So bootet das Plugin unter Redmine 5.1, 6.x und 7.x.

## [Unreleased] 2026-07-09 (64)

### Added
- **REST-API (JSON + XML)** für Automatisierungen, konsistent mit der Redmine-Kern-API
  (Authentifizierung per `X-Redmine-API-Key`, nur bei aktivem REST-Webservice;
  Autorisierung über bestehende Berechtigungen):
  - **Kontakte** (Kunden) — volles CRUD, projektbezogen:
    `GET/POST /projects/:id/helpdesk/contacts.{json,xml}`,
    `GET/PUT/DELETE /helpdesk/contacts/:id.{json,xml}`. Lesen: `view_helpdesk_info`,
    Schreiben: `manage_helpdesk_contacts`.
  - **Tickets** (Redmine-Issues mit Helpdesk-Zusatzdaten: Kunde, Postfach,
    SLA-Zustand, Nachrichtenverlauf) — volles CRUD:
    `GET/POST /projects/:id/helpdesk/tickets.{json,xml}`,
    `GET/PUT/DELETE /helpdesk/tickets/:id.{json,xml}`. Issue-Persistenz delegiert an
    das Kern-Issue-Modell; Autorisierung über `view/add/edit/delete_issues`. Anlegen/
    Ändern kann per `contact_email`/`contact_id` direkt einen Kunden zuordnen;
    `?include=messages` liefert den Nachrichtenverlauf.
  - **Projekt-Einstellungen** (Antwort-/Phishing-/SLA-Konfiguration inkl. Prioritäts-
    Overrides) — Singleton je Projekt, `GET/PUT /projects/:id/helpdesk/settings.{json,xml}`
    (partielles Update). Lesen: `view_helpdesk_info`, Schreiben: `manage_helpdesk`;
    nach dem Speichern werden die SLA-Fälligkeiten neu berechnet.
  - `lib/redmine_expert_helpdesk/api_serializers.rb` (neu) gemeinsame Serialisierer
    für den `api`-Builder; `app/controllers/helpdesk_{contacts,tickets}_api_controller.rb`
    (neu) mit `accept_api_auth`; `app/views/helpdesk_{contacts,tickets}_api/*.api.rsb`
    (neu) Templates für JSON/XML; Routen in `config/routes.rb`; Paginierung über
    `api_offset_and_limit`/`api_meta`.
  - `test/integration/helpdesk_api_test.rb` (neu) Integrationstests (API-Key, JSON);
    create-faehige Routen im vollen Zyklus (anlegen → verifizieren → löschen).
    Änderung/Löschung antworten mit `204 No Content`.
  - `API.md` (neu) ausführliche API-Referenz (alle Parameter, Beispiele je Fall)
    inkl. Abschnitt „Not yet available via REST" (was noch nicht per API geht);
    README verweist nur noch mit Endpunktliste + kurzem curl-Beispiel darauf.

## [Unreleased] 2026-07-09 (63)

### Added
- **Projektauswahl beim Legacy-Kontaktimport** statt „alles importieren" öffnet der
  Import-Knopf jetzt eine Auswahlseite mit den Projekten, die Alt-Kontakte haben
  (je Projekt aufgeschlüsselt nach Kontakten **mit Tickets** und **ohne Tickets**,
  plus einem „kein Projekt"-Bucket); nicht mehr genutzte alte Projekte lassen sich
  abwählen. Es werden dann nur die gewählten Projekte importiert — sowohl Kontakte
  als auch Ticket-Verknüpfungen.
  - `lib/redmine_expert_helpdesk/legacy_contacts_import.rb` Konstruktor-Filter +
    `selected?`, Filter in `import_contacts`/`link_issues`, neue Klassenmethode
    `legacy_project_options` (Projekte mit Alt-Kontaktzahl).
  - `app/controllers/helpdesk_legacy_import_controller.rb` neue `new`-Action
    (Auswahlseite), `import` liest `params[:project_ids]` (leer → Fehlermeldung).
  - `app/views/helpdesk_legacy_import/new.html.erb` (neu) Auswahlformular mit
    „Alle auswählen"; `config/routes.rb` GET-Route `helpdesk/legacy_import/select`.
  - `app/views/settings/_helpdesk_settings.html.erb` Knopf verlinkt auf die
    Auswahlseite (GET) statt direktem POST.
  - `config/locales/de.yml`, `config/locales/en.yml` neue `*_legacy_*`-Schlüssel.
  - `test/unit/legacy_contacts_import_test.rb` (neu) Tests für `selected?`.

## [Unreleased] 2026-07-08 (62)

### Fixed
- **Reaktionsuhr lief auf geschlossenen Tickets ohne erfasste Erstreaktion ewig
  weiter** und konnte so nie erfüllt/überschritten sein. Jetzt endet die Reaktion
  spätestens beim Lösen/Schließen: liegt keine Erstreaktion vor, gilt der
  Schließzeitpunkt (`closed_on`) als Abschluss — dadurch kann die Reaktion bei
  gelösten Tickets korrekt erfüllt **oder überschritten** sein. Konsistent in
  Ticket-Kopf, Grid-Spalte/-Filter/-Sortierung und SLA-Statistik.
  - `lib/redmine_expert_helpdesk/sla.rb` (`state_for`),
    `lib/redmine_expert_helpdesk/patches/issue_patch.rb` (`helpdesk_sla_reaction`),
    `lib/redmine_expert_helpdesk/patches/issue_query_patch.rb` (Rank-SQL, `COALESCE`),
    `lib/redmine_expert_helpdesk/sla_statistics.rb` (`reaction_status`).

## [Unreleased] 2026-07-08 (61)

### Fixed
- **„Offen überschritten" in der SLA-Statistik zählte auch geschlossene Tickets**
  und konnte dadurch größer als die Anzahl offener Tickets sein: Die Reaktionsuhr
  eines geschlossenen Tickets ohne erfasste Erstreaktion erschien fälschlich als
  „offen überschritten". Offene Uhr-Zustände (laufend/Warnung/offen überschritten)
  werden jetzt nur noch für **offene** Tickets gezählt — sowohl in der KPI-Kachel
  als auch in der Erfüllungs-Textzeile.
  - `lib/redmine_expert_helpdesk/sla_statistics.rb` `totals` und `clock_compliance`.

## [Unreleased] 2026-07-08 (60)

### Added
- **Werte- und Prozentbeschriftungen in den SLA-Statistik-Diagrammen** (auch ohne
  Hover — wichtig auf Mobilgeräten):
  - `assets/javascripts/chartjs-plugin-datalabels.min.js` (neu) chartjs-plugin-datalabels
    v2.2.0 (MIT) lokal gebundelt; wird pro Diagramm registriert.
  - `assets/javascripts/helpdesk_sla_stats.js` Volumen/Stoßzeiten zeigen die
    absolute **Anzahl** auf den Balken (Prozentanteil im Tooltip); die SLA-Erfüllung
    ist ein **Erfüllungsquoten-Balken (met%, 0–100%)** je Uhr passend zur Textzeile.
    Bewusst keine Segment-Anteil-Beschriftung, damit bei Daten in nur einem
    Bucket/Segment keine irreführenden „100%" entstehen. Fehlt das Plugin, rendern
    die Diagramme weiterhin (nur ohne Beschriftungen).
  - `app/views/helpdesk_sla_statistics/index.html.erb` bindet das Plugin ein.

## [Unreleased] 2026-07-08 (59)

### Changed
- **SLA-Statistik nutzt jetzt interaktive Chart.js-Diagramme** statt statischer
  CSS-Balken responsiv/mobiltauglich, mit Tooltips und Legenden:
  - `assets/javascripts/chart.umd.min.js` (neu) Chart.js v4.4.6 (MIT) lokal
    gebundelt (kein CDN, offline-/CSP-tauglich).
  - `assets/javascripts/helpdesk_sla_stats.js` (neu) rendert Volumen- (Balken),
    Durchschnittszeiten- (Linien), Erfüllungs- (gestapelte Balken) und
    Stoßzeiten-Diagramme; Daten aus einem JSON-Insel-Element (kein inline-Script).
  - `app/views/helpdesk_sla_statistics/index.html.erb` `<canvas>`-Container +
    JSON-Dateninsel, bindet Chart.js über `content_for :header_tags` ein;
    KPI-Kacheln bleiben als HTML.
  - `assets/stylesheets/helpdesk_activity.css` `hd-stats-*`-Balkenstyles durch
    `hd-chart-box`-Container ersetzt.
  - `app/helpers/helpdesk_sla_statistics_helper.rb` nicht mehr benötigte
    CSS-Balken-Helfer entfernt (Zeitformat/Wochentagsname bleiben).

## [Unreleased] 2026-07-08 (58)

### Added
- **Projekt-Reiter „SLA-Statistik"** (nur bei aktivem SLA sichtbar) mit Kennzahlen
  und CSS-Balkendiagrammen über die SLA-relevanten Tickets, gruppierbar nach
  Tag/Woche/Monat/Jahr mit Zeitraum-Auswahl:
  - Ticketvolumen (erstellt/geschlossen), SLA-Erfüllung (erfüllt vs. überschritten
    je Reaktions-/Lösungsuhr + offene Überschreitungen), Durchschnitts- und
    Median-Zeiten (Erstreaktion/Lösung), Stoßzeiten nach Stunde und Wochentag.
  - `lib/redmine_expert_helpdesk/sla_statistics.rb` (neu) reiner Aggregations-Service
    (Buckets/Volumen/Ø/Median/Erfüllung/Stoßzeiten), Zeit-Buckets in lokaler
    Serverzeit; wiederverwendet `Sla.clock_status_from` und die vorberechneten
    Fälligkeiten/Geschäftsminuten aus `helpdesk_ticket_infos`.
  - `app/controllers/helpdesk_sla_statistics_controller.rb` (neu) mit SLA-Guard
    (403, wenn SLA inaktiv), Perioden-/Zeitraum-Parameter.
  - `app/views/helpdesk_sla_statistics/index.html.erb` +
    `app/helpers/helpdesk_sla_statistics_helper.rb` (neu) CSS-Balken/KPI-Kacheln.
  - `assets/stylesheets/helpdesk_activity.css` neue `hd-stats-*`-Styles.
  - `init.rb` neue Berechtigung `view_helpdesk_sla_statistics` und SLA-gegateter
    Projektmenü-Eintrag; `config/routes.rb` Route `helpdesk_sla_statistics`.
  - `config/locales/de.yml`, `config/locales/en.yml` neue `label_helpdesk_stats_*`-
    und `label_helpdesk_sla_statistics`-Schlüssel.
  - `test/unit/sla_statistics_test.rb` (neu) Tests für Mittelwert/Median/Buckets.

## [Unreleased] 2026-07-08 (57)

### Fixed
- **SLA-Geschäftszeiten wurden in UTC statt lokaler Zeit interpretiert** dadurch
  waren Reaktions-/Lösungs-Fälligkeiten falsch (z. B. Ticket 09:26 Uhr → „fällig
  bis 10:10" statt 09:36): Die konfigurierten Bürozeiten (z. B. 08:00–17:00) sind
  lokale Zeiten, wurden aber über `Time.zone` ausgewertet, das in Hintergrundjobs
  und für Benutzer ohne Zeitzonen-Einstellung UTC ist (08:00 UTC = 10:00 lokal).
  - `lib/redmine_expert_helpdesk/business_hours.rb` `time_on` baut die Bürozeiten
    jetzt in der lokalen Serverzeit (`Time.local`); Tages­grenzen über `getlocal`.
    Konsistent mit der Anzeige (lokale Zeit).
  - `test/unit/business_hours_test.rb` Eingaben ebenfalls in lokaler Zeit.
  - Hinweis: Die vorberechneten Fälligkeiten der Grid-Spalten werden beim nächsten
    SLA-Cron-Lauf (`helpdesk/sla_check`) bzw. bei Ticket-Bearbeitung neu berechnet.

## [Unreleased] 2026-07-07 (56)

### Added
- **SLA-Status als Ticket-Grid-Spalten „SLA Reaktion" und „SLA Lösung"** je
  sortier- und filterbar, damit sich Tickets nach SLA-Status überblicken und
  eingrenzen lassen. Da der Status geschäftszeit-/zeitabhängig ist (nicht direkt
  SQL-fähig), werden die absoluten Fälligkeiten vorberechnet und gespeichert; der
  Grid-Status ergibt sich dann aus reinem Zeitstempel-Vergleich gegen die aktuelle
  Zeit (immer aktuell):
  - `db/migrate/026_add_sla_deadlines_to_helpdesk_ticket_infos.rb` (neu) vier
    Spalten `sla_reaction_due_at`, `sla_reaction_warn_at`, `sla_solution_due_at`,
    `sla_solution_warn_at` (warn_at = Fälligkeit bei 80 % der Zielzeit)
  - `lib/redmine_expert_helpdesk/sla.rb` neu `refresh_deadlines!` (berechnet/leert
    die Fälligkeiten via `BusinessHours#due_at`), `clock_status_from` (günstige
    Statusableitung ohne Geschäftszeit-Schleife), `refresh_project_deadlines!`
  - `lib/redmine_expert_helpdesk/patches/issue_query_patch.rb` zwei sortierbare
    Spalten + zwei Listen-Filter; Status als CASE-Rang-Subquery über die
    gespeicherten Zeitstempel vs. `UTC_TIMESTAMP()` (MariaDB)
  - `lib/redmine_expert_helpdesk/patches/issue_patch.rb` `after_save`-Refresh der
    Fälligkeiten (nur bei neu/Prioritätswechsel/fehlend) sowie Anzeige-Accessoren
    `helpdesk_sla_reaction` / `helpdesk_sla_solution`
  - `lib/redmine_expert_helpdesk/patches/queries_helper_patch.rb` (neu) rendert die
    beiden Spalten als farbige Ampel-Chips (Wiederverwendung der `hd-sla-*`-Styles)
  - `lib/redmine_expert_helpdesk/sla_breach_check.rb` frischt beim Lauf die
    Fälligkeiten aller SLA-Projekte auf (Backfill/Aktualisierung der Grid-Werte)
  - `app/controllers/helpdesk_project_settings_controller.rb` berechnet die
    Fälligkeiten offener Tickets nach Speichern der SLA-Einstellungen neu
  - `config/locales/de.yml`, `config/locales/en.yml` neue Schlüssel
    `label_helpdesk_sla_running`, `label_helpdesk_sla_warning`,
    `label_helpdesk_sla_reaction_col`, `label_helpdesk_sla_solution_col`
  - `init.rb` Registrierung des neuen QueriesHelper-Patches

## [Unreleased] 2026-07-07 (55)

### Added
- **Eigener CronJob-Endpunkt für die SLA-Prüfung** die SLA-Überschreitungsprüfung
  kann jetzt unabhängig vom Mailabruf über eine eigene URL ausgelöst werden
  (`GET`/`POST /helpdesk/sla_check?key=API-KEY`), gesichert per eigenem API-Key:
  - `config/routes.rb` neue Route `helpdesk/sla_check`
  - `app/controllers/helpdesk_fetch_controller.rb` neue Action `sla_check` (timing-sicherer
    Key-Vergleich, ruft `SlaBreachCheck.run_if_due`, liefert JSON `{checked_at, notified}`
    bzw. `{checked_at, skipped:true}` wenn bereits ein Lauf aktiv ist); gemeinsamer Helper
    `valid_api_key?` für `fetch_all` und `sla_check`
  - `init.rb` neue Plugin-Einstellung `sla_api_key`
  - `app/views/settings/_helpdesk_settings.html.erb` Eingabefeld für den SLA-API-Key
  - `config/locales/de.yml`, `config/locales/en.yml` Schlüssel `label_helpdesk_sla_api_key`,
    `text_helpdesk_sla_api_key_info`

### Changed
- **SLA-Prüfung nicht mehr huckepack im `fetch_all`** der Piggyback-Aufruf wurde aus
  `fetch_all` entfernt; die SLA-Prüfung wird jetzt ausschließlich über den neuen
  `sla_check`-Endpunkt ausgelöst (kein doppeltes Auslösen mehr). `fetch_all` führt weiterhin
  Mailabruf und Phishing-Feed-Sync aus.
  - `lib/redmine_expert_helpdesk/sla_breach_check.rb` `run_if_due` liefert jetzt die Anzahl
    versendeter Benachrichtigungen zurück (statt `true`), bzw. `false` bei gehaltenem Lock

## [Unreleased] 2026-07-06 (54)

### Fixed
- **Empfänger der initialen Helpdesk-Mail wurden nirgends angezeigt** — gespeichert wurden sie korrekt (per DB verifiziert), aber die initiale Mail hat kein Journal (sie entsteht mit dem Ticket selbst), daher griff das Journal-Badge-System nicht, und die Info-Leiste am Ticketkopf behandelte nur eingehende Mails:
  - `lib/redmine_expert_helpdesk/hooks.rb` — `view_issues_show_details_bottom` übergibt bei Tickets ohne eingehende Mail die erste ausgehende/init-Nachricht als `outbound` an die Info-Leiste
  - `app/views/helpdesk/_issue_header_bar.html.erb` — neuer Abschnitt „Gesendet an": erste An-Adresse + „+N"-Tag (Tooltip mit vollständiger Liste), CC-/BCC-Tags mit Tooltip, Sendezeitpunkt rechts; Tag-Styling `hih-addr-tag` analog zu den Journal-Badges
  - `config/locales/de.yml`, `config/locales/en.yml` — Schlüssel `label_helpdesk_sent_to`

## [Unreleased] 2026-07-06 (53)

### Added
- **Initiale Helpdesk-Mail an mehrere Empfänger** — das „Neues Helpdesk-Ticket"-Formular (und das Zuordnungsformular für Bestandstickets) unterstützt jetzt mehrere An-Adressen (kommagetrennt) sowie neue CC- und BCC-Felder, jeweils mit Kontakt-Autocomplete:
  - `app/views/helpdesk/_init_section.html.erb` — CC/BCC-Zeilen in beiden Varianten; Autocomplete tokenbasiert (ersetzt nur das letzte Komma-Token, Vorschläge je Token); Platzhalter-Hinweis „Mehrere Adressen mit Komma trennen"
  - `lib/redmine_expert_helpdesk/init_mailer.rb` — `contact_email` akzeptiert kommagetrennte Liste (erster Empfänger wird als Kundenkontakt verknüpft), neue Parameter `cc:`/`bcc:`; SMTP-Versand setzt to/cc/bcc am Mail-Objekt; Graph-MIME erhält `Cc:`- und `Bcc:`-Header (Exchange entfernt Bcc beim Versand); `HelpdeskMessage` speichert `recipient_to/cc/bcc` vollständig
  - `app/controllers/helpdesk_init_controller.rb`, `lib/redmine_expert_helpdesk/hooks.rb` (`controller_issues_new_after_save`) — parsen Adresslisten, validieren die erste An-Adresse, reichen cc/bcc durch
  - `config/locales/de.yml`, `config/locales/en.yml` — Schlüssel `text_helpdesk_multi_recipients_hint`

### Fixed
- `app/views/helpdesk/_init_section.html.erb` — Checkbox-Beschriftung „Initiale E-Mail an Kunden senden" ragte links aus dem sichtbaren Bereich (nur „…en senden" sichtbar): Redmines `.tabular label`-Regel setzt `margin-left:-180px`, der CSS-Override im Init-Abschnitt überschrieb `float`/`width`, aber nicht `margin`; ergänzt um `margin: 0 !important`

## [Unreleased] 2026-07-06 (52)

### Added
- **SLA-Funktion (Reaktions- und Lösungszeit in Geschäftsminuten)** — pro Projekt aktivierbar, Zielzeiten optional je Priorität überschreibbar; Uhren laufen nur innerhalb konfigurierter Arbeitszeiten (Wochentage + Zeitspanne); Ampel-Anzeige am Ticket; optionale Benachrichtigung bei Überschreitung
- `lib/redmine_expert_helpdesk/business_hours.rb` (neu) — Geschäftszeit-Rechner: `elapsed_minutes` (Minuten innerhalb der Arbeitszeiten zwischen zwei Zeitpunkten, Wochenenden/Randzeiten geclampt) und `due_at` (Fälligkeitszeitpunkt nach N Geschäftsminuten); tolerant gegen ungültige Zeitformate (Fallback 08:00–17:00)
- `lib/redmine_expert_helpdesk/sla.rb` (neu) — `targets_for` (Prio-Override → Projekt-Default), `clock_state`/`state_for` (Status `:met`/`:breached_done`/`:running`/`:warning` ab 80 %/`:breached` mit due_at), `enabled_for?` (SLA gilt nur für Tickets nach Aktivierung — `sla_enabled_at`-Guard verhindert, dass Bestandstickets beim Einschalten rot werden), Tracking-Methoden `record_first_response!` und `sync_solution!` (setzt Lösungsminuten aus `issue.closed_on`, Reset bei Reopen)
- `lib/redmine_expert_helpdesk/sla_breach_check.rb` (neu) — prüft offene Tickets in SLA-Projekten auf Überschreitungen (Piggyback in `fetch_all`, Cache-Lock); benachrichtigt einmalig (notified_at-Marker) per `HelpdeskSlaMailer` an Eskalations-E-Mail und/oder Projekt-User
- `app/mailers/helpdesk_sla_mailer.rb` + `app/views/helpdesk_sla_mailer/sla_breach.text.erb` (neu) — Benachrichtigungs-Mail mit Ticket-Link, betroffenen Uhren und Ist/Ziel-Minuten
- `app/models/helpdesk_sla_priority.rb` (neu) — Zielzeit-Overrides je Priorität (leer = Projekt-Default)
- `app/views/helpdesk/_sla_box.html.erb` (neu) — SLA-Anzeige am Ticketkopf: zwei Chips (Reaktion/Lösung): grün „erfüllt (Xm/Ym)“, blau „fällig bis …“, gelb ab 80 %, rot „überschritten“; wird unabhängig vom Kundenkontakt gerendert
- `app/views/projects/settings/_helpdesk.html.erb` — eigenes SLA-Formular: Aktiv-Schalter, Zielzeiten, Wochentag-Checkboxen, Arbeitszeit-Spanne, Prio-Override-Tabelle (je aktiver IssuePriority), Benachrichtigung (Checkbox + Eskalations-E-Mail + User-Select)
- `app/controllers/helpdesk_project_settings_controller.rb` — Update-Action in `update_reply_settings`/`update_sla_settings` aufgeteilt (Marker `sla_form`, damit das zweite Formular die Antwort-Einstellungen nicht zurücksetzt); `sla_enabled_at` wird beim Einschalten gesetzt; Prio-Overrides werden upserted, leere Zeilen gelöscht
- `lib/redmine_expert_helpdesk/hooks.rb` — `controller_issues_edit_after_save` erweitert: öffentlicher Kommentar stoppt Reaktionsuhr (`record_first_response!`), Statuswechsel synchronisiert Lösungszeit (`sync_solution!`); `view_issues_show_details_bottom` rendert die SLA-Box (auch ohne Kontakt)
- `app/controllers/helpdesk_replies_controller.rb` — Kundenantwort stoppt die Reaktionsuhr ebenfalls (dedupe über `||=`-Semantik in `record_first_response!`)
- `app/controllers/helpdesk_fetch_controller.rb` — `SlaBreachCheck.run_if_due` nach dem Mailabruf
- `app/models/helpdesk_project_setting.rb` — `sla_work_days_array`, Validierungen (HH:MM-Format, positive Minuten)
- `assets/stylesheets/helpdesk_activity.css` — Chip-Styles (`hd-sla-met/running/warning/breached`)
- `config/locales/de.yml`, `config/locales/en.yml` — ~25 neue Schlüssel (Formular, Chips, Mailtexte)
- `test/unit/business_hours_test.rb` (neu, 14 Tests) — Clamping, mehrtägig, Wochenend-Skip, due_at-Randfälle (Start vor Arbeitsbeginn/am Wochenende), Fallback bei ungültigem Zeitformat; Kernlogik zusätzlich standalone verifiziert (11/11 Checks)
- `test/unit/sla_test.rb` (neu, 7 Tests) — Statusberechnung met/warning/breached/breached_done, Minuten-Berechnung bei fehlendem Stored-Wert

### Migration
- `023_add_sla_settings_to_helpdesk_project_settings.rb` — `sla_enabled`, `sla_enabled_at`, `sla_reaction/solution_minutes`, `sla_work_days` (Default `1,2,3,4,5`), `sla_work_start/end` (Default 08:00/17:00), `sla_notify_enabled/email/user_id`
- `024_create_helpdesk_sla_priorities.rb` — Tabelle `helpdesk_sla_priorities` (project_id + priority_id unique, reaction/solution_minutes)
- `025_add_sla_tracking_to_helpdesk_ticket_infos.rb` — `first_response_at`, `reaction/solution_business_minutes`, `sla_reaction/solution_notified_at` an `helpdesk_ticket_infos`

## [Unreleased] 2026-07-06 (51)

### Added
- `app/views/helpdesk/_issue_sidebar.html.erb` — Eingehend-Badges zeigen jetzt auch die Empfänger der Mail: „An"- und „CC"-Tags (Stil wie bei den Ausgehend-Badges) mit vollständiger Adressliste im Tooltip; bei mehreren Adressen wird „+N" angezeigt; Datenfelder `to`/`cc` im `hdIncoming`-Array ergänzt (gespeichert wurden `recipient_to`/`recipient_cc` für eingehende Mails bereits seit Migration 009 — es fehlte nur die Anzeige)

## [Unreleased] 2026-07-06 (50)

### Changed
- **Heuristik-Audit umgesetzt: alle Zuordnungen auf explizite Verknüpfungen umgestellt**

- **1. Autoritative Ticket-Zuordnung (`HelpdeskTicketInfo`)** — ersetzt die Konvention „Kontakt der ersten HelpdeskMessage = Kunde des Tickets" (5 Lesestellen):
  - `app/models/helpdesk_ticket_info.rb` (neu) — eine Zeile pro Ticket (`issue_id` unique): `helpdesk_contact_id` (Kunde), `helpdesk_mailbox_id` (Ursprungspostfach); `for_issue`, `link!` (überschreibt gesetzte Werte nicht — Erstkontakt bleibt Kunde)
  - Schreibstellen: `mail_processor.rb` (bei jedem Mail-Eingang), `init_mailer.rb` (manuelles Zuordnen/Erstellen), `legacy_contacts_import.rb` (Import + Reparatur)
  - Lesestellen umgestellt: `hooks.rb` (Info-Leiste, Kundenkarte/Zuordnungsformular, Antwortformular), `helpdesk_replies_controller.rb` (Mailbox/Kontakt-Ermittlung, Fallback-Kette entfernt), `_issue_sidebar.html.erb` (origin_mailbox)
- **2. Ausgehende Antworten: deterministische Journal-Verknüpfung** — ersetzt das 30s-Timestamp-Matching der Ausgehend-Badges:
  - `helpdesk_replies_controller.rb` — liefert `helpdesk_message_id` im JSON zurück
  - `_reply_in_edit.html.erb` — injiziert die ID als Hidden-Field `hd_sent_message_id` in das Issue-Formular vor dem Submit
  - `hooks.rb` — neuer Hook `controller_issues_edit_after_save`: verknüpft das entstehende Journal exakt per ID mit der versendeten Message (`journal_id`), mit Issue-Verifikation
  - `_issue_sidebar.html.erb` — beide Badge-Typen (ein-/ausgehend) nutzen jetzt ausschließlich `journal_id` (gemeinsamer Helper `noteHeaderFor`); `THRESHOLD_MS`, `hdJournals`-Array und `journals_with_notes`-Local komplett entfernt
- **3. Toten Code entfernt** — `app/views/helpdesk/_issue_panel.html.erb` gelöscht (wurde von keinem Hook mehr gerendert, enthielt ein veraltetes Duplikat des Badge-JS inkl. Timestamp-Matching)

### Migration
- `022_create_helpdesk_ticket_infos.rb` — Tabelle `helpdesk_ticket_infos` (issue_id unique + Index, helpdesk_contact_id + Index, helpdesk_mailbox_id, timestamps); **Backfill**: bestehende Tickets erhalten Kunde/Postfach aus ihrer jeweils ersten Nachricht

## [Unreleased] 2026-07-06 (49)

### Changed
- `app/views/helpdesk/_issue_sidebar.html.erb` — Timestamp-Fallback für Eingehend-Badges entfernt (nur Demo-/Testdaten im Einsatz, keine Bestandsdaten vor Migration 021); Zuordnung ausschließlich über `journal_id`, ungenutztes `createdAt`-Feld aus dem Datenarray entfernt

## [Unreleased] 2026-07-06 (48)

### Changed
- **Eingehende Mail-Badges: direkte Journal-Verknüpfung statt Timestamp-Heuristik** — das Timestamp-Matching (Badge-Zuordnung über „Journal wurde innerhalb von 30s zur HelpdeskMessage erstellt") war ein Workaround für die fehlende Verknüpfung; für eingehende Mails ist es unnötig, da `MailHandler.receive` das Journal-Objekt direkt liefert:
  - `lib/redmine_expert_helpdesk/mail_processor.rb` — speichert `journal_id` (= `object.id` wenn Journal) an der eingehenden `HelpdeskMessage`
  - `app/views/helpdesk/_issue_sidebar.html.erb` — Badge-Injektion nutzt bevorzugt `journalId` (exakt); Timestamp-Fallback bleibt nur für Bestandsdaten vor Migration 021 erhalten
  - Ausgehend-Badges behalten das Timestamp-Matching: dort entsteht das Journal durch Redmines separaten Issue-Update-Request, der Reply-Controller kennt die Journal-ID nicht

### Migration
- `021_add_journal_id_to_helpdesk_messages.rb` — Spalte `journal_id` (integer, Index) an `helpdesk_messages`

## [Unreleased] 2026-07-06 (47)

### Fixed
- **Mail-Kopfzeile in Journal-Einträgen** — der Ansatz aus Eintrag (46) funktionierte nicht: Redmines Wiki-Sanitizer entfernt `class`-Attribute aus HTML in Journal-Notizen (per DOM-Analyse bestätigt: `<div>` ohne Klasse), serverseitiges Markup ist daher nicht stylebar. Umstellung auf clientseitige Badge-Injektion analog zu den bestehenden Ausgehend-Badges:
  - `lib/redmine_expert_helpdesk/mail_processor.rb` — schreibt kein HTML mehr in die Journal-Notiz; `received_mail_header`-Methode und Locale-basierte Kopfzeile entfernt
  - `app/views/helpdesk/_issue_sidebar.html.erb` — neues `hdIncoming`-Datenarray (created_at für Timestamp-Matching, Kontaktname/-mail, EML-URL/-Größe, Empfangszeit) und `buildIncomingBadge()`: injiziert „✉ Name (email) 📎 Original E-Mail (Größe) Zeit" in den `h4.note-header` des passenden Journals (Matching über `HelpdeskMessage.created_at` ≈ Journal-Erstellungszeit, 30s-Schwellwert, gemeinsame used-Map mit den Ausgehend-Badges); `inbound_msgs` lädt jetzt auch `:helpdesk_contact`
  - `assets/stylesheets/helpdesk_activity.css` — toten `.hd-received-bar`-Style wieder entfernt

## [Unreleased] 2026-07-06 (46)

### Changed
- `lib/redmine_expert_helpdesk/mail_processor.rb` — Journal-Einträge eingehender Mails erhalten statt des nackten „📎 Original E-Mail"-Links eine **einzeilige Mail-Kopfzeile** (neue Methode `received_mail_header`): E-Mail-Icon, „Empfangen von *Name* (email)" mit mailto-Link, Büroklammer-Icon + „Original E-Mail (Größe)"-Downloadlink, rechtsbündiger Empfangszeitstempel; HTML-escaped via `ERB::Util.html_escape`
- `assets/stylesheets/helpdesk_activity.css` — neue Styles `.helpdesk-mail-header.hd-received-bar`: hellblaue Balken-Optik (Flexbox, eine Zeile), Icons 16px, Zeitstempel per `margin-left:auto` rechtsbündig
- `config/locales/de.yml`, `config/locales/en.yml` — Schlüssel `label_helpdesk_received_from` („Empfangen von" / „Received from")

## [Unreleased] 2026-07-02 (45)

### Fixed
- `app/views/helpdesk_contacts/index.html.erb` — Pagination der Kundenliste wurde als ungestyle Aufzählungsliste dargestellt: `pagination_links_full` liefert nur `<ul class="pages">`, Redmines CSS greift aber nur innerhalb von `.pagination`; Aufruf jetzt wie in den Core-Views in `<span class="pagination">` gewrappt

## [Unreleased] 2026-07-02 (44)

### Fixed
- `app/views/helpdesk/_issue_sidebar.html.erb`, `app/views/helpdesk/_issue_header_bar.html.erb` — Klick auf den Kundennamen im Ticket führte zu `helpdesk_contacts?search=<email>`, die Liste unterstützte den Parameter aber nicht (zeigte ungefiltert alle Kunden); verlinkt jetzt direkt auf die Kunden-Detailseite (`edit_helpdesk_contact_path`), da die Kontakt-ID bekannt ist

### Added
- `app/controllers/helpdesk_contacts_controller.rb` — Kundenliste unterstützt jetzt den `search`-Parameter: Freitextsuche über Name, E-Mail und Firma (case-insensitive, LIKE mit `sanitize_sql_like`); Trefferzahl und Pagination berücksichtigen den Filter
- `app/views/helpdesk_contacts/index.html.erb` — Suchfeld mit Anwenden/Zurücksetzen oberhalb der Liste; Pro-Seite-Links erhalten den Suchbegriff
- `config/locales/de.yml`, `config/locales/en.yml` — Schlüssel `label_helpdesk_contact_search`

## [Unreleased] 2026-07-02 (43)

### Added
- **Reparatur-Button für Alt-Anhänge (EML-Original-Mails)** — das alte Plugin redmine_contacts_helpdesk speicherte Original-Mails als Attachments mit `container_type = 'HelpdeskTicket'` und `container_id` = HelpdeskTicket-ID; nach der Deinstallation sind diese auf den Tickets unsichtbar (DB-Analyse: 178.514 betroffene Anhänge, davon 176.724 über `helpdesk_tickets` einem Ticket zuordenbar)
- `lib/redmine_expert_helpdesk/legacy_contacts_import.rb` — neue Methode `fix_attachments` (Bulk-SQL): hängt Anhänge per `UPDATE ... INNER JOIN helpdesk_tickets` auf `container_type='Issue'`/`container_id=issue_id` um; verknüpft anschließend EMLs (`content_type='message/rfc822'`) mit synthetischen Import-Messages ohne EML-Verweis (`eml_attachment_id`), sodass der „Original-Mail"-Link auf Alt-Tickets erscheint; verwaiste Anhänge (kein helpdesk_tickets-Eintrag) bleiben unangetastet; neue Klassenmethode `misplaced_attachment_count`; `FixResult`-Struct (fixed/orphaned/linked)
- `app/controllers/helpdesk_legacy_import_controller.rb` — Aktion `fix_attachments` mit Ergebnis-Flash
- `config/routes.rb` — Route `POST helpdesk/legacy_fix_attachments`
- `app/views/settings/_helpdesk_settings.html.erb` — Button „EML-Anhänge jetzt reparieren" mit Info (Anzahl betroffener Anhänge); Legacy-Abschnitt erscheint jetzt auch, wenn nur Alt-Anhänge (ohne contacts-Tabelle) vorhanden sind
- `config/locales/de.yml`, `config/locales/en.yml` — Schlüssel `text/button_helpdesk_legacy_fix*`, `notice/error_helpdesk_legacy_fix*`

## [Unreleased] 2026-07-02 (42)

### Fixed
- `lib/redmine_expert_helpdesk/legacy_contacts_import.rb` — **Tickets bekamen falsche Kontakte zugeordnet**: der Import nutzte `contacts_issues`, das in redmine_contacts aber nur die generische „zugeordnete Kontakte"-Tabelle ist (mehrere Kontakte pro Ticket, oft ohne den eigentlichen Kunden — per DB-Analyse bestätigt: 185.759 `helpdesk_tickets`-Zeilen vs. 115.490 `contacts_issues`-Zeilen, 20.993 Tickets mit mehreren Kontakten, Kunde häufig nicht enthalten). Der Import nutzt jetzt die **autoritative Kunden-Zuordnung aus `helpdesk_tickets`** (redmine_contacts_helpdesk); `contacts_issues` nur noch als Fallback wenn `helpdesk_tickets` fehlt
- **Reparatur früherer Import-Läufe**: bestehende synthetische Import-Messages (ohne `helpdesk_mailbox_id`) mit abweichendem Kontakt werden per `update_columns` auf den korrekten Kunden umgestellt (neuer Zähler `issue_links_repaired`); echte Mail-Verläufe (mit Mailbox) werden nie angefasst
- Zusätzlich übernimmt der Import jetzt `message_id` (ohne spitze Klammern) und `ticket_date` aus `helpdesk_tickets` in die synthetische `HelpdeskMessage` — verbessert das Antwort-Threading für Alt-Tickets
- `app/controllers/helpdesk_legacy_import_controller.rb`, `config/locales/de.yml`, `config/locales/en.yml` — Ergebnis-Flash um `%{repaired}` erweitert; Info-Texte auf helpdesk_tickets als Quelle aktualisiert

## [Unreleased] 2026-07-02 (41)

### Added
- **Import aus redmine_contacts / redmine_contacts_helpdesk** — übernimmt Altdaten des RedmineUP-Plugins aus den noch vorhandenen Tabellen `contacts`, `contacts_projects`, `contacts_issues`
- `lib/redmine_expert_helpdesk/legacy_contacts_import.rb` (neu) — Importer-Service, liest die Alttabellen per Raw-SQL (Plugins nicht mehr installiert):
  - Kontakte: E-Mail (erste Adresse bei kommagetrennten Listen), Name (Vor-/Mittel-/Nachname bzw. Firmenname bei `is_company`), Firma, Telefon (erste Nummer), Notizen (aus `background`); Projekt-Zuordnung aus `contacts_projects` **plus** Projekten verknüpfter Tickets; ein `HelpdeskContact` pro (E-Mail, Projekt)
  - Ticket-Verknüpfungen: pro Eintrag in `contacts_issues` wird eine synthetische `HelpdeskMessage` (direction `in`, ohne Mailbox/Message-ID, `sent_at` = Ticket-Erstellung) angelegt, damit Kundenkarte und Info-Leiste auf den alten Tickets erscheinen
  - Idempotent: vorhandene Kontakte (E-Mail+Projekt) und Tickets mit bestehendem Helpdesk-Verlauf werden übersprungen; Kontakte ohne E-Mail werden gezählt und übersprungen; gelöschte Projekte/Tickets werden ignoriert
  - `available?`/`legacy_contact_count` für die bedingte Anzeige in den Einstellungen
- `app/controllers/helpdesk_legacy_import_controller.rb` (neu) — Admin-only Import-Aktion mit Ergebnis-Flash (angelegt/vorhanden/verknüpft/übersprungen)
- `config/routes.rb` — Route `POST helpdesk/legacy_import`
- `app/views/settings/_helpdesk_settings.html.erb` — Abschnitt „Import aus redmine_contacts" mit Info (Anzahl gefundener Alt-Kontakte) und Import-Button; nur sichtbar wenn Altdaten vorhanden sind
- `init.rb` — Require für den Importer
- `config/locales/de.yml`, `config/locales/en.yml` — Schlüssel `label/button/text_helpdesk_legacy_import*`, `notice/error_helpdesk_legacy_import*`

## [Unreleased] 2026-07-02 (40)

### Fixed
- `app/views/helpdesk_mailboxes/_form.html.erb` — Fußzeilen-Vorschau saß außerhalb der Formularzeile: `<pre>` ist ein Block-Element und in `<p>` nicht erlaubt, der Browser schloss das `<p>` daher vorzeitig (leeres `<p>` im DOM, Vorschau linksbündig unter dem Label); ersetzt durch `<span>` mit `white-space:pre-wrap` und `font-family:monospace` — gleiche Darstellung, valides HTML, korrekte Ausrichtung neben dem Label

## [Unreleased] 2026-07-02 (39)

### Changed
- `app/views/helpdesk_mailboxes/_form.html.erb` — Fußzeilen-Vorschau: feste Breite 460px (passend zu den Textareas, verhindert Umbruch unter das Label), hellblauer Hintergrund (`#eaf4fd`) mit blauem Rahmen statt grau

## [Unreleased] 2026-07-02 (38)

### Added
- `app/views/helpdesk_mailboxes/_form.html.erb` — Live-Vorschau „Vorschau effektive Fußzeile“ unterhalb des Fußzeilen-Felds: zeigt die Kombination aus Postfach-Fußzeile und zentraler Signatur gemäß gewähltem Fußzeilen-Modus (JS, aktualisiert bei Modus-Wechsel und Eingabe; zentrale Signatur wird als data-Attribut eingebettet); zeigt „Kein(e)“ wenn leer
- `config/locales/de.yml`, `config/locales/en.yml` — Schlüssel `label_helpdesk_footer_preview`, `text_helpdesk_footer_preview_info`

### Fixed
- `app/views/helpdesk/_macro_chips.html.erb` — Makro-Chips lösen nach dem Einfügen jetzt ein `input`-Event aus, damit Live-Vorschauen (Fußzeilen-Vorschau) den eingefügten Makrotext sofort anzeigen

## [Unreleased] 2026-07-02 (37)

### Added
- **Zentrale Signatur (Fußzeile)** — globale Signatur in den Plugin-Einstellungen, die an ausgehende Kundenantworten und initiale Mails angehängt wird; pro Postfach über den neuen „Fußzeilen-Modus" kombinierbar
- `app/models/helpdesk_mailbox.rb` — Konstante `FOOTER_MODES` (`inherit`/`prepend`/`override`) mit Inclusion-Validierung; neue Methode `effective_footer_template`: `inherit` = zentrale Signatur (Fallback auf Postfach-Fußzeile solange keine zentrale gepflegt ist → abwärtskompatibel für Bestandspostfächer), `prepend` = Postfach-Fußzeile + Leerzeile + zentrale Signatur, `override` = nur Postfach-Fußzeile; `footer_mode` in `safe_attributes` aufgenommen
- `init.rb` — Settings-Default `global_footer` (leer)
- `app/views/settings/_helpdesk_settings.html.erb` — Abschnitt „Zentrale Signatur" mit Textarea und Makro-Chips
- `app/views/helpdesk_mailboxes/_form.html.erb` — Auswahl „Fußzeilen-Modus" oberhalb des Fußzeilen-Felds
- `config/locales/de.yml`, `config/locales/en.yml` — Schlüssel `label/field_helpdesk_global_footer`, `text_helpdesk_global_footer_info`, `field_helpdesk_footer_mode`, `label_helpdesk_footer_mode_{inherit,prepend,override}`, `text_helpdesk_footer_mode_info`
- `test/unit/helpdesk_mailbox_test.rb` (neu) — 7 Tests: inherit mit/ohne zentrale Signatur, leerer Modus = inherit, override, prepend (auch mit leerer Postfach-Fußzeile), Validierung

### Changed
- `app/controllers/helpdesk_replies_controller.rb`, `lib/redmine_expert_helpdesk/hooks.rb`, `lib/redmine_expert_helpdesk/init_mailer.rb` — verwenden `mailbox.effective_footer_template` statt `mailbox.reply_footer` (alle drei Stellen, an denen die Fußzeile gerendert wird: Kundenantwort, Antwortformular-Vorschau, initiale Mail)

### Migration
- `020_add_footer_mode_to_helpdesk_mailboxes.rb` — Spalte `footer_mode` (string(20), default `inherit`, not null) an `helpdesk_mailboxes`

## [Unreleased] 2026-07-02 (36)

### Added
- **Heuristiken für verschleierte Links** (file: `lib/redmine_expert_helpdesk/phishing_scanner.rb`) — drei neue Erkennungen, die Links nicht entfernen, sondern mit einer gelben Warnbox markieren:
  1. **Weiterleitungs-Links**: URL trägt eine zweite, url-kodierte Ziel-URL im Query-Parameter (z. B. `redirect-url.email/?link=https%3A%2F%2F...`); die eingebettete Ziel-URL wird dekodiert, in der Warnbox angezeigt („tatsächliches Ziel: …") und zusätzlich gegen den Feed-Spiegel geprüft — ist das Ziel dort bekannt, wird der Link als voller Treffer neutralisiert
  2. **Kurz-URL-Dienste**: Konstante `SHORTENER_DOMAINS` (bit.ly, tinyurl.com, t.co, …); Warnbox „Ziel nicht erkennbar"
  3. **Anchor-Mismatch**: HTML-Anchors, deren sichtbarer Linktext eine andere Domain zeigt als das href-Ziel (`<a href="evil.net">www.paypal.com</a>`); Subdomain-Verhältnisse gelten nicht als Mismatch
- Verdachtsfälle erhalten in HTML eine Warnbox hinter dem Anchor (nie in Attribute geschrieben), in Plaintext einen `[⚠ …]`-Zusatz hinter der URL; zusätzlich gelbes Warnbanner am Mail-Anfang (rotes Banner weiterhin nur bei bestätigten Treffern); SafeLinks gelten nicht als Weiterleitungs-Verdacht
- `lib/redmine_expert_helpdesk/mail_processor.rb` — Verdachtsfälle werden nie quarantänisiert (zu viele legitime Fälle wie Newsletter-Tracking), auch bei Aktion `quarantine` wird nur bei bestätigten Treffern quarantänisiert; Journal-Notiz um Abschnitt „verschleierte Links" erweitert (`add_phishing_note` nimmt jetzt hits + suspicions)
- `config/locales/de.yml`, `config/locales/en.yml` — Schlüssel `text_helpdesk_phishing_suspicion_banner`, `..._redirect`, `..._shortener`, `..._anchor`, `note_helpdesk_phishing_suspicions`
- `test/unit/phishing_scanner_test.rb` — 6 neue Tests: Redirect-Verdacht (Beispiel-Link aus realer Phishing-Mail), Redirect mit bekanntem Phishing-Ziel = voller Treffer, Kurz-URL-Verdacht, Anchor-Mismatch (mit Warnbox-Assertion), übereinstimmender Linktext kein Verdacht, SafeLinks kein Redirect-Verdacht

### Changed
- `PhishingScanner.scan` liefert jetzt `{ :mime, :hits, :suspicions }` (vorher ohne `:suspicions`)

## [Unreleased] 2026-07-02 (35)

### Added
- **Phishing.Database als zweiter Feed** (github.com/Phishing-Database/Phishing.Database) — optionaler Community-Feed mit aktiven Phishing-URLs (Plain-Text, kein Key nötig), zusätzlich zum PhishTank-Spiegel
- `lib/redmine_expert_helpdesk/phishing_database_sync.rb` (neu) — Download der Plain-Text-Liste (`phishing-links-ACTIVE.txt`), Zeilen-Parsing (Kommentare/Leerzeilen überspringen, Zeilen ohne Schema als `http://` interpretieren), gzip-Erkennung, Import als Quelle `phishing_database` (phish_id/target = nil)
- `lib/redmine_expert_helpdesk/phishing_feeds.rb` (neu) — Orchestrator für alle Feeds: `run_if_stale` (pro Quelle Intervall-geprüft, Cache-Lock gegen Doppelläufe) und `run_all` (manueller Sync, liefert Ergebnisse und Fehler pro Quelle)
- `test/unit/phishing_database_sync_test.rb` (neu) — Zeilen-Parsing, Schema-Ergänzung, Quellen-Trennung beim Ersetzen, per-Source-Staleness

### Changed
- `app/models/helpdesk_phishing_url.rb` — Konstante `SOURCES`; `stale?(interval, source)` prüft pro Quelle; neue Klassenmethoden `replace_source!` (transaktionaler Voll-Import einer Quelle, Duplikate über Quellen hinweg werden per Unique-Index übersprungen) und `with_utf8mb4_connection` (aus PhishtankSync hierher verschoben)
- `lib/redmine_expert_helpdesk/phishtank_sync.rb` — auf `replace_source!` umgestellt (löscht nur noch eigene Quelle statt `delete_all`); Rows enthalten `:source => 'phishtank'`; `run_if_stale`, Lock und utf8mb4-Handling in `PhishingFeeds` bzw. Modell verschoben
- `lib/redmine_expert_helpdesk/phishing_scanner.rb` — Treffer enthalten `:source_label` („PhishTank #ID" bzw. „Phishing.Database"); Ersetzungstext und Log nutzen das Label
- `lib/redmine_expert_helpdesk/mail_processor.rb` — Journal-Notiz nutzt `source_label` statt fest „PhishTank #ID"
- `app/controllers/helpdesk_fetch_controller.rb` — ruft `PhishingFeeds.run_if_stale` auf
- `app/controllers/helpdesk_phishtank_controller.rb` — Button synchronisiert alle aktivierten Feeds (`PhishingFeeds.run_all`), Flash zeigt Ergebnis/Fehler pro Quelle
- `lib/tasks/helpdesk_phishtank.rake` — synchronisiert alle aktivierten Feeds
- `init.rb` — Requires für `phishing_database_sync`/`phishing_feeds`; neue Settings-Defaults `phishing_database_enabled` (`0`), `phishing_database_feed_url` (GitHub-Raw-URL)
- `app/views/settings/_helpdesk_settings.html.erb` — Checkbox + Feed-URL für Phishing.Database; Statuszeile jetzt pro Quelle (Anzahl + letzter Import); Button-Beschriftung generalisiert
- `config/locales/de.yml`, `config/locales/en.yml` — neue Schlüssel (`field_helpdesk_phishing_database_*`, `text_helpdesk_phishing_source_status`, `notice/error_helpdesk_phishing_sync_*`); `text_helpdesk_phishing_link_removed` nutzt `%{source}` statt `%{phish_id}`; veraltete Schlüssel entfernt
- `README.md`, `README.de.md`, `ROADMAP.md` — Phishing.Database als umgesetzt dokumentiert

### Migration
- `019_add_source_to_helpdesk_phishing_urls.rb` — Spalte `source` (string(30), default `phishtank`, not null) mit Index an `helpdesk_phishing_urls`

## [Unreleased] 2026-07-02 (34)

### Fixed
- `lib/redmine_expert_helpdesk/phishing_scanner.rb` — Scan brach mit `invalid byte sequence in UTF-8` ab (dadurch blieb der Phishing-Link im Ticket): `decoded_body` erzwang blind UTF-8, aber Outlook-Mails deklarieren oft windows-1252/iso-8859-1; jetzt wird der Body vom deklarierten Part-Charset nach UTF-8 konvertiert (`encode` mit `:invalid/:undef => :replace`) und abschließend `scrub` angewendet, sodass der Regex-Scan nie mehr an ungültigen Bytes scheitert
- `lib/redmine_expert_helpdesk/phishing_scanner.rb` — `rewrite_part` setzt jetzt `part.charset = 'UTF-8'`, da der neu geschriebene Body UTF-8 ist; vorher hätte ein Empfänger die Bytes im alten Charset interpretiert (Mojibake)

## [Unreleased] 2026-07-02 (33)

### Added
- `lib/redmine_expert_helpdesk/phishing_scanner.rb` — ausführliches Logging im Scan: Anzahl/Typen der Mail-Parts, Anzahl extrahierter URLs pro Part, SafeLink-Auflösungen (info), Treffer (warn, mit PhishTank-ID), Nicht-Treffer inkl. berechnetem Hash (debug, zum Abgleich mit `url_hash` in der DB), Abschluss-Zusammenfassung (geprüfte URLs / Treffer)
- `lib/redmine_expert_helpdesk/mail_processor.rb` — `phishing_check_enabled?` loggt jetzt den konkreten Übersprung-Grund (global deaktiviert / im Projekt deaktiviert / Spiegel leer) bzw. „Prüfung aktiv" mit konfigurierter Aktion

## [Unreleased] 2026-07-02 (32)

### Fixed
- `lib/redmine_expert_helpdesk/phishtank_sync.rb` — PhishTank-Import schlug weiterhin mit `Incorrect string value` fehl, obwohl die Tabelle bereits utf8mb4 war (Migration 018): Redmines `database.yml` nutzt `encoding: utf8` (= utf8mb3), daher lehnte der Server 4-Byte-UTF-8 bereits auf **Verbindungsebene** ab; neue Methode `with_utf8mb4_connection` stellt die Session während des Imports per `SET NAMES utf8mb4` um und stellt danach den vorherigen Charset wieder her (No-Op bei Nicht-MySQL-Adaptern oder wenn die Verbindung bereits utf8mb4 ist)

## [Unreleased] 2026-07-02 (31)

### Fixed
- PhishTank-Import schlug fehl mit `Mysql2::Error: Incorrect string value: '\xF0\x9D\x90\xA2...'` — PhishTank-URLs enthalten 4-Byte-UTF-8-Zeichen (Homoglyphen-Domains mit z. B. mathematischen Buchstaben, ein gängiger Phishing-Trick), die Tabelle war aber mit Redmines Standard-Charset utf8mb3 angelegt

### Migration
- `018_convert_helpdesk_phishing_urls_to_utf8mb4.rb` — konvertiert `helpdesk_phishing_urls` per `ALTER TABLE ... CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci` (nur bei MySQL/MariaDB-Adapter; kein Down-Path, da utf8mb4 abwärtskompatibel ist)

## [Unreleased] 2026-07-02 (30)

### Changed
- `lib/redmine_expert_helpdesk/phishtank_sync.rb` — Feed-URL ist jetzt konfigurierbar: Konstante `DEFAULT_FEED_URL` (`https://data.phishtank.com/data/{key}/online-valid.json.gz`, https statt http) ersetzt `ANONYMOUS_URL`/`KEYED_URL`; Konstruktor nimmt `feed_url_template` als zweiten Parameter; Platzhalter `{key}` wird durch den App-Key ersetzt, ohne Key wird das Pfadsegment `/{key}` entfernt (anonymer Endpunkt)
- `init.rb` — neuer Settings-Default `phishtank_feed_url`
- `app/views/settings/_helpdesk_settings.html.erb` — Eingabefeld „Feed-URL" mit Voreinstellung
- `app/controllers/helpdesk_phishtank_controller.rb`, `lib/tasks/helpdesk_phishtank.rake` — übergeben die konfigurierte Feed-URL an `PhishtankSync`
- `config/locales/de.yml`, `config/locales/en.yml` — Schlüssel `field_helpdesk_phishtank_feed_url`, `text_helpdesk_phishtank_feed_url_info`

### Fixed
- PhishTank-Download schlug mit HTTP 404 fehl (http://-Endpunkt); Default nutzt jetzt `https://data.phishtank.com` und die URL kann bei künftigen Endpunkt-Änderungen ohne Code-Anpassung korrigiert werden

## [Unreleased] 2026-07-02 (29)

### Added
- `app/controllers/helpdesk_phishtank_controller.rb` (neu) — Admin-only Controller (`require_admin`) für den manuellen PhishTank-Sync; führt `PhishtankSync#run` aus und meldet Erfolg (Anzahl importierter URLs) bzw. Fehler per Flash; Weiterleitung zurück zu den Plugin-Einstellungen; bei deaktivierter Integration Fehlermeldung
- `config/routes.rb` — Route `POST helpdesk/phishtank_sync` (`helpdesk_phishtank_sync_path`)
- `app/views/settings/_helpdesk_settings.html.erb` — Button „PhishTank-Datenbank jetzt herunterladen" unterhalb der Statuszeile (mit Bestätigungsdialog, da der Download einige Minuten dauern kann)
- `config/locales/de.yml`, `config/locales/en.yml` — Schlüssel `button_helpdesk_phishtank_sync`, `text_helpdesk_phishtank_sync_confirm`, `notice_helpdesk_phishtank_sync_done`, `error_helpdesk_phishtank_sync_failed`, `error_helpdesk_phishtank_disabled`

## [Unreleased] 2026-07-02 (28)

### Added
- **PhishTank-Integration (Phishing-Link-Erkennung)** — optionale, pro Projekt aktivierbare Prüfung eingehender Mails gegen einen lokalen Spiegel der PhishTank-Datenbank; Microsoft SafeLinks werden lokal dekodiert (kein HTTP-Request)
- `app/models/helpdesk_phishing_url.rb` (neu) — Modell für den lokalen PhishTank-Spiegel; `normalize` (Schema/Host lowercase, Fragment weg, Trailing-Slash weg), `hash_for`/`lookup` (SHA-256-Hash-Lookup über Unique-Index), `stale?(interval_hours)` für die Intervall-Prüfung
- `lib/redmine_expert_helpdesk/phishtank_sync.rb` (neu) — Download von `online-valid.json.gz` (anonym oder mit App-Key), gunzip + JSON-Parse, Voll-Import in Transaktion (delete_all + insert_all in 1000er-Batches, Duplikat-Filterung); `run_if_stale` mit Rails.cache-Lock gegen parallele Downloads; bei Fehlern bleiben alte Daten erhalten
- `lib/redmine_expert_helpdesk/phishing_scanner.rb` (neu) — scannt text/plain- und text/html-Parts auf URLs, dekodiert SafeLinks (`*.safelinks.protection.outlook.com` → Query-Parameter `url`), prüft gegen den Spiegel und ersetzt Treffer durch Warnhinweis (`[LINK ENTFERNT – Phishing-Verdacht (PhishTank #ID)]`) plus Warnbanner am Body-Anfang; multipart-sicher (Base64-Re-Encoding je Part); Fehler führen zu unverändertem MIME (fail-open)
- `lib/tasks/helpdesk_phishtank.rake` (neu) — Rake-Task `redmine_expert_helpdesk:phishtank_sync` für manuellen/Cron-Trigger
- `lib/redmine_expert_helpdesk/mail_processor.rb` — Phishing-Prüfung in `process_message` nach dem Auto-Reply-Filter: bei Aktion `quarantine` wird die Mail ohne Ticket in den Skipped-Ordner verschoben; bei `neutralize` läuft die Verarbeitung mit umgeschriebenem MIME weiter und `add_phishing_note` hinterlegt eine Journal-Notiz mit allen entfernten URLs (inkl. aufgelöster SafeLinks-Ziele und PhishTank-IDs); neue Helper `phishing_check_enabled?`, `phishing_action`, `project_setting`, `add_phishing_note`
- `app/controllers/helpdesk_fetch_controller.rb` — `fetch_all` triggert `PhishtankSync.run_if_stale` nach dem Mailabruf (Piggyback auf den Cron-Aufruf); Fehler beim Sync beeinträchtigen den Mailabruf nicht
- `app/views/settings/_helpdesk_settings.html.erb` — neues PhishTank-Fieldset: Aktiv-Checkbox, App-Key (optional), Download-Intervall, Statusanzeige (Anzahl URLs + letzter Import)
- `app/views/projects/settings/_helpdesk.html.erb` — Projekt-Optionen (nur sichtbar wenn global aktiviert): Checkbox „Phishing-Prüfung aktivieren" + Auswahl der Aktion (neutralisieren/Quarantäne)
- `app/controllers/helpdesk_project_settings_controller.rb` — speichert `phishing_check_enabled` und `phishing_action` (Whitelist-geprüft)
- `app/models/helpdesk_project_setting.rb` — Konstante `PHISHING_ACTIONS` (`neutralize`, `quarantine`), Inclusion-Validierung, `effective_phishing_action` mit Fallback auf `neutralize`
- `init.rb` — Requires für `phishtank_sync` und `phishing_scanner`; neue Settings-Defaults `phishtank_enabled` (`0`), `phishtank_app_key` (``), `phishtank_interval_hours` (`6`)
- `config/locales/de.yml`, `config/locales/en.yml` — 15 neue Schlüssel (PhishTank-Labels, Projekt-Optionen, Warnbanner, Journal-Notiz, Statuszeile)
- `ROADMAP.md` (neu) — geplante Anti-Phishing-Maßnahmen: weitere Feeds (URLhaus, OpenPhish, Google Safe Browsing), URL-Heuristiken (Punycode, IP-Literale, Anchor-Mismatch), SPF/DKIM/DMARC-Auswertung, URL-Shortener-Auflösung, Anhang-Scanning (ClamAV/VirusTotal), Meldeworkflow, Eskalation, Reporting
- `test/unit/helpdesk_phishing_url_test.rb` (neu) — Normalisierung (Case, Trailing-Slash, Fragment), Lookup, `stale?`
- `test/unit/phishing_scanner_test.rb` (neu) — SafeLinks-Dekodierung, Treffer in Plaintext/Multipart-HTML, MIME-Rewrite, saubere Mail unverändert, fehlertolerantes Verhalten
- `test/unit/phishtank_sync_test.rb` (neu) — Import mit gestubbtem Download, Duplikat-Filterung, Voll-Ersetzung, Fehlerfall erhält Altdaten
- `test/unit/helpdesk_project_setting_test.rb` — Tests für `phishing_action`-Validierung und `effective_phishing_action` ergänzt

### Migration
- `016_create_helpdesk_phishing_urls.rb` — neue Tabelle `helpdesk_phishing_urls` (`url` TEXT, `url_hash` VARCHAR(64) mit Unique-Index, `phish_id` mit Index, `target`, `imported_at`)
- `017_add_phishing_settings_to_helpdesk_project_settings.rb` — `phishing_check_enabled` (boolean, default false) und `phishing_action` (string, default `neutralize`) an `helpdesk_project_settings`

## [Unreleased] 2026-06-30 (27)

### Fixed
- `lib/redmine_expert_helpdesk/mail_processor.rb` — `HelpdeskMessage.message_id` wurde mit spitzen Klammern gespeichert (`<id@host>`), aber `find_referenced_issue` suchte ohne Klammern (via `scan(/<([^>]+)>/)`); dadurch schlug der Lookup fuer `ensure_thread_reference` immer fehl und Antworten auf den Autoresponder wurden als neue Tickets angelegt; Fix: `meta['internetMessageId'].to_s.delete('<>').strip` beim Speichern

## [Unreleased] 2026-06-30 (26)

### Fixed
- `lib/redmine_expert_helpdesk/mail_processor.rb` — Autoresponder schlug mit HTTP 400 fehl, weil Microsoft Graph `internetMessageHeaders` im JSON-`sendMail`-Body ablehnt; Umstellung auf `send_mail_mime` (MIME-Endpunkt), der vollstaendige Header-Kontrolle erlaubt; `send_autoresponder` bekommt jetzt `in_reply_to_message_id` (= `meta['internetMessageId']` der Kundenmail), setzt `In-Reply-To` und `References` auf die Message-ID der urspruenglichen Kundenmail; Antworten des Kunden auf den Autoresponder enthalten diese ID in ihrer `References`-Kette, sodass `find_referenced_issue` und Redmines MailHandler das Ticket korrekt zuordnen

## [Unreleased] 2026-06-30 (25)

### Fixed
- `lib/redmine_expert_helpdesk/mail_processor.rb` — Antworten auf den Autoresponder erzeugten ein neues Ticket, weil MailHandler die Mail nicht dem richtigen Ticket zuordnen konnte (fehlender `[#id]`-Betreff oder unbekannte Message-ID). Drei-Schichten-Fix:
  1. `send_autoresponder`: synthetische Redmine-Message-ID (`redmine.issue-{id}.autoresponder.{ts}@helpdesk`) als `References`-Header im ausgehenden Autoresponder gesetzt; Exchange/Outlook propagiert diesen Header in Antworten, Redmines MailHandler erkennt `redmine.issue-(\d+)\.` darin
  2. `send_autoresponder`: synthetische ID wird in `HelpdeskMessage.message_id` gespeichert, sodass `find_referenced_issue` Antworten auch ohne Betreff-Match zuordnen kann
  3. Neue Methode `ensure_thread_reference(mime)`: wird in `process_message` vor `MailHandler.receive` aufgerufen; injiziert `[#id]` in den Betreff wenn `find_referenced_issue` ein Ticket findet und der Betreff kein `[#id]` enthaelt – Fallback fuer alle anderen Faelle (geaenderter Betreff, fehlende Header-Propagierung)

## [Unreleased] 2026-06-30 (24)

### Added
- `lib/redmine_expert_helpdesk/mail_processor.rb` — nach erfolgreichem Autoresponder-Versand wird `Journal.create!` aufgerufen und eine interne Notiz am Ticket hinterlegt ("Automatische Bestätigungsmail an <email> versendet."); Notiz erscheint nur wenn der Versand erfolgreich war (vor dem `rescue GraphClient::GraphError`)
- `config/locales/de.yml`, `config/locales/en.yml` — Schluessel `note_helpdesk_autoresponder_sent` hinzugefuegt

## [Unreleased] 2026-06-30 (23)

### Changed
- `assets/stylesheets/helpdesk_activity.css` — `padding-bottom: 2px !important` zu allen drei Icon-Klassen hinzugefuegt, um unteren Abschnitt des Pfeil-Kreises sichtbar zu halten

## [Unreleased] 2026-06-30 (22)

### Fixed
- `assets/stylesheets/helpdesk_activity.css` — Pfeil-Kreis der Bootstrap-Icons erstreckt sich bis y=16 (untere Kante des 16px-ViewBox); SVGs fuer `in` und `out` auf `viewBox="0 0 16 18"` umgestellt (2 Einheiten Puffer unten), sodass der Kreis bei gerenderten 18px auf y≈16px endet und nicht abgeschnitten wird; `background-position` fuer alle drei Icons auf `0 0` vereinheitlicht

## [Unreleased] 2026-06-29 (21)

### Fixed
- `assets/stylesheets/helpdesk_activity.css` — SVG-Data-URI auf Base64-Kodierung umgestellt (`data:image/svg+xml;base64,...`) fuer zuverlaessige Browser-Darstellung; `background-position: left center` und `padding-left: 22px !important` explizit gesetzt um Abschneiden des Icons zu verhindern

## [Unreleased] 2026-06-29 (20)

### Changed
- `assets/stylesheets/helpdesk_activity.css` — Eingehende Pfeil-Icons auf Gruen (`%232e7d32`) geaendert, ausgehende auf Rot (`%23c62828`); `background-size` fuer beide von 16px auf 18px erhoeht fuer bessere Sichtbarkeit

## [Unreleased] 2026-06-29 (19)

### Added
- `assets/stylesheets/helpdesk_activity.css` (neu) — CSS-Regeln fuer `.icon-helpdesk-message-in`, `.icon-helpdesk-message-out`, `.icon-helpdesk-message-init` mit inline-SVG als `background-image` Data-URI (Bootstrap Icons, MIT); Redmine 5.x rendert Aktivitaets-Feed-Icons via CSS-Klassen, nicht SVG-Sprites
- `lib/redmine_expert_helpdesk/hooks.rb` — `view_layouts_base_html_head`-Hook hinzugefuegt, der `helpdesk_activity.css` per `stylesheet_link_tag(..., :plugin => 'redmine_expert_helpdesk')` in den HTML-Head jeder Seite einbindet

## [Unreleased] 2026-06-29 (18)

### Fixed
- `app/models/helpdesk_message.rb` — `acts_as_event` rief ebenfalls standardmaessig `self.description` auf (fuer `event_description`); Fehler: `undefined method 'description'`; behoben durch `:description => Proc.new { nil }` im `acts_as_event`-Aufruf

## [Unreleased] 2026-06-29 (17)

### Fixed
- `app/models/helpdesk_message.rb` — `acts_as_event` rief standardmaessig `self.author` auf (fuer `event_author`), die Methode existiert in `HelpdeskMessage` aber nicht; Fehler: `undefined method 'author'`; behoben durch explizite Option `:author => Proc.new { nil }` im `acts_as_event`-Aufruf

## [Unreleased] 2026-06-29 (16)

### Fixed
- `init.rb` — `Redmine::Activity.register` warf `ArgumentError: Unknown key: :plugin` beim Start; `:plugin => :redmine_expert_helpdesk` entfernt, da Redmine 5.1.4 diesen Schluessel nicht kennt (gueltige Schluessel: `:class_name`, `:default`)

## [Unreleased] 2026-06-29 (15)

### Added
- `app/models/helpdesk_message.rb` — added `acts_as_event` (Ereignisdarstellung im Aktivitaets-Feed: Titel `[#id] Betreff`, Zeitstempel `sent_at || created_at`, Verlinkung auf das Ticket, Typ `helpdesk-message-{in|out|init}`, Gruppierung nach Issue) und `acts_as_activity_provider` (Typ `helpdesk_messages`, Timestamp `created_at`, Permission `view_helpdesk_info`, Scope mit JOIN auf Issue und Project); `scope :visible` fuer allgemeine Modellabfragen; `def project` als Hilfsmethode fuer `acts_as_event`
- `init.rb` — `Redmine::Activity.register :helpdesk_messages` mit `:class_name => 'HelpdeskMessage'`, `:default => true` und `:plugin => :redmine_expert_helpdesk`; registriert eingehende, ausgehende und initiale Helpdesk-Nachrichten als eigenen Aktivitaets-Typ im Feed
- `assets/icons.svg` (neu) — SVG-Sprite mit drei Symbolen: `icon--helpdesk-message-in` (Briefumschlag mit Pfeil nach unten, eingehend), `icon--helpdesk-message-out` (Briefumschlag mit Pfeil nach oben, ausgehend), `icon--helpdesk-message-init` (geoffneter Briefumschlag, Erstkontakt); basiert auf Bootstrap Icons v1.11 (MIT); wird von `sprite_icon(..., plugin: 'redmine_expert_helpdesk')` geladen
- `config/locales/de.yml`, `config/locales/en.yml` — Schluessel `label_helpdesk_message_plural` hinzugefuegt ("Helpdesk-Nachrichten" / "Helpdesk Messages"); wird in der Aktivitaets-Seitenleiste als Checkbox-Label angezeigt

### Ergebnis
- Im Redmine-Aktivitaets-Feed erscheinen Helpdesk-Nachrichten als eigene Kategorie mit drei verschiedenen Icons je nach Richtung (eingehend = Pfeil runter, ausgehend = Pfeil hoch, Erstkontakt = offener Umschlag); die Kategorie kann in der Seitenleiste ein-/ausgeblendet werden; sichtbar fuer Nutzer mit `view_helpdesk_info`-Berechtigung in Projekten mit aktiviertem Helpdesk-Modul

## [Unreleased] 2026-06-29 (14)

### Changed
- `app/models/helpdesk_mailbox.rb` — added `after_initialize :set_defaults, if: :new_record?`; pre-fills `autoresponder_subject` (`[#{{ticket_id}}] {{ticket_subject}}`), `autoresponder_body` (German confirmation template with ticket number, subject and project name), and `reply_footer` (`--\n{{project_name}}`) for new mailboxes only; existing records are not affected

## [Unreleased] 2026-06-29 (13)

### Added
- `app/views/helpdesk/_macro_chips.html.erb` (new partial) — renders a row of clickable macro chips for any input/textarea; clicking a chip inserts the macro text at the current cursor position; CSS + click handler JS are injected once into the page `<head>` via `content_for :header_tags` (guarded by `@hd_macro_chips_assets_loaded` to avoid duplicates)
- `config/locales/de.yml`, `config/locales/en.yml` — added `label_helpdesk_macros` key ("Makros" / "Macros") used as chip-bar label

### Changed
- `app/views/helpdesk_mailboxes/_form.html.erb` — replaced static `<em class="info">` macro hint on `autoresponder_body` and `reply_footer` with `_macro_chips` partial; added `_macro_chips` partial to `autoresponder_subject` and `reply_header` fields (previously had no macro hint at all)
- `app/views/projects/settings/_helpdesk.html.erb` — added `_macro_chips` partial after the `reply_subject_template` text field

## [Unreleased] 2026-06-29 (12)

### Changed
- `README.md` — added **Running the Tests** section: prerequisites (`db:create`, `db:migrate`, `redmine:plugins:migrate`), full-suite rake command, single-file and multi-file ruby invocations, guidance on when to run tests, and a `docker-compose.test.yml` example for the no-`docker-exec` container workflow
- `README.de.md` — same section added in German; also fixed truncated trailing bullet point in the *Hinweise* section

## [Unreleased] 2026-06-29 (11)

### Changed
- `test/unit/helpdesk_rule_test.rb` — expanded: added `test_equals_on_subject_case_insensitive`, `test_sender_contains`, `test_unknown_operator_returns_false`; validation tests for `condition_field`, `operator`, `action_type`, `action_value`, `condition_value`; `apply_to` tests for all six branches (`set_priority`, `set_tracker`, `set_category`, `set_assignee`, `ignore`, not-found cases) using Mocha stubs; defined `IssueStub` Struct to avoid DB for apply_to tests
- `test/unit/mail_processor_filter_test.rb` — replaced bare `Object.new` graph stub with typed `NullGraph` null-object class; added MIME constants (`AUTO_REPLY_MIME`, `AUTO_REPLY_WITH_MONITORING_MIME`, `NDR_MIME`); added five new tests for `auto_reply_filtered?`: disabled-by-default, filters auto-reply, NDR passthrough, sender-whitelist bypass, header-whitelist bypass; `processor_for` accepts optional extra mailbox attrs
- `test/unit/template_renderer_test.rb` — added `test_renders_issue_dot_notation`, `test_renders_contact_object`, `test_renders_user_object` (all using Mocha mocks); `test_issue_url_uses_setting` (stubs `Setting.host_name`/`protocol`); `test_legacy_and_dot_notation_are_equivalent` (asserts both notations produce identical output)

### Added
- `test/unit/helpdesk_message_test.rb` (new) — tests `DIRECTIONS` constant membership and size; direction inclusion validation; issue presence validation; `incoming` and `outgoing` scopes (with `fixtures :all` and real DB records)
- `test/unit/helpdesk_contact_test.rb` (new) — tests `display_name` fallback logic; `find_or_create_for` creates/reuses contacts, normalises email to lowercase, fills in blank name without overwriting existing name, scopes contacts by project
- `test/unit/helpdesk_project_setting_test.rb` (new) — tests `DEFAULT_SUBJECT_TEMPLATE` constant value; `effective_subject_template` returns default for nil/blank/whitespace-only input, returns custom template otherwise

## [Unreleased] 2026-06-30 (10)

### Changed
- Hook `view_issues_sidebar_queries_bottom` (Datei: `lib/redmine_expert_helpdesk/hooks.rb`): Zeigt jetzt das "Kunde zuordnen"-Formular (`_init_section`) in der Seitenleiste an, wenn noch kein Kontakt zugeordnet ist (statt in der Ticket-Bearbeitungsform). Erfordert `send_helpdesk_reply`-Berechtigung und mind. ein aktives Postfach.
- Hook `view_issues_edit_notes_bottom` (Datei: `lib/redmine_expert_helpdesk/hooks.rb`): Gibt jetzt `''` zurueck wenn kein Kontakt vorhanden ist (frueheres Zuordnungsformular wurde in die Seitenleiste verschoben).


### Fixed
- Partial `helpdesk/_init_section.html.erb`: Redmines `.tabular label { float:left; width:180px; text-align:right }` hat den Checkbox-Label des Init-Formulars im neuen Ticket-Formular zu einem schmalen Float-Streifen am linken Rand gemacht. Fix: Eigene `<style>`-Sektion mit `#hd-init-section label { float:none !important; ... }` und `clear:both` am Container. Ersetzt das `<label>`-Element durch strukturierte `<div>`-Elemente.
- Partial `helpdesk/_init_section.html.erb`: Alle benoetigten CSS-Klassen (`.hd-init-input`, `.hd-init-row` etc.) sind jetzt selbst in der Partial definiert und haengen nicht mehr von `_reply_in_edit.html.erb` ab, das auf der Neues-Ticket-Seite nicht geladen wird.
- Partial `helpdesk/_reply_in_edit.html.erb`: Fehlender CSS-Selektor `#hd-reply-section` vor den Hintergrundstil-Deklarationen ergaenzt (war zuvor ein ungültiger Block ohne Selektor).

### Changed
- Partial `helpdesk/_init_section.html.erb` – UX-Neugestaltung fuer bestehende Tickets (`in_new_form: false`): E-Mail- und Namensfeld sind jetzt **immer sichtbar** (nicht mehr hinter der Checkbox versteckt). Nutzer kann Kontakt zuordnen ohne eine Mail zu senden. Checkbox "Als E-Mail an Kunden senden" blendet nur noch das optionale Nachrichten-Textarea ein/aus.
- Hook `controller_issues_new_after_save` (Datei: `lib/redmine_expert_helpdesk/hooks.rb`): Verknuepft jetzt auch ohne `send_mail=1` einen Kontakt, wenn eine E-Mail-Adresse angegeben wurde. `send_mail` wird als Boolean an `InitMailer` weitergegeben.
- Neue Uebersetzungsschluessel: `label_helpdesk_assign_kunde` (de: "Kunde zuordnen", en: "Assign Customer").


### Added
- Neuer Service `RedmineExpertHelpdesk::InitMailer` (Datei: `lib/redmine_expert_helpdesk/init_mailer.rb`) – kapselt das Erstellen eines Kundenkontakts und das optionale Versenden einer initialen Mail. Unterstützt beide Transportwege (SMTP und Graph-API/MIME). Wird von `HelpdeskInitController` und dem `controller_issues_new_after_save`-Hook verwendet.
- Neuer Controller `HelpdeskInitController` (Datei: `app/controllers/helpdesk_init_controller.rb`) – verarbeitet `POST /projects/:project_id/issues/:issue_id/helpdesk_init`. Verknüpft einen Kundenkontakt mit einem bestehenden Ticket und sendet optional eine initiale Mail. Erfordert die Berechtigung `send_helpdesk_reply`.
- Neues Partial `helpdesk/_init_section.html.erb` – zeigt ein Kontaktzuordnungs- und Initialmail-Formular. Wird sowohl im Ticket-Erstellungsformular (innerhalb des Hauptformulars, `in_new_form: true`) als auch im Ticket-Bearbeitungsformular für Tickets ohne Kundenkontakt (eigenes `<form>`-Tag, `in_new_form: false`) verwendet. Enthält Single-Value-Autocomplete für das E-Mail-Feld mit automatischer Befüllung des Namensfeldes. Mailbox-Auswahl wird bei mehreren Postfächern eingeblendet. Für bestehende Tickets: optionales Nachrichtentext-Textarea (sonst: Ticket-Beschreibung).
- Neuer Hook `view_issues_form_details_bottom` in `hooks.rb` – injiziert das `_init_section`-Partial in das Ticket-Erstellungsformular, wenn das Projekt ein aktives Postfach hat und der Nutzer `send_helpdesk_reply`-Berechtigung besitzt. Nur für neue Tickets (`issue.new_record?`).
- Neuer Hook `controller_issues_new_after_save` in `hooks.rb` – sendet nach erfolgreichem Anlegen eines Tickets eine initiale Mail, wenn `helpdesk_init[send_mail]=1` als Formularparameter übergeben wurde. Fehler werden geloggt, brechen die Ticket-Erstellung aber nicht ab.
- Neuer Hook `view_issues_index_bottom` in `hooks.rb` – fügt per JavaScript einen Button „Neues Helpdesk-Ticket" in den Kontextbereich der Ticket-Liste (neben „Neues Ticket") ein. Verlinkt auf das Ticket-Erstellungsformular mit `?helpdesk_init=1`.
- Neue Route `POST /projects/:project_id/issues/:issue_id/helpdesk_init` als `issue_helpdesk_init_path` (Datei: `config/routes.rb`).
- `helpdesk_init => [:create]` zur Berechtigung `send_helpdesk_reply` hinzugefügt (Datei: `init.rb`).
- `require_relative` für `init_mailer` in `init.rb` ergänzt.
- Neue Übersetzungsschlüssel (de.yml / en.yml): `label_helpdesk_send_initial_mail`, `label_helpdesk_contact_name_optional`, `label_helpdesk_initial_mail_body`, `label_helpdesk_initial_mail_body_hint`, `text_helpdesk_init_uses_description`, `button_helpdesk_assign_contact`, `button_helpdesk_new_ticket`, `notice_helpdesk_init_mail_sent`, `notice_helpdesk_contact_assigned`, `error_helpdesk_invalid_email`, `error_helpdesk_no_mailbox`.

### Changed
- Hook `view_issues_show_details_bottom` (Datei: `lib/redmine_expert_helpdesk/hooks.rb`): Kontaktsuche verwendet jetzt **alle** HelpdeskMessages (nicht mehr nur `direction='in'`). `inbound` wird als `nil` übergeben, wenn das erste Ticket nicht eingehend war – zeigt dann Kontaktname/-mail ohne EML-Link.
- Hook `view_issues_sidebar_queries_bottom` (Datei: `lib/redmine_expert_helpdesk/hooks.rb`): Kontaktsuche verwendet jetzt alle HelpdeskMessages statt nur `HelpdeskMessage.incoming`. Die Seitenleiste wird jetzt auch für manuell zugeordnete Kontakte angezeigt.
- Hook `view_issues_edit_notes_bottom` (Datei: `lib/redmine_expert_helpdesk/hooks.rb`): Wenn kein Kontakt verknüpft ist, wird das `_init_section`-Partial angezeigt statt einfach leerzurückgeben. Kontaktsuche ebenfalls auf alle Messages erweitert. Mailbox-Fallback auf `first_msg.helpdesk_mailbox` statt `inbound_msg.helpdesk_mailbox`.
- Partial `helpdesk/_issue_header_bar.html.erb`: Zugriffe auf `inbound.recipient_to`, `inbound.recipient_cc`, `inbound.eml_attachment_id` und `inbound.sent_at` sind jetzt nil-sicher (`inbound&.`), damit kein Crash auftritt wenn `inbound` nil ist (manuell zugeordneter Kontakt).
- `direction='init'` als neuer Wert für `helpdesk_messages.direction` – wird gesetzt wenn ein Kontakt ohne Mailversand manuell zugeordnet wird. Keine DB-Migration nötig (String-Spalte ohne ENUM).


### Added
- Message-ID wird für alle ausgehenden Antworten generiert und in `helpdesk_messages.message_id` gespeichert. Format: `<uuid@domain>` (Domain aus der Absenderadresse des Postfachs). Gilt für beide Transportwege: Graph-API-MIME (Message-ID in MIME-Header) und SMTP (über `mail_obj.message_id`). Ermöglicht zuverlässige Zuordnung von Kundenantworten via `In-Reply-To`. (Datei: `app/controllers/helpdesk_replies_controller.rb`)
- Neue private Hilfsmethode `generate_message_id(from_address)` im `HelpdeskRepliesController`. (Datei: `app/controllers/helpdesk_replies_controller.rb`)


### Fixed
- Autocomplete: Display-Namen mit Komma (z. B. "Flak, Krystian") werden jetzt RFC 2822-konform gequotet (`"Flak, Krystian" <email>`), damit der MIME-Parser sie nicht als Trennzeichen interpretiert. (Datei: `app/controllers/helpdesk_contacts_controller.rb`)
- Beim Absenden werden nachgestellte Kommas in den Adressfeldern (An/CC/BCC) entfernt — sowohl im JavaScript (Client) als auch im Controller (Server). Verhindert "Invalid address"-Fehler (501 5.1.3) durch leere Empfänger nach dem letzten Komma. (Datei: `app/views/helpdesk/_reply_in_edit.html.erb`, `app/controllers/helpdesk_replies_controller.rb`)


### Added
- Kontakt-Autocomplete in den Adressfeldern (An / CC / BCC) des Antwortformulars: Beim Tippen (ab 2 Zeichen) werden passende Kontakte des Projekts per Dropdown vorgeschlagen. Unterstützt kommagetrennte Mehrfacheingabe; Auswahl per Maus, Pfeiltasten oder Enter/Tab. Ergebnisse werden gecacht. (Datei: `app/views/helpdesk/_reply_in_edit.html.erb`)
- Neuer API-Endpunkt `GET /projects/:project_id/helpdesk_contacts/autocomplete?q=...` sucht Kontakte nach Name und E-Mail (Teilstring, case-insensitive, max. 10 Ergebnisse). Gibt JSON-Array zurück. (Datei: `app/controllers/helpdesk_contacts_controller.rb`, `config/routes.rb`)
- Berechtigung `send_helpdesk_reply` und `manage_helpdesk_contacts` um Aktion `autocomplete` erweitert. (Datei: `init.rb`)


### Added
- Paginierung der Kundenliste (`index`-Aktion): Kontakte werden seitenweise geladen statt alle auf einmal. Pro-Seite-Switcher (10 / 25 / 50 / 100) über der Tabelle; aktive Auswahl wird fett hervorgehoben. Seitennavigation via `Redmine::Pagination::Paginator` + `pagination_links_full`. (Datei: `app/controllers/helpdesk_contacts_controller.rb`, `app/views/helpdesk_contacts/index.html.erb`)
- Ticket-Limit in der Kundendetailansicht (`edit`-Aktion): Zeigt nur noch die letzten N Tickets. Wenn weitere Tickets existieren, erscheint ein Hinweistext "Zeigt die N neuesten von X Tickets". (Datei: `app/controllers/helpdesk_contacts_controller.rb`, `app/views/helpdesk_contacts/edit.html.erb`)
- Neue Plugin-Einstellungen `contacts_per_page` (Standard: 25) und `contact_ticket_limit` (Standard: 10) im Bereich „Anzeigeeinstellungen" der Plugin-Konfiguration. (Datei: `init.rb`, `app/views/settings/_helpdesk_settings.html.erb`)
- Neue Übersetzungsstrings für Anzeigeeinstellungen in `de.yml` und `en.yml`: `label_helpdesk_display_settings`, `label_helpdesk_contacts_per_page`, `text_helpdesk_contacts_per_page_info`, `label_helpdesk_contact_ticket_limit`, `text_helpdesk_contact_ticket_limit_info`, `label_helpdesk_showing_latest_n`.


- **Kritischer Bug: falscher Token-Wert an Controller übergeben** (file: `app/views/helpdesk/_reply_in_edit.html.erb`) — Das JS sendete den **Zähler** (z. B. `"1"`, `"2"`) aus dem Input-`name`-Attribut (`attachments[1][token]`), nicht den echten Token-String (`"ID.DIGEST"`) aus dem Input-`value`. `Attachment.find_by_token("1")` liefert immer `nil`, weil der Digest-Teil fehlt. Fix: Selektor auf `[name$="][token]"]` eingeschränkt (nur Token-Inputs) und `inp.value` statt `m[1]` verwendet.

### Changed
- **Graph-API-Versand auf MIME-Endpunkt umgestellt** (files: `app/controllers/helpdesk_replies_controller.rb`, `lib/redmine_expert_helpdesk/graph_client.rb`) — Der JSON-basierte `sendMail`-Aufruf wurde für den Graph-Pfad vollständig durch den MIME-Endpunkt ersetzt (`Content-Type: text/plain`, Body = Base64-kodierte RFC-2822-MIME-Nachricht). Hintergrund: Exchange Online schreibt den HTML-Body bei JSON-Requests um und entkoppelt dabei CID-Referenzen (`cid:...`) von den `isInline`-Anhängen, sodass Inline-Bilder in Outlook immer kaputt erscheinen. Mit dem MIME-Endpunkt bleibt die gesamte MIME-Struktur erhalten. Data-URI-Ansatz verworfen, da Outlook Desktop (Word-Rendering-Engine) Data-URIs nicht rendert.
- **`build_cid_mime` eingeführt** (file: `app/controllers/helpdesk_replies_controller.rb`) — Baut eine vollständige RFC-2822-MIME-Nachricht mit korrekter `multipart/related`-Struktur (HTML-Teil + Inline-Bild-CID-Parts) und optional `multipart/mixed` für reguläre Datei-Anhänge. Zeilenenden: CRLF. Base64-Kodierung mit 76-Zeichen-Zeilenumbruch (RFC 2045).
- **`build_cid_map` eingeführt** (file: `app/controllers/helpdesk_replies_controller.rb`) — Ersetzt `src="filename"` im HTML durch `cid:img{id}x{i}@helpdesk.local` und gibt die CID-Map zurück. Nur Bilder mit Regex-Match werden eingebettet.
- **`mime_encode_subject` und `mime_base64` eingeführt** (file: `app/controllers/helpdesk_replies_controller.rb`) — RFC-2047-Kodierung des Betreffs für Nicht-ASCII-Zeichen; binärsichere Base64-Kodierung für MIME-Parts.
- **`send_mail_mime` in GraphClient eingeführt** (file: `lib/redmine_expert_helpdesk/graph_client.rb`) — Führt einen direkten `Net::HTTP`-POST an `/users/{mailbox}/sendMail` mit `Content-Type: text/plain` und Base64-kodiertem MIME-Inhalt durch.
- **`embed_inline_images` behalten** (file: `app/controllers/helpdesk_replies_controller.rb`) — Weiterhin für SMTP-Pfad zuständig (Data-URI-Einbettung + reguläre Datei-Anhänge).

### Changed
- **Inline-Bild-Einbettung: CID durch Base64-Data-URI ersetzt** (file: `app/controllers/helpdesk_replies_controller.rb`) — Der bisherige CID-Ansatz (`isInline: true` + `contentId` im Graph-API-JSON) wurde aufgegeben, da Outlook die CID-Referenzen nicht korrekt auflöste (Bilder wurden als kaputt angezeigt). Neuer Ansatz: `embed_inline_images` liest die Bilddatei ein, erzeugt einen `data:MIME;base64,...`-URI und ersetzt das `src`-Attribut im HTML-Body direkt. Das Bild erscheint dadurch an der richtigen Stelle im Mailtext (wo es eingefügt wurde). Zusätzlich wird dasselbe Bild als regulärer `fileAttachment` mitgeschickt (Fallback für Mail-Clients, die Data-URIs blockieren).
- **`build_inline_cids` entfernt, `embed_inline_images` eingeführt** (file: `app/controllers/helpdesk_replies_controller.rb`) — Umbenennung und vollständiger Rewrite der Hilfsmethode. Rückgabe: `[processed_html, [embedded_attachment_objects]]`. Nur Bilder, deren Dateiname im `src`-Attribut gefunden wird (Regex-Match), werden eingebettet und als Anhang gesendet.
- **`send_reply_smtp` vereinfacht** (file: `app/controllers/helpdesk_replies_controller.rb`) — `cid_pairs`-Parameter entfernt, stattdessen `embedded_atts`-Array. Kein multipart/related mehr für CID-Parts. HTML-Body enthält Data-URIs; alle Anhänge (reguläre + eingebettete Bilder) werden als normale Datei-Anhänge gesendet.

## [Unreleased] 2026-06-25

### Added
- **Antworten-Button im Ticket-Kopf** (files: `app/views/helpdesk/_issue_header_bar.html.erb`, `config/locales/de.yml`, `config/locales/en.yml`) — Grüner „Antworten"-Link (Icon `icon-email`) wird per JS in das `.contextual`-Div des Issue-Show-Seite injiziert. Beim Klick bleibt die Seite erhalten (`showAndScrollTo('update','hd-send-mail-cb')`), das Inline-Bearbeitungsformular wird geöffnet, die Checkbox „Als E-Mail an Kunden senden" automatisch aktiviert und die Empfängerfelder sichtbar geschaltet. Selektor auf `#content > div.contextual` eingegrenzt, um die Sidebar-`.contextual` (Beobachter-Hinzufügen) zu vermeiden.
- **Eingefügte / per Drag-Drop hochgeladene Bilder im Antwort-E-Mail** (files: `app/views/helpdesk/_reply_in_edit.html.erb`, `app/controllers/helpdesk_replies_controller.rb`) — JS sammelt alle pending-Attachment-Tokens (`attachments[TOKEN][filename]`-Hidden-Inputs im Formular) und übergibt sie als `inline_attachment_tokens[]` an den Controller. Der Controller sucht die zugehörigen `Attachment`-Records per `Attachment.find_by_token(token)` (Redmine-6-Token-Format: `"id.digest"`, kein eigenes Datenbankfeld) und filtert nach `author_id == User.current.id`. Die gefundenen Attachments werden sowohl beim Graph-API- als auch beim SMTP-Versand an die E-Mail angehängt.

### Fixed
- **Empfängerfelder nicht sichtbar bei Auto-Aktivierung** (file: `app/views/helpdesk/_reply_in_edit.html.erb`) — Das `dispatchEvent('change')` wurde vor der Registrierung des `change`-Listeners aufgerufen, daher blieb `#hd-mail-extra` unsichtbar. Gefixt durch direktes Setzen von `extra.style.display = ''` in der Auto-Aktivierungslogik statt via Event-Dispatch.
- **Falscher `.jstBlock`-Selektor** (file: `app/views/helpdesk/_reply_in_edit.html.erb`) — `document.querySelector('.jstBlock')` traf die Beschreibungs-Textarea (im `display:none`-Container), nicht den Kommentar-Editor. Korrigiert zu `document.querySelector('#add_notes .jstBlock')`.


### Added
- **Status und Bearbeiter nach Antwort automatisch setzen** (files: `db/migrate/015_add_reply_actions_to_helpdesk_project_settings.rb`, `app/models/helpdesk_project_setting.rb`, `app/controllers/helpdesk_project_settings_controller.rb`, `app/views/projects/settings/_helpdesk.html.erb`, `lib/redmine_expert_helpdesk/hooks.rb`, `app/views/helpdesk/_reply_in_edit.html.erb`, `config/locales/de.yml`, `config/locales/en.yml`) — Neue Spalten `reply_status_id` (integer, FK auf `issue_statuses`) und `reply_assign_to_sender` (boolean, default false) in `helpdesk_project_settings`. Im Projekteinstellungs-Tab zwei neue Felder: Dropdown „Status nach Antwort" und Checkbox „Ticket nach Antwort mir zuweisen". Nach erfolgreichem Mail-Versand setzt das JS im Antwortformular das Status-Select (`issue[status_id]`) und/oder das Bearbeiter-Select (`issue[assigned_to_id]`) auf die konfigurierten Werte, bevor `issueForm.submit()` aufgerufen wird. Die Änderungen landen damit im selben Journal-Eintrag wie die Notiz.

## [Unreleased] 2026-06-24 (3)

### Added
- **Versandweg je Postfach konfigurierbar (Graph API oder SMTP)** (files: `db/migrate/014_add_reply_transport_to_helpdesk_mailboxes.rb`, `app/models/helpdesk_mailbox.rb`, `app/controllers/helpdesk_replies_controller.rb`, `app/views/helpdesk_mailboxes/_form.html.erb`, `config/locales/de.yml`, `config/locales/en.yml`) — Neue Spalte `reply_transport` (string, default `'graph'`) in `helpdesk_mailboxes`. Im Formular (Fieldset „Antwortvorlagen") neues Dropdown „Versandweg": „Microsoft Graph API (Exchange)" oder „SMTP (Redmine-Standard)". Der Reply-Controller verzweigt nach `mailbox.reply_transport`: bei `smtp` wird `send_reply_smtp` aufgerufen, das eine `Mail`-Instanz baut und über `ActionMailer::Base.delivery_method`/`smtp_settings` zustellt; bei `graph` (Standard) wie bisher über `GraphClient#send_mail`. Anhänge werden für SMTP via `mail_obj.add_file` als MIME-Parts gehängt; für Graph API weiterhin als base64-`fileAttachment`. Fehler beider Pfade werden als `{ success: false, error: ... }` an den Client zurückgegeben.

## [Unreleased] 2026-06-24 (2)

### Fixed
- **NDR-Mails wurden fälschlicherweise als Auto-Reply gefiltert** (file: `lib/redmine_expert_helpdesk/mail_processor.rb`) — `auto_reply_headers_present?` hat Exchange-NDRs (Unzustellbarkeitsbenachrichtigungen) bisher als Auto-Replies eingestuft, weil sie `Auto-Submitted: auto-generated` und `X-MS-Exchange-Generated-Message-Source` enthalten. Zwei Korrekturen: (1) Neue frühe Rückgabe `false` wenn `X-MS-Exchange-Message-Is-NDR: True` gesetzt ist. (2) `X-MS-Exchange-Generated-Message-Source` wird jetzt nur noch als Auto-Reply-Indikator gewertet, wenn der Wert **nicht** `NonDeliveryReport` ist — damit werden NDRs nie als Auto-Reply eingestuft, OOO-Antworten und andere Exchange-generierte Nachrichten jedoch weiterhin gefiltert.

## [Unreleased] 2026-06-24

### Added
- **Zielordner automatisch anlegen beim Speichern** (files: `lib/redmine_expert_helpdesk/graph_client.rb`, `app/controllers/helpdesk_mailboxes_controller.rb`, `config/locales/de.yml`, `config/locales/en.yml`) — Nach dem Speichern einer Postfach-Konfiguration (create/update) werden die konfigurierten Zielordner (`processed_folder`, `skipped_folder`, `failed_folder`) im Exchange-Postfach automatisch angelegt, falls sie noch nicht existieren. Neue Methode `find_or_create_folder(mailbox, folder_name)` in `GraphClient`: versucht zunächst `resolve_folder_id`; bei `GraphError` (Ordner nicht gefunden) wird `create_folder` aufgerufen und der Folder-Cache geleert. Im Controller neue private Methode `ensure_mailbox_folders` ruft dies für alle drei Zielordner auf; Fehler werden als `flash[:warning]` angezeigt, ohne den Speichervorgang zu blockieren.

### Fixed
- **`sprite_icon` in Plugin-Views** (file: `app/views/helpdesk_mailboxes/_form.html.erb`) — `sprite_icon('reload', 'Ordner laden')` wurde durch `<span class="icon icon-reload">Ordner laden</span>` ersetzt, da `sprite_icon` in Plugin-Controller-Views nicht verfügbar ist.

## [Unreleased] 2026-06-23 (6)

### Added
- **Migration 013** (file: `db/migrate/013_add_sent_attachments_to_helpdesk_messages.rb`) — Neue Spalte `sent_attachments` (text, nullable) in `helpdesk_messages` zur Speicherung der komma-getrennten Dateinamen versendeter Anhänge.

### Changed
- **Journal-Badge: Korrektes E-Mail-Icon** (files: `app/views/helpdesk/_issue_panel.html.erb`, `app/views/helpdesk/_issue_sidebar.html.erb`) — `buildBadge()` verwendet jetzt `<span class="icon icon-email">` (Redmine CSS-Klassen-Icon) statt `\u2709` (Unicode-Zeichen). Separater `<span class="hd-recipient">` für den Adresstext. Neues CSS `.helpdesk-mail-header .icon` setzt `width: 16px; height: 16px; padding: 0` damit das Icon korrekt in der Flex-Zeile dargestellt wird.
- **Journal-Badge: Anhänge anzeigen** (files: `app/views/helpdesk/_issue_panel.html.erb`, `app/views/helpdesk/_issue_sidebar.html.erb`, `app/controllers/helpdesk_replies_controller.rb`) — `buildBadge()` erhält neuen Parameter `attachments`. `hdMessages`-JSON enthält jetzt `attachments`-Feld aus `sent_attachments`. Bei versendeten Anhängen wird `<span class="icon icon-attachment">` plus ein Badge mit Dateiname (oder „N Anhänge" bei mehreren) angezeigt.
- **Controller: Dateinamen bei Anhang-Versand speichern** (file: `app/controllers/helpdesk_replies_controller.rb`) — `sent_filenames`-Array wird während der Attachment-Verarbeitung befüllt und als komma-getrennte Zeichenkette in `HelpdeskMessage.sent_attachments` gespeichert.

## [Unreleased] 2026-06-23 (5)

### Added
- **Anhänge an Kundenantwort anhängen** (files: `app/views/helpdesk/_reply_in_edit.html.erb`, `app/controllers/helpdesk_replies_controller.rb`, `config/locales/de.yml`, `config/locales/en.yml`) — Im Antwortformular werden alle bestehenden Ticket-Anhänge als Checkboxliste (mit Dateiname und Größe) angezeigt, sofern das Ticket Anhänge hat. Aktivierte Anhänge werden per `attachment_ids[]` an den Controller übermittelt. Der Controller prüft, dass die IDs tatsächlich zum Ticket gehören (Sicherheits-Whitelist via `@issue.attachments.pluck(:id)`), liest die Dateien binär ein, kodiert sie als Base64 und hängt sie als `#microsoft.graph.fileAttachment`-Objekte an die Graph-API-Nachricht. Neue Locale-Schlüssel: `label_helpdesk_reply_attachments`.

## [Unreleased] 2026-06-23 (4)

### Added
- **Empfänger-Tooltip am E-Mail-Icon der Info-Leiste** (files: `lib/redmine_expert_helpdesk/mail_processor.rb`, `app/views/helpdesk/_issue_header_bar.html.erb`) — Beim Verarbeiten eingehender Mails werden die `To`- und `CC`-Header der MIME-Nachricht geparst (`Mail.read_from_string(mime)`) und in den Spalten `recipient_to` / `recipient_cc` der `HelpdeskMessage` gespeichert. Das E-Mail-Icon in der Helpdesk-Info-Leiste zeigt bei Hover einen Browser-Tooltip mit „An: …" und „CC: …" (sofern vorhanden). Bestehende Nachrichten ohne gespeicherte Empfänger zeigen keinen Tooltip.

## [Unreleased] 2026-06-23 (3)

### Added
- **Helpdesk-Info-Leiste am Ticket-Kopf** (files: `app/overrides/issues_show_helpdesk_header.rb`, `app/views/helpdesk/_issue_header_bar.html.erb`) — Via Deface-Override wird direkt unterhalb der Autorenzeile (`<p class="author">`) eine schmale Info-Leiste eingeblendet, die Absender (Name + E-Mail), EML-Download-Link (mit Dateigröße) und Empfangszeitstempel der ersten eingehenden Helpdesk-Mail zeigt. Sichtbar nur wenn Helpdesk-Modul aktiv und Berechtigung `view_helpdesk_info` vorhanden. Nur auf der Ticket-Detailseite (Deface `virtual_path: issues/show`).

### Changed
- **Aktionswert-Feld in Automatisierungsregeln** (file: `app/views/helpdesk_mailboxes/edit.html.erb`) — Das freie Textfeld für den Aktionswert ist jetzt ein dynamisches Dropdown, das sich je nach gewähltem Aktionstyp anpasst. Optionen werden serverseitig als JSON in ein `data-action-options`-Attribut eingebettet und via Plain-JS beim `change`-Event des Aktionstyp-Selects aufgebaut: `set_priority` → aktive Prioritäten (Name), `set_tracker` → Tracker des Projekts (Name), `set_category` → Kategorien des Projekts (Name), `set_assignee` → Projektmitglieder (Anzeigename → Login als Wert), `ignore` → kein Wertfeld. In der Regelliste wird bei `set_assignee` der vollständige Name des Benutzers statt des Logins angezeigt.

### Added
- **Ticket-Wiederöffnung bei eingehender Antwort** (file: `lib/redmine_expert_helpdesk/mail_processor.rb`) — Neue Methode `reopen_if_closed(issue)`: Wenn eine Antwort einem geschlossenen Ticket zugeordnet wird und `reopen_status_id` am Postfach konfiguriert ist, wird das Ticket auf diesen Status gesetzt (`issue.save(:validate => false)`). Wird nur bei Antworten aufgerufen (nicht bei neuen Tickets).
- **Neues Ticket bei zu alten geschlossenen Tickets** (file: `lib/redmine_expert_helpdesk/mail_processor.rb`) — Neue Methoden `maybe_strip_thread_for_new_issue(mime)` und `find_referenced_issue(msg)`: Ist `reopen_max_age_days` konfiguriert und das referenzierte Ticket älter als dieses Limit (gemessen an `updated_on`), werden `In-Reply-To`-, `References`-Header und das `[#ID]`-Muster im Betreff aus der MIME-Nachricht entfernt, bevor sie an den Redmine `MailHandler` übergeben wird. Dieser legt daraufhin ein neues Ticket an. Ticket-Referenz wird zuerst über `[#ID]` im Betreff gesucht, als Fallback über `HelpdeskMessage.message_id` aus `In-Reply-To`/`References`.
- **Migration 012** (file: `db/migrate/012_add_reopen_settings_to_helpdesk_mailboxes.rb`) — Neue Spalten `reopen_status_id` (integer, FK auf `issue_statuses`) und `reopen_max_age_days` (integer, nullable) in `helpdesk_mailboxes`.
- **Postfach-Formular** (file: `app/views/helpdesk_mailboxes/_form.html.erb`) — Neues Fieldset „Ticket-Wiederöffnung" mit Dropdown für den Wiederöffnungs-Status und Zahlenfeld für das maximale Alter in Tagen.
- **Model** (file: `app/models/helpdesk_mailbox.rb`) — `belongs_to :reopen_status, :class_name => 'IssueStatus'`; `safe_attributes` um `reopen_status_id` und `reopen_max_age_days` ergänzt.
- **Lokalisierung** (files: `config/locales/de.yml`, `config/locales/en.yml`) — Neue Schlüssel: `label_helpdesk_reopen`, `field_helpdesk_reopen_status`, `text_helpdesk_reopen_status_info`, `field_helpdesk_reopen_max_age_days`, `text_helpdesk_reopen_max_age_days_info`.

### Added
- **Separate Zielordner für übersprungene und fehlgeschlagene Mails** (file: `lib/redmine_expert_helpdesk/mail_processor.rb`) — Neue Methoden `move_skipped` und `move_failed`. Übersprungene Mails (Blacklist-/Ignorier-Regel-Treffer, Auto-Reply-Filter, MailHandler-Ablehnung) werden jetzt in den konfigurierbaren `skipped_folder` verschoben; Mails, bei deren Verarbeitung eine Exception aufgetreten ist, in den `failed_folder`. Beide Ordner fallen auf `processed_folder` zurück, wenn sie leer sind. Fehler-Exception in `process_all` ruft nun `move_failed` auf, so dass keine Mails unverarbeitet im Quellordner verbleiben.
- **Migration 011** (file: `db/migrate/011_add_skipped_and_failed_folder_to_helpdesk_mailboxes.rb`) — Neue Spalten `skipped_folder` (string) und `failed_folder` (string) in `helpdesk_mailboxes`. Bestehende Postfächer nutzen automatisch `processed_folder` als Fallback.
- **Postfach-Formular** (file: `app/views/helpdesk_mailboxes/_form.html.erb`) — Neue Eingabefelder „Zielordner (übersprungen)" und „Zielordner (Fehler)" direkt nach dem bestehenden Zielordner-Feld; beide Felder nutzen die vorhandene Ordner-Datalist mit Autocomplete.
- **Lokalisierung** (files: `config/locales/de.yml`, `config/locales/en.yml`) — Neue Schlüssel: `field_helpdesk_skipped_folder`, `text_helpdesk_skipped_folder_info`, `field_helpdesk_failed_folder`, `text_helpdesk_failed_folder_info`.
- **Model** (file: `app/models/helpdesk_mailbox.rb`) — `safe_attributes` um `skipped_folder` und `failed_folder` ergänzt.

### Added
- **Auto-Reply-Filter** (file: `lib/redmine_expert_helpdesk/mail_processor.rb`) — Neue Methode `auto_reply_filtered?`, die nach dem MIME-Download die Mail-Header auf bekannte Auto-Reply-Kennzeichnungen prüft: `auto-submitted` (RFC 3834, Wert != `no`), `x-auto-response-suppress`, `x-ms-exchange-generated-message-source`, `x-autorespond`, `x-autoreply`, `x-autoresponder`, `precedence: bulk/list/junk`. Erkannte Auto-Replies werden übersprungen und in den Zielordner verschoben (identisches Verhalten wie Blacklist-Treffer). Der Check läuft nach dem MIME-Download, aber vor dem Redmine `MailHandler`.
- **Absender-Whitelist für Auto-Reply-Filter** (file: `lib/redmine_expert_helpdesk/mail_processor.rb`) — Methode `auto_reply_header_whitelist_matches?`: Absender, die in `auto_reply_sender_whitelist` eingetragen sind, werden vom Auto-Reply-Filter ausgenommen. Format: eine E-Mail-Adresse oder Domain pro Zeile (gleiche Syntax wie allow_list/deny_list).
- **Header-Whitelist für Auto-Reply-Filter** (file: `lib/redmine_expert_helpdesk/mail_processor.rb`) — Methode `auto_reply_header_whitelist_matches?`: Bestimmte Header:Wert-Paare heben den Auto-Reply-Filter auf. Format je Zeile: `Header-Name: Wert` oder `Header-Name: *` für beliebigen Wert. Nützlich, wenn ein bekanntes System (z. B. ein CRM) Auto-Reply-ähnliche Header setzt, dessen Mails aber verarbeitet werden sollen.
- **Migration 010** (file: `db/migrate/010_add_auto_reply_filter_to_helpdesk_mailboxes.rb`) — Neue Spalten `auto_reply_filter_enabled` (boolean, default false), `auto_reply_sender_whitelist` (text), `auto_reply_header_whitelist` (text) in `helpdesk_mailboxes`. Bestehende Postfächer bleiben unverändert (Filter standardmäßig deaktiviert).
- **Postfach-Formular** (file: `app/views/helpdesk_mailboxes/_form.html.erb`) — Neues Fieldset „Auto-Reply-Filter" mit Checkbox zur Aktivierung, Absender-Whitelist-Textarea und Header-Whitelist-Textarea, jeweils mit erklärenden Hinweistexten.
- **Lokalisierung** (files: `config/locales/de.yml`, `config/locales/en.yml`) — Neue Schlüssel: `label_helpdesk_auto_reply_filter`, `field_helpdesk_auto_reply_filter_enabled`, `text_helpdesk_auto_reply_filter_info`, `field_helpdesk_auto_reply_sender_whitelist`, `text_helpdesk_auto_reply_sender_whitelist_info`, `field_helpdesk_auto_reply_header_whitelist`, `text_helpdesk_auto_reply_header_whitelist_info`.
- **Model** (file: `app/models/helpdesk_mailbox.rb`) — `safe_attributes` um `auto_reply_filter_enabled`, `auto_reply_sender_whitelist`, `auto_reply_header_whitelist` ergänzt.

## [Unreleased] 2026-06-18 (5)

### Fixed
- **Makros im Betreff wurden nicht ersetzt** (file: `lib/redmine_expert_helpdesk/template_renderer.rb`) — `TemplateRenderer.render` verwendete die Regex `\w+`, die Punkte nicht matcht. Das Default-Template (`Re: [#{{issue.id}}] {{issue.subject}}`) und die Projektkonfiguration nutzen aber Punkt-Notation. Fix: Regex auf `[\w.]+` erweitert; Replacements-Hash um Punkt-Notation (`issue.id`, `issue.subject`, `contact.name`, `contact.email`, `user.name`, `project.name`, `issue.url`) ergänzt. Legacy-Notation (`ticket_id`, `ticket_subject` usw.) bleibt weiterhin unterstützt.
- **Empfänger-Info fehlte im Journal-Eintrag** (file: `app/views/helpdesk/_reply_in_edit.html.erb`) — Nach der Umstellung auf Redmines eigenes Notizfeld wurde `build_recipients_header` entfernt, womit die "✉ An: …"-Zeile im Journal verschwand. Behoben: Die JS-Funktion `hdBuildRecipientHeader()` baut das `<div class="helpdesk-mail-header">…</div>`-HTML serverseitig zusammen und injiziert es in den Notiz-Textarea-Inhalt unmittelbar vor dem Formular-Submit. Die bestehende `moveHelpdeskHeaders()`-Funktion verschiebt das Element dann ans `h4.note-header`-Element.

## [Unreleased] 2026-06-18 (4)

### Changed
- **`_reply_in_edit.html.erb` komplett neu geschrieben** (file: `app/views/helpdesk/_reply_in_edit.html.erb`) — Entfernt doppelten Inhalt (alter Rich-Text-Editor-Ansatz und neuer Note-Content-Ansatz waren beide vorhanden). Jetzt eine saubere einzige Implementierung: Checkbox "Als E-Mail an Kunden senden", bei Aktivierung An/CC/BCC-Felder und optionale Signatur-Vorschau. Kein eigener Rich-Text-Editor mehr — Redmines natives `issue_notes`-Textarea wird als E-Mail-Inhalt verwendet. Stil: blaues Panel (`#edf2fa` / `#c8d8ec`) passend zum Screenshot-Referenzdesign.
- **Controller-Aufräumung** (file: `app/controllers/helpdesk_replies_controller.rb`) — Nicht mehr benötigte private Methoden entfernt: `build_recipients_header`, `html_to_wiki`, `walk_node`, `li_contents`, `process_inline_images`, `save_image_attachment`. Diese wurden bei der Umstellung auf Redmines eigenes Notizfeld als E-Mail-Inhalt überflüssig.

### Added
- **Keine-docker-exec-Regel** (file: `.github/copilot-instructions.md`) — Abschnitt "Container Management" ergänzt: Nie `docker exec` verwenden; Code-/Migrations-Änderungen durch Container-Neubau anwenden. Copilot soll nach Implementierung darauf hinweisen.

## [Unreleased] 2026-06-18 (3)

### Changed
- **`HelpdeskRepliesController#create` komplett umgebaut** (file: `app/controllers/helpdesk_replies_controller.rb`) — Statt eines eigenen HTML-Editors wird jetzt Redmines eigenes Wiki-Notizfeld verwendet. Eingabe: `params[:note_content]` (Wiki-Markup aus `#issue_notes`). Wiki → HTML-Konvertierung via `Redmine::WikiFormatting.formatter.new(text).to_html`. Kein `process_inline_images` mehr. Kein separates Journal-Eintrag mehr im Reply-Controller (das erledigt das normale Formular). Betreff kommt aus Projekteinstellungen mit Makro-Auswertung. Antwort immer als JSON.
- **`_reply_in_edit.html.erb` vereinfacht** (file: `app/views/helpdesk/_reply_in_edit.html.erb`) — Kein eigener Rich-Text-Editor mehr. Nur Checkbox + An/CC/BCC + Signatur-Vorschau. JS liest `#issue_notes`-Wert und sendet ihn per `fetch()` an den Reply-Endpunkt. Checkbox-Standardzustand kommt aus Projekteinstellung `send_reply_by_default`.
- **`hooks.rb` erweitert** (file: `lib/redmine_expert_helpdesk/hooks.rb`) — `view_issues_edit_notes_bottom` übergibt jetzt `footer_text` und `send_by_default` als Locals an das Partial.

### Added
- **Migration 008** (file: `db/migrate/008_create_helpdesk_project_settings.rb`) — Neue Tabelle `helpdesk_project_settings` mit `project_id`, `send_reply_by_default boolean default true`, `reply_subject_template string`.
- **Model `HelpdeskProjectSetting`** (file: `app/models/helpdesk_project_setting.rb`) — `belongs_to :project`, `for_project(project)` gibt vorhandene oder neue (ungespeicherte) Zeile zurück, `effective_subject_template` liefert Vorlage oder Default.
- **Controller `HelpdeskProjectSettingsController#update`** (file: `app/controllers/helpdesk_project_settings_controller.rb`) — Speichert Projekteinstellungen; erreichbar via `PUT /projects/:project_id/helpdesk_project_setting`.
- **Route** (file: `config/routes.rb`) — `resource :helpdesk_project_setting, :only => [:update]` unter `projects/:project_id`.
- **Projekteinstellungen-View** (file: `app/views/projects/settings/_helpdesk.html.erb`) — Fieldset „Antworteinstellungen" am Anfang des Helpdesk-Tabs: Checkbox „Antworten standardmäßig als E-Mail senden" + Betreff-Vorlage-Feld mit Makro-Hinweis.
- **Lokalisierungsschlüssel** (file: `config/locales/de.yml`, `config/locales/en.yml`) — `label_helpdesk_reply_settings`, `label_helpdesk_send_reply_by_default`, `label_helpdesk_reply_subject_template`, `text_helpdesk_subject_template_hint`, `label_helpdesk_mail_footer_preview`.

## [Unreleased] 2026-06-18 (2)

### Changed
- **Antwortformular ins Bearbeitungsformular verschoben** (file: `app/views/helpdesk/_issue_panel.html.erb`, `app/views/helpdesk/_reply_in_edit.html.erb` neu, `lib/redmine_expert_helpdesk/hooks.rb`) — Das bisherige `<details>`-Antwortformular wurde aus dem Kunden-Info-Panel (`_issue_panel.html.erb`) entfernt. Stattdessen erscheint unterhalb der Notizen-Textarea im Standard-Bearbeitungsformular eine Checkbox „Als E-Mail an Kunden senden". Wenn aktiviert, werden An/CC/BCC/Betreff-Felder und der Rich-Text-Editor eingeblendet. Beim Absenden des Formulars wird zunächst per `fetch()` (JSON) die Mail an den Kunden gesendet; erst bei Erfolg wird das normale Issue-Formular (Notiz → Journal) abgeschickt. Bei Fehler erscheint ein `alert()` und das Formular wird nicht abgesendet.
- **Neuer View-Hook `view_issues_edit_notes_bottom`** (file: `lib/redmine_expert_helpdesk/hooks.rb`) — zusätzlich zum bestehenden `view_issues_show_description_bottom`-Hook. Prüft Modul, Berechtigung `send_helpdesk_reply` und Vorhandensein eines Helpdesk-Kontakts; rendert bei Erfolg `helpdesk/_reply_in_edit`.
- **`HelpdeskRepliesController#create` unterstützt JSON** (file: `app/controllers/helpdesk_replies_controller.rb`) — `respond_to` für `html` (Redirect mit Flash) und `json` (JSON-Response `{success: true, message: ...}` bzw. `{success: false, error: ...}` mit HTTP 422). Ermöglicht den `fetch()`-Aufruf aus dem Bearbeitungsformular.

### Added
- **`label_helpdesk_send_as_mail`** (file: `config/locales/de.yml`, `config/locales/en.yml`) — neuer Lokalisierungsschlüssel für die Checkbox-Beschriftung.

## [Unreleased] 2026-06-18

### Added
- **Kunden-Tab im Projekt-Menü** (file: `init.rb`, `config/routes.rb`, `app/controllers/helpdesk_contacts_controller.rb`, `app/views/helpdesk_contacts/index.html.erb`, `app/views/helpdesk_contacts/edit.html.erb`) — neuer Menüpunkt „Kunden" in der Projektnavigation (nach „Tickets"). Zeigt alle Kontakte des Projekts mit Name, E-Mail, Firma, Telefon, Ticket-Anzahl und letztem Ticket. Editierbar (Name, Firma, Telefon, Notizen), löschbar. Auf der Edit-Seite werden die letzten 20 Tickets des Kunden aufgeführt.
- **Berechtigung `manage_helpdesk_contacts`** (file: `init.rb`) — steuert Zugriff auf `HelpdeskContactsController` (index, edit, update, destroy).
- **`phone`-Feld für Kontakte** (file: `app/models/helpdesk_contact.rb`, `db/migrate/007_add_project_to_helpdesk_contacts.rb`) — Telefonnummer je Kontakt.
- **Projekt-Kontext für Kontakte** (file: `app/models/helpdesk_contact.rb`, `lib/redmine_expert_helpdesk/mail_processor.rb`) — `HelpdeskContact` gehört jetzt zu einem Projekt. `find_or_create_for` nimmt `project` als dritten Parameter; `MailProcessor` übergibt `@mailbox.project`. Unterschiedliche Projekte führen separate Kundenlisten mit eigenen Metadaten.
- **Spalte „Kunde" in der Issue-Liste** (file: `lib/redmine_expert_helpdesk/patches/issue_patch.rb`, `lib/redmine_expert_helpdesk/patches/issue_query_patch.rb`) — neue sortierbare Spalte und Textfilter in `IssueQuery`. Suche auf Name und E-Mail-Adresse des Kontakts. Operatoren: `~` (enthält), `!~`, `=`, `!`.
- **Letzter Fehler je Postfach** (file: `app/views/projects/settings/_helpdesk.html.erb`, `lib/redmine_expert_helpdesk/mail_processor.rb`, `db/migrate/006_add_last_error_to_helpdesk_mailboxes.rb`) — Fehlerspalte in der Postfachliste. Graph-Abruffehler und Mail-Verarbeitungsfehler werden in `last_error` / `last_error_at` gespeichert. Nach erfolgreichem Abruf werden beide Felder geleert. Fehlertext wird auf 60 Zeichen gekürzt, vollständige Meldung + Zeitstempel im `title`-Attribut (Hover).
- **Hinweis „Entra-Berechtigungen entfernen" erweitert** (file: `README.md`) — Warnblock enthält jetzt vollständigen PowerShell-Befehl zum Entfernen von `Mail.ReadWrite` und `Mail.Send` aus Entra ID nach EXO-RBAC-Einrichtung, inkl. Verifikationshinweis im Azure-Portal.
- **Empfänger-Header und EML-Link im Journal-Header** (file: `app/views/helpdesk/_issue_panel.html.erb`, `app/controllers/helpdesk_replies_controller.rb`, `lib/redmine_expert_helpdesk/mail_processor.rb`) — `<div class="helpdesk-mail-header">` statt `<p>`; JavaScript verschiebt diese Divs per `insertAdjacentElement('afterend', ...)` direkt nach das `h4.note-header`-Element, sodass sie im Header-Bereich des Journal-Eintrags erscheinen, nicht im Notiztext.

### Changed
- **`HelpdeskContact#find_or_create_for`** — Signatur erweitert um `project`-Parameter (breaking: alle Aufrufer müssen Projekt übergeben). Eindeutigkeit jetzt per `[email, project_id]` statt nur `email`.
- **`MailProcessor#process_all`** — Graph-Listaufruf ist jetzt in eigenen `rescue`-Block gefasst; Netzwerkfehler beim Abruf selbst werden als `last_error` gespeichert und mit frühem `return` abgebrochen. Bei Teilerfolg (einzelne Nachrichten fehlerhaft) wird der letzte Fehler gespeichert, `last_fetched_at` aber trotzdem aktualisiert. Vorher: einziger `update_column(:last_fetched_at)` am Ende, kein Fehler-Tracking.
- **`build_recipients_header`** (file: `app/controllers/helpdesk_replies_controller.rb`) — gibt jetzt `<div>` statt `<p>` zurück, damit das Element als Block-Element korrekt per JS aus dem `.wiki`-Bereich herausgezogen werden kann.
- **EML-Link in `mail_processor.rb`** — ebenfalls `<div class="helpdesk-mail-header">` statt `<p>`.

### Migration
- `006_add_last_error_to_helpdesk_mailboxes.rb` — fügt `last_error (text)` und `last_error_at (datetime)` zur Tabelle `helpdesk_mailboxes` hinzu.
- `007_add_project_to_helpdesk_contacts.rb` — fügt `project_id (integer)` und `phone (string)` zur Tabelle `helpdesk_contacts` hinzu. Bestehende Kontakte erhalten `project_id` aus dem ersten verknüpften Ticket-Projekt. Doppelte Kontakte per `(email, project_id)` werden zusammengeführt. Alter `UNIQUE`-Index auf `email` wird durch zusammengesetzten Index `[email, project_id]` ersetzt.
