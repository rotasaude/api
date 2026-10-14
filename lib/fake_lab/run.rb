# Laboratório simulado do compose de dev (ADR 0036). Nunca em produção.
abort "fake-lab nunca sobe em produção" if (ENV["RAILS_ENV"] || ENV["RACK_ENV"]).to_s == "production"

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
