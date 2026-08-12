# Microsoft-365-Einrichtungsskripte

> 🇩🇪 Deutsche Version · [English version](README.md)
>
> Die englische `README.md` ist maßgeblich und wird synchron gehalten.

Repo-interne Werkzeuge für die einmalige Einrichtung in Microsoft 365 / Entra ID, die das Plugin
für Graph-Postfächer benötigt (und für IMAP/SMTP-Postfächer, die sich per OAuth2 authentifizieren).
Von den Release-Archiven ausgeschlossen – sie gelangen nie zu den Nutzern des Plugins.

| Skript | Zweck |
|---|---|
| `setup-azure-app.ps1` | Legt App-Registrierung, Graph-Berechtigungen, Client-Secret und den Exchange-Online-RBAC-Scope an und erweitert sie. Wiederholt ausführbar. |
| `delete-app-registration.ps1` | Entfernt alles wieder (sauberer Neuanfang), mit Rückfrage vor jedem löschenden Schritt. |

Beide sind die ausführbare Fassung des Abschnitts *Azure-App-Registrierung* in
[`../README.de.md`](../README.de.md), der auch die Entsprechungen für Azure-Portal, Azure CLI und
Terraform dokumentiert.

```powershell
# Ersteinrichtung
./setup-azure-app.ps1 -MailboxEmailList "helpdesk@example.com" -TestMailbox "helpdesk@example.com"

# Sobald die Prüfung oben InScope: True meldet – siehe „Warum Schritt 5 entscheidend ist“
./setup-azure-app.ps1 -RemoveEntraGraphPermissions

# Später: ein weiteres Projekt, ein weiteres Postfach
./setup-azure-app.ps1 -MailboxEmailList "sales@example.com"
```

### Wie ein erneuter Lauf die Installation findet

Namen taugen schlecht als Anker – eine von Hand unter `redmine-helpdesk`
angelegte Installation fände ein Skript mit der Vorgabe
`redmine-expert-helpdesk-live` nicht, und es legte eine zweite, parallele
Installation an, statt die erste zu erweitern. Die Ressourcen tragen deshalb
eine Markierung:

- **Die App-Registrierung ist getaggt** (`Tags` enthält
  `RedmineExpertHelpdesk`, `-ResourceTag`). Nach diesem Tag sucht ein erneuter
  Lauf, nicht nach dem Anzeigenamen. Installationen aus der Zeit vor dem Tag
  werden beim nächsten Lauf nachträglich markiert – das repariert sich also beim
  ersten Lauf des aktualisierten Skripts von selbst.
- **Der Service Principal wird über die AppId aufgelöst**, nie über einen Namen.
- **Der Management-Scope wird aus den Rollenzuweisungen der App gelesen** –
  erweitert wird der Scope, dem die App tatsächlich zugewiesen ist, wie immer er
  heißt.

In der Praxis heißt das: `-AppDisplayName` und `-RbacScopeName` braucht es nur
für die Ersteinrichtung oder zur Abgrenzung. Um zu sehen, worauf ein Lauf zielen
würde:

```powershell
Get-MgApplication -Filter "tags/any(t:t eq 'RedmineExpertHelpdesk')" |
    Select-Object DisplayName, AppId, Tags

Get-ManagementRoleAssignment |
    Where-Object { $_.Role -like "Application Mail.*" } |
    Select-Object Role, RoleAssigneeName, CustomResourceScope
```

### Mehrere Installationen in einem Tenant (Dev neben Live)

Ein Dev-Stack braucht eine eigene App-Registrierung, damit seine
Plugin-Instanz nicht an die Live-Helpdesk-Postfächer kommt. `-Environment`
trennt die beiden – der Parameter leitet das Tag *und* beide Namen ab, damit
nichts kollidiert und kein weiterer Parameter wiederholt werden muss:

| | `-Environment LIVE` (Vorgabe) | `-Environment DEV` |
|---|---|---|
| Tag | `RedmineExpertHelpdesk:LIVE` | `RedmineExpertHelpdesk:DEV` |
| App-Registrierung | `redmine-expert-helpdesk-live` | `redmine-expert-helpdesk-dev` |
| EXO-Scope | `Redmine-expert-Helpdesk-Mailboxes-LIVE` | `Redmine-expert-Helpdesk-Mailboxes-DEV` |

