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

    def save(result)
      FileUtils.mkdir_p(dir)
      slug = result.name.to_s.parameterize.presence || "race"
      path = File.join(dir, "#{slug}-#{SecureRandom.hex(3)}.json")
      File.write(path, JSON.pretty_generate(result.to_h))
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
