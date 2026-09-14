namespace :db do
  namespace :seed do
    desc "Load the dashboard demo dataset into every dev city (idempotent)"
    task demo: :environment do
      load Rails.root.join("db/seeds/dashboard_demo.rb")
    end

    # Cada cidade é verificada dentro da conexão dela (DashboardDemo.verify!).
    desc "Verify the dashboard demo dataset populates every panel (every dev city)"
    task "demo:verify": :environment do
      require Rails.root.join("lib/dashboard_demo").to_s

      failures = DashboardDemo.verify!
      if failures.empty?
        puts "[dashboard_demo:verify] OK — all panels populated for every dev city"
      else
        abort "[dashboard_demo:verify] FAILURES:\n- #{failures.join("\n- ")}"
      end
    end
  end
end
