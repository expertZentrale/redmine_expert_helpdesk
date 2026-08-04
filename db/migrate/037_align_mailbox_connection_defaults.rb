class AlignMailboxConnectionDefaults < ActiveRecord::Migration[6.1]
  # Two column defaults that predate the IMAP backend and no longer hold.
  #
  # 1. reply_transport defaulted to 'graph' (migration 014, when Graph was the
  #    only backend). #available_reply_transports offers 'graph' exclusively to
  #    microsoft_hosted? mailboxes, so a new plain IMAP mailbox started out on a
  #    transport its own validation rejects. 'provider' means "whatever backend
  #    this mailbox uses" and is valid for every mailbox - for a Graph mailbox
  #    #outgoing_route resolves it straight back to 'graph', so nothing changes
  #    there.
  #
  # 2. imap_port/imap_security/smtp_port/smtp_security carried defaults
  #    (migration 034), which quietly made #apply_preset! a no-op for them: it
  #    assigns only where `self[attr].blank?`, and a column default is never
  #    blank. Neither a preset nor the global connection defaults could ever set
  #    a port or an encryption mode - only the two host columns, which have no
  #    default, actually worked. It went unnoticed because the microsoft and
  #    google presets happen to use 993/587 too. Leaving these NULL hands the
  #    decision back to #apply_preset!; ImapClient#port and SmtpSender#port
  #    already fall back per security mode when the column is empty.
  #
  # Stored values are untouched - existing mailboxes keep what they have.
  def up
    change_column_default :helpdesk_mailboxes, :reply_transport, 'provider'
    change_column_default :helpdesk_mailboxes, :imap_port,     nil
    change_column_default :helpdesk_mailboxes, :imap_security, nil
    change_column_default :helpdesk_mailboxes, :smtp_port,     nil
    change_column_default :helpdesk_mailboxes, :smtp_security, nil
  end

  def down
    change_column_default :helpdesk_mailboxes, :reply_transport, 'graph'
    change_column_default :helpdesk_mailboxes, :imap_port,     993
    change_column_default :helpdesk_mailboxes, :imap_security, 'ssl'
    change_column_default :helpdesk_mailboxes, :smtp_port,     587
    change_column_default :helpdesk_mailboxes, :smtp_security, 'starttls'
  end
end
