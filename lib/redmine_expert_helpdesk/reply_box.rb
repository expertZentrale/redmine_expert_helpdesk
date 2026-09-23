# Colours of the customer-facing block in the ticket edit form.
#
# The reply to a customer is written in Redmine's ordinary note field, which looks
# exactly like the field used for an internal note. _reply_in_edit.html.erb therefore
# wraps the mail fields, the note editor and the signature preview in one block and
# marks it while the reply is armed: a coloured background, plus a hazard border that
# says the text leaves the house.
#
# Both colours are configurable centrally and per project (HelpdeskProjectSetting
# #effective_reply_box_color / #effective_reply_hazard_color).
module RedmineExpertHelpdesk
  module ReplyBox
    # The blue the block has always had, and an amber that reads as caution without
    # competing with Redmine's own red error styling.
    #
    # These constants are the real fallback, not init.rb's :default hash: a key added
    # there reads nil on every install whose settings form has not been saved since,
    # and a nil colour would reach the stylesheet as an empty custom property.
    DEFAULT_BOX_COLOR    = '#edf2fa'.freeze
    DEFAULT_HAZARD_COLOR = '#e8a33d'.freeze

    # #rgb or #rrggbb, nothing else.
    HEX_COLOR = /\A#(\h{3}|\h{6})\z/.freeze

    module_function

    # The value if it is a hex colour, otherwise +fallback+.
    #
    # Both values are interpolated into a stylesheet, so an unvalidated string is a
    # style injection: "red; } body { display: none" would close the rule and write
    # its own. Anything that is not plainly a hex colour is therefore discarded rather
    # than escaped - there is no legitimate second spelling to preserve.
    def color(value, fallback)
      candidate = value.to_s.strip
      candidate.match?(HEX_COLOR) ? candidate.downcase : fallback
    end

    def box_color(value)
      color(value, DEFAULT_BOX_COLOR)
    end

    def hazard_color(value)
      color(value, DEFAULT_HAZARD_COLOR)
    end
  end
end
