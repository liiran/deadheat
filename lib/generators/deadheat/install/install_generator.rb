# frozen_string_literal: true

require "rails/generators"

module Deadheat
  module Generators
    # bin/rails generate deadheat:install
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)
      desc "Sets up Dead Heat: bin/deadheat, a race test folder with an example, and the results dashboard."

      def create_binstub
        template "deadheat", "bin/deadheat"
        chmod "bin/deadheat", 0o755
      end

      def create_race_folder
        if rspec?
          template "race_helper_rspec.rb", "spec/races/race_helper.rb"
          template "example_race_spec.rb", "spec/races/example_race_spec.rb"
        else
          template "race_helper_minitest.rb", "test/races/race_helper.rb"
          template "example_race_test.rb", "test/races/example_race_test.rb"
        end
      end

      def ignore_results
        gitignore = File.join(destination_root, ".gitignore")
        return unless File.exist?(gitignore)

        lines = File.read(gitignore).lines.map(&:strip)
        return if lines.any? { |line| %w[/tmp/* /tmp tmp/ /tmp/ tmp /tmp/deadheat/].include?(line) }

        append_to_file ".gitignore", "\n# Dead Heat results\n/tmp/deadheat/\n"
      end

      def mount_dashboard
        route 'mount Deadheat::Engine => "/deadheat" if Rails.env.development?'
      end

      def next_steps
        folder = rspec? ? "spec/races" : "test/races"
        say <<~TEXT

          Dead Heat is set up. Next:

            bin/deadheat sweep     send each write request your tests make twice at once
            bin/deadheat scan      list places in the code that look racy
            bin/deadheat report    open the results

          Race tests go in #{folder}/. The example there shows the shape.
          If your app signs users in some other way than Devise or Rails 8's `sign_in_as`,
          tell Dead Heat how in #{folder}/race_helper.rb.
        TEXT
      end

      private

      def rspec?
        File.exist?(File.join(destination_root, ".rspec")) || File.directory?(File.join(destination_root, "spec"))
      end
    end
  end
end
