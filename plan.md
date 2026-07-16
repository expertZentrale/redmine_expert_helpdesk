# Plan: SLA-Funktion (Reaktions-/Lösungszeit) für redmine_expert_helpdesk

## TL;DR
Pro Projekt aktivierbare SLA-Ziele (Reaktionszeit + Lösungszeit in Geschäftsminuten),
optional je Priorität überschreibbar. Arbeitszeiten (Wochentage + Zeitspanne) pro Projekt;
SLA-Uhren laufen nur innerhalb dieser Zeiten. Anzeige am Ticket (grün/gelb/rot),
optionale Benachrichtigung bei Überschreitung (E-Mail-Feld für Eskalationsmanager oder Projekt-User).
Tracking auf HelpdeskTicketInfo (first_response_at, Geschäftsminuten Reaktion/Lösung).

## Entscheidungen (mit User geklärt)
- Ziele: pro Projekt als Default + optional pro Priorität überschreibbar
- Reaktionsuhr stoppt: erster öffentlicher Journal-Kommentar eines Mitarbeiters ODER Kundenantwort-Mail
- Verletzung: Anzeige + optional konfigurierbare Benachrichtigung (E-Mail-Feld + User-Auswahl)
- Arbeitszeiten: einfach (Wochentage an/aus + eine Zeitspanne), pro Projekt
- Lösungszeit: issue.closed_on (Redmine-Standard), bei Reopen zurückgesetzt
- Kein Scheduler: Breach-Check piggyback auf fetch_all (wie PhishTank-Sync)
- Warnstufe (gelb) fest bei 80 % der Zielzeit (v1)
- Bestandstickets: sla_enabled_at-Guard — SLA gilt nur für Tickets ab Aktivierung

## Architektur
- Migrationen 023 (Projekt-Settings), 024 (helpdesk_sla_priorities), 025 (Tracking an helpdesk_ticket_infos)
- lib/business_hours.rb: elapsed_minutes / due_at (pur, testbar)
- lib/sla.rb: targets_for (Prio→Projekt), clock_state/state_for (:met/:breached_done/:running/:warning/:breached),
  record_first_response!, sync_solution! (closed_on, Reset bei Reopen), enabled_for? (sla_enabled_at-Guard)
- lib/sla_breach_check.rb: fetch_all-Piggyback mit Cache-Lock, einmalige Benachrichtigung (notified_at),
  Mailer app/mailers/helpdesk_sla_mailer.rb + Text-Template
- Hooks: controller_issues_edit_after_save (Reaktion via öffentlichem Journal, Lösung via Statuswechsel);
  view_issues_show_details_bottom rendert _sla_box (unabhängig vom Kontakt)
- Replies-Controller: record_first_response! bei Kundenantwort
- Settings-UI: eigenes SLA-Formular im Helpdesk-Tab (sla_form-Marker, damit Reply-Settings nicht überschrieben werden),
  Prio-Override-Tabelle (leer = Default), Benachrichtigung (E-Mail + User-Select)

## Verifikation
1. Rebuild → Migrationen 023–025; SLA konfigurieren (Reaktion 60, Lösung 480, Mo–Fr 08–17)
2. Testmail Freitag 16:50 → „fällig bis Montag …" (Geschäftszeit-Übertrag)
3. Öffentliche Notiz → Reaktion grün; schließen → Lösung grün; Reopen → Uhr läuft wieder
4. Ziel 1 min + fetch_all → genau eine Benachrichtigung, Wiederholung sendet nicht erneut

## Explizit NICHT enthalten (v1)
- Feiertagskalender, je-Tag-Arbeitszeiten; SLA-Pause bei „Warten auf Kunde" (Roadmap);
  Issue-Listen-Spalte/Filter (Roadmap); Kundenzufriedenheit/Vote

