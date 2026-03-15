# frozen_string_literal: true

require_relative 'lib/legion/gaia/version'

Gem::Specification.new do |spec|
  spec.name = 'legion-gaia'
  spec.version       = Legion::Gaia::VERSION
  spec.authors       = ['Esity']
  spec.email         = ['matthewdiverson@gmail.com']
  spec.summary       = 'Cognitive coordination layer for the LegionIO framework'
  spec.description   = 'GAIA is the mind that inhabits the Legion body. Coordinates agentic subordinate functions, ' \
                       'drives the tick cycle, and provides channel abstraction for multi-interface communication.'
  spec.homepage      = 'https://github.com/LegionIO/legion-gaia'
  spec.license       = 'Apache-2.0'
  spec.require_paths = ['lib']
  spec.required_ruby_version = '>= 3.4'
  spec.files = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.extra_rdoc_files = %w[README.md LICENSE CHANGELOG.md]
  spec.metadata = {
    'bug_tracker_uri' => 'https://github.com/LegionIO/legion-gaia/issues',
    'changelog_uri' => 'https://github.com/LegionIO/legion-gaia/blob/main/CHANGELOG.md',
    'documentation_uri' => 'https://github.com/LegionIO/legion-gaia',
    'homepage_uri' => 'https://github.com/LegionIO/LegionIO',
    'source_code_uri' => 'https://github.com/LegionIO/legion-gaia',
    'wiki_uri' => 'https://github.com/LegionIO/legion-gaia/wiki',
    'rubygems_mfa_required' => 'true'
  }

  spec.add_dependency 'base64'
  spec.add_dependency 'legion-json'
  spec.add_dependency 'legion-logging'
end
