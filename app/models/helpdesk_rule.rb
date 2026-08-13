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
      principal = assignee_from_action_value(issue)
      issue.assigned_to = principal if principal
      principal.present?
    else
      false
    end
  end

  # Human-readable action value for the rules table: resolves the stored
  # principal, falling back to the raw value when it no longer exists. Login
  # first, in the same order as assignee_from_action_value - a login may consist
  # of digits only and must not be read as a principal id.
  def action_value_label
    return action_value unless action_type == 'set_assignee'

    principal   = User.find_by(:login => action_value)
    principal ||= Principal.find_by(:id => action_value) if action_value.to_s.match?(/\A\d+\z/)
    principal&.name || action_value
  end

  private

  # Rules created before groups were supported store the user's login; newer
  # rules store the principal id, which is the only way to address a group.
  # Login first, so legacy rows keep resolving exactly as they did before.
  def assignee_from_action_value(issue)
    assignables = issue.project.assignable_users
    assignables.detect { |p| p.is_a?(User) && p.login == action_value } ||
      assignables.detect { |p| p.id.to_s == action_value.to_s }
  end
end
