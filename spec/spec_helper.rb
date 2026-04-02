# frozen_string_literal: true

require 'bundler/setup'
require 'legion/logging'
require 'legion/settings'
Legion::Logging.setup(log_file: './legion.log', level: 'fatal')
Legion::Settings.load

require 'legion/gaia'

RSpec.configure do |config|
  config.example_status_persistence_file_path = '.rspec_status'
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