```powershell
# Die Dev-Installation einmal einrichten
./setup-azure-app.ps1 -Environment DEV `
    -MailboxEmailList "helpdesk-dev@example.com" -TestMailbox "helpdesk-dev@example.com"
./setup-azure-app.ps1 -Environment DEV -RemoveEntraGraphPermissions

# Danach unterscheidet allein -Environment DEV einen Dev-Lauf
./setup-azure-app.ps1 -Environment DEV -MailboxEmailList "sales-dev@example.com"

# ... und die Live-Installation bleibt davon unberührt
./setup-azure-app.ps1 -MailboxEmailList "sales@example.com"

# Nur die Dev-Seite wieder abräumen
./delete-app-registration.ps1 -Environment DEV
```

Beide Installationen tragen zusätzlich das schlichte Tag
`RedmineExpertHelpdesk` – damit lassen sich unabhängig von der Umgebung alle
Installationen eines Tenants auflisten:

```powershell
Get-MgApplication -Filter "tags/any(t:t eq 'RedmineExpertHelpdesk')" |
    Select-Object DisplayName, AppId, Tags
```

Die Bezeichnung ist frei wählbar (`DEV`, `TEST`, `STAGING`, `kunde-x`) und
Groß-/Kleinschreibung spielt keine Rolle. Den Umgebungen jeweils eigene
Postfachadressen geben: die Scopes sind zwar getrennt, zwei Scopes *dürfen*
aber dasselbe Postfach nennen – dann erreichen es beide Installationen.

> ⚠️ Nur wenn `-ResourceTag` von Hand überschrieben wird, können sich zwei
> Installationen ein Tag teilen. Dann passen beide, und das Skript rät nicht –
> es listet die Kandidaten auf und verlangt `-AppDisplayName`.

---

## Wie das Berechtigungsmodell funktioniert

Der Zugriff wird über **zwei voneinander unabhängige Ebenen** gesteuert – und die zweite bedeutet
erst dann etwas, wenn die erste weg ist.

**Ebene 1 – Anwendungsberechtigungen in Entra ID.** `Mail.ReadWrite` und `Mail.Send` werden der
App-Registrierung als *Anwendungsberechtigungen* erteilt (app-only, ohne angemeldeten Benutzer).
Sie gelten **tenantweit**: eine App mit diesen Berechtigungen kann in **jedem Postfach des Tenants**
lesen und in dessen Namen senden. In Entra ID selbst lassen sie sich nicht eingrenzen.

**Ebene 2 – Exchange Online Application RBAC.** Ein *Management-Scope* beschreibt über einen
Empfängerfilter eine Menge von Postfächern, zwei *Management-Rollenzuweisungen*
(`Application Mail.ReadWrite`, `Application Mail.Send`) binden die App an diesen Scope. Das ist die
Ebene, die die App tatsächlich auf die Helpdesk-Postfächer beschränkt. Sie ersetzt das veraltete
`New-ApplicationAccessPolicy`.

### Warum Schritt 5 entscheidend ist

Die beiden Ebenen wirken **additiv, nicht schneidend**. Solange die Entra-Berechtigungen aus
Ebene 1 bestehen, ist der RBAC-Scope reine Dekoration – die App erreicht jedes Postfach des
Tenants, ganz gleich, was im Scope steht. Die Einrichtung ist deshalb erst abgeschlossen nach:

```powershell
./setup-azure-app.ps1 -RemoveEntraGraphPermissions
```

Das entfernt die Berechtigungen aus Ebene 1 und lässt den RBAC-Scope als einzige wirksame
Beschränkung zurück. **Erst ausführen, wenn** die Berechtigungsprüfung `InScope: True` meldet –
sonst verliert die App den Mailzugriff, bevor sie je einen eingegrenzten hatte.

Aus demselben Grund **überspringt `setup-azure-app.ps1` den Schritt zur Berechtigungsvergabe bei
einem erneuten Lauf** gegen eine bestehende App-Registrierung: sie beim Aufnehmen eines Postfachs
erneut zu vergeben, würde den tenantweiten Zugriff stillschweigend wieder öffnen. Falls sie
tatsächlich neu vergeben werden müssen (z. B. nach einem abgebrochenen ersten Lauf), gibt es
`-EnsureEntraGraphPermissions`.

---

## Die passende Variante der Postfach-Auswahl

`-MailboxScopeOption` bestimmt, wie der Management-Scope Postfächer auswählt. Zur Laufzeit sind
alle vier gleich restriktiv – **der Unterschied liegt darin, wer das nächste Postfach aufnehmen
kann und was er oder sie dafür braucht.** Das ist die Entscheidung, nicht die Stärke der
Absicherung.

| Variante | Wer ein Postfach aufnehmen kann | Was dafür nötig ist | Passt, wenn |
|---|---|---|---|
| `EmailList` (Vorgabe) | Nur eine **Exchange-Administratorin** | Skript erneut ausführen (oder `Set-ManagementScope` von Hand) | Wenige, stabile Postfächer; jede Aufnahme soll ein bewusster, nachvollziehbarer Akt sein |
| `CustomAttribute` | Alle, die **Postfächer anlegen/bearbeiten** dürfen (Recipient Management) | `Set-Mailbox -CustomAttribute1 …` – ein zusätzliches Feld beim Anlegen des freigegebenen Postfachs | Viele Projekte, Aufnahme an das Mail-Team delegiert |
| `SecurityGroup` | Die **Gruppenbesitzerin** – darf eine normale Benutzerin sein | Mitglied hinzufügen (PowerShell, EAC oder Outlook) | Zugriffe werden ohnehin über Gruppen verwaltet und eine sichtbare, prüfbare Mitgliederliste ist erwünscht |
| `DomainSuffix` | Alle, die in dieser Domain **Postfächer anlegen** dürfen | Nichts – das Postfach in der Domain anlegen | Eine Domain (oder Subdomain) ist ausschließlich für Helpdesk-Postfächer reserviert |

### `EmailList` – ausdrückliche Liste *(Vorgabe des Skripts)*

```powershell
./setup-azure-app.ps1 -MailboxEmailList "helpdesk@example.com", "sales@example.com"
```

Filter: `PrimarySmtpAddress -eq 'helpdesk@example.com' -or PrimarySmtpAddress -eq 'sales@example.com'`

**Vorteil:** die ausdrücklichste und restriktivste Variante. Die vollständige Menge der
erreichbaren Postfächer steht an genau einer Stelle, und **niemand kann dem Plugin von sich aus
Zugriff auf ein Postfach verschaffen** – weder die Postfachbesitzerin noch wer Postfächer anlegt.
Jede Aufnahme geht über jemanden mit der Rolle Exchange-Administrator. Nichts wird jemals
implizit eingeschlossen.

**Preis:** genau das. Für jedes neue Projekt muss eine privilegierte Administratorin das Skript
ausführen. Werden Postfächer von einem Team angelegt, das die Rolle Exchange-Administrator *nicht*
hat, macht diese Variante es bei jedem einzelnen Projekt von jemandem abhängig, der sie hat.

**Hinweis:** `-MailboxEmailList` wirkt ergänzend – bereits im Scope enthaltene Adressen bleiben
erhalten. `-ReplaceMailboxList` steht für „genau diese Liste“, `-RemoveMailboxEmailList` entzieht
den Zugriff.

### `CustomAttribute` – Selbstbedienung über ein Postfach-Merkmal

```powershell
./setup-azure-app.ps1 -MailboxScopeOption CustomAttribute `
    -MailboxCustomAttributeValue "Redmine" -TestMailbox "helpdesk@example.com"
```

