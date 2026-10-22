# "Agendar" pela linha de cuidado (contrato §11 T4): o pedido de agendamento
# do módulo 17 da pessoa na unidade da equipe da inscrição. Reaproveita o
# pedido ABERTO dela nessa unidade (qualquer origem); com só um pedido
# marcado ali, recusa (already_scheduled); senão abre um (kind care_line,
# origem a inscrição, tipo retorno, prazo padrão). Ordem de travas: unidade
# (FOR SHARE, como Attendances::Close; o Drain e a desativação a pegam FOR
# UPDATE primeiro) → inscrição (serializa com o encerramento e com outro
# "Agendar"; o índice de um vivo por inscrição é a defesa de reserva) →
# (cidadão e inscrição, pelas FKs do INSERT).
module CareLines
  module OpenAppointmentRequest
    module_function

    def call(enrollment:, by:)
      unit = enrollment.team.health_unit
      ApplicationRecord.transaction do
        HealthUnit.lock_active!(unit.id)
        enrollment.lock!
        next Result.fail(:invalid_transition) unless enrollment.active?

        pairs = Citizen.not_erased.verification_level_verified.where(patient_id: enrollment.patient_id).order(:created_at, :id).to_a
        next Result.fail(:citizen_not_verified) if pairs.empty?

        live = AppointmentRequest.live_requests.where(citizen_id: pairs.map(&:id), target_unit_id: unit.id).order(:created_at, :id).to_a
        open = live.find { |r| r.status == "open" }
        next Result.ok(request: open, unit: unit, created: false) if open
        next Result.fail(:already_scheduled) if live.any?

        request = AppointmentRequest.create!(kind: "care_line", origin_care_line_enrollment: enrollment, citizen: pairs.first,
                                             origin_unit: unit, target_unit: unit, appointment_type_key: "retorno", priority: "routine",
                                             due_on: Time.zone.today + AppointmentRequest::DUE_IN_DAYS)
        DomainEvents.publish("appointment_request.created", appointment_request_id: request.id, care_line_enrollment_id: enrollment.id,
                                                            target_unit_id: unit.id, kind: request.kind, user_id: by.id)
        Result.ok(request: request, unit: unit, created: true)
      end
    rescue HealthUnit::Inactive
      Result.fail(:invalid_unit)
    end
  end
end
