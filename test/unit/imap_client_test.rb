require File.expand_path('../../test_helper', __FILE__)

# The IMAP client is exercised against a recording double instead of a mocking
# library: webmock cannot intercept raw IMAP sockets, and PluginGemfile has no
# test group, so a test-only gem would ship in production images.
class ImapClientTest < ActiveSupport::TestCase
  # Records every command and answers with canned data.
  class FakeImap
    attr_reader :commands
    attr_accessor :capabilities, :folders, :delim

    def initialize(capabilities: %w[IMAP4REV1 MOVE UIDPLUS], delim: '/')
      @commands = []
      @capabilities = capabilities
      @delim = delim
      @folders = []
      @uids = [3, 1, 2]
    end

    def record(name, *args)
      @commands << [name, *args]
    end

    def capability
      record(:capability)
      @capabilities
    end

    def select(name)
      record(:select, name)
    end

    def uid_search(criteria)
      record(:uid_search, criteria)
      @uids
    end

    def uid_fetch(uids, items)
      record(:uid_fetch, uids, items)
      [FetchData.new({ 'BODY[]' => 'RAW-MIME' })]
    end

    def uid_store(uid, mode, flags)
      record(:uid_store, uid, mode, flags)
    end

    def uid_move(uid, target)
      record(:uid_move, uid, target)
    end

    def uid_copy(uid, target)
      record(:uid_copy, uid, target)
    end

    def uid_expunge(uid)
      record(:uid_expunge, uid)
    end

    def expunge
      record(:expunge)
    end

    def create(name)
      record(:create, name)
      raise Net::IMAP::NoResponseError.new(FakeResponse.new('[ALREADYEXISTS] Mailbox exists')) if @folders.include?(name)

      @folders << name
    end

    def list(refname, pattern)
      record(:list, refname, pattern)
      return [MailboxList.new([], @delim, '')] if pattern.empty?

      @folders.map { |name| MailboxList.new([], @delim, name) }
    end

    def logout; end

    def disconnect; end

    def disconnected?
      true
    end

    FetchData = Struct.new(:attr)
    MailboxList = Struct.new(:attr, :delim, :name)
    FakeResponse = Struct.new(:message) do
      def data
        self
      end

      def text
        message
      end
    end
  end

  def setup
    Rails.cache.clear # the folder list is cached per mailbox id
    @mailbox = HelpdeskMailbox.new(
      :mailbox_address => 'hd@example.com',
      :provider        => 'imap',
      :source_folder   => 'INBOX',
      :imap_host       => 'imap.example.com',
      :auth_method     => 'password'
    )
    @fake = FakeImap.new
    @client = RedmineExpertHelpdesk::ImapClient.new(@mailbox, credentials)
    @client.instance_variable_set(:@imap, @fake)
  end

  def test_search_uses_uids_and_sorts_ascending
    assert_equal [1, 2, 3], @client.search_uids('INBOX', 10)
    assert_includes @fake.commands, [:uid_search, %w[ALL]]
  end

  def test_unseen_only_changes_the_criteria
    @mailbox.imap_unseen_only = true
    @client.search_uids('INBOX', 10)
    assert_includes @fake.commands, [:uid_search, %w[UNSEEN]]
  end

  def test_limit_is_applied_after_sorting
    assert_equal [1, 2], @client.search_uids('INBOX', 2)
  end

  # BODY[] (without PEEK) would silently set \Seen and break unseen-only mode.
  def test_fetches_use_peek
    @client.fetch_headers([1, 2])
    @client.fetch_mime(1)
    fetches = @fake.commands.select { |c| c.first == :uid_fetch }
    assert fetches.any?
    fetches.each do |cmd|
      items = Array(cmd[2]).join(' ')
      assert_includes items, 'BODY.PEEK['
      assert_not_match(/(?<!\.PEEK)\bBODY\[/, items)
    end
  end

  def test_fetch_mime_returns_binary
    mime = @client.fetch_mime('1')
    assert_equal 'RAW-MIME', mime
    assert_equal Encoding::BINARY, mime.encoding
  end

  def test_mark_as_read_sets_seen_flag
    @client.mark_as_read('7')
    assert_includes @fake.commands, [:uid_store, 7, '+FLAGS', [:Seen]]
  end

  def test_move_uses_move_extension_when_advertised
    @fake.folders << 'Verarbeitet'
    @client.move('5', 'Verarbeitet')
    assert @fake.commands.any? { |c| c.first == :uid_move }
    assert @fake.commands.none? { |c| c.first == :uid_copy }
  end

  def test_move_falls_back_to_copy_and_uid_expunge
    @fake.capabilities = %w[IMAP4REV1 UIDPLUS]
    @fake.folders << 'Verarbeitet'
    @client.move('5', 'Verarbeitet')
    assert_includes @fake.commands, [:uid_copy, 5, 'Verarbeitet']
    assert_includes @fake.commands, [:uid_store, 5, '+FLAGS', [:Deleted]]
    assert_includes @fake.commands, [:uid_expunge, 5]
    assert @fake.commands.none? { |c| c == [:expunge] }
  end

  # Without UIDPLUS the whole folder is expunged - the destructive last resort.
  def test_move_falls_back_to_plain_expunge_without_uidplus
    @fake.capabilities = %w[IMAP4REV1]
    @fake.folders << 'Verarbeitet'
    @client.move('5', 'Verarbeitet')
    assert_includes @fake.commands, [:expunge]
  end

  def test_folder_names_are_utf7_encoded_on_the_wire
    @client.select('Gelöschte Elemente')
    wire = @fake.commands.find { |c| c.first == :select }[1]
    assert_not_equal 'Gelöschte Elemente', wire
    assert_equal 'Gel&APY-schte Elemente', wire
  end

  def test_display_names_are_decoded_back
    @fake.folders << 'Gel&APY-schte Elemente'
    assert_includes @client.list_folders, 'Gelöschte Elemente'
  end

  def test_hierarchy_delimiter_is_translated
    @fake.delim = '.'
    @client.select('Verarbeitet/2026')
    assert_equal 'Verarbeitet.2026', @fake.commands.find { |c| c.first == :select }[1]
  end

  def test_already_existing_folder_is_not_an_error
    @fake.folders << 'Verarbeitet'
    assert_equal 'Verarbeitet', @client.create_folder('Verarbeitet')
  end

  def test_select_is_not_repeated_for_the_same_folder
    @client.select('INBOX')
    @client.select('INBOX')
    assert_equal 1, @fake.commands.count { |c| c.first == :select }
  end

  private

  def credentials
    RedmineExpertHelpdesk::Credentials.new(
      :auth_method => 'password', :username => 'hd@example.com', :password => 'pw'
    )
  end
end
