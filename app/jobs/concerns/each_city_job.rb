# Para jobs que rodam em cada cidade (tarefas recorrentes de housekeeping).
#
# Plano 5 (spec banco-por-cidade §4): as tarefas recorrentes moram na fila de
# cada cidade e são agendadas pelo scheduler dela. Por isso:
#   - no worker de uma cidade (CityWorkers::Context), o corpo roda só nessa cidade;
#   - fora de worker de cidade (console, specs), roda em toda cidade ativa;
#   - nos dois casos, cidade com schema atrasado fica de fora — código novo não
#     roda sobre schema velho.
#
# Isolamento de falha por cidade: uma cidade que levanta não impede as demais de
# rodar. Ao final, se alguma cidade falhou, levanta um erro agregado com os slugs
# e mensagens.
#
# Usar SEMPRE via `prepend EachCityJob` (NÃO include): com include, o perform do
# subclass aparece antes na cadeia de ancestrais e o wrap do módulo nunca dispara.
module EachCityJob
  class AggregatedFailure < StandardError
    def initialize(failures)
      @failures = failures
      super(failures.map { |slug, error| "#{slug}: #{error.class}: #{error.message}" }.join("; "))
    end

    attr_reader :failures
  end

  def perform(*args, **kwargs)
    failures = {}

    each_city_cities.each do |city|
      begin
        Current.city = city
        CityConnection.with(city) { super(*args, **kwargs) }
      rescue => e
        Rails.logger.error("[#{self.class.name}] city=#{city.slug} failed: #{e.class}: #{e.message}")
        failures[city.slug] = e
      end
    end

    raise AggregatedFailure, failures if failures.any?
  end

  private

  def each_city_cities
    worker_slug = CityWorkers::Context.city_slug
    scope = City.where(status: "active").order(:slug)
    scope = scope.where(slug: worker_slug) if worker_slug

    cities = scope.to_a

    if worker_slug && cities.empty?
      Rails.logger.warn("[#{self.class.name}] worker da cidade #{worker_slug} sem cidade ativa correspondente: nada a rodar")
      return cities
    end

    cities.reject do |city|
      next false unless CitySchema.behind?(city)

      Rails.logger.warn("[#{self.class.name}] city=#{city.slug} com schema atrasado: pulada")
      true
    end
  end
end