## Status SLA
IMPLEMENTIERT (2026-07-06, Container-Rebuild + Ende-zu-Ende-Test ausstehend):
- Migrationen 023–025, BusinessHours (standalone verifiziert: 11/11 Checks inkl. Wochenend-Skip),
  Sla, SlaBreachCheck + Mailer, Hooks, Replies-Controller, SLA-Box, Settings-UI, CSS, Locales,
  21 Unit-Tests, CHANGELOG (52), READMEs

---

# Plan: PhishTank-Integration (Phishing-Link-Erkennung) für redmine_expert_helpdesk

## TL;DR
Optionale, pro Projekt aktivierbare Phishing-Prüfung eingehender Mails gegen die PhishTank-Datenbank.
Globale Einstellungen (App-Key optional, Download-Intervall), lokaler DB-Spiegel in MariaDB,
Link-Scan vor MailHandler.receive mit SafeLinks-Auflösung, Aktion pro Projekt konfigurierbar
(Links neutralisieren ODER Mail in Quarantäne). Plus ROADMAP.md mit weiteren Maßnahmen.

## Entscheidungen (mit User geklärt)
- Kein PhishTank App-Key vorhanden → anonymer Download (Feld optional vorsehen)
- Aktion bei Treffer: pro Projekt konfigurierbar (neutralize | quarantine)
- roadmap: plugins/redmine_expert_helpdesk/ROADMAP.md
- Redmine 5.1.4 (Dockerfile.dev), kein Sidekiq → Download via Piggyback auf fetch_all + Rake-Task
- SafeLinks werden NICHT per HTTP aufgelöst — Original-URL steckt url-encodiert im Query-Parameter `url`

## Architektur / Neue Dateien
1. `db/migrate/016_create_helpdesk_phishing_urls.rb`
   - url (text), url_hash (string 64, unique index, SHA-256 der normalisierten URL),
     phish_id (integer, index), target (string), imported_at (datetime)
2. `db/migrate/017_add_phishing_settings_to_helpdesk_project_settings.rb`
   - phishing_check_enabled (boolean, default false, null false)
   - phishing_action (string, default 'neutralize') — Werte: neutralize | quarantine
3. `app/models/helpdesk_phishing_url.rb`
   - self.lookup(url) → normalisieren, hash, exact match
   - self.stale?(interval_hours) → maximum(:imported_at) älter als Intervall?
4. `lib/redmine_expert_helpdesk/phishtank_sync.rb`
   - download: http://data.phishtank.com/data/online-valid.json.gz (anonym)
     bzw. http://data.phishtank.com/data/{app_key}/online-valid.json.gz
   - User-Agent Pflicht: "phishtank/<kontakt>" Format
   - gunzip → JSON.parse → Batches via insert_all (je 1000), delete_all + import in Transaktion
   - Fehlerbehandlung: bei Download-Fehler alte Daten behalten, Rails.logger.error
5. `lib/redmine_expert_helpdesk/phishing_scanner.rb` (Kernstück, isoliert testbar)
   - scan(mime) → { mime:, hits: [{url:, resolved_url:, phish_id:, target:}] }
   - URL-Extraktion aus text/plain (Regex) und text/html
   - resolve_safelink(url): *.safelinks.protection.outlook.com → CGI.parse(query)['url']
   - Treffer-Ersetzung: URL → "[LINK ENTFERNT – Phishing-Verdacht (PhishTank #ID)]",
     Warnbanner am Anfang des Bodys (beide Parts)
   - Multipart-sicher: Parts einzeln bearbeiten (Base64-Re-Encoding), mail.to_s zurück

