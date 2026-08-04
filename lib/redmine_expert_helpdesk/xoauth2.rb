# SASL XOAUTH2 initial client response, shared by the IMAP and SMTP paths.
#
# The format is the de-facto standard used by Microsoft and Google:
#
#   base64("user=" USER 0x01 "auth=Bearer " TOKEN 0x01 0x01)
#
# strict_encode64 is mandatory - a line-wrapped Base64 breaks the AUTH command.
require 'base64'

module RedmineExpertHelpdesk
  module Xoauth2
    def self.sasl_string(user, token)
      "user=#{user}\x01auth=Bearer #{token}\x01\x01"
    end

    def self.encoded(user, token)
      Base64.strict_encode64(sasl_string(user, token))
    end

    # Servers answer a rejected XOAUTH2 with a base64-encoded JSON error in the
    # challenge rather than a plain failure.
    def self.decode_challenge(challenge)
      JSON.parse(Base64.decode64(challenge.to_s))
    rescue StandardError
      {}
    end
  end
end
