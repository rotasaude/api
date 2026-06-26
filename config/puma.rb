# Configuração do Puma para o papel "web" (ADR-0002).
threads ENV.fetch("RAILS_MIN_THREADS", 1), ENV.fetch("RAILS_MAX_THREADS", 5)

workers ENV.fetch("WEB_CONCURRENCY", 0)
preload_app!

port ENV.fetch("PORT", 3000)
environment ENV.fetch("RAILS_ENV", "development")
pidfile ENV.fetch("PIDFILE", "tmp/pids/server.pid")

plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"] == "true"
