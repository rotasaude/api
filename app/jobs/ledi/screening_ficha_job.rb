# Ficha da escuta no fechamento do atendimento (ADR 0030; spec §5). Leva só
# ids; a decisão (exportável, identificação, uma vez só) é do
# Ledi::ScreeningFicha, relida na hora em que roda.
module Ledi
  class ScreeningFichaJob < ApplicationJob
    include CityScopedJob
    queue_as :default

    # Módulo 31 (contrato §10): escuta de atendimento numa unidade `caps`
    # não é enfileirada (devolve nil).
    def self.enqueue_for(screening)
      return nil if Ledi::ScreeningFicha.caps?(screening)

      perform_later(city_slug: Current.city.slug, screening_id: screening.id)
    end

    def perform(city_slug:, screening_id:)
      with_city(city_slug) do
        screening = Screening.find_by(id: screening_id)
        Ledi::ScreeningFicha.generate(screening, city: Current.city) if screening
      end
    end
  end
end