Filter: `CustomAttribute1 -eq 'Redmine'`

**Vorteil:** Das ist die Variante, die den Engpass bei den Administratoren auflöst.
`CustomAttribute1` ist eine gewöhnliche Postfach-Eigenschaft, also kann **wer das freigegebene
Postfach ohnehin anlegen darf, es im selben Zug für das Plugin freischalten** – ohne
Exchange-Administrator, ohne Skriptlauf, ganz ohne Änderung am RBAC-Scope:

```powershell
New-Mailbox -Shared -Name "Sales Helpdesk" -PrimarySmtpAddress "sales@example.com"
Set-Mailbox -Identity "sales@example.com" -CustomAttribute1 "Redmine"
```

Ein Projekt aufzunehmen wird damit zu einer zusätzlichen Zeile in dem Ablauf, nach dem Postfächer
ohnehin bereitgestellt werden, und das Merkmal wandert mit dem Postfach mit. Der Entzug ist ebenso
einfach – Attribut leeren, und das Postfach fällt aus dem Scope.

**Preis:** Das Risiko liegt in eben dieser Delegation. Wer ein Postfach bearbeiten darf, kann nun
das Plugin daraufsetzen; die Grenze ist also nur so eng wie die Rollengruppe Recipient Management.
`CustomAttribute1`–`15` sind zudem eine **gemeinsam genutzte, tenantweite Ressource** – ein anderes
Team verwendet den gewählten Platz womöglich schon. Auf Platz und Wert einigen und beides
festhalten. In der Verwaltungsoberfläche steht das Attribut nicht prominent, es lässt sich also
ebenso leicht setzen wie vergessen.

