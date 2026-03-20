# frozen_string_literal: true

module Legion
  module Gaia
    module Logging
      private

      def log_debug(msg)
        Legion::Logging.debug(msg) if Legion.const_defined?('Logging')
      end

      def log_info(msg)
        Legion::Logging.info(msg) if Legion.const_defined?('Logging')
      end

      def log_warn(msg)
        Legion::Logging.warn(msg) if Legion.const_defined?('Logging')
      end
    end
  end
end
