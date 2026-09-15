# Nachrichtenverlauf eines Tickets (eingehend und ausgehend),
# inklusive Message-ID fuer das E-Mail-Threading.
class HelpdeskMessage < HelpdeskApplicationRecord
  belongs_to :issue
  belongs_to :helpdesk_contact, :optional => true
  belongs_to :helpdesk_mailbox, :optional => true
  belongs_to :eml_attachment,   :class_name => 'Attachment', :optional => true

  DIRECTIONS = %w[in out init].freeze

  validates :issue, :presence => true
  validates :direction, :inclusion => { :in => DIRECTIONS }

  scope :incoming, -> { where(:direction => 'in') }
  scope :outgoing, -> { where(:direction => 'out') }

  # Sichtbarkeit fuer Abfragen ausserhalb des Aktivitaets-Feeds
  scope :visible, lambda { |*args|
    user    = args.shift || User.current
    options = args.shift || {}
    joins(:issue => :project)
      .where(Issue.visible_condition(user, options))
  }

  # Aktivitaets-Feed: Ereignisdarstellung
  acts_as_event(
    :title    => Proc.new { |m|
      subject = m.subject.presence || (m.issue ? m.issue.subject : '?')
      "[##{m.issue_id}] #{subject}"
    },
    :datetime => Proc.new { |m| m.sent_at || m.created_at },
    :url      => Proc.new { |m|
      { :controller => 'issues', :action => 'show', :id => m.issue_id }
    },
    :type        => Proc.new { |m| "helpdesk-message-#{m.direction}" },
    :author      => Proc.new { nil },
    :description => Proc.new { nil },
    :group       => :issue
  )

  # Aktivitaets-Feed: Datenbankabfrage und Zugriffssteuerung
  acts_as_activity_provider(
    :type       => 'helpdesk_messages',
    :timestamp  => "#{table_name}.created_at",
    :permission => :view_helpdesk_info,
    :scope      => proc { joins(:issue => :project) }
  )

  # Benoetigt von acts_as_event (recipients-Methode)
  def project
    issue&.project
  end

  # Recipients of the mail that opened this ticket, offered behind the To and Cc
  # fields of the reply form. A customer mail is often addressed to several
  # people, and having to look those addresses up in the original mail and
  # retype them is what made agents drop them from the answer.
  #
  # Inbound Bcc does not exist - the sending MTA strips it - so only To and Cc
  # are returned. recipient_to/_cc may be NULL: MailProcessor parses the MIME
  # with a `rescue nil`, so a mail that failed to parse has no recipients stored
  # rather than an empty string.
  def self.original_recipients_for(issue, exclude: [])
    issue_id = issue.is_a?(Issue) ? issue.id : issue
    msg      = incoming.where(:issue_id => issue_id).order(:id => :asc).first
    return { :to => [], :cc => [] } unless msg

    blocked = Array(exclude).map { |a| a.to_s.strip.downcase }.reject(&:blank?)
    to      = split_addresses(msg.recipient_to, blocked)
    # An address in both headers is offered once. Adding it to To and Cc alike
    # would put a duplicate recipient on the outgoing mail.
    cc      = split_addresses(msg.recipient_cc, blocked + to.map(&:downcase))

    { :to => to, :cc => cc }
  end

  # Splits a stored recipient header into single addresses. MailProcessor writes
  # these as Mail#to.join(', '), so they are bare addresses - but a hand-written
  # row or a future sender may still wrap them in angle brackets. Comparison is
  # case-insensitive; the casing that comes back is the one that was stored.
  def self.split_addresses(value, blocked = [])
    seen = []
    value.to_s.split(/[,;]+/).filter_map do |raw|
      addr = raw.strip.sub(/\A.*</, '').sub(/>.*\z/, '').strip
      next if addr.blank?

      key = addr.downcase
      next if blocked.include?(key) || seen.include?(key)

      seen << key
      addr
    end
  end
  private_class_method :split_addresses
end
