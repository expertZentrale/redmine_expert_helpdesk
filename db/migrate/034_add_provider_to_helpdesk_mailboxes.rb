# Adds the mail provider selection plus IMAP/SMTP connection settings.
# Existing mailboxes default to 'graph' + 'global' credentials, so their
# behaviour is unchanged.
class AddProviderToHelpdeskMailboxes < ActiveRecord::Migration[6.1]
  def change
    t = :helpdesk_mailboxes

    add_column t, :provider,           :string,  :default => 'graph',  :null => false unless column_exists?(t, :provider)
    add_column t, :credentials_source, :string,  :default => 'global', :null => false unless column_exists?(t, :credentials_source)

    # Incoming (IMAP)
    add_column t, :imap_host,        :string                     unless column_exists?(t, :imap_host)
    add_column t, :imap_port,        :integer, :default => 993   unless column_exists?(t, :imap_port)
    add_column t, :imap_security,    :string,  :default => 'ssl' unless column_exists?(t, :imap_security)
    add_column t, :imap_username,    :string                     unless column_exists?(t, :imap_username)
    add_column t, :imap_verify_ssl,  :boolean, :default => true,  :null => false unless column_exists?(t, :imap_verify_ssl)
    add_column t, :imap_unseen_only, :boolean, :default => false, :null => false unless column_exists?(t, :imap_unseen_only)
    add_column t, :imap_timeout,     :integer, :default => 120   unless column_exists?(t, :imap_timeout)

    # Outgoing (SMTP)
    add_column t, :smtp_host,       :string                          unless column_exists?(t, :smtp_host)
    add_column t, :smtp_port,       :integer, :default => 587        unless column_exists?(t, :smtp_port)
    add_column t, :smtp_security,   :string,  :default => 'starttls' unless column_exists?(t, :smtp_security)
    add_column t, :smtp_username,   :string                          unless column_exists?(t, :smtp_username)
    add_column t, :smtp_verify_ssl, :boolean, :default => true, :null => false unless column_exists?(t, :smtp_verify_ssl)

    # Authentication
    add_column t, :auth_method,       :string, :default => 'oauth2' unless column_exists?(t, :auth_method)
    add_column t, :mail_password_enc, :text                         unless column_exists?(t, :mail_password_enc)
  end
end
