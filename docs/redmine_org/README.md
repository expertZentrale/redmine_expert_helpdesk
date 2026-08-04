# redmine.org plugin directory

Copy-paste sources for the plugin's listing at
<https://www.redmine.org/plugins/redmine_expert_helpdesk>.

The directory renders **Textile**, not Markdown — headings are `h3.`, bold is
`*text*`, inline code is `@code@`, links are `"label":url`. Everything here is
written in Textile so it can be pasted straight into the form without editing.

The directory keeps the description and the installation notes in **separate
fields**, so they are separate files here — don't merge them.

| File | Pastes into |
|------|-------------|
| `description.textile` | the **Description** field — what the plugin is and does, current version |
| `installation.textile` | the **Installation notes** field — requirements, install, configure, schedule, upgrade, uninstall |
| `releases/<version>.textile` | the **Notes** field when registering that version |

`docs/` is excluded from the release archives (`--exclude='docs'` in
`.github/workflows/release.yml`), so none of this ships to users.

## When cutting a release

1. Write `releases/<version>.textile` — user-facing changes only. The CHANGELOG
   is the source, but this is not a copy of it: drop the internal detail, keep
   what an operator deciding whether to upgrade needs. Add an *Upgrade notes*
   section when migrations run or behaviour changes.
2. Update `description.textile` if the release changed what the plugin *is* or
   *supports* — new backends, new requirements, dropped limitations. Bump the
   Redmine versions under *Requirements* if they moved.
3. Update `installation.textile` if the release changed a step: a new migration
   requirement, a new permission or setting, a changed endpoint, a new gem.
4. After pushing the tag, register the version at
   <https://www.redmine.org/plugins/redmine_expert_helpdesk> and paste the
   files into their respective fields.

The description drifting is the failure mode worth guarding against: 0.1.6 still
advertised "only Microsoft O365 is supported" after 0.2.0 had added generic
IMAP/SMTP.
