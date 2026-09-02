# Simple template renderer for autoresponders, footers and agent reply
# templates.
#
# Macros are written as {{name}}. Two notations are accepted for the original
# seven macros: dot notation ({{issue.subject}}) and the legacy underscore
# notation ({{ticket_subject}}) used by older autoresponder templates.
#
# Resolution is lazy: only macros that actually appear in the template are
# evaluated, so a footer using {{issue.id}} never touches the issue's status,
# assignee or custom fields. Anything that cannot be resolved renders as an
# empty string.
#
# Issue custom fields are addressed either by id ({{issue.cf.42}}) or by the
# slugified field name ({{issue.cf.vertragsnummer}}). They are only expanded
# when the field is both admin-enabled for macros (plugin setting
# macro_custom_field_ids) and visible to the acting user — these templates end
# up in customer-facing mail, so an internal field must not leak through a
# shared template.
module RedmineExpertHelpdesk
  class TemplateRenderer
    extend Redmine::I18n

    # Letters, digits, underscore and dot — dot notation and cf slugs.
    MACRO_PATTERN = /\{\{([\w.]+)\}\}/

    # Legacy underscore notation kept working; maps onto the dot notation.
    LEGACY_ALIASES = {
      'ticket_id'      => 'issue.id',
      'ticket_subject' => 'issue.subject',
      'ticket_url'     => 'issue.url',
      'contact_name'   => 'contact.name',
      'contact_email'  => 'contact.email',
      'user_name'      => 'user.name',
      'project_name'   => 'project.name'
    }.freeze

    # Static macros, in the order they are offered as chips in the UI.
    # Each entry resolves from the render context; nil becomes ''.
    RESOLVERS = {
      'issue.id'           => ->(c) { c[:issue]&.id },
      'issue.subject'      => ->(c) { c[:issue]&.subject },
      'issue.url'          => ->(c) { c[:issue] ? issue_url(c[:issue]) : nil },
      'issue.status'       => ->(c) { c[:issue]&.status&.name },
      'issue.priority'     => ->(c) { c[:issue]&.priority&.name },
      'issue.tracker'      => ->(c) { c[:issue]&.tracker&.name },
      'issue.author'       => ->(c) { c[:issue]&.author&.name },
      'issue.assignee'     => ->(c) { c[:issue]&.assigned_to&.name },
      'issue.category'     => ->(c) { c[:issue]&.category&.name },
      'issue.version'      => ->(c) { c[:issue]&.fixed_version&.name },
      'issue.start_date'   => ->(c) { format_date(c[:issue]&.start_date) },
      'issue.due_date'     => ->(c) { format_date(c[:issue]&.due_date) },
      'issue.created_on'   => ->(c) { format_date(c[:issue]&.created_on) },
      'issue.updated_on'   => ->(c) { format_date(c[:issue]&.updated_on) },
      'issue.done_ratio'   => ->(c) { c[:issue] ? "#{c[:issue].done_ratio}%" : nil },
      'issue.description'  => ->(c) { c[:issue]&.description },
      'issue.parent_id'    => ->(c) { c[:issue]&.parent_id },

      'contact.name'       => ->(c) { c[:contact] ? c[:contact].display_name : c[:contact_name] },
      'contact.email'      => ->(c) { c[:contact] ? c[:contact].email : c[:contact_email] },

      # The acting agent — User.current at the point the reply is composed.
      'user.name'          => ->(c) { c[:user]&.name },
      'user.firstname'     => ->(c) { c[:user]&.firstname },
      'user.lastname'      => ->(c) { c[:user]&.lastname },
      'user.login'         => ->(c) { c[:user]&.login },
      'user.mail'          => ->(c) { c[:user]&.mail },

      'project.name'       => ->(c) { c[:issue]&.project&.name },
      'project.identifier' => ->(c) { c[:issue]&.project&.identifier }
    }.freeze

    # Macro names offered as clickable chips / listed in the settings hint.
    # Legacy aliases are deliberately not advertised any more; they keep
    # working for templates that already use them.
    def self.catalogue
      RESOLVERS.keys
    end

    def self.render(template, context = {})
      return '' if template.blank?

      # Per-render memo: a template may use the same value twice (often once in
      # dot and once in legacy notation), and each lookup can be a DB hit.
      # Keyed by the normalised name so {{user.name}} and {{user_name}} share
      # one entry.
      memo = {}
      # Separate from the memo and from the caller's context hash: distinct
      # {{issue.cf.*}} macros have distinct names, so the memo never spares
      # them the enabled-field lookup. Held here it happens once per render,
      # and the caller's hash is never written to.
      shared = {}
      template.gsub(MACRO_PATTERN) do
        name = LEGACY_ALIASES.fetch(Regexp.last_match(1), Regexp.last_match(1))
        memo.fetch(name) { memo[name] = resolve(name, context, shared) }.to_s
      end
    end

    # Resolves a single macro name. Returns nil for anything unknown, which the
    # caller turns into an empty string.
    # +shared+ is an optional per-render scratch hash; see .render. Callers
    # outside render may omit it and pay one query per custom-field macro.
    def self.resolve(name, context, shared = nil)
      name = LEGACY_ALIASES.fetch(name, name)

      if (cf_key = name[/\Aissue\.cf\.(.+)\z/, 1])
        return custom_field_value(context, cf_key, shared)
      end

      resolver = RESOLVERS[name]
      return nil if resolver.nil?

      # Guarded: a nil association, a stubbed test double or a field the
      # current user may not read must render empty, never raise mid-mail.
      begin
        instance_exec(context, &resolver)
      rescue StandardError
        nil
      end
    end

    # Issue custom fields opted in by an admin, as an id => field lookup.
    def self.macro_custom_fields
      ids = macro_custom_field_ids
      return {} if ids.empty?

      IssueCustomField.where(:id => ids).index_by(&:id)
    rescue StandardError
      {}
    end

    def self.macro_custom_field_ids
      raw = Setting.plugin_redmine_expert_helpdesk['macro_custom_field_ids']
      # Checkboxes post an array, the plugin default and older installs hold a
      # comma-separated string — accept both.
      values = raw.is_a?(Array) ? raw : raw.to_s.split(',')
      values.map { |v| v.to_s.strip.to_i }.reject(&:zero?)
    rescue StandardError
      []
    end

    # Umlauts spelled out the German way before anything is stripped: field
    # names here are German, and folding "Zustaendigkeit" to "zust_ndigkeit"
    # would make the macro unreadable and near-impossible to guess.
    TRANSLITERATIONS = { 'ä' => 'ae', 'ö' => 'oe', 'ü' => 'ue', 'ß' => 'ss' }.freeze

    # Slug used to address a custom field by name: lowercased, umlauts spelled
    # out, remaining accents folded, every run of other characters collapsed to
    # a single underscore.
    def self.slugify(name)
      slug = name.to_s.downcase.gsub(/[äöüß]/) { |c| TRANSLITERATIONS[c] }
      slug = begin
               I18n.transliterate(slug)
             rescue StandardError
               slug
             end
      slug.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
    end

    def self.custom_field_value(context, key, shared = nil)
      issue = context[:issue]
      return nil if issue.nil?

      fields = if shared
                 shared.fetch(:macro_custom_fields) { shared[:macro_custom_fields] = macro_custom_fields }
               else
                 macro_custom_fields
               end
      return nil if fields.empty?

      # Numeric key addresses by id, anything else by slugified name. An id
      # never collides with a slug, so both notations can coexist.
      field = if key =~ /\A\d+\z/
                fields[key.to_i]
              else
                fields.values.find { |cf| slugify(cf.name) == key }
              end
      return nil if field.nil?
      return nil unless custom_field_visible?(field, issue, context[:user])

      format_custom_value(field, issue)
    rescue StandardError
      nil
    end

    # Admin opt-in is already implied by macro_custom_fields; this adds
    # Redmine's own role-based visibility on top, evaluated for the agent
    # composing the reply.
    def self.custom_field_visible?(field, issue, user)
      return true unless field.respond_to?(:visible_by?)

      field.visible_by?(issue.project, user || User.current)
    rescue StandardError
      false
    end

    def self.format_custom_value(field, issue)
      value = issue.custom_field_value(field)
      return nil if value.nil?

      cast = begin
        field.format.cast_value(field, value)
      rescue StandardError
        value
      end

      stringify(cast)
    end

    def self.stringify(value)
      case value
      when nil            then nil
      when Array          then value.map { |v| stringify(v) }.reject(&:blank?).join(', ')
      when true           then l(:general_text_Yes)
      when false          then l(:general_text_No)
      when Date, Time     then format_date(value)
      else value.to_s
      end
    end

    def self.issue_url(issue)
      host = Setting.host_name.to_s.sub(%r{/+$}, '')
      "#{Setting.protocol}://#{host}/issues/#{issue.id}"
    end
  end
end
