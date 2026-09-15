require "open3"

# Aplica o schema de cidade nas cidades do catálogo e registra a versão em
# cities.schema_version, que a guarda de runtime compara com a versão esperada
# pelo código (spec banco-por-cidade §4, Plano 4).
#
# Roda em processo de uma thread (rake city:migrate / city:migrate:all, ou o
# subprocesso do provisionamento) — ver CitySchema.
module CityMigrations
  # Estados com banco a migrar. provisioning é migrado pelo próprio job de
  # provisionamento; archived não tem mais banco.
  STATUSES = %w[active suspended].freeze

  class Failed < StandardError
    attr_reader :failures

    def initialize(failures)
      @failures = failures
      super("cidades não migradas: #{failures.map { |slug, message| "#{slug} (#{message})" }.join('; ')}")
    end
  end

  module_function

  def run(city)
    version = CitySchema.migrate!(city.database_url)
    city.update!(schema_version: version.to_s)
    version
  end

  # Migra cada cidade; uma falha não impede as demais. No fim levanta Failed com o
  # slug e a mensagem (sem credencial) de cada cidade que ficou para trás.
  def run_all(out: $stdout)
    failures = {}

    City.where(status: STATUSES).order(:slug).each do |city|
      out.puts "[city:migrate:all] #{city.slug} → #{run(city)}"
    rescue StandardError => e
      failures[city.slug] = "#{e.class}: #{CitySchema.redact(e.message)}"
      out.puts "[city:migrate:all] #{city.slug} FALHOU — #{failures[city.slug]}"
    end

    raise Failed, failures if failures.any?
  end

  # Migra a cidade num processo à parte (bin/rails city:migrate[slug]) e devolve a
  # City recarregada, com o schema_version gravado pela task. É o migrador do
  # ProvisionCityJob: dentro do worker, CitySchema.migrate! trocaria a conexão de
  # ActiveRecord::Base, que as threads do Solid Queue usam.
  module Subprocess
    class Failed < StandardError; end

    module_function

    def call(city)
      out, status = Open3.capture2e({ "RAILS_ENV" => Rails.env }, Rails.root.join("bin/rails").to_s,
                                    "city:migrate[#{city.slug}]", chdir: Rails.root.to_s)
      unless status.success?
        raise Failed, "city:migrate[#{city.slug}] saiu com #{status.exitstatus}: " \
                      "#{CitySchema.redact(out.lines.last(5).join).strip}"
      end

      city.reload
    end
  end
end