### `SecurityGroup` – Mitgliederliste

```powershell
./setup-azure-app.ps1 -MailboxScopeOption SecurityGroup `
    -MailboxSecurityGroup "helpdesk-mailboxes@example.com" -TestMailbox "helpdesk@example.com"
```

Filter: `MemberOfGroup -eq '<Distinguished Name der Gruppe>'`

**Vorteil:** der Mittelweg. Die Menge der erreichbaren Postfächer ist eine sichtbare, prüfbare
Liste statt eines an jedem Postfach versteckten Merkmals, und für Gruppenmitgliedschaften gibt es
in den meisten Organisationen bereits einen Ablauf und eine Nachvollziehbarkeit. Die Besitzrolle
lässt sich an eine normale Benutzerin übertragen, ein Postfach aufzunehmen braucht dann überhaupt
keine Administratorrolle – und geht über die EAC oder Outlook statt über PowerShell.

**Preis:** Die Gruppe muss einmal angelegt (mail-aktivierte Sicherheitsgruppe) und ihre Besitzrolle
bewusst vergeben werden, es ist also mehr aufzubauen als bei `CustomAttribute`. Verschachtelte
Gruppen werden nicht aufgelöst – Mitglieder müssen direkt eingetragen sein. Auch
Mitgliedschaftsänderungen brauchen einen Moment, bis sie wirken.

### `DomainSuffix` – alles in einer Domain

```powershell
./setup-azure-app.ps1 -MailboxScopeOption DomainSuffix `
    -MailboxDomainSuffix "@helpdesk.example.com" -TestMailbox "helpdesk@example.com"
```

Filter: `PrimarySmtpAddress -like '*@helpdesk.example.com'`

**Vorteil:** Aufnahme ohne jeden Handgriff. Das Postfach in der richtigen Domain anzulegen *ist*
der gesamte Vorgang – nichts zu setzen, nichts zu merken, kein zweiter Schritt, den man vergessen
könnte.

**Preis:** Die Domain wird zur Sicherheitsgrenze, sie muss also Helpdesk-Postfächern vorbehalten
bleiben und sonst nichts enthalten. Wer dort ein Postfach anlegt, gewährt dem Plugin Zugriff –
möglicherweise ohne es zu bemerken –, und es gibt kein Abwählen einzelner Postfächer. Außerdem
ist die Domain sichtbar: Kunden sehen sie in der Antwortadresse.

---

## Später die Variante wechseln

Ein häufiger Weg ist, mit `EmailList` für die ersten ein, zwei Projekte zu beginnen und auf
`CustomAttribute` zu wechseln, sobald die Zahl der Projekte den Administrator-Engpass spürbar
macht. Das Skript beherrscht das – es schreibt den Filter des bestehenden Scopes um und lässt
App-Registrierung, Client-Secret und Rollenzuweisungen unangetastet:

```powershell
# die heute im Scope enthaltenen Postfächer kennzeichnen
Set-Mailbox -Identity "helpdesk@example.com" -CustomAttribute1 "Redmine"
Set-Mailbox -Identity "sales@example.com"    -CustomAttribute1 "Redmine"

# Filteränderung erst ansehen, dann anwenden
./setup-azure-app.ps1 -MailboxScopeOption CustomAttribute `
    -MailboxCustomAttributeValue "Redmine" -TestMailbox "helpdesk@example.com" -WhatIf
