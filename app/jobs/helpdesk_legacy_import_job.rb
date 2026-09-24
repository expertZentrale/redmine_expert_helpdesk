# Runs the legacy contact import or the EML attachment repair outside the admin's
# request. Both touch every legacy contact / ticket, which on a real
# redmine_contacts dataset takes longer than any browser or reverse proxy waits.
# Progress and outcome go to the HelpdeskLegacyImportRun row the status page polls.
class HelpdeskLegacyImportJob < ActiveJob::Base
  queue_as :default

  def perform(run_id)
    run = HelpdeskLegacyImportRun.find_by(:id => run_id)
    return unless run && run.status == 'queued'

    run.start!
    progress = ->(phase, done, total) { run.progress!(phase, done, total) }

    result =
      if run.kind == 'fix_attachments'
        RedmineExpertHelpdesk::LegacyContactsImport.new(nil, :progress => progress).fix_attachments
      else
        RedmineExpertHelpdesk::LegacyContactsImport.new(run.project_id_list, :progress => progress).run
      end
    run.finish!(result)
  rescue StandardError => e
    Rails.logger.error "Helpdesk: legacy #{run&.kind} run ##{run_id} failed: #{e.class}: #{e.message}"
    run&.fail!(e.message)
  end
end
