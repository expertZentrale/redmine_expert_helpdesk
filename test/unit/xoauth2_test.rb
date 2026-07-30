require File.expand_path('../../test_helper', __FILE__)

# The SASL string is byte-exact by protocol; a golden-value assertion catches
# any accidental reformatting.
class Xoauth2Test < ActiveSupport::TestCase
  Xoauth2 = RedmineExpertHelpdesk::Xoauth2

  def test_sasl_string_bytes
    assert_equal "user=a@b.de\x01auth=Bearer TOK\x01\x01",
                 Xoauth2.sasl_string('a@b.de', 'TOK')
  end

  def test_encoded_is_strict_base64
    encoded = Xoauth2.encoded('a@b.de', 'TOK' * 40)
    assert_not_includes encoded, "\n"
    assert_equal Xoauth2.sasl_string('a@b.de', 'TOK' * 40), Base64.decode64(encoded)
  end

  def test_decode_challenge
    payload = Base64.strict_encode64('{"status":"400","schemes":"Bearer"}')
    assert_equal '400', Xoauth2.decode_challenge(payload)['status']
  end

  def test_decode_challenge_tolerates_garbage
    assert_equal({}, Xoauth2.decode_challenge('not base64 json'))
  end
end
