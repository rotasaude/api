# Consumidor de consultation.finalized e consultation.addendum_added (módulo
# 25, ADR 0043): a rede de segurança (Surveillance::SafetyNet). Roda na
# transação da cidade, como o CareLines::ProblemChangedJob: o portão lê só a
# plataforma (Gate.enabled?). Consulta finalizada sempre tem prontuário, então
# não relê o interruptor do prontuário. Nunca atribui Current.city.
module Surveillance
  class SafetyNetJob < ApplicationJob
    include IdempotentConsumer
    queue_as :default

    def handle(consultation_id:, addendum_id: nil, **)
      return unless Gate.enabled?(Current.city)

      consultation = Consultation.find_by(id: consultation_id)
      return if consultation.nil?

      addendum = addendum_id && ConsultationAddendum.find_by(id: addendum_id, consultation_id: consultation.id)
      return if addendum_id && addendum.nil?

      SafetyNet.call(consultation: consultation, addendum: addendum)
    end
  end
end
