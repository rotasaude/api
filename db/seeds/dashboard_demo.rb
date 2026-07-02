# Opt-in demo seed: populates every dashboard view (Aquisição/Triagem/Governança)
# for two municipalities, idempotently, spread over the last 30 days.
# Run: bin/rails db:seed:demo   (verify: bin/rails db:seed:demo:verify)
#
# All writes run under the admin (BYPASSRLS) connection because conversations,
# triages, consents, inbound/outbound messages, protocol_definitions,
# report_snapshots and domain_events are RLS-enforced and the seed runs without
# SET LOCAL. Idempotent via deterministic natural keys.
module DashboardDemo
  module_function

  CITIES = [
    { slug: "curitiba", name: "Curitiba Demo", uf: "PR", scale: 1.0, code: "CWB", ddd: "41" },
    { slug: "londrina", name: "Londrina Demo", uf: "PR", scale: 0.4, code: "LDB", ddd: "43" }
  ].freeze

  ACTOR_A = "ana@curitiba.demo".freeze
  ACTOR_B = "bruno@curitiba.demo".freeze

  # Deterministic timestamp `days` ago at a fixed hour/minute (no randomness).
  def at_days_ago(days, hour: 10)
    (Time.current - days.to_i.days).change(hour: hour, min: (days.to_i * 7) % 60, sec: 0)
  end

  # Map index i in [0, n) to a day offset in [0, 29], deterministically.
  def spread_days(i, n)
    n <= 1 ? 0 : ((i * 29.0) / (n - 1)).round
  end

  # Scale a base count by the city's factor (min 1).
  def scaled(base, city)
    [(base * city[:scale]).round, 1].max
  end

  def upsert_municipality(city)
    Municipality.find_or_create_by!(slug: city[:slug]) do |m|
      m.name = city[:name]
      m.uf = city[:uf]
      m.status = "active"
    end
  end

  def run!
    ApplicationRecord.connected_to(role: :admin) do
      CITIES.each do |city|
        upsert_municipality(city)
      end
    end
    report_counts
  end

  def report_counts
    ApplicationRecord.connected_to(role: :admin) do
      counts = {
        municipalities: Municipality.where(slug: CITIES.map { |c| c[:slug] }).count
      }
      puts "[dashboard_demo] #{counts.inspect}"
      counts
    end
  end
end

DashboardDemo.run!
