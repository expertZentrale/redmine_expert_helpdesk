require File.expand_path('../../test_helper', __FILE__)

# Blacklisting an attachment from the ticket page, and managing the entries again
# from the project settings.
class HelpdeskAttachmentBlacklistTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :members, :member_roles, :roles,
           :enabled_modules, :trackers, :projects_trackers, :issue_statuses,
           :enumerations, :issues, :journals

  PNG_BASE64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='.freeze

  def setup
    @project = Project.find(1)
    @project.enable_module!(:helpdesk)
    Role.find(1).add_permission!(:manage_helpdesk, :view_helpdesk_info)
    HelpdeskAttachmentBlacklist.delete_all
    @issue = Issue.find(1)
    @attachment = attach_png(@issue)
  end

  # --- Blacklisting from the ticket -----------------------------------------

  def test_blacklisting_stores_the_entry_and_purges_the_copies
    log_user('jsmith', 'jsmith') # Manager in project 1
    twin = attach_png(Issue.find(2), 'logo.png') # same bytes, same project

    assert_difference 'HelpdeskAttachmentBlacklist.count', 1 do
      assert_difference 'Attachment.count', -2 do
        post "/helpdesk/attachments/#{@attachment.id}/blacklist"
      end
    end

    assert_redirected_to "/issues/#{@issue.id}"
    entry = HelpdeskAttachmentBlacklist.order(:id).last
    assert_equal @project.id, entry.project_id
    assert_equal Digest::SHA256.hexdigest(Base64.decode64(PNG_BASE64)), entry.digest
    assert_equal 'image001.png', entry.filename
    assert_equal User.find_by_login('jsmith').id, entry.user_id
    assert_nil Attachment.find_by(:id => twin.id)
  end

  def test_preview_reports_the_number_of_copies
    log_user('jsmith', 'jsmith')
    attach_png(Issue.find(2), 'logo.png')

    get "/helpdesk/attachments/#{@attachment.id}/blacklist/preview"
    assert_response :success
    body = ActiveSupport::JSON.decode(response.body)
    assert_equal 2, body['copies']
    assert_equal 'image001.png', body['filename']
  end

  def test_blacklisting_the_same_file_twice_reuses_the_entry
    log_user('jsmith', 'jsmith')
    post "/helpdesk/attachments/#{@attachment.id}/blacklist"

    second = attach_png(Issue.find(2), 'logo.png')
    assert_no_difference 'HelpdeskAttachmentBlacklist.count' do
      post "/helpdesk/attachments/#{second.id}/blacklist"
    end
    assert_redirected_to "/issues/2"
    assert_nil Attachment.find_by(:id => second.id)
  end

  # --- Permissions -----------------------------------------------------------

  def test_blacklisting_is_denied_without_manage_helpdesk
    Role.find(1).remove_permission!(:manage_helpdesk)
    log_user('jsmith', 'jsmith')

    assert_no_difference 'HelpdeskAttachmentBlacklist.count' do
      post "/helpdesk/attachments/#{@attachment.id}/blacklist"
    end
    assert_response :forbidden
  end

  def test_blacklisting_is_denied_when_the_module_is_off
    @project.disable_module!(:helpdesk)
    log_user('jsmith', 'jsmith')

    post "/helpdesk/attachments/#{@attachment.id}/blacklist"
    assert_response :forbidden
  end

  def test_an_attachment_outside_a_ticket_is_not_blacklistable
    log_user('jsmith', 'jsmith')
    wiki_attachment = Attachment.find(1)
    wiki_attachment.update_columns(:container_type => 'WikiPage', :container_id => 1)

    post "/helpdesk/attachments/#{wiki_attachment.id}/blacklist"
    assert_response :not_found
  end

  # --- Type and size guard ---------------------------------------------------

  def test_a_pdf_cannot_be_blacklisted
    log_user('jsmith', 'jsmith')
    pdf = Attachment.create!(:container => @issue, :author => User.find(2),
                             :file => upload('handbuch.pdf', 'application/pdf', '%PDF-1.4'))

    assert_no_difference 'HelpdeskAttachmentBlacklist.count' do
      assert_no_difference 'Attachment.count' do
        post "/helpdesk/attachments/#{pdf.id}/blacklist"
      end
    end
    assert_redirected_to "/issues/#{@issue.id}"
    assert_match(/handbuch\.pdf/, flash[:error].to_s)
  end

  def test_the_button_is_only_drawn_for_eligible_attachments
    log_user('jsmith', 'jsmith')
    Attachment.create!(:container => @issue, :author => User.find(2),
                       :file => upload('handbuch.pdf', 'application/pdf', '%PDF-1.4'))

    get "/issues/#{@issue.id}"
    assert_response :success
    config = css_select('#helpdesk-attachment-blacklist-config').first
    assert config, 'blacklist config island missing'
    eligible = ActiveSupport::JSON.decode(config.children.first.to_s)['eligible']
    assert_includes eligible, @attachment.id
    assert_equal 1, eligible.size, 'the PDF must not be offered'
  end

  def test_no_config_is_shipped_when_nothing_is_eligible
    log_user('jsmith', 'jsmith')
    @attachment.destroy

    get "/issues/#{@issue.id}"
    assert_response :success
    assert_select '#helpdesk-attachment-blacklist-config', 0
  end

  def test_the_project_may_raise_the_size_limit
    log_user('jsmith', 'jsmith')
    big = Attachment.create!(:container => @issue, :author => User.find(2),
                             :file => upload('logo.png', 'image/png', 'x' * (120 * 1024)))

    post "/helpdesk/attachments/#{big.id}/blacklist"
    assert_match(/logo\.png/, flash[:error].to_s)

    put "/projects/#{@project.identifier}/helpdesk_project_setting",
        :params => { :blacklist_form => '1',
                     :helpdesk_project_setting => { :blacklist_max_kb => '200' } }

    assert_difference 'HelpdeskAttachmentBlacklist.count', 1 do
      post "/helpdesk/attachments/#{big.id}/blacklist"
    end
  end

  # 0 switches the size guard off, so a typo must not be coerced into it.
  def test_a_malformed_size_limit_is_rejected
    log_user('jsmith', 'jsmith')

    put "/projects/#{@project.identifier}/helpdesk_project_setting",
        :params => { :blacklist_form => '1',
                     :helpdesk_project_setting => { :blacklist_max_kb => 'abc' } }

    assert HelpdeskProjectSetting.for_project(@project).blacklist_max_kb.nil?,
           'a malformed limit must not be stored'
    assert_equal 100, HelpdeskProjectSetting.for_project(@project).effective_blacklist_max_kb
    assert flash[:error].present?
  end

  def test_an_emptied_size_limit_falls_back_to_the_central_one
    log_user('jsmith', 'jsmith')
    put "/projects/#{@project.identifier}/helpdesk_project_setting",
        :params => { :blacklist_form => '1',
                     :helpdesk_project_setting => { :blacklist_max_kb => '250' } }
    assert_equal 250, HelpdeskProjectSetting.for_project(@project).effective_blacklist_max_kb

    put "/projects/#{@project.identifier}/helpdesk_project_setting",
        :params => { :blacklist_form => '1',
                     :helpdesk_project_setting => { :blacklist_max_kb => '' } }
    assert_nil HelpdeskProjectSetting.for_project(@project).blacklist_max_kb
    assert_equal 100, HelpdeskProjectSetting.for_project(@project).effective_blacklist_max_kb
  end

  # --- Settings tab ----------------------------------------------------------

  def test_settings_tab_lists_the_entries_and_removes_them
    log_user('jsmith', 'jsmith')
    post "/helpdesk/attachments/#{@attachment.id}/blacklist"
    entry = HelpdeskAttachmentBlacklist.order(:id).last

    get "/projects/#{@project.identifier}/settings/expert_helpdesk"
    assert_response :success
    assert_select 'td', :text => 'image001.png'

    assert_difference 'HelpdeskAttachmentBlacklist.count', -1 do
      delete "/projects/#{@project.identifier}/helpdesk_attachment_blacklists/#{entry.id}"
    end
    assert_redirected_to settings_project_path(@project, :tab => 'expert_helpdesk')
  end

  def test_an_entry_of_another_project_cannot_be_removed
    log_user('jsmith', 'jsmith')
    foreign = HelpdeskAttachmentBlacklist.create!(
      :project_id => 2, :digest => 'a' * 64, :created_on => Time.current
    )

    delete "/projects/#{@project.identifier}/helpdesk_attachment_blacklists/#{foreign.id}"
    assert_response :not_found
    assert HelpdeskAttachmentBlacklist.exists?(foreign.id)
  end

  private

  def attach_png(container, filename = 'image001.png')
    attachment = Attachment.create!(:container => container, :author => User.find(2),
                                    :file => upload(filename, 'image/png',
                                                    Base64.decode64(PNG_BASE64)))
    container.reload
    attachment
  end

  def upload(filename, content_type, body)
    io = StringIO.new(body)
    io.define_singleton_method(:original_filename) { filename }
    io.define_singleton_method(:content_type) { content_type }
    io
  end
end
