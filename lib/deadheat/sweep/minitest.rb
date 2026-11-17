require "deadheat"

module Deadheat
  module Sweep
    # Tells the sweep when each integration test starts and ends.
    module MinitestHook
      def before_setup
        id = "#{self.class.name}##{name}"
        # In the race pass, a chosen test runs without a wrapping transaction: racing requests use
        # their own connections and must see its data. The sweep puts every table back afterwards.
        if Sweep.target?(id)
          self.class.uses_transaction(name) if self.class.respond_to?(:uses_transaction)
          DatabaseCleanerPause.start_pause
        end
        # The file to run is the one that defines the test class (a test can come from a shared module).
        _, line = method(name).source_location
        file = Object.const_source_location(self.class.name)&.first || method(name).source_location.first
        Sweep.begin_test(id: id, file: Sweep.relative(file), line: line, name: id, context: self, framework: "minitest")
        super
      end

      def after_teardown
        super
      ensure
        Sweep.end_test
        DatabaseCleanerPause.stop_pause
      end
    end
  end
end

ActionDispatch::IntegrationTest.prepend(Deadheat::Sweep::MinitestHook) unless ActionDispatch::IntegrationTest < Deadheat::Sweep::MinitestHook
