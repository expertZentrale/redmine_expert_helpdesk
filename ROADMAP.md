# Roadmap – Anti-Phishing-Maßnahmen

Dieses Dokument sammelt geplante und mögliche zukünftige Maßnahmen zur
Phishing-Abwehr im Helpdesk-Plugin. Bereits umgesetzt: PhishTank-Integration
(lokaler Datenbank-Spiegel, Link-Neutralisierung, Quarantäne) sowie der
Phishing.Database-Feed als zweite Quelle.

## Kurzfristig

### 1. Zusätzliche Threat-Intelligence-Feeds
- **URLhaus** (abuse.ch): kostenloser Feed für Malware-URLs, CSV/JSON, kein Key nötig
- **OpenPhish**: Community-Feed (kostenlos) mit Phishing-URLs
- **Google Safe Browsing API**: Lookup-API v4, kostenlos mit API-Key, deckt deutlich mehr ab als PhishTank
- **[Phishing.Database](https://github.com/Phishing-Database/Phishing.Database)**: ✅ **umgesetzt** —
  Community-Datenbank mit aktiven Phishing-URLs (per PyFunceble geprüft, stündlich aktualisiert),
  als zweiter lokaler Spiegel neben PhishTank integriert (Quelle `phishing_database`);
  Domain-Listen für Blocking auf Domain-Ebene bleiben als Ausbaustufe offen
- Architektur: ✅ Tabelle `helpdesk_phishing_urls` hat Spalte `source`, ein Sync-Service pro Feed (`PhishingFeeds`-Orchestrator)

### 2. URL-Heuristiken (ohne externe Abhängigkeit)
- **Punycode-/Homoglyphen-Erkennung**: Domains mit `xn--`-Präfix oder gemischten Skripten kennzeichnen
- **IP-Literal-URLs**: `http://203.0.113.5/login` ist fast immer verdächtig
- **Anchor-Text ≠ href-Ziel**: HTML-Links, deren sichtbarer Text eine andere Domain zeigt als das Ziel
- **Verdächtige TLDs**: konfigurierbare Liste (z. B. `.zip`, `.mov`, `.top`, `.gq`)

## Mittelfristig

### 3. Header-Auswertung (SPF/DKIM/DMARC)
- `Authentication-Results`-Header der eingehenden Mail parsen
- Bei `fail`/`softfail`: Warnhinweis in der Ticket-Notiz, optional Kategorisierung
- Anzeigename-Spoofing: Anzeigename entspricht internem Mitarbeiter, Absenderadresse ist extern

### 4. URL-Shortener-Auflösung
- HEAD-Requests mit Timeout gegen bekannte Shortener (bit.ly, t.co, tinyurl, …)
- Aufgelöste Ziel-URL erneut gegen die Feeds prüfen
- Vorsicht: ausgehende HTTP-Requests im Mailpfad → nur asynchron oder mit striktem Timeout

### 5. Anhang-Scanning
- **ClamAV**: lokaler Scan-Daemon (clamd) im Kubernetes-Cluster, Prüfung vor Attachment-Speicherung
- **VirusTotal API**: Hash-Lookup (kein Upload nötig, datenschutzfreundlich), 4 Requests/min kostenlos
- Gefährliche Dateitypen (`.html`, `.iso`, `.one`, Makro-Office) konfigurierbar blockieren/kennzeichnen

## Langfristig

### 6. Meldeworkflow
- "Phishing melden"-Button im Ticket (für Bearbeiter)
- Automatisch: Absender auf Mailbox-Blacklist, Security-Team benachrichtigen, Ticket schließen
- Optional: Meldung an PhishTank/URLhaus zurückspielen

### 7. Automatische Eskalation
- Bei Phishing-Verdacht: eigene Ticket-Kategorie, Zuweisung an Security-Verantwortlichen
- Prioritätserhöhung wenn mehrere Empfänger dieselbe Phishing-Mail erhalten (Kampagnen-Erkennung)

### 8. Kennzahlen & Reporting
- Dashboard: Phishing-Treffer pro Postfach/Zeitraum, Top-Ziele (Marken), Quarantäne-Quote
- Grafana-Anbindung über bestehende Infrastruktur

## Bewusst ausgeklammert
- **Live-API-Checks im Mailpfad** (Latenz, Verfügbarkeit): stattdessen lokale Spiegel
- **Machine-Learning-Klassifikation**: Aufwand/Nutzen für das Volumen nicht gerechtfertigt
- **Scan ausgehender Mails**: Bedrohungsmodell betrifft eingehende Mails
