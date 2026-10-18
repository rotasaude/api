# Middleware simulado do compose de dev (ADR 0037). Só em development e só com
# destino local (sem carregar o Rails).
require_relative "guard"

env = (ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "development").to_s
abort "fake-middleware só roda em development" unless FakeMiddleware::Guard.environment_ok?(env)

api_url = ENV.fetch("FAKE_MIDDLEWARE_API_URL", "http://api:3000")
abort "fake-middleware recusa FAKE_MIDDLEWARE_API_URL fora de um host local" unless FakeMiddleware::Guard.local_url?(api_url)

require "logger"
$stdout.sync = true
require_relative "runner"

client = FakeMiddleware::Client.new(api_url: api_url,
                                    city_host: ENV.fetch("FAKE_MIDDLEWARE_CITY_HOST", "curitiba.localhost"),
                                    token: ENV.fetch("FAKE_MIDDLEWARE_TOKEN"))
logger = Logger.new($stdout)
interval = Integer(ENV.fetch("FAKE_MIDDLEWARE_INTERVAL", "30"))
# `run.rb qc <approved|reject_2_2s>`: manda UMA corrida de controle e sai (prova no navegador).
if ARGV.first == "qc"
  scenario = ARGV[1] || "approved"
  abort "cenário desconhecido: use #{FakeMiddleware::QcPlan::SCENARIOS.join(' ou ')}" unless FakeMiddleware::QcPlan::SCENARIOS.include?(scenario)
  FakeMiddleware::Runner.qc(client: client, logger: logger, scenario: scenario)
  exit 0
end

require "date"
last_qc_on = nil
loop do
  begin
    FakeMiddleware::Runner.tick(client: client, logger: logger)
    # Uma corrida de controle aprovada por dia (como a rotina de abertura do laboratório).
    unless last_qc_on == Date.today
      FakeMiddleware::Runner.qc(client: client, logger: logger, scenario: "approved")
      last_qc_on = Date.today
    end
  rescue StandardError => e
    logger.warn("[fake-middleware] ciclo falhou: #{e.class}")
  end
  sleep interval
end
