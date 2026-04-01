# frozen_string_literal: true

module Legion
  module Gaia
    class ProactiveDispatcher
      MAX_PER_DAY     = 3
      MIN_INTERVAL    = 7200     # 2 hours
      IGNORE_COOLDOWN = 86_400   # 24 hours
      MAX_PENDING     = 5
      DAY_WINDOW      = 86_400   # 24 hours

      attr_reader :max_per_day, :min_interval, :ignore_cooldown, :pending_buffer

      def initialize(max_per_day: MAX_PER_DAY, min_interval: MIN_INTERVAL,
                     ignore_cooldown: IGNORE_COOLDOWN)
        @max_per_day     = max_per_day
        @min_interval    = min_interval
        @ignore_cooldown = ignore_cooldown
        @dispatch_log    = []
        @pending_buffer  = []
        @last_ignored_at = nil
      end

      def can_dispatch?
        prune_old_dispatches!
        return false if @dispatch_log.size >= @max_per_day
        return false if @dispatch_log.any? && (Time.now.utc - @dispatch_log.last[:at]) < @min_interval
        return false if @last_ignored_at && (Time.now.utc - @last_ignored_at) < @ignore_cooldown

        true
      end

      def record_dispatch!
        prune_old_dispatches!
        @dispatch_log << { at: Time.now.utc }
      end

      def record_ignored!
        @last_ignored_at = Time.now.utc
      end

      def dispatches_today
        prune_old_dispatches!
        @dispatch_log.size
      end

      def queue_intent(intent)
        @pending_buffer << intent
        @pending_buffer.shift while @pending_buffer.size > MAX_PENDING
      end

      def drain_pending
        drained = @pending_buffer.dup
        @pending_buffer.clear
        drained
      end

      def dispatch_with_gate(intent)
        return { dispatched: false, reason: :rate_limited } unless can_dispatch?

        content = generate_content(intent)
        return { dispatched: false, reason: :no_content } unless content

        partner_id = resolve_partner_id
        channel_id = resolve_partner_channel
        return { dispatched: false, reason: :no_partner } unless partner_id

        result = proactive_module.send_notification(
          content: content,
          priority: intent.dig(:trigger, :priority) || :low,
          channel_id: channel_id,
          user_id: partner_id
        )

        record_dispatch!
        { dispatched: true, content: content, result: result }
      rescue StandardError => e
        { dispatched: false, reason: :error, error: e.message }
      end

      private

      def prune_old_dispatches!
        cutoff = Time.now.utc - DAY_WINDOW
        @dispatch_log.reject! { |entry| entry[:at] < cutoff }
      end

      def proactive_module
        Legion::Gaia::Proactive
      end

      def generate_content(intent)
        trigger = intent[:trigger] || {}
        reason  = trigger[:reason]
        content = trigger[:content]

        prompt = build_prompt(reason, content)
        return prompt unless defined?(Legion::LLM) && Legion::LLM.started?

        result = Legion::LLM.ask(message: prompt)
        result&.content || prompt
      rescue StandardError
        prompt
      end

      def build_prompt(reason, content)
        case reason
        when :insight
          "I had an interesting insight I'd like to share with you: #{content}"
        when :check_in
          'I noticed you have been away longer than usual. Just checking in — hope everything is well.'
        when :milestone
          "Something noteworthy happened in our relationship: #{content}"
        when :curiosity
          "I have been thinking about something and wanted to ask: #{content}"
        else
          'I wanted to reach out and connect.'
        end
      end

      def resolve_partner_id
        return nil unless defined?(Legion::Gaia::BondRegistry)

        bond = Legion::Gaia::BondRegistry.all_bonds.find { |b| b[:role] == :partner }
        bond&.dig(:identity)&.to_s
      end

      def resolve_partner_channel
        return nil unless defined?(Legion::Gaia::BondRegistry)

        bond = Legion::Gaia::BondRegistry.all_bonds.find { |b| b[:role] == :partner }
        bond&.dig(:preferred_channel) || bond&.dig(:last_channel)
      end
    end
  end
end
