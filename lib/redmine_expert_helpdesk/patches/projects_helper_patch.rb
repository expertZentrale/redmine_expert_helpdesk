# Ergaenzt den Reiter "Helpdesk" in den Projekteinstellungen
module RedmineExpertHelpdesk
  module Patches
    module ProjectsHelperPatch
      def project_settings_tabs
        tabs = super
        if User.current.allowed_to?(:manage_helpdesk, @project)
          tabs << {
            :name => 'helpdesk',
            :action => :manage_helpdesk,
            :partial => 'projects/settings/helpdesk',
            :label => :label_helpdesk
          }
        end
        tabs
      end
    end
  end
end
