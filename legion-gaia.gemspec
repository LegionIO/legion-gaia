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
  spec.add_dependency 'legion-json', '>= 1.2.0'
  spec.add_dependency 'legion-logging', '>= 1.5.0'
  spec.add_dependency 'legion-settings', '>= 1.3.12'
  spec.add_dependency 'openssl'

  # Tick orchestrator — GAIA is inoperable without this
  spec.add_dependency 'lex-tick'

  # Privacy enforcement — safety layer for the cognitive stack
  spec.add_dependency 'lex-privatecore'

  # PHASE_MAP operational extensions (required for full tick cycle)
  spec.add_dependency 'legion-apollo', '>= 0.2.1'
  spec.add_dependency 'lex-apollo'
  spec.add_dependency 'lex-coldstart'
  spec.add_dependency 'lex-detect'
  spec.add_dependency 'lex-mesh'
  spec.add_dependency 'lex-synapse'

  # Consolidated cognitive domain gems (13 pillars of the mind)
  spec.add_dependency 'lex-agentic-affect'
  spec.add_dependency 'lex-agentic-attention'
  spec.add_dependency 'lex-agentic-defense'
  spec.add_dependency 'lex-agentic-executive'
  spec.add_dependency 'lex-agentic-homeostasis'
  spec.add_dependency 'lex-agentic-imagination'
  spec.add_dependency 'lex-agentic-inference'
  spec.add_dependency 'lex-agentic-integration'
  spec.add_dependency 'lex-agentic-language'
  spec.add_dependency 'lex-agentic-learning'
  spec.add_dependency 'lex-agentic-memory'
  spec.add_dependency 'lex-agentic-self', '>= 0.1.4'
  spec.add_dependency 'lex-agentic-social'
end
