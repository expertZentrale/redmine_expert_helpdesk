# Changelog – redmine_expert_helpdesk

> 🇬🇧 English version · [Deutsche Version](CHANGELOG.de.md)
>
> This English changelog starts fresh on 2026-07-24. Entries predating it live only in the German
> `CHANGELOG.de.md`. From here on, every change is recorded in **both** files (EN authoritative —
> GitHub release notes are generated from this file).

## [Unreleased] 2026-07-24 (85)

### Added
- **`LICENSE` file (GPL-2.0-or-later)** — the plugin is now explicitly licensed under the GNU
  General Public License v2 or later, matching Redmine itself. Adds a copyright/license header to
  `init.rb` and a **License** plus **Third-party components** section to `README.md` /
  `README.de.md` (documenting the bundled MIT-licensed Chart.js 4.4.6 and
  chartjs-plugin-datalabels 2.2.0, both served locally — no CDN request at runtime).
- **AI usage statistics** dashboard: a per-project **"AI statistics"** tab (mirroring the SLA
  dashboard — time-frame selector, at-a-glance totals, Chart.js visualisations) covering request
  volume, token usage, request-type/provider-model breakdown, success/failure, latency and busiest
  times. Backed by a new unified **AI request log** (`helpdesk_ai_requests`, migration 033) that
  records **every** AI call — summaries, KB extraction, embeddings and RAG retrieval — including
  failures (previously only logged) and embedding-token usage (previously discarded). Access is
  gated by a new **global** permission `view_helpdesk_ai_statistics` (grant it to a role, e.g.
  "ai-admin", to see the tab on all helpdesk projects). Tokens only — no cost/pricing yet.
- **Administration menu** entry ("expert Helpdesk", with a headset icon) that links directly to
  the plugin settings, so the configuration is reachable in one click from the Administration
  sidebar and the Administration index — instead of going via *Plugins → Configure*. The icon is
  version-aware: a plugin SVG-sprite icon on Redmine 6/7, the legacy `icon-*` CSS icon on Redmine 5
  (`init.rb`, `assets/images/icons.svg`).

### Fixed
- Issue list view: the JavaScript-injected **"Neues Helpdesk-Ticket"** button (next to "Neues Ticket")
  was rendered mangled under Redmine 7 — it still used the old `icon icon-*` CSS class, which Redmine 7
  removed, so no icon was supplied. Like the other JS-generated buttons, it now prepends the SVG sprite
  icon via `window.hdSpriteIcon('email')` (falling back to a plain label when unavailable)
  (`lib/redmine_expert_helpdesk/hooks.rb`).

### Changed
- **Documentation examples now use neutral placeholders**: the Microsoft Graph / Exchange setup
  snippets in `README.md`, `README.de.md` and `scripts/setup-azure-app.ps1` use
  `helpdesk.example.com` / `@example.com` throughout, and the development-workflow section of
  `CLAUDE.md` refers to the repository root relatively instead of by absolute path. This makes the
  examples copy-pasteable for any installation — `-MailboxDomainSuffix` / `-MailboxEmailList` are
  per-installation parameters and always had to be supplied. No functional change.
- **Screenshots in both READMEs**: `README.md` and `README.de.md` now open with a short gallery of
  the main screens (SLA statistics, AI statistics, customer list, ticket view) and carry inline
  screenshots in the customer, AI-summary and knowledge-base sections, so the plugin can be
  evaluated without installing it first. Images live in `docs/screenshots/{en,de}/` and are
  **excluded from the release archives** (`--exclude='docs'` in `.github/workflows/release.yml`),
  so the installable package does not grow.
- **New maintenance scripts** `scripts/seed_screenshot_demo.rb` and
  `scripts/teardown_screenshot_demo.rb` build and remove the synthetic demo project the
  screenshots are taken from (contacts, tickets with a realistic SLA mix, AI request log,
  knowledge-base entries). Both are scoped to a single project, write no global settings and are
  excluded from the release archives along with the rest of `scripts/`.
