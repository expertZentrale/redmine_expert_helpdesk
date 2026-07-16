require File.expand_path('../../test_helper', __FILE__)

class HelpdeskContactTest < ActiveSupport::TestCase
  # -----------------------------------------------------------------------
  # display_name (in-memory, no DB)
  # -----------------------------------------------------------------------

  def test_display_name_returns_name_when_present
    contact = HelpdeskContact.new(:name => 'Max Mustermann', :email => 'max@example.de')
    assert_equal 'Max Mustermann', contact.display_name
  end

  def test_display_name_falls_back_to_email_when_name_nil
    contact = HelpdeskContact.new(:name => nil, :email => 'max@example.de')
    assert_equal 'max@example.de', contact.display_name
  end

  def test_display_name_falls_back_to_email_when_name_blank
    contact = HelpdeskContact.new(:name => '', :email => 'max@example.de')
    assert_equal 'max@example.de', contact.display_name
  end

  # -----------------------------------------------------------------------
  # find_or_create_for (DB — wrapped in per-test transaction)
  # -----------------------------------------------------------------------

  def test_find_or_create_for_creates_new_contact
    contact = HelpdeskContact.find_or_create_for('new@example.de', 'New User', nil)
    assert contact.persisted?
    assert_equal 'new@example.de', contact.email
    assert_equal 'New User', contact.name
  end

  def test_find_or_create_for_normalizes_email_to_lowercase
    contact = HelpdeskContact.find_or_create_for(' UPPER@Example.DE ', nil, nil)
    assert_equal 'upper@example.de', contact.email
  end

  def test_find_or_create_for_reuses_existing_contact
    first  = HelpdeskContact.find_or_create_for('repeat@example.de', nil, nil)
    second = HelpdeskContact.find_or_create_for('REPEAT@Example.de', 'Egal', nil)
    assert_equal first.id, second.id
  end

  def test_find_or_create_for_fills_in_missing_name
    HelpdeskContact.find_or_create_for('fill@example.de', nil, nil)
    contact = HelpdeskContact.find_or_create_for('fill@example.de', 'Real Name', nil)
    assert_equal 'Real Name', contact.reload.name
  end

  def test_find_or_create_for_does_not_overwrite_existing_name
    HelpdeskContact.find_or_create_for('existing@example.de', 'Original Name', nil)
    contact = HelpdeskContact.find_or_create_for('existing@example.de', 'New Name', nil)
    assert_equal 'Original Name', contact.reload.name
  end

  def test_find_or_create_for_scopes_by_project
    project_a = Project.find(1)
    project_b = Project.find(2)
    contact_a = HelpdeskContact.find_or_create_for('shared@example.de', 'Project A', project_a)
    contact_b = HelpdeskContact.find_or_create_for('shared@example.de', 'Project B', project_b)
    assert_not_equal contact_a.id, contact_b.id
  end
end
