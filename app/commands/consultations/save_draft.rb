# Autosave do rascunho (ADR 0031; spec §4; contratos §4): só o autor, só
# draft. Valida tudo antes de gravar qualquer coisa (Consultations::ItemsInput);
# itens do corpo substituem a mesma chave de draft_items.
# Módulo 28 (ADR 0046; contrato §16 O25): o bloco `dental` só na consulta
# odontológica (DentalCare::DraftInput: colunas da FAO e draft_items["dental"],
# chave a chave); nela o `care_type` do topo é ignorado (vale dental.care_type).
# Módulo 32a: na consulta `urgency`, `care_type` → invalid_request `care_type`.
module Consultations
  class SaveDraft
    def self.call(consultation:, params:, by:)
      params = normalize(params)
      # O37: lido fora da transação (nenhuma leitura de interruptor no savepoint).
      return Result.fail(:feature_disabled, details: { feature: DentalCare::Gate::KEY }) if consultation.dental? && !DentalCare::Gate.usable?(Current.city)

      ApplicationRecord.transaction do
        consultation.lock!
        next Result.fail(:not_author) unless consultation.author_user_id == by.id
        next Result.fail(:not_draft) unless consultation.draft?
        next Result.fail(:invalid_request, details: { path: "dental" }) if params.key?("dental") && !consultation.dental?
        # Módulo 32a (Desvio 14): a urgência nunca grava tipo de atendimento.
        next Result.fail(:invalid_request, details: { path: "care_type" }) if params.key?("care_type") && consultation.urgency?

        general = consultation.dental? ? params.except("care_type", "dental") : params
        input = ItemsInput.call(general, patient: consultation.patient, cbo: consultation.cbo_code, kind: consultation.kind)
        next input if input.failure?

        attrs = input.payload[:attrs]
        items = consultation.draft_items.merge(input.payload[:draft_items])
        if params.key?("dental")
          dental = DentalCare::DraftInput.call(params["dental"], consultation: consultation)
          next dental if dental.failure?

          attrs = attrs.merge(dental.payload[:attrs])
          items["dental"] = (items["dental"] || {}).merge(dental.payload[:items])
        end
        consultation.update!(attrs.merge("draft_items" => items))
        Result.ok(consultation: consultation)
      end
    end

    def self.normalize(params)
      params = params.to_unsafe_h if params.respond_to?(:to_unsafe_h)
      params.is_a?(Hash) ? params.deep_stringify_keys : {}
    end
    private_class_method :normalize
  end
end
