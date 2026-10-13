# Ficha da consulta (ADR 0031; spec §6): na finalização (generate) e depois de
# adendo com mudança estruturada (refresh!). Só ids; a decisão é relida na
# hora em que roda. Ficha em envio: tenta de novo em 1 minuto.
module Ledi
  class ConsultationFichaJob < ApplicationJob
    include CityScopedJob
    queue_as :default

    # Esgotadas as tentativas com a ficha ainda em envio, a falha fica registrada
    # ("não gerada", com "gerar de novo") em vez de o adendo sumir (api#52).
    retry_on Ledi::ConsultationFicha::InFlight, wait: 1.minute, attempts: 10 do |job, _error|
      job.still_sending!
    end

    def self.enqueue_for(consultation, reason: "finalized")
      perform_later(city_slug: Current.city.slug, consultation_id: consultation.id, reason: reason)
    end

    def still_sending!
      city_slug, consultation_id = arguments.first.values_at(:city_slug, :consultation_id)
      with_city(city_slug) do
        consultation = Consultation.find_by(id: consultation_id)
        Ledi::ConsultationFicha.still_sending!(consultation) if consultation
      end
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
