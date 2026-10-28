# Pedido de regulação em rascunho na consulta (ADR 0044; contrato §3, §13 G4,
# G10, G12): cria (request: nil) ou substitui por inteiro (request: o rascunho).
# O rascunho é a linha `draft`; só vale na finalização ou no adendo (Promote,
# Task 5). Só a autora da consulta (rascunho ou finalizada; descartada é
# not_found). Ordem: forma → Targets.resolve → Requesters.check (CBO da
# consulta) → Diagnosis.check → texto e cor → limite de rascunhos (G4: o
# limite conta só os `draft`; promovidos não entram). Trava a consulta e depois
# o rascunho. Alvo, diagnóstico e justificativa nunca em log, evento nem Result.
module CareRegulation
  module SaveDraft
    KEYS = %w[type target_code cid10 ciap2 justification suggested_color state_regulated].freeze
    KEY_PATH_MAX = 64

    module_function

    # -> Result.ok(request:) | fail(:missing_role | :not_found | :not_author |
    # :invalid_transition | :invalid_request | :invalid_target | :cbo_not_allowed |
    # :invalid_cid10 | :invalid_ciap2 | :diagnosis_required | :cid10_not_allowed_for_cbo)
    def call(consultation:, attrs:, by:, request: nil)
      return Result.fail(:missing_role) unless by&.has_role?("health_professional")

      ApplicationRecord.transaction do
        consultation.lock!
        next Result.fail(:not_found) if consultation.discarded?
        next Result.fail(:not_author) unless consultation.author_user_id == by.id

        draft = nil
        if request
          draft = RegulationRequest.lock.find_by(id: request.id, consultation_id: consultation.id)
          next Result.fail(:not_found) unless draft
          next Result.fail(:invalid_transition) unless draft.status == "draft"
        end

        checked = check(consultation, attrs)
        next checked if checked.is_a?(Result)

        if draft.nil? && draft_count(consultation) >= Catalog::MAX_PER_CONSULTATION
          next Result.fail(:invalid_request, details: { path: "consultation" })
        end

        Result.ok(request: persist(consultation, draft, checked, by))
      end
    end

    # -> Hash com os valores a gravar | Result (recusa).
    def check(consultation, attrs)
      shape = shape(attrs)
      return shape if shape.is_a?(Result)

      resolved = Targets.resolve(type: shape["type"], code: shape["target_code"])
      return resolved if resolved.failure?

      target = resolved.payload.fetch(:target)
      cbo = consultation.cbo_code
      return Result.fail(:cbo_not_allowed) unless Requesters.check(cbo: cbo, target: target) == :ok

      diagnosis = Diagnosis.check(cbo: cbo, cid10: shape["cid10"], ciap2: shape["ciap2"])
      return diagnosis if diagnosis.failure?

      justification = shape["justification"]
      text = justification.is_a?(String) ? justification.strip : nil
      return invalid("justification") unless text && Catalog::JUSTIFICATION.cover?(text.length)
      return invalid("suggested_color") unless Catalog::COLORS.include?(shape["suggested_color"])

      { target: target, cid10: diagnosis.payload[:cid10], ciap2: diagnosis.payload[:ciap2], justification: text,
        suggested_color: shape["suggested_color"], state_regulated: shape["state_regulated"] }
    end

    # Só um Hash de chaves conhecidas; state_regulated ausente = false.
    def shape(attrs)
      return invalid("body") unless attrs.respond_to?(:to_h) && !attrs.is_a?(Array)

      hash = attrs.to_h.stringify_keys
      unknown = (hash.keys - KEYS).first
      return invalid(unknown.to_s[0, KEY_PATH_MAX]) if unknown

      state = hash.fetch("state_regulated", false)
      return invalid("state_regulated") unless [ true, false ].include?(state)

      hash.merge("state_regulated" => state)
    end

    def persist(consultation, draft, values, by)
      target = values.fetch(:target)
      fields = { target_type: target.type, target_code: target.code, target_name: target.name,
                 cid10: values[:cid10], ciap2: values[:ciap2], justification: values.fetch(:justification),
                 suggested_color: values.fetch(:suggested_color), state_regulated: values.fetch(:state_regulated),
                 requester_user_id: by.id, requester_cbo: consultation.cbo_code,
                 requester_unit_id: consultation.attendance.health_unit_id }
      if draft
        draft.update!(fields.merge(version: draft.version + 1))
        draft
      else
        RegulationRequest.create!(fields.merge(status: "draft", patient_id: consultation.patient_id,
                                               consultation_id: consultation.id))
      end
    end

    def draft_count(consultation) = RegulationRequest.where(consultation_id: consultation.id, status: "draft").count

    def invalid(path) = Result.fail(:invalid_request, details: { path: path })
    private_class_method :check, :shape, :persist, :draft_count, :invalid
  end
end
