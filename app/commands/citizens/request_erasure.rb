# ADR 0026: o citizen_verifier registra no posto, com documento conferido, o
# pedido de exclusão de TODOS os pares do CPF. CPF com par atendido nasce
# retido por base legal.
module Citizens
  module RequestErasure
    module_function

    def call(cpf:, document_checked:, by:)
      return Result.fail(:document_check_required) unless document_checked == true

      digits = CitizenIdentity::Cpf.normalize(cpf)
      return Result.fail(:invalid_cpf) unless digits

      pairs = pairs_of(digits)
      return Result.fail(:citizen_not_found) if pairs.empty?

      request = nil
      ApplicationRecord.transaction do
        retained = attended?(pairs)
        request = CitizenErasureRequest.create!(
          cpf: digits, presented_citizen: pairs.order(:created_at).first, requested_by_user: by,
          document_checked: true, status: retained ? "retained" : "pending", decided_at: (Time.current if retained)
        )
        DomainEvents.publish(retained ? "citizen.erasure_retained" : "citizen.erasure_requested", request_id: request.id)
      end
      Result.ok(request: request)
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?("idx_citizen_erasure_requests_one_pending")

      Result.fail(:already_pending)
    end

    def pairs_of(digits) = Citizen.not_erased.where(cpf: digits)

    def attended?(pairs) = Attendance.where(citizen_id: pairs.select(:id)).exists?
  end
end
