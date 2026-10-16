# Email flow – redmine_expert_helpdesk

> 🇬🇧 English version · [Deutsche Version](EMAIL_FLOW.de.md)

How a mail travels through the helpdesk: from the mailbox into a ticket, and from the ticket back
to the customer. Every diagram names the settings that change its path, and the
[settings reference](#8-settings-reference) at the end lists all of them with the place they are
configured.

**How to read the diagrams**: rounded boxes are steps, diamonds are decisions, and the label next
to a step names the setting that controls it (*in italics*). Colours mark where a mail ends up:

```mermaid
flowchart LR
  N([New ticket]):::new
  R([Note on an existing ticket]):::reply
  S[(Skipped folder)]:::skip
  F[(Failed folder)]:::fail
  classDef new fill:#d8efe1,stroke:#1f7a4d,color:#10301f
  classDef reply fill:#dbe7f5,stroke:#2f5d8a,color:#13283d
  classDef skip fill:#f6ead6,stroke:#9a6412,color:#3d2806
  classDef fail fill:#f8e4e2,stroke:#b23a3a,color:#3d1414
```

## Contents

1. [The big picture](#1-the-big-picture)
2. [Fetching](#2-fetching)
3. [Filters: is the mail processed at all?](#3-filters-is-the-mail-processed-at-all)
4. [Reply or new ticket?](#4-reply-or-new-ticket)
5. [What happens to the ticket](#5-what-happens-to-the-ticket)
6. [One mail, several projects](#6-one-mail-several-projects)
7. [Outgoing mail](#7-outgoing-mail)
8. [Settings reference](#8-settings-reference)

---

## 1. The big picture

A mailbox belongs to exactly one project. Fetching reads its source folder, every message runs
through the same pipeline, and the message is moved to one of three folders afterwards. Replies
written in Redmine leave through the mailbox's outgoing route, and the customer's answer arrives
in the source folder again.

```mermaid
flowchart LR
  T["Fetch trigger<br/>button or cron"] --> MB["Mailbox<br/>(one project)"]
  MB --> P["Pipeline<br/>sections 3 to 5"]
  P --> N([Ticket or note]):::new
  P --> S[(Skipped folder)]:::skip
  P --> F[(Failed folder)]:::fail
  N --> A["Agent replies<br/>in Redmine"]
  A --> O["Outgoing route<br/>section 7"]
  O --> C["Customer"]
  C -- answers --> MB
  classDef new fill:#d8efe1,stroke:#1f7a4d,color:#10301f
  classDef skip fill:#f6ead6,stroke:#9a6412,color:#3d2806
  classDef fail fill:#f8e4e2,stroke:#b23a3a,color:#3d1414
```

---

## 2. Fetching

There is no scheduler inside the plugin. A fetch starts from the button in the project settings or
from the cron endpoint `GET /helpdesk/fetch_all?key=…`, which also runs the SLA breach check and
the phishing feed sync.

```mermaid
flowchart TD
  T["Fetch button<br/>or /helpdesk/fetch_all"] --> M{"Fetching paused?<br/><i>Pause mail fetching</i>"}
  M -- yes --> X["Nothing is fetched"]
  M -- no --> L["For every mailbox that is enabled,<br/>in an active project with the Helpdesk module"]
  L --> Q["Read up to 25 messages from the source folder<br/><i>Source folder</i><br/><i>Only fetch unread mails</i> (IMAP)"]
  Q --> E["Process each message<br/>sections 3 to 5"]
  E --> W{"Fetching paused<br/>in the meantime?"}
  W -- yes --> STOP["Finish the current message,<br/>leave the rest for the next fetch"]
  W -- no --> E
```

- **IMAP** reads all messages of the source folder, or only unread ones when *Only fetch unread
  mails* is set. Microsoft Graph always reads unread messages only.
- A processed mail is marked as read and moved, so it is never picked up twice.

---

## 3. Filters: is the mail processed at all?

Before a ticket is touched, five checks can send a mail straight to the skipped folder. They run in
this order, cheapest first.

```mermaid
flowchart TD
  IN["Message from the source folder"] --> B{"Sender allowed?<br/><i>Whitelist</i> / <i>Blacklist</i>"}
  B -- no --> S[(Skipped folder)]:::skip
  B -- yes --> R{"An automation rule with<br/>action Ignore mail matches?<br/><i>Automation rules</i>"}
  R -- yes --> S
  R -- no --> D{"This project already<br/>received this Message-ID?"}
  D -- yes --> S
  D -- no --> AR{"Automatic reply?<br/><i>Auto-reply filter enabled</i><br/><i>Sender / Header exceptions</i>"}
  AR -- yes --> S
  AR -- no --> PH{"Phishing hit?<br/><i>PhishTank integration</i> (central)<br/><i>Phishing check</i> (project)"}
  PH -- "hit, Quarantine mail" --> S
  PH -- "hit, Neutralize links" --> NZ["Links rewritten,<br/>note added later"]
  PH -- no hit --> NEXT["Continue with section 4"]
  NZ --> NEXT
  classDef skip fill:#f6ead6,stroke:#9a6412,color:#3d2806
```

- **Whitelist / Blacklist**: one address or domain per line. A filled whitelist admits *only* its
  senders; the blacklist then removes senders from what is left.
- **Already received**: the same mail reaching two mailboxes of one project (To and Cc) is processed
  once. Another project receiving it is not a duplicate, see [section 6](#6-one-mail-several-projects).
- **Auto-reply filter**: out-of-office and similar mails are recognised by their headers.
  Bounce messages (NDRs) are never filtered, because a failed delivery is something an agent needs
  to see.
- **Skipped folder** falls back to the processed folder when empty. When both are empty the mail
  stays in the source folder and is only marked as read.

---

## 4. Reply or new ticket?

The plugin hands the mail to Redmine's own `MailHandler`, which makes the final decision. Before
that, the plugin adjusts the mail's *thread markers*, the parts of a mail that say which ticket it
belongs to:

| Marker | Where | Example |
| --- | --- | --- |
| Ticket tag | Subject | `Re: [#123] Printer broken`, `[Project - Bug #123]` |
| Redmine notification ID | `In-Reply-To` / `References` | `<redmine.issue-123.20261014…@example.com>` |
| Logged helpdesk Message-ID | `In-Reply-To` / `References` | ID of a customer mail or an agent reply the helpdesk stored |
| Forum reply tag | Subject | `Re: [Board - msg45] …` — always removed, a helpdesk mailbox never posts into a forum |

```mermaid
flowchart TD
  IN["Mail after the filters"] --> SW{"<i>Match replies only within<br/>the mailbox's project</i> on?"}
  SW -- yes --> SC["Remove markers that point at a ticket<br/>of ANOTHER project, or at no ticket<br/>(subprojects count as other projects)"]
  SW -- "no (default)" --> AGE
  SC --> AGE{"Referenced ticket of this project<br/>is closed and older than the limit?<br/><i>Max. age (days)</i>"}
  AGE -- yes --> STRIP["Remove all markers"]
  AGE -- no --> TAG{"Mail answers a logged helpdesk mail<br/>but the subject has no ticket tag?"}
  TAG -- yes --> ADD["Add the ticket tag to the subject"]
  TAG -- no --> MH
  ADD --> MH
  STRIP --> MH{"Redmine MailHandler:<br/>marker of an existing ticket found?"}
  MH -- yes --> RE([Note on that ticket]):::reply
  MH -- no --> NEW(["New ticket in the mailbox's project<br/><i>Defaults for new tickets</i>"]):::new
  MH -- "rejected<br/><i>Unknown senders: Ignore</i>" --> S[(Skipped folder)]:::skip
  classDef new fill:#d8efe1,stroke:#1f7a4d,color:#10301f
  classDef reply fill:#dbe7f5,stroke:#2f5d8a,color:#13283d
  classDef skip fill:#f6ead6,stroke:#9a6412,color:#3d2806
```

- **Only the mailbox's own project** (experimental, off by default). Without this step,
  `MailHandler` follows a marker into any project, and anyone who knows a ticket number can write
  into that ticket — that is how it behaves while the switch is off. Markers of the own project are
  kept, so the customer's ordinary reply still finds its ticket. A ticket opened through this
  mailbox and moved to another project since counts as the own project too. A subject naming more
  than 20 ticket numbers, nested more than five levels or longer than 998 characters loses all of
  its tags and brackets, and `In-Reply-To`/`References` with more than 50
  message ids are dropped. The `.eml` attached to
  the ticket keeps the subject and headers exactly as received.
- **Max. age (days)** forces a new ticket for an answer to a ticket that was closed long ago. `0`
  or empty turns the limit off.
- **Unknown senders** decides what `MailHandler` does with an address that has no Redmine account:
  *Accept (anonymous)*, *Create user account*, or *Ignore* (the mail is skipped).
- `MailHandler` also rejects mails from Redmine's own *Emission email address*, and applies Redmine's
  *Incoming emails* settings (*Truncate emails after one of these lines*, *Exclude attachments by
  name*).

---

## 5. What happens to the ticket

After `MailHandler` has created the ticket or the note, the plugin finishes the job. The two
branches differ only at the start.

```mermaid
flowchart TD
  NEW(["New ticket"]):::new --> AS["Default assignee, if MailHandler set none<br/><i>Assign new tickets to</i> (project)"]
  AS --> RU["Automation rules in their order<br/><i>Automation rules</i>: priority, tracker,<br/>category, assignee"]
  RE([Note on a ticket]):::reply --> ST{"Ticket closed?"}
  ST -- yes --> RS["Status for a reply to a closed ticket<br/><i>Status (closed issue)</i>"]
  ST -- no --> OS["Status for a reply to an open ticket<br/><i>Status (open issue)</i>"]
  RS --> AW["Flag: waiting for an answer<br/><i>Mark tickets awaiting a response</i>"]
  OS --> AW
  RU --> COM
  AW --> COM["Show embedded images, drop blocked<br/>attachments <i>Show embedded images</i>, <i>Blocked attachments</i>"]
  COM --> CT["Link the contact, attach the original mail as .eml"]
  CT --> REL["Relate to tickets of other projects<br/>see section 6"]
  REL --> AU{"New ticket?"}
  AU -- yes --> AR["Autoresponder<br/><i>Autoresponder enabled</i>"]
  AU -- no --> PN
  AR --> PN["Phishing note, if links were rewritten"]
  PN --> AI["AI summary, in the background<br/>replies only if the project includes them<br/><i>AI summaries</i> (central + project)"]
  AI --> CC["Completeness check, new tickets only<br/><i>Completeness check</i> (central + project)"]
  CC --> DONE[(Processed folder)]
  classDef new fill:#d8efe1,stroke:#1f7a4d,color:#10301f
  classDef reply fill:#dbe7f5,stroke:#2f5d8a,color:#13283d
```

- **Status on a reply**: either status left empty means the ticket's status stays as it is. A
  closed ticket that ends up in an open status counts as *reopened*.
- **Waiting for an answer** is not set when the mail was written by an agent.
- **AI summary** runs for new tickets, and for replies only when the project's scope includes them.
  The **completeness check** runs for new tickets only. Both run in the background and never stop
  the fetch.
- **Any error** in this pipeline moves the mail to the **failed folder** and the fetch continues
  with the next message. The error is shown on the mailbox (*last error*).

---

## 6. One mail, several projects

Customers often write to several helpdesk addresses at once (To, Cc or Bcc), and colleagues in one
project may not know that another project is involved. With *Match replies only within the
mailbox's project* on, each mailbox handles its copy for its own project only. Everything in this
section applies only then; while it is off, every copy follows its markers into the referenced
ticket, as before.

```mermaid
flowchart LR
  M["One mail<br/>To: helpdesk-a@… Cc: helpdesk-b@…<br/>Subject: Re: [#123] Printer"] --> MA["Mailbox of project A"]
  M --> MB["Mailbox of project B"]
  MA --> A1(["#123 in A gets a note<br/>tag belongs to A, kept"]):::reply
  MB --> SB["Tag #123 belongs to A:<br/>removed"]
  SB --> B1(["New ticket in B"]):::new
  B1 <-. "related to<br/><i>Allow cross-project issue relations</i>" .-> A1
  classDef new fill:#d8efe1,stroke:#1f7a4d,color:#10301f
  classDef reply fill:#dbe7f5,stroke:#2f5d8a,color:#13283d
```

| Situation | Result |
| --- | --- |
| Customer writes to A and B | One ticket in A, one in B, related to each other |
| Mail to B quoting `[#123]` of project A | New ticket in B, related to #123 |
| Answer to an A conversation, sent to B | New ticket in B, related to the A ticket |
| Agent of A replies with B's address in Cc | New ticket in B; nothing comes back into A |
| Stranger quotes a ticket of a project without Helpdesk | New ticket, no relation |
| Same mail reaches two mailboxes of one project | One ticket; the second copy is skipped |

**How the projects learn about each other**

- **Relation *related to***: added without a history entry or notification. Redmine shows it only to
  users who may see both tickets. A removed ticket tag only leads to a relation when that ticket's
  project has the Helpdesk module, because anyone can type a ticket number into a subject. Needs
  Redmine's *Allow cross-project issue relations*; without it the tickets are created but not
  linked.
- **Sidebar *Also received by***: the other helpdesk addresses from To and Cc. The project name
  appears only for viewers who may see that project. Mailboxes reached by Bcc stay invisible.

---

## 7. Outgoing mail

Four kinds of mail leave the helpdesk, and all of them take the mailbox's outgoing route:

| Mail | Triggered by |
| --- | --- |
| Agent reply | *Reply* on the ticket page |
| Initial mail | Assigning a contact to a ticket, or *New helpdesk ticket* |
| Autoresponder | A new ticket, when *Autoresponder enabled* |
| Completeness follow-up | The completeness check finding the first mail incomplete |

```mermaid
flowchart TD
  OUT["Agent reply, initial mail,<br/>autoresponder, follow-up"] --> SV{"<i>Send via</i>"}
  SV -- "Mailbox backend" --> PR{"Mailbox type"}
  PR -- IMAP --> MS["Mailbox's own SMTP server"]
  PR -- "Microsoft Graph" --> GR["Microsoft Graph sendMail"]
  SV -- "Microsoft Graph API" --> GR
  SV -- "SMTP (Redmine default)" --> RS["Redmine's global SMTP<br/><i>Sender override (From)</i><br/><i>Set Reply-To to the mailbox address</i>"]
  GR --> SENT1["Exchange files the Sent copy itself"]
  MS --> SENT2["IMAP mailboxes: copy into the Sent folder<br/><i>Sent folder</i>"]
  RS --> SENT2
  SENT1 --> C["Customer"]
  SENT2 --> C
```

- ***Send via* Microsoft Graph API** is only offered for a Graph mailbox, or an IMAP mailbox on
  Microsoft 365 when the central app registration is configured.
- **SMTP (Redmine default)** embeds inline images as data URIs. The other two routes send them as attachments
  referenced from the HTML.

**How the customer's answer finds its ticket again**

```mermaid
flowchart LR
  R["Agent reply<br/>Subject: <i>Subject template</i><br/>default Re: [#123] …"] --> LOG["Its Message-ID is logged<br/>on the ticket"]
  LOG --> C["Customer answers"]
  C --> T1{"Subject still<br/>has the tag?"}
  T1 -- yes --> M([Note on #123]):::reply
  T1 -- "no, but In-Reply-To<br/>names the logged ID" --> M
  classDef reply fill:#dbe7f5,stroke:#2f5d8a,color:#13283d
```

- The **subject template** of the project settings builds the subject; the default carries the
  ticket tag. A template without `{{issue.id}}` still works, because the reply's Message-ID is
  stored and the customer's mail client sends it back in `In-Reply-To`.
- The **autoresponder** refers to the customer's first mail (`In-Reply-To`), so an answer to it lands
  on the ticket as well.
- **Header** and **footer** of the mailbox frame the reply text. *Footer mode* decides between the
  mailbox footer and the central footer.
- Outgoing mails keep their markers even when another project's helpdesk address is a recipient.
  That project's mailbox removes them on arrival ([section 6](#6-one-mail-several-projects)).

### Hand-over instead of mail (experimental)

When an agent addresses another project's helpdesk mailbox in a reply, the mail would travel out
through SMTP and come back in through that mailbox. With the hand-over switched on, the ticket is
created in the other project directly and that address gets no mail.

```mermaid
flowchart TD
  R["Agent writes a reply<br/>To / Cc / Bcc contains helpdesk-b@…"] --> E{"Hand-over active for both projects?<br/><i>Enable hand-over to other projects</i> (central)<br/><i>Take part in hand-overs</i> (project A and B)"}
  E -- no --> MAIL["Ordinary recipient:<br/>mailed, becomes a ticket in B on arrival"]
  E -- yes --> ASK{"Agent chooses<br/>(nothing preselected)"}
  ASK -- "Only this note" --> N1(["New ticket in B:<br/>note + attachments sent with it"]):::new
  ASK -- "Complete history" --> N2(["New ticket in B:<br/>note + description + public notes<br/>+ all attachments"]):::new
  N1 --> LINK["Related to A's ticket (not when Bcc only), customer<br/>linked as B's contact, line added to A's note"]
  N2 --> LINK
  LINK --> REST{"Other recipients left?"}
  REST -- yes --> SEND["Mail to them, without B's address"]
  REST -- no --> DONE["No mail at all"]
  classDef new fill:#d8efe1,stroke:#1f7a4d,color:#10301f
```

- **Both projects have to take part.** The central switch makes the option visible in the project
  settings; each project then decides for itself whether it hands over and accepts hand-overs.
- **Private notes stay behind** in the complete history: they were written for the source team.
- The ticket in B is authored by the agent and gets the mailbox's *Defaults for new tickets* and B's
  *Assign new tickets to* (else Redmine's project default). Only projects the agent can see are
  hand-over targets; any other project's address is mailed as before. The same customer becomes B's contact, so B can answer them from its ticket.
- **Several recipients**: every participating project named in To, Cc or Bcc gets one ticket,
  even when two of its mailboxes are named. Everybody else is mailed as before; when only
  hand-over addresses were in To, the Cc moves up to To. If only Bcc recipients would be left, the
  reply is refused before anything is handed over. A To cleared on purpose stays empty: with only
  B's address in Cc, nothing is mailed, not even to the customer.
- **If the mail to the remaining recipients fails**, the ticket in B is removed again, so sending
  once more does not create it twice — unless someone in B has already worked on it (an edit, a
  note, booked time): then it stays, and the error names it, so the agent leaves B's address out
  when sending again. Once the mail is out, the ticket stays even if recording the
  reply fails afterwards; the agent is told not to send again. B's notification about the new
  ticket goes out only then, never for a hand-over that is taken back.
- Ticket images the note quotes go along even when their checkbox is not ticked; image references
  in the copied text point at the copies. A project reached by Bcc only is named in the source
  note only when that note is private, and its ticket is not related to the source ticket.
- **Text from an AI draft** (the reply note, or notes in the complete history) goes over as a note
  of its own, marked as AI-drafted, with a placeholder in the description: the target's knowledge
  base and answer drafts leave it out, as they do on the source.
- Nothing about the new ticket is announced before the hand-over is final: no notification, and
  with a closed default status no knowledge-base entry.

#### In the initial mail

The initial mail — *New Helpdesk Ticket*, and *Assign Contact* on a ticket without a customer —
hands over the same way, but there is nothing to choose: a new ticket has no notes yet, so the
other project gets what the mail would have carried.

```mermaid
flowchart TD
  I["Agent ticks <i>Send as e-mail to customer</i><br/>To / Cc / Bcc contains helpdesk-b@…"] --> E{"Hand-over active for both projects?"}
  E -- no --> MAIL["Ordinary recipient: mailed"]
  E -- yes --> OUT["B's address leaves the mail"]
  OUT --> TO{"Anybody left in To?"}
  TO -- yes --> OK["First To address becomes the customer"]
  TO -- "no, but Cc" --> MOVE{"<i>Move the first Cc recipient to To</i> ticked?"}
  MOVE -- yes --> OK
  MOVE -- no --> STOP["Form blocks saving:<br/>nothing mailed, nothing handed over"]
  TO -- "no, only Bcc" --> STOP
  TO -- "nobody at all" --> ONLY["No mail, no customer"]
  OK --> N(["New ticket in B:<br/>subject, text, all attachments"]):::new
  ONLY --> N
  N --> SEND["Mail to the remaining recipients;<br/>note in A names B's ticket"]
  classDef new fill:#d8efe1,stroke:#1f7a4d,color:#10301f
```

- **The form says what will happen** while the agent types: which projects get the ticket, who
  becomes the customer, and a warning as soon as nobody is left in To. Saving is blocked only where
  the mail could not go out as shown.
- **If the mail fails**, the hand-over stays — the ticket exists either way, and nobody is asked to
  send again. The ticket page names both: the mail error and the tickets that were created.
- Without the mail (*Send as e-mail to customer* unticked) nothing is handed over; the To address
  is only linked as the customer, as before.

---

## 8. Settings reference

**Where to find them**

- **Central**: *Administration → Plugins → Redmine expert Helpdesk → Configure*
- **Project**: *Project → Settings → Helpdesk*
- **Mailbox**: *Project → Settings → Helpdesk → Mailboxes → (mailbox)*
- **Redmine**: *Administration → Settings*

| Setting | Where | Effect | Section |
| --- | --- | --- | --- |
| Pause mail fetching | Central | Blocks every fetch (maintenance mode) | [2](#2-fetching) |
| Enabled | Mailbox | Mailbox is fetched at all | [2](#2-fetching) |
| Source folder | Mailbox | Folder the mails are read from | [2](#2-fetching) |
| Only fetch unread mails | Mailbox (IMAP) | Read unread mails only instead of all | [2](#2-fetching) |
| Processed / Skipped / Failed folder | Mailbox | Where a mail is moved afterwards | [3](#3-filters-is-the-mail-processed-at-all), [5](#5-what-happens-to-the-ticket) |
| Whitelist / Blacklist | Mailbox | Senders that are processed / skipped | [3](#3-filters-is-the-mail-processed-at-all) |
| Automation rules, action *Ignore mail* | Mailbox | Skip mails by subject or sender | [3](#3-filters-is-the-mail-processed-at-all) |
| Auto-reply filter enabled, Sender / Header exceptions | Mailbox | Skip out-of-office and similar mails | [3](#3-filters-is-the-mail-processed-at-all) |
| Enable PhishTank integration | Central | Phishing feeds are mirrored and checked | [3](#3-filters-is-the-mail-processed-at-all) |
| Enable phishing check for this project, Action on phishing hit | Project | Check links; *Quarantine mail* skips, *Neutralize links* rewrites | [3](#3-filters-is-the-mail-processed-at-all) |
| Max. age (days) | Mailbox | Answer to a long-closed ticket becomes a new ticket | [4](#4-reply-or-new-ticket) |
| Unknown senders | Mailbox | *Accept*, *Create user account* or *Ignore* | [4](#4-reply-or-new-ticket) |
| Defaults for new tickets (tracker, priority, status) | Mailbox | Attributes of a new ticket | [4](#4-reply-or-new-ticket) |
| Suppress Redmine notifications | Mailbox | No Redmine notification mails for created tickets and notes | [4](#4-reply-or-new-ticket) |
| Assign new tickets to | Project | Assignee of a new ticket (user or group) | [5](#5-what-happens-to-the-ticket) |
| Automation rules (priority, tracker, category, assignee) | Mailbox | Change a new ticket by subject or sender | [5](#5-what-happens-to-the-ticket) |
| Status (closed issue) / Status (open issue) | Mailbox | Status after a customer reply | [5](#5-what-happens-to-the-ticket) |
| Mark tickets awaiting a response | Central | Flag tickets with an unanswered customer reply | [5](#5-what-happens-to-the-ticket) |
| Show embedded images in the ticket | Central | Embedded images appear in the ticket text instead of `[cid:…]` markers | [5](#5-what-happens-to-the-ticket) |
| Blocked attachments | Project, entries added from the ticket page | Drop known logos and tracking pixels | [5](#5-what-happens-to-the-ticket) |
| Autoresponder enabled, subject, body | Mailbox | Confirmation mail for a new ticket | [5](#5-what-happens-to-the-ticket), [7](#7-outgoing-mail) |
| Enable AI summaries, Generate AI summaries for this project | Central + project | Summary note in the background | [5](#5-what-happens-to-the-ticket) |
| Enable completeness check, Mode | Central + project | Follow-up mail when the first mail lacks information | [5](#5-what-happens-to-the-ticket), [7](#7-outgoing-mail) |
| Match replies only within the mailbox's project | Central, *Experimental* | A mail only continues tickets of the receiving mailbox's project; foreign markers are removed, the tickets related | [4](#4-reply-or-new-ticket), [6](#6-one-mail-several-projects) |
| Allow cross-project issue relations | Redmine, *Issue tracking* | Tickets of different projects can be related | [6](#6-one-mail-several-projects) |
| Send via | Mailbox | Outgoing route: *Mailbox backend*, *Microsoft Graph API* or *SMTP (Redmine default)* | [7](#7-outgoing-mail) |
| Sender override (From), Set Reply-To to the mailbox address | Mailbox (SMTP route) | Sender address when sending via *SMTP (Redmine default)* | [7](#7-outgoing-mail) |
| Enable hand-over to other projects | Central, *Experimental* | Experimental: hand-over instead of mail becomes available | [7](#hand-over-instead-of-mail-experimental) |
| Take part in hand-overs | Project, *Experimental* | This project hands over and accepts hand-overs | [7](#hand-over-instead-of-mail-experimental) |
| Sent folder | Mailbox (IMAP) | Where the copy of a sent mail is filed | [7](#7-outgoing-mail) |
| Subject template | Project | Subject of agent replies | [7](#7-outgoing-mail) |
| Header, Footer, Footer mode | Mailbox (+ central footer) | Frame around the reply text | [7](#7-outgoing-mail) |
| Emission email address | Redmine, *Email notifications* | Mails from this address are rejected | [4](#4-reply-or-new-ticket) |
| Truncate emails after one of these lines, Exclude attachments by name | Redmine, *Incoming emails* | Applied by `MailHandler` to every mail | [4](#4-reply-or-new-ticket) |
