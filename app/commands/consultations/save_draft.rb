# app/commands/consultations/save_draft.rb
# Autosave do rascunho (ADR 0031; spec §4; contratos §4): só o autor, só
# draft. Valida tudo antes de gravar qualquer coisa (Consultations::ItemsInput);
# itens do corpo substituem a mesma chave de draft_items.
module Consultations
  class SaveDraft
    def self.call(consultation:, params:, by:)
      ApplicationRecord.transaction do
        consultation.lock!
        next Result.fail(:not_author) unless consultation.author_user_id == by.id
        next Result.fail(:not_draft) unless consultation.draft?

        input = ItemsInput.call(params, patient: consultation.patient, cbo: consultation.cbo_code)
        next input if input.failure?

        consultation.update!(input.payload[:attrs].merge("draft_items" => consultation.draft_items.merge(input.payload[:draft_items])))
        Result.ok(consultation: consultation)
      end
    end
  end
end
