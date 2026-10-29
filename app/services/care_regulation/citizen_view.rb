# O que o cidadão vê do pedido de regulação (ADR 0044; contrato §9, §13 G3; a
# decisão 9 da spec: o cidadão nunca vê a posição). Forma fixa, montada à mão:
#   { id, label, status, scheduled_at, place, updated_at }
# `label` é a frase ("Consulta em Cardiologia" para especialidade; o nome do
# procedimento). `status` segue CITIZEN_STATUS; rascunho e `missed` não estão
# nele e ficam de fora. Data e local só com o pedido em `scheduled`.
# Nunca cor, posição, CID, CIAP, justificativa, prazo, motivo, autorização nem
# prestador. Quem chama grava a trilha citizen.
module CareRegulation
  module CitizenView
    module_function

    def call(patient_id:)
      return [] if patient_id.nil?

      RegulationRequest.where(patient_id: patient_id, status: Catalog::CITIZEN_STATUS.keys)
                       .order(updated_at: :desc, id: :asc).map { |request| item(request) }
    end

    def item(request)
      scheduled = request.status == "scheduled"
      { id: request.id, label: label(request), status: Catalog::CITIZEN_STATUS.fetch(request.status),
        scheduled_at: scheduled ? request.scheduled_at&.iso8601 : nil, place: scheduled ? request.schedule_place : nil,
        updated_at: request.updated_at.iso8601 }
    end

    def label(request)
      request.target_type == "specialty" ? "Consulta em #{request.target_name}" : request.target_name
    end
  end
end
