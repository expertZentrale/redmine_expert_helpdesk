# redmine.org plugin directory

Copy-paste sources for the plugin's listing at
<https://www.redmine.org/plugins/redmine_expert_helpdesk>.

The directory renders **Textile**, not Markdown — headings are `h3.`, bold is
`*text*`, inline code is `@code@`, links are `"label":url`. Everything here is
written in Textile so it can be pasted straight into the form without editing.

| File | Pastes into |
|------|-------------|
| `description.textile` | the plugin's **Description** field — always describes the current version |
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
3. After pushing the tag, register the version at
   <https://www.redmine.org/plugins/redmine_expert_helpdesk> and paste both
   files in.

The description drifting is the failure mode worth guarding against: 0.1.6 still
advertised "only Microsoft O365 is supported" after 0.2.0 had added generic
IMAP/SMTP.
