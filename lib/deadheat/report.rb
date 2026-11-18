# frozen_string_literal: true

require "erb"
require "json"
require "fileutils"
require "time"

module Deadheat
  # The results of a sweep or a race-test run as one self-contained HTML page. The same page is
  # written by `bin/deadheat report` and served by the /deadheat dashboard in development.
  module Report
    Run = Struct.new(:id, :dir, :sweep, :results, :suspects, :started_at, keyword_init: true)

    STATUS = {
      "race" => ["Race", "race"], "crash" => ["Crash", "crash"], "hung" => ["Hung", "crash"],
      "differs" => ["Note", "note"], "protected" => ["Protected", "ok"], "ok" => ["No race", "ok"]
    }.freeze

    module_function

    def start(argv, out: $stdout)
      root = Dir.pwd
      open = argv.delete("--open")
      run = load(root, argv.first)
      unless run
        out.puts "No results yet. Run `bin/deadheat sweep` or your race tests first."
        return 1
      end
      path = File.join(folder(root), "report.html")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, html(run))
      out.puts "Report written to #{path.delete_prefix("#{root}/")}"
      launch(path) if open
      0
    end

    # Where results are kept: tmp/deadheat in the app, unless the config says otherwise.
    def folder(root)
      Deadheat.config.results_dir || File.join(root, "tmp/deadheat")
    end

    # Newest first. A regression test's own recheck isn't a run to show.
    def runs(root)
      Dir[File.join(folder(root), "runs/*")].select { |dir| File.directory?(dir) && !File.basename(dir).start_with?("recheck-") }
                                           .sort_by { |dir| File.mtime(dir) }.reverse
    end

    # A results file as a Hash, or nil when it's missing, half-written or not what we wrote.
    def read(path)
      data = JSON.parse(File.read(path))
      data if data.is_a?(Hash)
    rescue JSON::ParserError, SystemCallError
      nil
    end

    # A run's id is its folder name under tmp/deadheat/runs. Anything else (a path, "..") is refused,
    # so an id can never point outside that folder.
    RUN_ID = /\A[A-Za-z0-9][\w.-]*\z/

    def load(root, id = nil)
      return if id && !(id.is_a?(String) && id.match?(RUN_ID) && !id.include?(".."))

      dir = id ? File.join(folder(root), "runs", id) : runs(root).find { |d| Dir[File.join(d, "*.json")].any? }
      return unless dir && File.directory?(dir)

      sweep = read(File.join(dir, "sweep.json"))
      results = Dir[File.join(dir, "*.json")].filter_map do |path|
        next if File.basename(path).start_with?("sweep", "targets-")

        data = read(path)
        data if data && data["findings"].is_a?(Array)
      end
      suspects = Array(read(File.join(folder(root), "scan.json"))&.dig("suspects")).grep(Hash)
      Run.new(id: File.basename(dir), dir: dir, sweep: sweep, results: results, suspects: suspects, started_at: File.mtime(dir))
    end

    # Opens the report in the default browser. Each command gets the path as one argument and no
    # shell is involved, so a folder name can't be read as a command.
    def launch(path)
      command = case RbConfig::CONFIG["host_os"]
                when /mswin|mingw|cygwin/ then ["explorer.exe", path.tr("/", "\\")]
                when /darwin/ then ["open", path]
                else ["xdg-open", path]
                end
      system(*command, out: File::NULL, err: File::NULL)
    end

    # ---- the page ------------------------------------------------------------------------------

    def html(run)
      entries = entries(run)
      problems = entries.select { |e| %w[race crash hung].include?(e[:status]) }
      notes = entries.select { |e| e[:status] == "differs" }
      clean = entries.select { |e| %w[ok protected].include?(e[:status]) }
      ERB.new(TEMPLATE, trim_mode: "-").result(binding)
    end

    # One entry per race (a sweep target, or a race test), worst first.
    def entries(run)
      list = run.results.map do |result|
        finding = (result["findings"] || []).first
        status = finding ? finding["status"] : "ok"
        sweep = result["sweep"]
        {
          title: sweep ? "#{sweep['method']} #{sweep['route'] || sweep['path']}" : result["name"],
          subtitle: sweep ? "from #{sweep['name']} (#{sweep['file']})" : result["location"],
          status: status,
          result: result,
          findings: result["findings"] || [],
          broken: result.fetch("counts", {}).values_at("race", "crash", "hung").compact.sum,
          tries: result["tries"],
          irreversible: result["irreversible"],
          suspects: suspects_for(run, result)
        }
      end
      order = %w[race crash hung differs protected ok]
      list.sort_by { |e| [order.index(e[:status]) || 9, e[:title].to_s] }
    end

    # Scan suspects in the code the race's queries came from.
    def suspects_for(run, result)
      sources = (result["findings"] || []).flat_map { |f| (f["timeline"] || []).filter_map { |row| row["source"]&.split(":")&.first } }.uniq
      run.suspects.select { |s| sources.include?(s["file"]) }
    end

    def h(text)
      ERB::Util.html_escape(text.to_s)
    end

    # `code` spans for backticked words in our own sentences.
    def prose(text)
      h(text).gsub(/`([^`]+)`/) { "<code>#{Regexp.last_match(1)}</code>" }
    end

    def when_text(run)
      run.started_at.strftime("%-d %b %Y, %H:%M")
    end

    def duration(seconds)
      return "" unless seconds.is_a?(Numeric)

      seconds < 60 ? "#{seconds.round(1)} s" : "#{(seconds / 60).floor}m #{(seconds % 60).round.to_s.rjust(2, '0')}s"
    end

    def database(run)
      run.results.filter_map { |r| r["database"] }.first
    end

    # Rows for the two-lane timeline: [time, actor index, row].
    def lanes(finding)
      actors = finding["actors"] || finding["timeline"].map { |row| row["actor"] }.uniq
      [actors, finding["timeline"].map { |row| [row, actors.index(row["actor"]) || 0] }]
    end

    def overlap_tables(finding)
      text = finding["why"].to_s
      text[/(?:read|looked in) (\w+) before/, 1]
    end

    TEMPLATE = <<~'ERB'
      <!doctype html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
      <title>Dead Heat report</title>
      <style>
        :root {
          --bg: #f7f7f5; --panel: #ffffff; --ink: #18181b; --muted: #6b6b72; --line: #e6e5e1; --soft: #f1f0ec;
          --race: #d92d20; --race-bg: #fdecea; --crash: #b54708; --crash-bg: #fef4e6; --note: #3559c7; --note-bg: #ebf0fd;
          --ok: #067647; --ok-bg: #e8f6ee; --a: #3559c7; --b: #b42fa0; --mark: #fff3bf;
          --mono: ui-monospace, "SF Mono", "Cascadia Mono", Menlo, Consolas, monospace;
        }
        @media (prefers-color-scheme: dark) {
          :root { --bg: #111113; --panel: #18181b; --ink: #ededef; --muted: #9b9ba3; --line: #2a2a2f; --soft: #202024;
            --race: #ff6b5e; --race-bg: #3a1714; --crash: #f5a524; --crash-bg: #33230b; --note: #8aa2ff; --note-bg: #1b2340;
            --ok: #4ad295; --ok-bg: #10291d; --a: #8aa2ff; --b: #f08ad8; --mark: #3b3416; }
        }
        * { box-sizing: border-box; }
        body { margin: 0; background: var(--bg); color: var(--ink); font: 15px/1.55 system-ui, -apple-system, "Segoe UI", sans-serif; }
        main { max-width: 1080px; margin: 0 auto; padding: 32px 20px 64px; }
        header { display: flex; align-items: center; gap: 12px; margin-bottom: 6px; }
        .logo { width: 28px; height: 28px; position: relative; flex: none; }
        .logo i { position: absolute; left: 0; right: 0; height: 3px; border-radius: 2px; background: var(--ink); }
        .logo i:nth-child(1) { top: 7px; } .logo i:nth-child(2) { top: 18px; }
        .logo b { position: absolute; top: 0; bottom: 0; left: 18px; width: 3px; border-radius: 2px; background: var(--race); }
        h1 { font-size: 22px; margin: 0; letter-spacing: -0.01em; }
        .meta { color: var(--muted); margin: 0 0 24px 40px; }
        .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 12px; margin-bottom: 28px; }
        .stat { background: var(--panel); border: 1px solid var(--line); border-radius: 12px; padding: 14px 16px; }
        .stat strong { display: block; font-size: 26px; line-height: 1.2; font-variant-numeric: tabular-nums; }
        .stat span { color: var(--muted); font-size: 13px; }
        .stat.race strong { color: var(--race); } .stat.ok strong { color: var(--ok); }
        h2 { font-size: 13px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); margin: 28px 0 10px; }
        details.card { background: var(--panel); border: 1px solid var(--line); border-radius: 12px; margin-bottom: 10px; overflow: hidden; }
        details.card > summary { list-style: none; cursor: pointer; padding: 14px 16px; display: grid; grid-template-columns: auto 1fr auto; gap: 4px 12px; align-items: baseline; }
        details.card > summary::-webkit-details-marker { display: none; }
        details.card[open] > summary { border-bottom: 1px solid var(--line); }
        .pill { font-size: 12px; font-weight: 600; padding: 2px 9px; border-radius: 999px; white-space: nowrap; }
        .pill.race { color: var(--race); background: var(--race-bg); } .pill.crash { color: var(--crash); background: var(--crash-bg); }
        .pill.note { color: var(--note); background: var(--note-bg); } .pill.ok { color: var(--ok); background: var(--ok-bg); }
        .endpoint { font-family: var(--mono); font-size: 14px; font-weight: 600; overflow-wrap: anywhere; }
        .count { color: var(--muted); font-size: 13px; white-space: nowrap; font-variant-numeric: tabular-nums; }
        .headline { grid-column: 2 / 4; }
        .sub { grid-column: 2 / 4; color: var(--muted); font-size: 13px; }
        .irr { display: inline-block; margin-left: 8px; font-size: 12px; font-weight: 600; color: var(--race); border: 1px solid currentColor; border-radius: 6px; padding: 0 6px; }
        .body { padding: 16px; display: grid; grid-template-columns: minmax(0, 1fr); gap: 18px; }
        .body > * { min-width: 0; }
        .timeline table { min-width: 560px; }
        .body h3 { margin: 0 0 6px; font-size: 13px; color: var(--muted); font-weight: 600; }
        .body p { margin: 0; }
        ul.diff { margin: 0; padding: 0; list-style: none; display: grid; gap: 4px; }
        ul.diff li { background: var(--soft); border-radius: 8px; padding: 6px 10px; font-family: var(--mono); font-size: 13px; overflow-wrap: anywhere; }
        ul.fix { margin: 0; padding-left: 18px; display: grid; gap: 6px; }
        code { font-family: var(--mono); font-size: 0.92em; background: var(--soft); padding: 1px 5px; border-radius: 5px; }
        .timeline { border: 1px solid var(--line); border-radius: 10px; overflow-x: auto; }
        .timeline table { width: 100%; border-collapse: collapse; font-family: var(--mono); font-size: 12.5px; }
        .timeline th { text-align: left; font-family: system-ui, sans-serif; font-size: 12px; color: var(--muted); font-weight: 600; padding: 8px 10px; border-bottom: 1px solid var(--line); background: var(--soft); }
        .timeline td { padding: 6px 10px; vertical-align: top; border-bottom: 1px solid var(--line); }
        .timeline tr:last-child td { border-bottom: 0; }
        .timeline td.t { color: var(--muted); white-space: nowrap; text-align: right; width: 70px; }
        .timeline td.q { width: 45%; overflow-wrap: anywhere; }
        .timeline .lane0 { border-left: 3px solid var(--a); } .timeline .lane1 { border-left: 3px solid var(--b); }
        .timeline tr.hot td.q.filled { background: var(--mark); }
        .timeline tr.quiet td.q.filled { opacity: 0.5; }
        .timeline .src { display: block; color: var(--muted); font-size: 11.5px; margin-top: 2px; }
        .timeline .wait { display: block; color: var(--crash); font-size: 11.5px; margin-top: 2px; }
        .kind { font-size: 11px; font-weight: 600; color: var(--muted); margin-right: 6px; text-transform: uppercase; }
        .repro { font-family: var(--mono); font-size: 13px; background: var(--soft); border-radius: 8px; padding: 8px 10px; overflow-x: auto; white-space: nowrap; }
        ul.clean { margin: 0; padding: 0; list-style: none; background: var(--panel); border: 1px solid var(--line); border-radius: 12px; }
        ul.clean li { display: flex; justify-content: space-between; gap: 12px; padding: 9px 16px; border-bottom: 1px solid var(--line); }
        ul.clean li:last-child { border-bottom: 0; }
        ul.clean .endpoint { font-weight: 500; }
        .empty { background: var(--panel); border: 1px solid var(--line); border-radius: 12px; padding: 24px; text-align: center; color: var(--muted); }
        footer { margin-top: 40px; color: var(--muted); font-size: 13px; }
        @media (max-width: 640px) {
          main { padding: 20px 14px 48px; }
          details.card > summary { grid-template-columns: auto 1fr; }
          .count { grid-column: 2; }
          .headline, .sub { grid-column: 1 / 3; }
          .meta { margin-left: 0; }
        }
      </style>
      </head>
      <body>
      <main>
        <header><div class="logo" aria-hidden="true"><i></i><i></i><b></b></div><h1>Dead Heat</h1></header>
        <p class="meta">
          <%= run.sweep ? "Sweep of #{entries.size} endpoint#{'s' unless entries.size == 1}" : "#{entries.size} race test#{'s' unless entries.size == 1}" %>
          · <%= h database(run) %> · <%= h when_text(run) %><%= run.sweep ? h(" · #{duration(run.sweep['seconds'])}") : "" %>
        </p>

        <section class="stats">
          <div class="stat <%= problems.any? ? 'race' : 'ok' %>"><strong><%= problems.size %></strong><span><%= problems.size == 1 ? "race found" : "races found" %><%= problems.count { |e| e[:irreversible] }.positive? ? " · #{problems.count { |e| e[:irreversible] }} irreversible" : "" %></span></div>
          <div class="stat ok"><strong><%= clean.size %></strong><span>no race found</span></div>
          <% if notes.any? %><div class="stat"><strong><%= notes.size %></strong><span>right data, different replies</span></div><% end %>
          <% if (cov = run.sweep&.dig("coverage")) && cov["share"] %>
          <div class="stat"><strong><%= (cov["share"].to_f * 100).round %>%</strong><span><%= h cov["checked"] %> of <%= h cov["write_endpoints"] %> write endpoints checked, no setup</span></div>
          <% end %>
        </section>

        <% if problems.empty? %>
          <div class="empty">No races found<%= entries.first && entries.first[:tries] ? h(" in #{entries.first[:tries]} tries per #{run.sweep ? 'endpoint' : 'race'}") : "" %>. A timing bug can't be proven absent, but none showed up.</div>
        <% else %>
          <h2>Races</h2>
        <% end %>

        <% (problems + notes).each_with_index do |entry, index| %>
          <% finding = entry[:findings].first %>
          <% label, css = STATUS.fetch(entry[:status], ["?", "note"]) %>
          <details class="card" <%= index.zero? ? "open" : "" %>>
            <summary>
              <span class="pill <%= css %>"><%= label %></span>
              <span class="endpoint"><%= h entry[:title] %></span>
              <span class="count"><%= h(entry[:status] == "differs" ? finding["count"] : entry[:broken]) %>/<%= h entry[:tries] %> tries</span>
              <span class="headline"><%= prose finding["title"] %><% if finding["irreversible"] %><span class="irr">Irreversible</span><% end %></span>
              <% if entry[:subtitle] %><span class="sub"><%= h entry[:subtitle] %></span><% end %>
            </summary>
            <div class="body">
              <% if finding["lines"]&.any? %>
              <div><h3>Two at once, compared with one at a time</h3><ul class="diff"><% finding["lines"].each do |line| %><li><%= h line %></li><% end %></ul></div>
              <% end %>
              <% if finding["why"] && entry[:status] != "differs" %><div><h3>Why</h3><p><%= prose finding["why"] %></p></div><% end %>
              <% if finding["timeline"]&.any? %>
              <% actors, rows = lanes(finding) %>
              <% hot = overlap_tables(finding) %>
              <div>
                <h3>What happened in try <%= h finding["try"] %> (<%= h finding["pauses"] %>)</h3>
                <div class="timeline"><table>
                  <tr><th></th><% actors.first(2).each do |actor| %><th><%= h actor %></th><% end %></tr>
                  <% written = finding["timeline"].select { |r| r["kind"] == "write" }.flat_map { |r| r["tables"] || [] }.uniq %>
                  <% rows.each do |row, lane| %>
                  <% hit = hot && row["sql"].to_s.match?(/\b#{Regexp.escape(hot)}\b/) && row["kind"] != "transaction" %>
                  <% quiet = !hit && row["kind"] == "read" && row["tables"] && (row["tables"] & written).empty? %>
                  <tr class="<%= hit ? 'hot' : '' %><%= quiet ? 'quiet' : '' %>">
                    <td class="t"><%= format("%.1f", row["at_ms"].to_f) %> ms</td>
                    <% 2.times do |i| %>
                    <% if i == lane %>
                    <td class="q filled lane<%= i %>"><span class="kind"><%= h(row["kind"] == "transaction" ? "tx" : row["kind"]) %></span><%= h row["sql"] %><% if row["source"] %><span class="src"><%= h row["source"] %></span><% end %><% if row["pause"] && row["paused_ms"].to_i.positive? %><span class="wait">waited <%= h row["paused_ms"] %> ms <%= h row["pause"] %> this query</span><% end %></td>
                    <% else %>
                    <td class="q"></td>
                    <% end %>
                    <% end %>
                  </tr>
                  <% end %>
                </table></div>
              </div>
              <% end %>
              <% if finding["fixes"]&.any? && entry[:status] != "differs" %>
              <div><h3>How to fix it</h3><ul class="fix"><% finding["fixes"].each do |fix| %><li><%= prose fix %></li><% end %></ul></div>
              <% end %>
              <% if entry[:suspects].any? %>
              <div><h3>The scan flagged this code too</h3><ul class="diff"><% entry[:suspects].each do |s| %><li><%= h "#{s['file']}:#{s['line']}" %> · <%= h s["message"] %></li><% end %></ul></div>
              <% end %>
              <% if entry[:result]["reproduce"] && entry[:status] != "differs" %>
              <div><h3>Run it again</h3><div class="repro"><%= h entry[:result]["reproduce"] %></div></div>
              <% end %>
            </div>
          </details>
        <% end %>

        <% if clean.any? %>
          <h2>No race found</h2>
          <ul class="clean">
            <% clean.each do |entry| %>
            <li><span class="endpoint"><%= h entry[:title] %></span><span class="count"><%= h entry[:tries] %> tries<%= entry[:status] == "protected" ? " · protected" : "" %></span></li>
            <% end %>
          </ul>
        <% end %>

        <footer>Dead Heat <%= Deadheat::VERSION %> · run <%= h run.id %> · "No race found" means none showed up in that many tries, not that one can't happen.</footer>
      </main>
      </body>
      </html>
    ERB
  end
end
