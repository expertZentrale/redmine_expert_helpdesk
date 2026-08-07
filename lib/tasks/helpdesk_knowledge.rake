# Wissensbasis-Batchaufgaben.
#
#   bundle exec rake redmine_expert_helpdesk:kb_backfill RAILS_ENV=production
#   bundle exec rake redmine_expert_helpdesk:kb_reembed  RAILS_ENV=production
#
namespace :redmine_expert_helpdesk do
  desc 'Nimmt bereits geschlossene Tickets beitragender Projekte in die Wissensbasis auf'
  task :kb_backfill => :environment do
    unless RedmineExpertHelpdesk::AiFeatures.kb_enabled?
      puts 'Wissensbasis ist in den Plugin-Einstellungen deaktiviert.'
      next
    end

    total = 0
    HelpdeskProjectSetting.where.not(:kb_ingest_mode => 'off').find_each do |ps|
      project = Project.find_by(:id => ps.project_id)
      next unless project

      scope = Issue.where(:project_id => project.id)
                   .joins(:status).where(:issue_statuses => { :is_closed => true })
                   .where.not(:id => HelpdeskKnowledgeEntry.where(:project_id => project.id).select(:issue_id))
      count = 0
      scope.find_each do |issue|
        HelpdeskKnowledgeIngestJob.perform_later(issue.id)
        count += 1
      end
      total += count
      puts "#{project.identifier}: #{count} Tickets zur Aufnahme eingereiht."
    end
    puts "Gesamt eingereiht: #{total}."
  end

  desc 'Baut die Vektoren aller freigegebenen Wissensbasis-Eintraege neu (z. B. nach Modellwechsel)'
  task :kb_reembed => :environment do
    settings = Setting.plugin_redmine_expert_helpdesk
    unless RedmineExpertHelpdesk::AiFeatures.kb_enabled?
      puts 'Wissensbasis ist deaktiviert.'
      next
    end

    store = RedmineExpertHelpdesk::KnowledgeStore.for(settings)
    unless store.configured?
      puts 'Vektor-Store ist nicht konfiguriert.'
      next
    end

    # Collections/Zeilen je Projekt leeren (bei Qdrant wird die Collection mit der
    # aktuellen Dimension neu erzeugt; bei pgvector mit geaenderter Dimension muss
    # die Tabelle helpdesk_kb_vectors manuell verworfen werden).
    HelpdeskKnowledgeEntry.approved.distinct.pluck(:project_id).each do |pid|
      store.reset!(pid)
    rescue StandardError => e
      puts "Reset Projekt #{pid} fehlgeschlagen: #{e.message}"
    end

    ok = 0
    HelpdeskKnowledgeEntry.approved.find_each do |entry|
      ok += 1 if HelpdeskKnowledgeIngestJob.index_entry(entry)
    end
    puts "Neu indexiert: #{ok} Eintraege."
  end
end
