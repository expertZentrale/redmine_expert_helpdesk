# Changelog – redmine_expert_helpdesk

> 🇬🇧 English version · [Deutsche Version](CHANGELOG.de.md)
>
> This English changelog starts fresh on 2026-07-24. Entries predating it live only in the German
> `CHANGELOG.de.md`. From here on, every change is recorded in **both** files (EN authoritative —
> GitHub release notes are generated from this file).

## [Unreleased] 2026-07-24 (85)

### Added
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
