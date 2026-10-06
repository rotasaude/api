# O que Book e FitIn compartilham (ADR 0029 §4.3). Chamado DENTRO da transação.
#
# Ordem de travas: cidadão (FOR UPDATE: duas marcações do mesmo cidadão se
# enfileiram, e citizen_busy vê a anterior) → horários vivos do pedido → pedido.
# Horário antes de pedido é a ordem de CancelByCitizen, Lapse e Drain; cidadão
# antes de tudo é a de Citizens::Erase. Depois disso vêm a unidade (FOR SHARE)
# e, no encaixe, o turno (FOR UPDATE).
module Appointments
  module Placement
    module_function

    def parse(value)
      Time.zone.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def lock!(request)
      Citizen.lock.find(request.citizen_id)
      Appointment.where(request_id: request.id, status: Appointment::LIVE).order(:id).lock.to_a
      request.lock!
    end

    def bookable?(request) = %w[open scheduled].include?(request.status)

    def citizen_busy?(request, starts, ends)
      own = Appointment.where(request_id: request.id, status: Appointment::LIVE).select(:id)
      Appointment.where(citizen_id: request.citizen_id, status: Appointment::ACTIVE).where.not(id: own)
                 .where("scheduled_at < ? AND COALESCE(ends_at, scheduled_at + make_interval(secs => ?)) > ?",
                        ends, Appointment::LEGACY_SPAN.to_i, starts)
                 .exists?
    end

    # Remarcar = encerrar o vivo como `moved` e criar o novo ligado a ele (o
    # mesmo mecanismo do esvaziamento de unidade, api#29).
    def create!(request:, at:, by:, now:, **attrs)
      previous = request.appointments.live.first
      previous&.update!(status: "moved", ended_at: now)
      born_confirmed = at - now < Appointment::BORN_CONFIRMED_WITHIN
      appointment = Appointment.create!(
        request: request, citizen_id: request.citizen_id, health_unit_id: request.target_unit_id, scheduled_at: at,
        scheduled_by_user: by, moved_from_appointment: previous, status: born_confirmed ? "confirmed" : "scheduled",
        confirmed_at: born_confirmed ? now : nil,
        confirmation_deadline_at: born_confirmed ? nil : at - Appointment::CONFIRMATION_LEAD, **attrs
      )
      request.update!(status: "scheduled", reopened_reason: nil)
      if previous
        DomainEvents.publish("appointment.moved", from_appointment_id: previous.id, to_appointment_id: appointment.id,
                                                  to_unit_id: appointment.health_unit_id, born_confirmed: born_confirmed,
                                                  fit_in: appointment.fit_in?)
      end
      appointment
    end
  end
end
