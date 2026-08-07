# Global on/off state of the AI and knowledge-base features.
#
# The raw `Setting.plugin_redmine_expert_helpdesk['ai_enabled'].to_s == '1'` compare used to be
# duplicated across controllers, jobs, patches and views, and the menu entry for the AI statistics
# tab was missing it entirely — which is why that tab showed up even with AI switched off.
# Every gate on the global AI/KB switches goes through here.
module RedmineExpertHelpdesk
  module AiFeatures
    module_function

    def settings
      Setting.plugin_redmine_expert_helpdesk
    end

    def ai_enabled?
      settings['ai_enabled'].to_s == '1'
    end

    def kb_enabled?
      settings['kb_enabled'].to_s == '1'
    end

    # True when at least one of the two is on. The AI statistics page reports both AI summary
    # and knowledge-base requests, so either feature alone makes it meaningful.
    def any_enabled?
      ai_enabled? || kb_enabled?
    end
  end
end
