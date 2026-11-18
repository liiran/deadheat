# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Deadheat
  # Saves each race's result as JSON under tmp/deadheat/, for `deadheat report` and the dashboard.
  module Results
    module_function

    def run_id
      @run_id ||= ENV["DEADHEAT_RUN_ID"] || Time.now.utc.strftime("%Y%m%d-%H%M%S")
    end

    def dir
      File.join(Deadheat.config.results_path, "runs", run_id)
    end

    KEEP = 30
    OURS = /\A(?:recheck-)?\d{8}-\d{6}(?:-\h+)?\z/

    # Keeps the newest runs and deletes older ones. Only folders named like a run and holding nothing
    # but Dead Heat's own files are ever deleted.
    def prune(runs = File.join(Deadheat.config.results_path, "runs"), keep: KEEP)
      folders = Dir[File.join(runs, "*")].select { |path| File.directory?(path) && File.basename(path).match?(OURS) }
      old = folders.sort_by { |path| File.mtime(path) }[0...-keep] || []
      old.each do |path|
        entries = Dir.children(path)
        FileUtils.rm_r(path, secure: true) if entries.all? { |name| name.match?(/\.(?:json|jsonl|log)\z/) && File.file?(File.join(path, name)) }
      end
    rescue SystemCallError
      nil
    end

    def save(result, extra: {})
      prune unless @pruned
      @pruned = true
      FileUtils.mkdir_p(dir)
      slug = result.name.to_s.parameterize.first(60).delete_suffix("-").presence || "race"
      path = File.join(dir, "#{slug}-#{SecureRandom.hex(3)}.json")
      File.write(path, JSON.pretty_generate(result.to_h.merge(extra)))
      path
    rescue SystemCallError => e
      warn "Dead Heat couldn't save its result: #{e.message}"
      nil
    end

    def reset!
      @run_id = nil
    end
  end
end
