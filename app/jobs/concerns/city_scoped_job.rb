# Wrapper de cidade para jobs. Todo job que toca dado de domínio inclui isto.
# Falha fechada: sem cidade (ou cidade não servível), levanta — não vaza.
#
# O job carrega o SLUG, não o objeto: o payload viaja pela fila, que mora no
# banco da própria cidade (Plano 5).
#
# O yield roda dentro de uma transação na conexão da cidade — mesma garantia
# que o antigo with_tenant dava (ApplicationRecord.transaction do ... end).
# Sem isso, um dedup row (ProcessedEvent, o "alert:<triage_id>" do
# DispatchMunicipalityAlertJob, o OutboundMessage do SendWhatsappJob) comita
# ANTES do efeito que ele deveria guardar contra retry — se esse efeito
# falhar, o retry encontra o dedup row e pula em vez de tentar de novo,
# perdendo o alerta/mensagem em vez de reprocessar. Uma transação aberta
# durante uma chamada HTTP/SMTP é o mesmo trade-off que já existia antes
# desta migração; movê-la para fora da transação é uma melhoria separada,
# não desta task.
module CityScopedJob
  extend ActiveSupport::Concern

  class CityMissing < StandardError; end
  class CityNotServable < StandardError; end
  # Cidade com schema atrasado (spec §4, Plano 5): o job espera o city:migrate:all
  # em vez de rodar código novo sobre schema velho. ApplicationJob reagenda.
  class CitySchemaBehind < StandardError; end
  # Job de outra cidade que não a do worker que o executa: a fila de uma cidade só
  # tem jobs dela (Plano 5). Defesa em profundidade do roteamento — não é
  # descartado, fica visível como falha.
  class CityMismatch < StandardError; end

  private

  def with_city(slug)
    raise CityMissing, "#{self.class.name}: slug nulo" if slug.blank?

    worker_slug = CityWorkers::Context.city_slug
    if worker_slug && worker_slug != slug
      raise CityMismatch, "#{self.class.name}: job da cidade #{slug} no worker da cidade #{worker_slug}"
    end

    city = City.find_by(slug: slug)
    raise CityMissing, "#{self.class.name}: cidade #{slug} não existe" if city.nil?
    unless city.servable?
      raise CityNotServable, "#{self.class.name}: cidade #{slug} não está servível (status=#{city.status})"
    end
    raise CitySchemaBehind, "#{self.class.name}: cidade #{slug} com schema atrasado" if CitySchema.behind?(city)

    Current.city = city
    CityConnection.with(city) do
      ApplicationRecord.transaction { yield }
    end
  end
end