```

Die Postfächer **vor** dem Filterwechsel kennzeichnen – sobald der Scope wechselt, fällt jedes
Postfach ohne das Attribut heraus und sein Mailabruf beginnt zu scheitern.

---

## Benötigte Rollen

| Aufgabe | Rolle |
|---|---|
| App registrieren, Client-Secret anlegen | Anwendungsadministrator oder Cloudanwendungsadministrator (Entra ID) |
| Graph-Anwendungsberechtigungen erteilen | Dieselbe; die Administratorzustimmung für Microsoft-Graph-App-Rollen kann je nach Tenant-Konfiguration zusätzlich Privilegierter Rollenadministrator oder Globaler Administrator erfordern |
| EXO-Service-Principal, Scope und Rollenzuweisungen anlegen | Exchange-Administrator (Rolle `Role Management`, Teil von Organization Management) |
| Danach ein Postfach aufnehmen | Hängt vollständig von der gewählten Variante ab – siehe Tabelle oben |

Benötigte PowerShell-Module: `Microsoft.Graph` und `ExchangeOnlineManagement`.

---

## Befehlsübersicht

```powershell
# Jede Scope-Änderung vorab ansehen: zeigt alten Filter, neuen Filter, aufgenommene und entfernte Adressen
./setup-azure-app.ps1 -MailboxEmailList "sales@example.com" -WhatIf

# Postfach aufnehmen / entfernen (Variante EmailList)
./setup-azure-app.ps1 -MailboxEmailList "sales@example.com"
./setup-azure-app.ps1 -RemoveMailboxEmailList "sales@example.com"

# Scope auf genau diese Liste setzen, unabhängig vom aktuellen Inhalt
./setup-azure-app.ps1 -MailboxEmailList "helpdesk@example.com" -ReplaceMailboxList

# Client-Secret erneuern (der neue Wert muss in Redmine eingetragen werden)
./setup-azure-app.ps1 -NewClientSecret

# Die Filter-Zusammenführung offline prüfen – ohne Verbindung, ohne Änderung
./setup-azure-app.ps1 -SelfTest

# Vollständiger Rückbau
./delete-app-registration.ps1
```

`Get-Help ./setup-azure-app.ps1 -Detailed` dokumentiert jeden Parameter (englisch).

Das Skript vergibt Zugriff auf Postfächer, es **legt sie nicht an**. Die Postfächer müssen bereits
im Tenant vorhanden sein.

---

## Fehlersuche

**`InScope: False` direkt nach einer Änderung.** Für einige Minuten zu erwarten – Exchange Online
braucht Zeit, bis eine RBAC-Änderung repliziert ist. Das Skript wiederholt die Prüfung bereits
mehrfach, bevor es einen Fehler meldet. `-RemoveEntraGraphPermissions` erst ausführen, wenn `True`
gemeldet wird.

**„The existing scope filter is not a plain mailbox address list“.** Der Scope wurde mit einer
anderen `-MailboxScopeOption` angelegt (oder von Hand bearbeitet); eine Adresse hineinzumischen
würde diesen Filter zerstören. Entweder das Postfach so aufnehmen, wie es die gewählte Variante
vorsieht (Attribut, Gruppenmitgliedschaft, Domain), oder mit `-ReplaceMailboxList` den Filter
bewusst überschreiben.

**„Multiple app registrations named …“.** Jede spätere Suche über den Anzeigenamen wäre mehrdeutig.
Die überzähligen Registrierungen mit `delete-app-registration.ps1` entfernen oder einen anderen
`-AppDisplayName` verwenden.

**`Connect-MgGraph` scheitert mit „Method not found: …WithLogging“.** Das Modul
`ExchangeOnlineManagement` lädt ein älteres `Microsoft.Identity.Client`, das das Graph-SDK danach
unbrauchbar macht. Eine frische PowerShell-Sitzung starten; beide Skripte sind genau deshalb so
angeordnet, dass alle Graph-Arbeiten vor der Verbindung zu Exchange Online stattfinden.

**Das Postfach ist im Scope, Redmine scheitert trotzdem.** Der RBAC-Scope ist nur die halbe Miete –
prüfen, ob Tenant-ID, Client-ID und Client-Secret unter *Administration → Plugins → Redmine expert
Helpdesk* eingetragen sind und ob das Client-Secret noch gültig ist (`-NewClientSecret` stellt ein
neues aus).
