# Laboratório simulado do compose de dev/staging (ADR 0036). Só nos ambientes de
# simulação — a mesma lista de Platform::Features::SIMULATION_ENVS (sem carregar o Rails).
abort "fake-lab só roda em ambiente de simulação (development, test, staging)" unless
  %w[development test staging].include?((ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "development").to_s)

require "logger"
require_relative "runner"

client = FakeLab::Client.new(api_url: ENV.fetch("FAKE_LAB_API_URL", "http://api:3000"),
                             city_host: ENV.fetch("FAKE_LAB_CITY_HOST", "curitiba.localhost"),
                             token: ENV.fetch("FAKE_LAB_TOKEN"))
logger = Logger.new($stdout)
interval = Integer(ENV.fetch("FAKE_LAB_INTERVAL", "30"))
loop do
  begin
    FakeLab::Runner.tick(client: client, logger: logger)
  rescue StandardError => e
    logger.warn("[fake-lab] ciclo falhou: #{e.class}")
  end
  sleep interval
end
