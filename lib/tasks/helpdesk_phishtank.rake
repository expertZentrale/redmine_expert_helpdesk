# Manueller bzw. Cron-Trigger fuer den Phishing-Feed-Sync (PhishTank + Phishing.Database):
#   bundle exec rake redmine_expert_helpdesk:phishtank_sync RAILS_ENV=production
namespace :redmine_expert_helpdesk do
  desc 'Laedt die aktivierten Phishing-Feeds herunter und aktualisiert den lokalen Spiegel'
  task :phishtank_sync => :environment do
    settings = Setting.plugin_redmine_expert_helpdesk
    unless settings['phishtank_enabled'] == '1'
      puts 'Phishing-Integration ist in den Plugin-Einstellungen deaktiviert.'
      next
    end

    results, errors = RedmineExpertHelpdesk::PhishingFeeds.run_all
    results.each { |source, count| puts "#{source}: #{count} URLs importiert." }
    errors.each  { |source, msg|   puts "#{source}: FEHLER – #{msg}" }
  end
end
