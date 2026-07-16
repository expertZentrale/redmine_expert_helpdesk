# Mehrere Feed-Quellen im URL-Spiegel unterscheiden (PhishTank, Phishing.Database).
class AddSourceToHelpdeskPhishingUrls < ActiveRecord::Migration[6.1]
  def change
    unless column_exists?(:helpdesk_phishing_urls, :source)
      add_column :helpdesk_phishing_urls, :source, :string, :limit => 30, :default => 'phishtank', :null => false
      add_index :helpdesk_phishing_urls, :source
    end
  end
end
