# An answer template ("Textbaustein") an agent can insert into the note field.
# project_id NULL = global template, offered in every helpdesk project;
# otherwise the template belongs to that project alone.
#
# The content may use the same macros as autoresponder and footer templates,
# see RedmineExpertHelpdesk::TemplateRenderer. They are expanded server-side on
# insertion, because they need the ticket, its customer and the acting user.
class HelpdeskReplyTemplate < HelpdeskApplicationRecord
  include Redmine::SafeAttributes

  belongs_to :project, :optional => true

  validates :name,    :presence => true, :length => { :maximum => 255 }
  validates :content, :presence => true
  # Unique per scope only: the same name may exist once globally and once per
  # project, which is how a project overrides a global template by name.
  validates :name, :uniqueness => { :scope => :project_id, :case_sensitive => false }

  # Global templates get their own position sequence; where(project_id: nil)
  # is IS NULL, so they do not share numbering with any project.
  acts_as_positioned :scope => :project_id

  scope :active, -> { where(:enabled => true) }
  scope :global, -> { where(:project_id => nil) }
  scope :for_project, lambda { |project|
    where(:project_id => (project.is_a?(Project) ? project.id : project.to_i))
  }

  safe_attributes 'name', 'content', 'position', 'enabled'

  # Templates offered in a project's note editor: the project's own first (they
  # are the more specific answer), then the global ones, each block by position
  # with name as a stable tie-breaker.
  def self.available_for(project)
    return none if project.nil?

    where(:project_id => [project.id, nil])
      .order(Arel.sql("CASE WHEN #{quoted_table_name}.project_id IS NULL THEN 1 ELSE 0 END"),
             :position => :asc, :name => :asc)
  end

  def global?
    project_id.nil?
  end

  # Expands the template's macros for the ticket it is being inserted into.
  # contact may be nil (ticket without a linked customer) — TemplateRenderer
  # renders unknown macros as an empty string.
  def render_for(issue, contact, user)
    RedmineExpertHelpdesk::TemplateRenderer.render(
      content, :issue => issue, :contact => contact, :user => user
    )
  end
end
