# Maintenance mode: while it is on, no mailbox is fetched - neither by the
# fetch_all cron endpoint nor by the project's "fetch now" button - and a fetch
# already running stops before its next message. Meant for upgrades and for
# scaling pods down: switch it on, wait until status says idle, then proceed.
#
# The flag is the 'maintenance_mode' plugin setting, so every replica sees it
# (settings live in the database; Redmine re-checks its settings cache on every
# request). A running fetch outlives the request that read the cache, which is
# why the per-message check reads the row directly (fresh: true).
#
# Order matters for the "idle" answer to be trustworthy: a fetch registers its
# HelpdeskFetchRun *before* it checks the flag. A fetch that registered too late
# to show up in a status read therefore sees the flag and never touches a mail.
module RedmineExpertHelpdesk
  module Maintenance
    SETTING = 'maintenance_mode'.freeze

    module_function

    def active?(fresh: false)
      settings = fresh ? stored_settings : Setting.plugin_redmine_expert_helpdesk
      settings.is_a?(Hash) && settings[SETTING].to_s == '1'
    end

    def set!(enabled)
      # Never saved yet: start from the defaults, or the write would persist a
      # hash holding only this key and every other setting would read nil.
      current = stored_settings
      current = Setting.plugin_redmine_expert_helpdesk unless current.is_a?(Hash)
      Setting.plugin_redmine_expert_helpdesk = current.to_h.merge(SETTING => enabled ? '1' : '0')
      Rails.logger.warn "Helpdesk: maintenance mode #{enabled ? 'enabled' : 'disabled'}"
    end

    # What an operator needs before scaling down: is the switch on, and is any
    # pod still inside a fetch.
    def status
      HelpdeskFetchRun.purge_stale!
      runs = HelpdeskFetchRun.live.order(:started_at).map do |r|
        { :mailbox => r.mailbox_address, :host => r.host, :pid => r.pid, :processed => r.processed,
          :started_at => r.started_at&.iso8601, :heartbeat_at => r.heartbeat_at&.iso8601 }
      end
      maintenance = active?(fresh: true)
      { :maintenance => maintenance, :running => runs, :idle => runs.empty?,
        :safe_to_stop => maintenance && runs.empty? }
    end

    def stored_settings
      Setting.find_by(:name => 'plugin_redmine_expert_helpdesk')&.value
    end
  end
end
