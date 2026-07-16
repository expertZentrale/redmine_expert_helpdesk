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
end
