require File.expand_path('../../test_helper', __FILE__)

class SecretBoxTest < ActiveSupport::TestCase
  SecretBox = RedmineExpertHelpdesk::SecretBox

  def test_round_trip
    encrypted = SecretBox.encrypt('s3cret')
    assert_not_equal 's3cret', encrypted
    assert SecretBox.encrypted?(encrypted)
    assert_equal 's3cret', SecretBox.decrypt(encrypted)
  end

  # Pre-existing plaintext must stay readable so no data migration is needed.
  def test_plaintext_passes_through
    assert_equal 'legacy-plaintext', SecretBox.decrypt('legacy-plaintext')
    assert_not SecretBox.encrypted?('legacy-plaintext')
  end

  def test_blank_values
    assert_nil SecretBox.encrypt(nil)
    assert_equal '', SecretBox.encrypt('')
    assert_equal '', SecretBox.decrypt(nil)
  end

  def test_already_encrypted_is_not_double_wrapped
    once = SecretBox.encrypt('token')
    assert_equal once, SecretBox.encrypt(once)
  end

  def test_undecryptable_value_raises
    tampered = "#{SecretBox::PREFIX}not-a-valid-ciphertext"
    assert_raise(SecretBox::DecryptionError) { SecretBox.decrypt(tampered) }
    assert_nil SecretBox.decrypt_safe(tampered)
  end
end
