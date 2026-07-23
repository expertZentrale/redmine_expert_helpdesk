# Ergaenzt den Reiter "Helpdesk" in den Projekteinstellungen.
#
# Bewusst per UnboundMethod-Capture statt prepend/super: so koexistiert die
# Erweiterung mit Plugins, die project_settings_tabs per alias_method_chain
# patchen (z. B. RedmineUP redmine_contacts_helpdesk). prepend+super kollidiert
# dort ("super: no superclass method 'project_settings_tabs'"), weil deren
# alias_method die prepend-Methode einfaengt und der bare super dann ins Leere
# laeuft. Der explizite Aufruf der gecachten Original-Methode ist gegen
# Reihenfolge und Verkettung unempfindlich.
module RedmineExpertHelpdesk
  module Patches
    module ProjectsHelperPatch
      def self.apply!(base)
        return if base.instance_variable_get(:@expert_helpdesk_tabs_patched)

        original = base.instance_method(:project_settings_tabs)
        base.send(:define_method, :project_settings_tabs) do
          tabs = original.bind(self).call
          if User.current.allowed_to?(:manage_helpdesk, @project)
            tabs << {
              :name    => 'helpdesk',
              :action  => :manage_helpdesk,
              :partial => 'projects/settings/helpdesk',
              :label   => :label_helpdesk
            }
          end
          tabs
        end
        base.instance_variable_set(:@expert_helpdesk_tabs_patched, true)
      end
    end
  end
end
