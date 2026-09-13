# Para recurring tasks que precisam rodar em toda cidade (sucessor do antigo
# wrapper cross-tenant que rodava sob a conexão administrativa BYPASSRLS).
# Roda o corpo do perform uma vez por cidade ATIVA, sob a conexão daquela
# cidade.
#
# Isolamento de falha por cidade: uma cidade que levanta não impede as demais
# de rodar. Ao final, se alguma cidade falhou, levanta um erro agregado com
# os slugs e mensagens — não silencioso, mas também não derruba a passada
# inteira na primeira falha.
#
# Usar SEMPRE via `prepend EachCityJob` (NÃO include) — mesmo motivo do
# wrapper antigo: com include, o perform do subclass aparece antes na cadeia
# de ancestrais e o wrap do módulo nunca dispara. Com prepend, o perform do
# módulo executa primeiro e chama super (o perform do job) para cada cidade.
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

    City.where(status: "active").find_each do |city|
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
end
