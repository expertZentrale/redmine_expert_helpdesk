# Verknuepft Projekte mit ihren Helpdesk-Postfaechern und Antwortvorlagen
module RedmineExpertHelpdesk
  module Patches
    module ProjectPatch
      def self.included(base)
        base.class_eval do
          has_many :helpdesk_mailboxes, :dependent => :destroy
          # Only the project's own templates; global ones have no project_id.
          has_many :helpdesk_reply_templates, :dependent => :destroy
        end
      end
    end
  end
end
