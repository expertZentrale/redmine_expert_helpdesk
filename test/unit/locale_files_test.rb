require File.expand_path('../../test_helper', __FILE__)

# Every UI language ships every key. Redmine falls back to English for a
# missing one, so a gap fails nowhere else: the page just shows an English
# label in the middle of a translated screen.
class HelpdeskLocaleFilesTest < ActiveSupport::TestCase
  LOCALES = %w(en de es fr it pt pt-BR).freeze
  DIR = File.expand_path('../../../config/locales', __FILE__)

  def test_the_plugin_ships_exactly_these_locales
    shipped = Dir.glob(File.join(DIR, '*.yml')).map { |path| File.basename(path, '.yml') }
    assert_equal LOCALES.sort, shipped.sort
  end

  # Redmine offers only the languages core ships a file for, so any other
  # code (pt_BR, es-MX) would never be picked. Core's files are the list:
  # I18n.available_locales would also count this plugin's own files.
  def test_every_locale_is_one_redmine_core_ships
    core = Dir.glob(Rails.root.join('config', 'locales', '*.yml').to_s).map { |path| File.basename(path, '.yml') }
    LOCALES.each { |code| assert_includes core, code }
  end

  def test_every_locale_has_the_english_keys_in_the_same_order
    english = entries('en').map(&:first)
    (LOCALES - ['en']).each do |code|
      keys = entries(code).map(&:first)
      assert_equal [], english - keys, "missing in #{code}.yml"
      assert_equal [], keys - english, "not in en.yml but in #{code}.yml"
      assert_equal english, keys, "order of #{code}.yml"
    end
  end

  def test_translations_are_filled_and_keep_their_placeholders
    english = Hash[entries('en')]
    (LOCALES - ['en']).each do |code|
      entries(code).each do |key, value|
        assert value.is_a?(String) && !value.strip.empty?, "#{code}.#{key} is empty"
        assert_equal placeholders(english[key]), placeholders(value), "placeholders of #{code}.#{key}"
      end
    end
  end

  private

  def entries(code)
    data = YAML.safe_load(File.read(File.join(DIR, "#{code}.yml")))
    assert_equal [code], data.keys, "root key of #{code}.yml"
    flatten(data[code])
  end

  def flatten(hash, prefix = nil)
    hash.each_with_object([]) do |(key, value), list|
      path = prefix ? "#{prefix}.#{key}" : key.to_s
      if value.is_a?(Hash)
        list.concat(flatten(value, path))
      else
        list << [path, value]
      end
    end
  end

  # %{name} interpolations and the helpdesk's {{macro}} names.
  def placeholders(text)
    text.to_s.scan(/%\{\w+\}|\{\{[^}]*\}\}/).sort
  end
end
