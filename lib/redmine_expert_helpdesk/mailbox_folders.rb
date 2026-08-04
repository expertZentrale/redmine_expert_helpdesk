# Creates the target folders a mailbox needs (processed / skipped / failed) after
# it has been saved.
#
# Extracted from HelpdeskMailboxesController so the REST API creates the same
# folders the UI does — a mailbox created via API would otherwise fail on the
# first fetch because its processed folder does not exist on the server.
module RedmineExpertHelpdesk
  module MailboxFolders
    module_function

    # Returns nil on success (or when there is nothing to do) and the provider's
    # error message when folder creation failed. Callers decide how to surface it;
    # a failure here must never abort the save, the mailbox itself is fine.
    def ensure!(mailbox)
      return nil if mailbox.mailbox_address.blank?

      provider = RedmineExpertHelpdesk::MailProvider.for(mailbox)
      return nil unless provider.configured?

      folders = [mailbox.processed_folder, mailbox.skipped_folder, mailbox.failed_folder].compact.uniq
      provider.with_session do
        folders.each do |folder|
          next if folder.blank?

          provider.find_or_create_folder(folder)
        end
      end
      nil
    rescue RedmineExpertHelpdesk::MailProvider::ProviderError => e
      e.message
    end
  end
end
