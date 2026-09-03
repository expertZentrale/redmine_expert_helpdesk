require File.expand_path('../../test_helper', __FILE__)
require 'tmpdir'
require 'zlib'
require 'securerandom'

# Byte floor, pixel floor and the header parsers. All free of DB/HTTP, so a Struct
# is enough as the settings object and the images are written to a temp dir.
class ImageRelevanceTest < ActiveSupport::TestCase
  Filter = RedmineExpertHelpdesk::ImageRelevance

  FakeSetting = Struct.new(:ai_min_image_kb, :keyword_init => true)
  FakeAttachment = Struct.new(:filename, :content_type, :filesize, :diskfile,
                              :keyword_init => true)

  def setup
    @dir = Dir.mktmpdir('image_relevance_test')
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  def setting(kb = Filter::DEFAULT_MIN_IMAGE_KB)
    FakeSetting.new(:ai_min_image_kb => kb)
  end

  # --- fixtures -------------------------------------------------------------

  def png(width, height)
    ihdr = [width, height].pack('N2') + [8, 2, 0, 0, 0].pack('C5')
    "\x89PNG\r\n\x1a\n".b + chunk('IHDR', ihdr) + chunk('IEND', '')
  end

  def chunk(type, data)
    body = type.b + data.b
    [data.bytesize].pack('N') + body + [Zlib.crc32(body)].pack('N')
  end

  def gif(width, height)
    "GIF89a".b + [width, height].pack('v2') + "\x00\x00\x00".b
  end

  def jpeg(width, height)
    sof = "\xff\xc0".b + [11].pack('n') + "\x08".b + [height, width].pack('n2') + "\x01\x00\x11\x00".b
    "\xff\xd8".b + sof + "\xff\xda".b + [2].pack('n')
  end

  # +bytes+ lets a test set the file size independently of the real pixel size.
  def attachment(data, name: 'shot.png', type: 'image/png', bytes: nil)
    path = File.join(@dir, "#{SecureRandom.hex(4)}_#{name}")
    File.binwrite(path, data.to_s.b)
    FakeAttachment.new(:filename => name, :content_type => type,
                       :filesize => bytes || data.to_s.bytesize, :diskfile => path)
  end

  # --- dimension parsing ----------------------------------------------------

  def test_dimensions_png
    assert_equal [800, 600], Filter.dimensions(attachment(png(800, 600)).diskfile)
  end

  def test_dimensions_gif
    assert_equal [3, 2], Filter.dimensions(attachment(gif(3, 2), :name => 'x.gif').diskfile)
  end

  def test_dimensions_jpeg
    assert_equal [640, 480], Filter.dimensions(attachment(jpeg(640, 480), :name => 'x.jpg').diskfile)
  end

  def test_dimensions_of_truncated_header_is_nil
    assert_nil Filter.dimensions(attachment(png(800, 600).byteslice(0, 12)).diskfile)
  end

  def test_dimensions_of_missing_file_is_nil
    assert_nil Filter.dimensions(File.join(@dir, 'does_not_exist.png'))
  end

  def test_dimensions_of_unknown_format_is_nil
    assert_nil Filter.dimensions(attachment('<svg/>', :name => 'x.svg', :type => 'image/svg+xml').diskfile)
  end

  # --- byte floor -----------------------------------------------------------

  def test_small_image_is_dropped
    logo = attachment(png(200, 80), :bytes => 900)
    assert_equal [], Filter.relevant_images([logo], setting)
  end

  def test_large_image_is_kept
    shot = attachment(png(800, 600), :bytes => 40 * 1024)
    assert_equal [shot], Filter.relevant_images([shot], setting)
  end

  def test_unknown_size_is_kept
    # "When in doubt, keep" - the same rule the completeness check follows.
    shot = attachment(png(800, 600), :bytes => 0)
    assert_equal [shot], Filter.relevant_images([shot], setting)
  end

  def test_zero_threshold_disables_the_byte_floor
    logo = attachment(png(200, 80), :bytes => 900)
    assert_equal [logo], Filter.relevant_images([logo], setting(0))
  end

  def test_nil_setting_falls_back_to_the_default
    logo = attachment(png(200, 80), :bytes => 900)
    assert_equal [], Filter.relevant_images([logo], nil)
  end

  # --- pixel floor ----------------------------------------------------------

  def test_tracking_pixel_is_dropped_despite_its_size
    # 1x1 padded to 20 KB passes the byte floor but carries nothing.
    pixel = attachment(png(1, 1), :bytes => 20 * 1024)
    assert_equal [], Filter.relevant_images([pixel], setting)
  end

  def test_pixel_floor_still_applies_when_the_byte_floor_is_off
    pixel = attachment(png(1, 1), :bytes => 20 * 1024)
    assert_equal [], Filter.relevant_images([pixel], setting(0))
  end

  def test_image_without_a_readable_header_is_kept
    odd = attachment('not really an image', :bytes => 40 * 1024)
    assert_equal [odd], Filter.relevant_images([odd], setting)
  end

  # --- type detection -------------------------------------------------------

  def test_non_image_is_not_selected
    doc = attachment('%PDF-1.4', :name => 'log.pdf', :type => 'application/pdf', :bytes => 40 * 1024)
    assert_equal [], Filter.relevant_images([doc], setting)
  end

  def test_image_without_content_type_is_detected_by_extension
    shot = attachment(png(800, 600), :type => '', :bytes => 40 * 1024)
    assert Filter.image?(shot)
    assert_equal [shot], Filter.relevant_images([shot], setting)
  end

  def test_input_order_is_preserved
    logo = attachment(png(200, 80), :name => 'logo.png', :bytes => 900)
    a    = attachment(png(800, 600), :name => 'a.png', :bytes => 40 * 1024)
    b    = attachment(png(640, 480), :name => 'b.png', :bytes => 30 * 1024)

    assert_equal [a, b], Filter.relevant_images([a, logo, b], setting)
  end

  # The completeness check must keep using exactly this definition.
  def test_completeness_check_shares_the_image_predicate
    shot = attachment(png(800, 600), :bytes => 40 * 1024)
    assert_equal Filter.image?(shot),
                 RedmineExpertHelpdesk::CompletenessCheck.image?(shot)
  end
end
