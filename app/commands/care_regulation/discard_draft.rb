# Apaga o rascunho de regulação (ADR 0044; contrato §3): só `draft` e só a
# autora da consulta; o pedido promovido nunca some (trigger). Mesma ordem de
# travas do SaveDraft: consulta, depois o rascunho.
module CareRegulation
  module DiscardDraft
    module_function

    # -> Result.ok | fail(:missing_role | :not_found | :not_author | :invalid_transition)
    def call(request:, by:)
      return Result.fail(:missing_role) unless by&.has_role?("health_professional")

      ApplicationRecord.transaction do
        consultation = Consultation.lock.find_by(id: request.consultation_id)
        next Result.fail(:not_found) if consultation.nil? || consultation.discarded?
        next Result.fail(:not_author) unless consultation.author_user_id == by.id

        draft = RegulationRequest.lock.find_by(id: request.id)
        next Result.fail(:not_found) unless draft
        next Result.fail(:invalid_transition) unless draft.status == "draft"

        draft.delete
        Result.ok
      end
    end
  end
end
