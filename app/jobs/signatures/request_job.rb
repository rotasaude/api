# Consumidor de consultation.finalized e consultation.addendum_added (ADR 0032;
# spec §5). Só abre o pedido e enfileira o SignJob: nada de HTTP aqui
# (ADR-0005). O 19a não muda. Nunca atribui Current.city (CityScopedJob).
module Signatures
  class RequestJob < ApplicationJob
    include IdempotentConsumer

    queue_as :default

    def handle(consultation_id:, addendum_id: nil, **)
      document = addendum_id ? ConsultationAddendum.find_by(id: addendum_id) : Consultation.find_by(id: consultation_id)
      return if document.nil?
      return if document.is_a?(Consultation) && !document.finalized?

      OpenRequest.call(document)
    end
  end
end
