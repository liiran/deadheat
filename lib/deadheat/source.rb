# frozen_string_literal: true

module Deadheat
  # Finds the line of the app's own code that sent a query, the same way Rails' verbose query logs do.
  module Source
    module_function

    def root
      @root ||= defined?(Rails) && Rails.respond_to?(:root) && Rails.root ? "#{Rails.root}/" : "#{Dir.pwd}/"
    end

    def reset!
      @root = nil
    end

    # The innermost frame in the app (app/, lib/, …). A frame in the test itself is used only when
    # nothing in the app is on the stack.
    def locate
      prefix = root
      in_test = nil
      Thread.each_caller_location do |location|
        path = location.absolute_path || location.path
        next unless path&.start_with?(prefix)

        relative = path.delete_prefix(prefix)
        next if relative.start_with?("vendor/", "bin/", "config/boot", "node_modules/")
        next if path.include?("/gems/") || path.include?("/lib/deadheat")

        if relative.start_with?("test/", "spec/")
          in_test ||= "#{relative}:#{location.lineno}"
          next
        end
        return "#{relative}:#{location.lineno}"
      end
      in_test
    end
  end
end
