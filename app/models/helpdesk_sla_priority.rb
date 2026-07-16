# SLA-Zielzeiten je Prioritaet (Override der Projekt-Defaults).
# Leere Minuten-Werte bedeuten: der Projekt-Default gilt.
class HelpdeskSlaPriority < HelpdeskApplicationRecord
  belongs_to :project
  belongs_to :priority, :class_name => 'IssuePriority'

  validates :project_id,  :presence => true
  validates :priority_id, :presence => true, :uniqueness => { :scope => :project_id }
  validates :reaction_minutes, :solution_minutes,
            :numericality => { :only_integer => true, :greater_than => 0 }, :allow_nil => true
end
