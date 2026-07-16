# Verknuepft Projekte mit ihren Helpdesk-Postfaechern
module RedmineExpertHelpdesk
  module Patches
    module ProjectPatch
      def self.included(base)
        base.class_eval do
          has_many :helpdesk_mailboxes, :dependent => :destroy
        end
      end
    end
  end
end
