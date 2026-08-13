# Path helpers for answer templates. The same resource is served in two scopes —
# per project and global — under two route names, so every view that links to a
# template goes through these instead of picking a route name itself.
# project is nil for the global templates managed in the plugin settings.
module HelpdeskReplyTemplatesHelper
  def hd_reply_templates_path(project)
    project ? helpdesk_reply_templates_path(:project_id => project) : global_helpdesk_reply_templates_path
  end

  def hd_new_reply_template_path(project)
    project ? new_helpdesk_reply_template_path(:project_id => project) : new_global_helpdesk_reply_template_path
  end

  def hd_edit_reply_template_path(template, project)
    if project
      edit_helpdesk_reply_template_path(template, :project_id => project)
    else
      edit_global_helpdesk_reply_template_path(template)
    end
  end

  def hd_reply_template_path(template, project)
    if project
      helpdesk_reply_template_path(template, :project_id => project)
    else
      global_helpdesk_reply_template_path(template)
    end
  end
end