## Integrationspunkte (bestehende Dateien)
- `init.rb`: requires + Settings-Defaults phishtank_enabled/phishtank_app_key/phishtank_interval_hours
- `app/views/settings/_helpdesk_settings.html.erb`: PhishTank-Fieldset (Checkbox, Key, Intervall, Status)
- `app/views/projects/settings/_helpdesk.html.erb`: Checkbox phishing_check_enabled + Select phishing_action
- `app/controllers/helpdesk_project_settings_controller.rb`: neue Felder in update (Whitelist-geprüft)
- `app/models/helpdesk_project_setting.rb`: PHISHING_ACTIONS, Validierung, effective_phishing_action
- `lib/redmine_expert_helpdesk/mail_processor.rb` in process_message:
  - Nach auto_reply_filtered?-Check, VOR maybe_strip_thread_for_new_issue:
    - quarantine → move_skipped, result.skipped, Log, return
    - neutralize → mime ersetzen, nach Issue-Erstellung add_phishing_note (Journal)
- `app/controllers/helpdesk_fetch_controller.rb` (fetch_all): PhishtankSync.run_if_stale
  (begin/rescue, Cache-Lock gegen Doppellauf)
- `lib/tasks/helpdesk_phishtank.rake`: redmine_expert_helpdesk:phishtank_sync

## Locales (de.yml + en.yml)
- label_helpdesk_phishtank, field_helpdesk_phishtank_*, field_helpdesk_phishing_*,
  label_helpdesk_phishing_action_neutralize/quarantine, note_helpdesk_phishing_links_removed,
  text_helpdesk_phishing_link_removed, text_helpdesk_phishing_warning_banner, Statuszeile

## ROADMAP.md (plugins/redmine_expert_helpdesk/ROADMAP.md)
Feeds (URLhaus, OpenPhish, Google Safe Browsing), URL-Heuristiken (Punycode, IP-Literale,
Anchor-Mismatch, TLDs), SPF/DKIM/DMARC, URL-Shortener, Anhang-Scanning (ClamAV/VirusTotal),
Anzeigename-Spoofing, Meldeworkflow, Eskalation, Reporting.

## Tests (test/unit/)
- phishing_scanner_test.rb: SafeLinks, Extraktion, MIME-Rewrite (multipart), Clean-Mail, Fehlertoleranz
- phishtank_sync_test.rb: gestubbter Import, Duplikate, Voll-Ersetzung, Fehlerfall erhält Altdaten
- helpdesk_phishing_url_test.rb: Normalisierung, Lookup, stale?
- helpdesk_project_setting_test.rb: phishing_action-Validierung + effective_phishing_action

## Verifikation
1. Container-Rebuild → Migrationen 016+017 laufen (REDMINE_PLUGINS_MIGRATE=1)
2. Global aktivieren, Sync triggern (fetch_all/Rake), via MariaDB-MCP:
   SELECT COUNT(*) FROM helpdesk_phishing_urls; (> 10.000 erwartet)
3. Fake-Eintrag einfügen (Test-URL), Testmail mit dieser URL + SafeLinks-Wrapper senden
4. neutralize: Ticket prüfen — Link ersetzt, Warnbanner, Journal-Notiz
5. quarantine: Mail landet im Skipped-Ordner, kein Ticket

## Explizit NICHT enthalten
- Kein Live-API-Check gegen PhishTank (checkurl API) — nur lokaler DB-Spiegel
- Keine HTTP-Redirect-Verfolgung (URL-Shortener) — Roadmap
- Kein Scan ausgehender Mails
- Kein Scan bestehender Tickets (nur neue eingehende Mails)

## Status
IMPLEMENTIERT (2026-07-02, Container-Rebuild + Ende-zu-Ende-Test ausstehend):
- Migrationen 016 + 017
- HelpdeskPhishingUrl, PhishtankSync (run_if_stale mit Cache-Lock), PhishingScanner
- MailProcessor-Hook (quarantine/neutralize + add_phishing_note)
- fetch_all-Piggyback, Rake-Task, Global-/Projekt-Settings-UI, Locales de/en
- ROADMAP.md, CHANGELOG-Eintrag (28), README-Abschnitte de/en
- 4 Unit-Test-Dateien (3 neu, 1 erweitert)
