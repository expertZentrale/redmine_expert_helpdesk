# Mindestgroesse (KB), ab der ein Bild als Screenshot/Foto zaehlt.
# Signatur-Logos und Tracking-Pixel haengen an fast jeder Mail und sind meist
# 1-10 KB gross; ohne diese Schwelle waere "Anhang erforderlich" praktisch immer
# erfuellt und die Regel damit wirkungslos. Gilt nur fuer Bilder - ein kleines
# Log oder PDF ist trotz geringer Groesse echtes Beweismaterial.
class AddInfoRequestMinAttachmentToHelpdeskProjectSettings < ActiveRecord::Migration[6.1]
  def change
    return if column_exists?(:helpdesk_project_settings, :info_request_min_attachment_kb)

    add_column :helpdesk_project_settings, :info_request_min_attachment_kb,
               :integer, :default => 15
  end
end
