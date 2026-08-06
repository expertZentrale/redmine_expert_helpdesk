# Adds the "hd-awaiting" CSS class to issues waiting for an agent, so the ticket
# grid highlights them. Redmine's issues/_list.html.erb renders
# class="... <%= issue.css_classes %>" on every row, and the My Page blocks do the
# same -- one patch covers both surfaces.
#
# Applied via UnboundMethod capture, NOT prepend/super, for the same reason as
# QueriesHelperPatch: alias_method_chain-based plugins (RedmineUP
# redmine_contacts_helpdesk) may patch the same method, and prepend/super collides
# with them. Capture is order-insensitive. IssuePatch is include'd rather than
# prepended, so it cannot override css_classes either way.
module RedmineExpertHelpdesk
  module Patches
    module IssueCssClassesPatch
      def self.apply!(base)
        return if base.instance_variable_get(:@expert_helpdesk_css_classes_patched)

        original = base.instance_method(:css_classes)
        # *args: newer Redmine versions pass a user (css_classes(user = User.current)).
        base.send(:define_method, :css_classes) do |*args|
          classes = original.bind(self).call(*args)
          begin
            classes = "#{classes} hd-awaiting" if helpdesk_awaiting_agent
          rescue StandardError
            # never break the issue list over a decoration
          end
          classes
        end

        base.instance_variable_set(:@expert_helpdesk_css_classes_patched, true)
      end
    end
  end
end
