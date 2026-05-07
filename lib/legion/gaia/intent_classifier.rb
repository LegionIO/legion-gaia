# frozen_string_literal: true

module Legion
  module Gaia
    module IntentClassifier
      extend Legion::Logging::Helper

      INTENT_TYPES = %i[casual question directive seeking_advice greeting urgent direct_engage].freeze

      GREETING_PATTERN = /\A\s*(hi|hello|hey|good\s+(morning|afternoon|evening)|howdy|greetings)\b/i
      QUESTION_PATTERN = /\?\s*\z|\b(what|how|why|when|where|who|which|can you|could you|is there)\b/i
      SEEKING_ADVICE_PATTERN = /\b(what do you think|should i|help me|your (opinion|thoughts|advice)|recommend)\b/i
      DIRECTIVE_PATTERN = /\A\s*(run|deploy|execute|start|stop|create|delete|update|fix|check|do)\b/i
      URGENT_PATTERN = /\b(asap|critical|broken|down|emergency|urgent|immediately|outage)\b/i
      DIRECT_ADDRESS_PATTERN = /\bgaia\b/i

      module_function

      def classify(content)
        log.debug "classify(#{content})"
        text = content.to_s.strip
        return :casual if text.empty?

        return :greeting if text.match?(GREETING_PATTERN)
        return :urgent if text.match?(URGENT_PATTERN)
        return :seeking_advice if text.match?(SEEKING_ADVICE_PATTERN)
        return :directive if text.match?(DIRECTIVE_PATTERN)
        return :question if text.match?(QUESTION_PATTERN)

        :casual
      end

      def direct_engage?(content)
        log.debug "direct_engage?(#{content})"
        content.to_s.match?(DIRECT_ADDRESS_PATTERN)
      end

      def classify_with_engagement(content)
        log.debug "classify_with_engagement(#{content})"
        { intent: classify(content), direct_engage: direct_engage?(content) }
      end
    end
  end
end
