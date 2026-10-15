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

    # The mailbox that actually received this mail is always in its To. The
    # caller passes the mailbox it would reply *from*, and reply_form falls back
    # to the first enabled project mailbox once the original one is disabled -
    # so take the addresses off the message itself too, or we offer our own
    # helpdesk address back to the agent and the answer loops into the helpdesk.
    blocked = (Array(exclude) + mailbox_addresses(msg.helpdesk_mailbox))
              .map { |a| a.to_s.strip.downcase }.reject(&:blank?)
    to      = split_addresses(msg.recipient_to, blocked)
    # An address in both headers is offered once. Adding it to To and Cc alike
    # would put a duplicate recipient on the outgoing mail.
    cc      = split_addresses(msg.recipient_cc, blocked + to.map(&:downcase))

    { :to => to, :cc => cc }
  end

  # Both spellings of a Message-ID. Rows are not stored uniformly: incoming
  # mail carries the provider's form (IMAP without, Graph with angle brackets),
  # outgoing replies always store "<id>". A lookup with only one form misses
  # half the rows.
  def self.message_id_variants(id)
    bare = id.to_s.strip.delete_prefix('<').delete_suffix('>')
    return [] if bare.blank?

    [bare, "<#{bare}>"]
  end

  # True when this project already received the mail - a second mailbox of the
  # same project got it too (To + Cc), or a fetch is repeated after a failed
  # move. Scoped to the project on purpose: the same mail sent to two projects
  # is two tickets, one in each.
  #
  # "Received" means through one of the project's mailboxes *or* into one of
  # its tickets: a reply on a ticket moved to another project lands there
  # (ThreadScope#local?), and only the receiving mailbox still names us.
  def self.received_in_project?(message_id, project)
    variants = message_id_variants(message_id)
    return false if variants.empty? || project.nil?

    mailbox_ids = HelpdeskMailbox.where(:project_id => project.id).select(:id)
    rows = incoming.where(:message_id => variants)
    return true if rows.where(:helpdesk_mailbox_id => mailbox_ids).exists? ||
                   rows.joins(:issue).where(Issue.table_name => { :project_id => project.id }).exists?

    # A ticket opened here and moved away counts as ours (ThreadScope#local?),
    # whichever project's mailbox happened to fetch the reply first.
    scope = RedmineExpertHelpdesk::ThreadScope.new(project)
    rows.includes(:issue).any? { |m| m.issue && scope.local?(m.issue) }
  end

  # The other helpdesk mailboxes a mail of this ticket was addressed to, i.e.
  # the projects that got their own copy of it. Only To/Cc are known - a
  # mailbox reached by Bcc stays invisible, as it should.
  #
  # The mailboxes that received the ticket's mails are never "also": for a
  # ticket moved to another project, the mailbox it was opened through is still
  # in To but belongs to the old project.
  def self.co_recipient_mailboxes(issue)
    rows      = incoming.where(:issue_id => issue.id).to_a
    addresses = rows.flat_map do |m|
      split_addresses(m.recipient_to) + split_addresses(m.recipient_cc)
    end.map(&:downcase).uniq
    return [] if addresses.empty?

    HelpdeskMailbox.includes(:project)
                   .where('LOWER(mailbox_address) IN (?)', addresses)
                   .where.not(:project_id => issue.project_id)
                   .where.not(:id => rows.map(&:helpdesk_mailbox_id).compact)
                   .order(:mailbox_address).to_a
  end

  # What the recipients pill on the ticket header and on incoming journals
  # shows for one inbound mail: every To/Cc address, each flagged whether it
  # is the mailbox that received the mail, plus how many people besides us
  # were addressed in each header (the pill's "An +1" / "CC +2").
  #
  # Unlike original_recipients_for our own mailbox stays in the lists - the
  # popover marks it instead of hiding it, so agents see which of several
  # support mailboxes the customer wrote to. An address in both headers is
  # listed under To only.
  def self.recipient_summary(msg)
    own = mailbox_addresses(msg.helpdesk_mailbox).map { |a| a.to_s.strip.downcase }
    to  = split_addresses(msg.recipient_to)
    cc  = split_addresses(msg.recipient_cc, to.map(&:downcase))
    tag = ->(addr) { { :address => addr, :own => own.include?(addr.downcase) } }
    to  = to.map(&tag)
    cc  = cc.map(&tag)

    {
      :to        => to,
      :cc        => cc,
      :to_others => to.count { |r| !r[:own] },
      :cc_others => cc.count { |r| !r[:own] }
    }
  end

  # Splits a stored recipient header into single addresses. MailProcessor writes
  # these as Mail#to.join(', '), so they are bare addresses - but a hand-written
  # or legacy row can carry the RFC 2822 `"Name" <addr>` form, whose display
  # name may itself contain a comma. Comparison is case-insensitive; the casing
  # that comes back is the one that was stored.
  def self.split_addresses(value, blocked = [])
    seen = []
    scan_tokens(value).filter_map do |token|
      addr = bare_address(token)
      next if addr.blank?

      key = addr.downcase
      next if blocked.include?(key) || seen.include?(key)

      seen << key
      addr
    end
  end
  private_class_method :split_addresses

  # A comma or semicolon inside quotes or angle brackets separates nothing -
  # splitting on every one of them tears `"Doe, Jane" <jane@doe.com>` into two
  # fragments and offers both as recipients.
  def self.scan_tokens(value)
    tokens  = []
    current = +''
    quoted  = false
    angled  = false
    escaped = false

    value.to_s.each_char do |ch|
      # A backslash-escaped character is literal - in particular \" does not
      # close the quoted string. Toggling on it flips the parity, and the next
      # comma then looks unquoted and splits the display name in half.
      if escaped
        current << ch
        escaped = false
        next
      end

      case ch
      when '\\'     then escaped = true
      when '"'      then quoted = !quoted
      when '<'      then angled = true
      when '>'      then angled = false
      when ',', ';'
        unless quoted || angled
          tokens << current
          current = +''
          next
        end
      end
      current << ch
    end

    tokens << current
  end
  private_class_method :scan_tokens

  # The address out of `Name <addr>`, or the token itself when it is bare.
  def self.bare_address(token)
    text  = token.to_s.strip
    match = text.match(/<([^>]*)>/)
    (match ? match[1] : text).strip
  end
  private_class_method :bare_address

  # Every address that is us, for a mailbox that may be nil. from_address and
  # reply_to_address differ from mailbox_address only under an SMTP From
  # override, but then they are what the customer actually saw.
  def self.mailbox_addresses(mailbox)
    return [] unless mailbox

    [mailbox.mailbox_address, mailbox.from_address, mailbox.reply_to_address].compact
  end
  private_class_method :mailbox_addresses
end
