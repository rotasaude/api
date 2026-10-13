module Ops
  # Teto de conexões do Postgres (rodada especial do 19, api#74). É a conta de PICO: cada pool
  # conta o menor entre o seu tamanho e as threads que o usam. Os números vêm dos arquivos reais
  # (config/queue.yml, config/queue_platform.yml e deploy/production/deploy.yml); a spec
  # spec/config/connection_budget_spec.rb aplica esta conta à configuração de produção.
  # Runbook: docs/operacao/conexoes-postgres.md.
  class ConnectionBudget
    # O Solid Queue de um worker usa as threads dele + 2 (polling e heartbeat).
    SOLID_QUEUE_EXTRA = 2
    # Supervisor, dispatcher e scheduler de cada supervisor Solid Queue.
    CONTROL_PROCESSES = 3
    # Conexões de cada processo de controle no banco da fila e na plataforma.
    CONTROL_CITY = 2
    CONTROL_PLATFORM = 1
    # Console, migrações, backup, kamal app exec e as superuser_reserved_connections.
    RESERVED = 20

    attr_reader :web_hosts, :web_concurrency, :web_threads, :city_workers, :platform_workers

    def self.from_files(root: Rails.root, env: "production")
      deploy = YAML.safe_load(root.join("deploy/production/deploy.yml").read, aliases: true)
      new(
        web_hosts: Array(deploy.dig("servers", "web", "hosts")).size,
        web_concurrency: deploy.dig("env", "clear", "WEB_CONCURRENCY").to_i,
        web_threads: deploy.dig("env", "clear", "RAILS_MAX_THREADS").to_i,
        city_workers: worker_threads(root.join("config/queue.yml"), env),
        platform_workers: worker_threads(root.join("config/queue_platform.yml"), env)
      )
    end

    def self.worker_threads(path, env)
      ActiveSupport::ConfigurationFile.parse(path).fetch(env).fetch("workers").map { |worker| worker.fetch("threads").to_i }
    end

    # Texto da rake ops:connection_budget[cidades].
    def self.report(cities, budget: from_files)
      [
        "Orçamento de conexões do Postgres para #{cities} cidade(s) — pico, por parte:",
        format("  web, base (plataforma e cache)           %5d", budget.web_base),
        format("  web, por cidade                          %5d × %d", budget.web_per_city, cities),
        format("  worker por cidade, no banco da cidade    %5d × %d", budget.worker_city_db_per_city, cities),
        format("  worker por cidade, na plataforma         %5d × %d", budget.worker_platform_per_city, cities),
        format("  plataforma (supervisor dela)             %5d", budget.platform),
        format("  reserva (console, migrações, backup)     %5d", RESERVED),
        format("  total                                    %5d", budget.total(cities)),
        format("  pico de uma cidade (CONNECTION LIMIT da role) %d", budget.role_per_city),
        "Com 20% de folga: max_connections ≥ #{(budget.total(cities) / 0.8).ceil}, " \
          "CITY_ROLE_CONNECTION_LIMIT ≥ #{(budget.role_per_city / 0.8).ceil}."
      ].join("\n")
    end

    def initialize(web_hosts:, web_concurrency:, web_threads:, city_workers:, platform_workers:)
      @web_hosts = web_hosts
      @web_concurrency = web_concurrency
      @web_threads = web_threads
      @city_workers = city_workers
      @platform_workers = platform_workers
    end

    # Processos Puma de todos os hosts.
    def web_processes = web_hosts * [ web_concurrency, 1 ].max

    # Pools de plataforma e de cache de cada processo web.
    def web_base = web_processes * web_threads * 2

    # Pools do CityRecord e do shard do Solid Queue (banco da cidade) de cada processo web.
    def web_per_city = web_processes * web_threads * 2

    # Cada worker: Solid Queue padrão (threads + 2), shard do Solid Queue e CityRecord, no banco da
    # cidade; mais os processos de controle.
    def worker_city_db_per_city
      city_workers.sum { |threads| (threads + SOLID_QUEUE_EXTRA) + threads + threads } + CONTROL_PROCESSES * CONTROL_CITY
    end

    # Cada worker: PlatformRecord (threads); mais os processos de controle.
    def worker_platform_per_city
      city_workers.sum + CONTROL_PROCESSES * CONTROL_PLATFORM
    end

    # Supervisor da plataforma: Solid Queue (threads + 2) e PlatformRecord, mais o controle.
    def platform
      platform_workers.sum { |threads| (threads + SOLID_QUEUE_EXTRA) + threads } + CONTROL_PROCESSES * CONTROL_CITY
    end

    # Pico de uma cidade no banco dela: o que o CONNECTION LIMIT do rota_city_<slug> precisa comportar.
    def role_per_city = web_per_city + worker_city_db_per_city

    def total(cities)
      raise ArgumentError, "cidades precisa ser inteiro positivo" unless cities.is_a?(Integer) && cities.positive?

      web_base + cities * (web_per_city + worker_city_db_per_city + worker_platform_per_city) + platform + RESERVED
    end
  end
end
