# Encryption for secrets stored in helpdesk_mailboxes columns (OAuth client
# secrets, refresh tokens, IMAP/SMTP passwords, service-account keys).
#
# ActiveRecord::Encryption ("encrypts :foo") would be the obvious choice but is
# Rails 7+; this plugin still supports Redmine 5.1 (Rails 6.1). ActiveSupport's
# MessageEncryptor behaves identically on Rails 6.1 through 8.
#
# Encrypted values carry a "enc:v1:" prefix. Values without the prefix are
# returned unchanged, so any pre-existing plaintext stays readable and no data
# migration is forced.
#
# Caveat: rotating Rails' secret_key_base makes stored secrets unrecoverable.
# Operators then have to re-enter passwords and re-run the OAuth consent.
module RedmineExpertHelpdesk
  module SecretBox
    PREFIX = 'enc:v1:'.freeze
    SALT   = 'redmine_expert_helpdesk mailbox secret'.freeze
    CIPHER = 'aes-256-gcm'.freeze

    class DecryptionError < StandardError; end

    class << self
      # Returns nil for blank input, otherwise the prefixed ciphertext.
      def encrypt(value)
        return nil if value.nil?

        str = value.to_s
        return str if str.empty?
        return str if encrypted?(str) # already encrypted, don't double-wrap

        PREFIX + encryptor.encrypt_and_sign(str)
      end

      # Returns the plaintext. Values without the prefix are legacy plaintext
      # and pass through untouched.
      def decrypt(value)
        str = value.to_s
        return str unless encrypted?(str)

        encryptor.decrypt_and_verify(str[PREFIX.length..-1])
      rescue ActiveSupport::MessageEncryptor::InvalidMessage,
             ActiveSupport::MessageVerifier::InvalidSignature => e
        raise DecryptionError, e.message
      end

      # Like #decrypt but never raises — returns nil when the value cannot be
      # decrypted (e.g. after a secret_key_base rotation).
      def decrypt_safe(value)
        decrypt(value)
      rescue DecryptionError
        nil
      end

      def encrypted?(value)
        value.to_s.start_with?(PREFIX)
      end

      def reset!
        @encryptor = nil
      end

      private

      def encryptor
        @encryptor ||= begin
          len = ActiveSupport::MessageEncryptor.key_len(CIPHER)
          key = ActiveSupport::KeyGenerator.new(secret_key_base).generate_key(SALT, len)
          ActiveSupport::MessageEncryptor.new(key, :cipher => CIPHER)
        end
      end

      def secret_key_base
        Rails.application.secret_key_base.presence ||
          raise(DecryptionError, 'secret_key_base is not configured')
      end
    end
  end
end
