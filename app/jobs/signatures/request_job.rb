# Consumidor de consultation.finalized e consultation.addendum_added (ADR 0032;
# spec §5). Rede de segurança: o pedido já nasce na finalização/no adendo
# (decisão do usuário 2026-10-09); aqui OpenRequest devolve :exists e nada se
# enfileira. Só abre quando a transação de origem não abriu (ex.: certificado
# ativado entre o commit e o consumo). Nada de HTTP aqui (ADR-0005). Nunca
# atribui Current.city (CityScopedJob).
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
