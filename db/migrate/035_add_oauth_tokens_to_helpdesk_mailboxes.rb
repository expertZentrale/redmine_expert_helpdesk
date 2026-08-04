# Per-mailbox OAuth2 configuration and token storage for the IMAP/SMTP provider.
# Secret columns (*_enc) hold values encrypted by RedmineExpertHelpdesk::SecretBox.
class AddOauthTokensToHelpdeskMailboxes < ActiveRecord::Migration[6.1]
  def change
    t = :helpdesk_mailboxes

    add_column t, :oauth_preset, :string, :default => 'microsoft'          unless column_exists?(t, :oauth_preset)
    add_column t, :oauth_grant,  :string, :default => 'client_credentials' unless column_exists?(t, :oauth_grant)

    add_column t, :oauth_tenant_id,         :string unless column_exists?(t, :oauth_tenant_id)
    add_column t, :oauth_client_id,         :string unless column_exists?(t, :oauth_client_id)
    add_column t, :oauth_client_secret_enc, :text   unless column_exists?(t, :oauth_client_secret_enc)
    add_column t, :oauth_authorize_url,     :string unless column_exists?(t, :oauth_authorize_url)
    add_column t, :oauth_token_url,         :string unless column_exists?(t, :oauth_token_url)
    add_column t, :oauth_scope,             :string unless column_exists?(t, :oauth_scope)

    add_column t, :oauth_refresh_token_enc, :text     unless column_exists?(t, :oauth_refresh_token_enc)
    add_column t, :oauth_token_expires_at,  :datetime unless column_exists?(t, :oauth_token_expires_at)
    add_column t, :oauth_connected_at,      :datetime unless column_exists?(t, :oauth_connected_at)

    # JWT bearer grant (Google service account with domain-wide delegation)
    add_column t, :oauth_sa_email,  :string unless column_exists?(t, :oauth_sa_email)
    add_column t, :oauth_sa_key_enc, :text  unless column_exists?(t, :oauth_sa_key_enc)
  end
end
