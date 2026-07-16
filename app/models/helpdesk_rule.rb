# Automatisierungsregel eines Postfachs.
# Bedingung (Feld/Operator/Wert) wird gegen Betreff oder Absender geprueft,
# die Aktion setzt Ticketfelder oder verwirft die Mail ("ignore").
class HelpdeskRule < HelpdeskApplicationRecord
  include Redmine::SafeAttributes

  belongs_to :helpdesk_mailbox

  CONDITION_FIELDS = %w[subject sender].freeze
  OPERATORS        = %w[contains equals regex].freeze
  ACTION_TYPES     = %w[set_priority set_tracker set_category set_assignee ignore].freeze

  validates :condition_field, :inclusion => { :in => CONDITION_FIELDS }
  validates :operator,        :inclusion => { :in => OPERATORS }
  validates :action_type,     :inclusion => { :in => ACTION_TYPES }
  validates :condition_value, :presence => true
  validates :action_value,    :presence => true, :unless => proc { |r| r.action_type == 'ignore' }

  acts_as_positioned :scope => :helpdesk_mailbox_id

  safe_attributes 'condition_field', 'operator', 'condition_value',
                  'action_type', 'action_value', 'position'

  def matches?(subject, sender)
    value = condition_field == 'subject' ? subject.to_s : sender.to_s
    case operator
    when 'contains' then value.downcase.include?(condition_value.to_s.downcase)
    when 'equals'   then value.casecmp(condition_value.to_s).zero?
    when 'regex'
      begin
        Regexp.new(condition_value, Regexp::IGNORECASE).match?(value)
      rescue RegexpError
        false
      end
    else false
    end
  end

  # Wendet die Aktion auf das Ticket an. Liefert true, wenn etwas geaendert wurde.
  def apply_to(issue)
    case action_type
    when 'set_priority'
      priority = IssuePriority.find_by(:name => action_value) || IssuePriority.find_by(:id => action_value)
      issue.priority = priority if priority
      priority.present?
    when 'set_tracker'
      tracker = issue.project.trackers.find_by(:name => action_value) ||
                issue.project.trackers.find_by(:id => action_value)
      issue.tracker = tracker if tracker
      tracker.present?
    when 'set_category'
      category = issue.project.issue_categories.find_by(:name => action_value) ||
                 issue.project.issue_categories.find_by(:id => action_value)
      issue.category = category if category
      category.present?
    when 'set_assignee'
      user = issue.project.users.detect { |u| u.login == action_value || u.id.to_s == action_value.to_s }
      issue.assigned_to = user if user
      user.present?
    else
      false
    end
  end
end
