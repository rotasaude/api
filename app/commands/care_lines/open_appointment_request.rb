# "Agendar" pela linha de cuidado (contrato §11 T4): o pedido de agendamento
# do módulo 17 da pessoa na unidade da equipe da inscrição. O pedido vivo da
# própria inscrição vem primeiro: depois de um Drain ele vive noutra unidade
# (aberto → reaproveita com a unidade de destino dele; marcado →
# already_scheduled). Senão, reaproveita o pedido ABERTO da pessoa na unidade
# da equipe (qualquer origem); com só um pedido marcado ali, recusa
# (already_scheduled); senão abre um (kind care_line, origem a inscrição,
# tipo retorno, prazo padrão).
#
# Ordem de travas, a mesma de Appointments::Placement: unidade da equipe (FOR
# SHARE; o Drain e a desativação a pegam FOR UPDATE primeiro) → cidadãos
# (pares validados, FOR NO KEY UPDATE: a exclusão LGPD e a revogação da
# validação esperam, e o par lido é o que vale) → inscrição (FOR UPDATE:
# serializa com o encerramento e com outro "Agendar"; o índice de um vivo por
# inscrição é a defesa de reserva).
module CareLines
  module OpenAppointmentRequest
    module_function

    def call(enrollment:, by:)
      ApplicationRecord.transaction do
        unit = HealthUnit.lock("FOR SHARE").find(enrollment.team.health_unit_id)
        pairs = Citizen.not_erased.verification_level_verified.where(patient_id: enrollment.patient_id)
                       .order(:id).lock("FOR NO KEY UPDATE").to_a
        enrollment.lock!
        next Result.fail(:invalid_transition) unless enrollment.active?
        next Result.fail(:citizen_not_verified) if pairs.empty?

        own = AppointmentRequest.live_requests.where(origin_care_line_enrollment_id: enrollment.id).includes(:target_unit).first
        if own && own.target_unit_id != unit.id
          next own.status == "open" ? Result.ok(request: own, unit: own.target_unit, created: false) : Result.fail(:already_scheduled)
        end
        next Result.fail(:invalid_unit) unless unit.active

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
    end
  end
end
