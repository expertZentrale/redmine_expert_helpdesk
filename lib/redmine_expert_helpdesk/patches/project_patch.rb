# Verknuepft Projekte mit ihren Helpdesk-Postfaechern und Antwortvorlagen
module RedmineExpertHelpdesk
  module Patches
    module ProjectPatch
      def self.included(base)
        base.class_eval do
          has_many :helpdesk_mailboxes, :dependent => :destroy
          # Only the project's own templates; global ones have no project_id.
          has_many :helpdesk_reply_templates, :dependent => :destroy
          # Without this, deleting a project left its contacts behind with a
          # project_id pointing nowhere: invisible in every (project-scoped)
          # list, and refused by the API's write check even for admins, since
          # allowed_to? on a nil project is always false (#46). Declared after
          # core's has_many :issues, so the issues are gone by the time this
          # runs; the contact's own :nullify handles anything left.
          has_many :helpdesk_contacts, :dependent => :destroy
        end
      end
    end
  end
end
