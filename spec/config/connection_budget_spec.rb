require "rails_helper"

# Rodada especial do 19 (api#74): a conta de conexões para as cidades do go-live
# cabe no Postgres configurado. Acrescentar worker, thread ou host sem rever o
# max_connections reprova aqui. Runbook: docs/operacao/conexoes-postgres.md.
RSpec.describe "Postgres connection budget for the go-live" do
  let(:go_live_cities) { 5 } # decisão do usuário, 2026-10-13
  let(:headroom) { 0.8 }     # 20% de folga
  let(:deploy) { YAML.safe_load(Rails.root.join("deploy/production/deploy.yml").read, aliases: true) }
  let(:budget) { Ops::ConnectionBudget.from_files }

  def max_connections(config = deploy)
    cmd = config.dig("accessories", "postgres", "cmd").to_s
    value = cmd[/max_connections=(\d+)/, 1]
    raise "deploy.yml: acessório postgres sem `-c max_connections=N` no cmd" unless value

    value.to_i
  end

  it "fits the go-live cities in 80% of max_connections" do
    total = budget.total(go_live_cities)
    expect(total).to be <= (max_connections * headroom).floor,
                     "#{total} conexões para #{go_live_cities} cidades; max_connections=#{max_connections}"
  end

  it "fits one city's peak in 80% of the per-role connection limit" do
    limit = deploy.dig("env", "clear", "CITY_ROLE_CONNECTION_LIMIT").to_i
    expect(budget.role_per_city).to be <= (limit * headroom).floor,
                     "pico de uma cidade #{budget.role_per_city}; CITY_ROLE_CONNECTION_LIMIT=#{limit}"
  end

  it "keeps the code default role limit above one city's peak, for environments without the variable" do
    expect(CityDatabase.role_connection_limit_default * headroom).to be >= budget.role_per_city
  end

  it "sizes the worker pool for the largest worker plus Solid Queue's two" do
    threads = deploy.dig("servers", "worker", "env", "clear", "RAILS_MAX_THREADS").to_i
    expect(threads).to be >= budget.city_workers.max + Ops::ConnectionBudget::SOLID_QUEUE_EXTRA
  end

  it "says so when the postgres accessory loses its max_connections" do
    without = deploy.deep_dup.tap { |config| config["accessories"]["postgres"]["cmd"] = "postgres" }
    expect { max_connections(without) }.to raise_error(/sem `-c max_connections=N`/)
  end
end
