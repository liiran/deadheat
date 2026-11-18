# frozen_string_literal: true

module Deadheat
  # Many apps wrap every test in DatabaseCleaner's :transaction strategy. Racing requests use their own
  # database connections and can't see rows inside that open transaction, so while Dead Heat races (a
  # race test, or a test the sweep chose) DatabaseCleaner's start and clean step aside. Dead Heat puts
  # every table it touched back the way it was instead.
  module DatabaseCleanerPause
    KEY = :deadheat_pause_database_cleaner

    module Methods
      def start
        DatabaseCleanerPause.paused? ? nil : super
      end

      def clean
        DatabaseCleanerPause.paused? ? nil : super
      end

      def cleaning(&block)
        DatabaseCleanerPause.paused? ? block.call : super
      end
    end

    class << self
      def install!
        return if @installed || !defined?(::DatabaseCleaner)

        @installed = true
        ::DatabaseCleaner.singleton_class.prepend(Methods)
      end

      def pause
        install!
        previous = paused?
        Thread.current.thread_variable_set(KEY, true)
        yield
      ensure
        Thread.current.thread_variable_set(KEY, previous)
      end

      def start_pause
        install!
        Thread.current.thread_variable_set(KEY, true)
      end

      def stop_pause
        Thread.current.thread_variable_set(KEY, nil)
      end

      def paused?
        Thread.current.thread_variable_get(KEY) ? true : false
      end
    end
  end
end
