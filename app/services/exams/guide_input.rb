# Corpo da guia da recepção (contrato §3; Divergência D2) → atributos de
# Exams::Open. Paciente pelo par validado (Patients::Resolve) ou pelo id.
# O paciente sai por último (Resolve cria e liga): unidade, solicitante e
# justificativa primeiro; quem chama roda tudo na transação da guia, para
# que uma recusa depois (catálogo, guia) desfaça o Resolve.
module Exams
  module GuideInput
    NAME = (3..120)

    module_function

    def call(params, user:)
      unit = params[:unit_id].is_a?(String) && HealthUnit.find_by(id: params[:unit_id], active: true)
      return Result.fail(:not_found) unless unit
      return Result.fail(:not_unit_staff) unless Access.unit_staff?(user, unit.id)

      requester = requester(params[:requester])
      return requester if requester.is_a?(Result)

      cid10 = nil
      if params[:cid10_justification].present?
        cid10 = ClinicalTerms.find("cid10", params[:cid10_justification])&.code
        return Result.fail(:invalid_cid10) unless cid10
      end
      reference = params[:external_reference]
      return Result.fail(:invalid_external_reference) unless reference.nil? || (reference.is_a?(String) && reference.length <= 60)

      patient = patient_from(params)
      return patient if patient.is_a?(Result)

      Result.ok(attrs: { patient: patient, unit: unit, sigtap_code: params[:sigtap_code].to_s, priority: params[:priority].presence || "routine",
                         cid10: cid10, external_reference: reference.presence, **requester })
    end

    # Paciente do corpo: par validado (citizen_id → Patients::Resolve; par
    # declarado → citizen_not_verified) ou patient_id. Público para a Task 16
    # (resultado externo) reusar o mesmo recorte (R7).
    def patient_from(params)
      if params[:citizen_id].present?
        citizen = params[:citizen_id].is_a?(String) && Citizen.not_erased.find_by(id: params[:citizen_id])
        return Result.fail(:not_found) unless citizen

        resolved = Patients::Resolve.call(citizen)
        return Result.fail(:citizen_not_verified) if resolved.failure?

        resolved.payload[:patient]
      else
        (params[:patient_id].is_a?(String) && Patient.find_by(id: params[:patient_id])) || Result.fail(:not_found)
      end
    end

    def requester(raw)
      raw = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
      return Result.fail(:invalid_requester) unless raw.is_a?(Hash)

      raw = raw.stringify_keys
      if raw["user_id"].present?
        user = User.find_by(id: raw["user_id"], deactivated_at: nil)
        return Result.fail(:invalid_requester) unless user&.has_role?("health_professional")

        { requester_user: user }
      else
        name = raw["name"].is_a?(String) ? raw["name"].strip : ""
        return Result.fail(:invalid_requester) unless NAME.cover?(name.length)
        return Result.fail(:invalid_cns) unless Professionals::Cns.valid?(raw["cns"])

        { requester_name: name, requester_cns: raw["cns"] }
      end
    end
    private_class_method :requester
  end
end
