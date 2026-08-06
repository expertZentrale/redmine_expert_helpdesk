# Log helper for the AI/knowledge-base features.
#
# Counterpart of MailLogger for everything the AI side wants to say about a run
# (input length, skip decisions, ...). Errors are logged by their call sites at
# warn/error level and do not pass through here.
#
# The severity comes from the 'ai_log_level' setting, with 'off' to silence the
# diagnostics entirely. One catch this class handles: Rails' own logger runs at
# :info in production, so a line written at :debug would never reach the log and
# picking 'debug' in the settings would look broken. When the configured
# severity is below what the logger accepts, the line is therefore emitted at
# the logger's own level instead and keeps its severity in the prefix
# ([helpdesk][ai][debug]) - the setting decides *whether* diagnostics are
# written, the Rails log level cannot veto that choice.
module RedmineExpertHelpdesk
  module AiLogger
    PREFIX = '[helpdesk][ai]'.freeze

    OFF = 'off'.freeze
    LEVELS = [OFF, 'debug', 'info', 'warn', 'error'].freeze
    DEFAULT_LEVEL = 'debug'.freeze

    SEVERITIES = { 'debug' => 0, 'info' => 1, 'warn' => 2, 'error' => 3 }.freeze

    class << self
      def debug(message)
        configured = level
        return if configured == OFF

        logger = Rails.logger
        return unless logger

        severity = visible_severity(logger, configured)
        logger.public_send(severity, "#{PREFIX}[#{configured}] #{message}")
      rescue StandardError
        nil
      end

      # Configured verbosity; falls back to the default for unknown values.
      def level
        configured = Setting.plugin_redmine_expert_helpdesk['ai_log_level'].to_s
        LEVELS.include?(configured) ? configured : DEFAULT_LEVEL
      rescue StandardError
        DEFAULT_LEVEL
      end

      private

      # Raises the severity to the logger's threshold when it would swallow the
      # line (production: :info). Never lowers it.
      def visible_severity(logger, configured)
        wanted = SEVERITIES[configured] || 0
        threshold = logger.respond_to?(:level) ? logger.level.to_i : 0
        SEVERITIES.key([[wanted, threshold].max, SEVERITIES['error']].min) || configured
      end
    end
  end
end
