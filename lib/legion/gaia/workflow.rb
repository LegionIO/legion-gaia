# frozen_string_literal: true

require 'legion/gaia/workflow/errors'
require 'legion/gaia/workflow/checkpoint'
require 'legion/gaia/workflow/definition'
require 'legion/gaia/workflow/instance'

module Legion
  module Gaia
    # Generic state machine DSL for workflow orchestration.
    #
    # Provides a `workflow` class method that defines a state machine on any
    # Ruby class or module, plus `create_workflow` for instantiation.
    #
    # == Quick example
    #
    #   class DocProcessor
    #     include Legion::Gaia::Workflow
    #
    #     workflow :document_processing do |w|
    #       w.state :received, initial: true
    #       w.state :parsing
    #       w.state :enriching
    #       w.state :indexed, terminal: true
    #       w.state :failed,  terminal: true
    #
    #       w.transition :received,  to: :parsing
    #       w.transition :parsing,   to: :enriching, guard: ->(ctx) { ctx[:parse_ok] }
    #       w.transition :parsing,   to: :failed
    #       w.transition :enriching, to: :indexed
    #       w.transition :enriching, to: :failed
    #
    #       w.checkpoint :enriching, name: :quality_check,
    #                    condition: ->(ctx) { ctx[:score].to_f >= 0.8 }
    #
    #       w.on_enter(:indexed) { |inst| puts "Indexed! id=#{inst.id}" }
    #       w.on_enter(:failed)  { |inst| puts "Failed!  id=#{inst.id}" }
    #     end
    #   end
    #
    #   inst = DocProcessor.create_workflow(metadata: { doc_id: 42 })
    #   inst.transition!(:parsing)
    #   inst.transition!(:enriching, parse_ok: true)
    #   inst.transition!(:indexed, score: 0.9)
    #
    # == Standalone (no include)
    #
    # You can also use the DSL directly:
    #
    #   defn = Legion::Gaia::Workflow.define(:my_pipeline) do |w|
    #     w.state :start, initial: true
    #     w.state :finish, terminal: true
    #     w.transition :start, to: :finish
    #   end
    #   inst = Legion::Gaia::Workflow::Instance.new(definition: defn)
    #   inst.transition!(:finish)
    module Workflow
      # ------------------------------------------------------------------ class methods

      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # Define a named workflow on this class.
        # Successive calls with the same +name+ replace the previous definition.
        #
        # @param name [Symbol, String]
        # @yield [definition] DSL block receives the new Definition object
        # @return [Definition]
        def workflow(name, &block)
          @workflow_definitions ||= {}
          defn = Definition.new(name.to_sym)
          block&.call(defn)
          @workflow_definitions[name.to_sym] = defn
          defn
        end

        # Look up a Definition by name.
        # @return [Definition, nil]
        def workflow_definition(name)
          @workflow_definitions&.[](name.to_sym)
        end

        # Returns all definitions registered on this class.
        # @return [Hash{Symbol => Definition}]
        def workflow_definitions
          @workflow_definitions || {}
        end

        # Create an Instance for the named workflow.
        # Uses the first (and usually only) definition if +name+ is omitted.
        #
        # @param name [Symbol, nil] workflow name; defaults to first registered
        # @param metadata [Hash]
        # @return [Instance]
        def create_workflow(name: nil, metadata: {})
          target = name ? workflow_definition(name) : workflow_definitions.values.first
          raise ArgumentError, "No workflow definition found for #{name.inspect}" unless target

          Instance.new(definition: target, metadata: metadata)
        end
      end

      # ------------------------------------------------------------------ standalone factory

      # Build a Definition without including the module into a class.
      #
      # @param name [Symbol, String]
      # @yield [definition] receives the Definition object for DSL calls
      # @return [Definition]
      def self.define(name, &block)
        defn = Definition.new(name.to_sym)
        block&.call(defn)
        defn
      end
    end
  end
end
