# Ficha da consulta (ADR 0031; spec §6): na finalização (generate) e depois de
# adendo com mudança estruturada (refresh!). Só ids; a decisão é relida na
# hora em que roda. Ficha em envio: tenta de novo em 1 minuto.
module Ledi
  class ConsultationFichaJob < ApplicationJob
    include CityScopedJob
    queue_as :default

    retry_on Ledi::ConsultationFicha::InFlight, wait: 1.minute, attempts: 10

    def self.enqueue_for(consultation, reason: "finalized")
      perform_later(city_slug: Current.city.slug, consultation_id: consultation.id, reason: reason)
    end

    def perform(city_slug:, consultation_id:, reason: "finalized")
      with_city(city_slug) do
        consultation = Consultation.find_by(id: consultation_id)
        if consultation
          reason == "addendum" ? Ledi::ConsultationFicha.refresh!(consultation, city: Current.city)
                               : Ledi::ConsultationFicha.generate(consultation, city: Current.city)
        end
      end
    end
  end
end
