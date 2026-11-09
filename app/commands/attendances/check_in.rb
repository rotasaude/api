# Check-in por código (spec §2.1, §2.6): confere e consome o código sob lock;
# se o par é declarado e o documento foi conferido, valida junto — tudo na
# mesma transação.
# Módulo 32a (ADR 0050; plano, Desvio 3): `urgency` e `waiting_room` são os
# interruptores urgency_care e waiting_room_display já lidos pelo controlador,
# fora da transação. Com a urgência, a UPA só recebe pela recepção da
# urgência (Urgency::Arrive); com a sala de espera, a linha nasce com a senha.
module Attendances
  class CheckIn
    # O horário deixou de estar confirmado entre a leitura sem lock e o lock
    # (ex.: o cidadão cancelou): o check-in inteiro desfaz.
    class AppointmentNotEligible < StandardError; end

    # Só a violação destes índices é "outro check-in chegou antes" (corrida
    # entre a checagem sem lock e o INSERT). Qualquer outra sobe.
    ORIGIN_INDEXES = %w[index_attendances_on_triage_id index_attendances_on_appointment_id].freeze

    def self.call(cpf:, code:, health_unit_id:, document_checked:, by:, urgency: false, waiting_room: false)
      unit = HealthUnit.active_units.find_by(id: health_unit_id)
      return Result.fail(:invalid_unit) unless unit
      # Módulo 31 (P32): o CAPS não recebe check-in (o nome iria ao wpda).
      return Result.fail(:caps_unit_not_allowed) if unit.caps?
      return Result.fail(:urgency_reception_required) if urgency && unit.upa?

      result = nil
      triage = appointment = nil
      ApplicationRecord.transaction do
        unit = HealthUnit.lock_active!(unit.id)
        match = Citizens::VerificationCodeMatch.call(cpf: cpf, code: code, lock: true, purpose: "check_in")
        next result = match if match.failure?

        citizen = match.payload[:citizen]
        appointment = match.payload[:appointment]
        triage = match.payload[:triage]
        if appointment
          state = AppointmentCheckInEligibility.check(appointment, health_unit_id: unit.id)
          next result = AppointmentCheckInEligibility.failure_for(state, appointment) unless state == :ok
        else
          # Trava a triagem (ADR 0026): Triages::Anonymize trava a mesma linha,
          # então o check-in ou a anonimização vence, nunca os dois. O lock!
          # relê a linha e a conversa antes de reconferir a elegibilidade.
          triage.lock!
          state = CheckInEligibility.check(triage)
          next result = LookupForCheckIn.failure_for(state, triage) unless state == :ok
        end

        match.payload[:verification_code].update!(consumed_at: Time.current)
        verified = document_checked == true && citizen.active_verification.nil? && verify_once(citizen, by)
        now = Time.current
        attendance = Attendance.create!(triage: triage, appointment: appointment, citizen: citizen, health_unit: unit,
                                        checked_in_by_user: by, checked_in_at: now, check_in_method: "code",
                                        **ticket_for(unit, at: now, waiting_room: waiting_room))
        fulfil(appointment, health_unit_id: unit.id) if appointment
        publish(attendance)
        result = Result.ok(attendance: attendance, verified: verified)
      end
      result
    rescue ActiveRecord::RecordNotUnique => e
      already_checked_in(e, triage_id: triage&.id, appointment_id: appointment&.id)
    rescue AppointmentNotEligible
      Result.fail(:appointment_not_eligible)
    rescue HealthUnit::Inactive
      Result.fail(:invalid_unit)
    end

    # Senha da sala de espera (Attendances::Ticket), só com o interruptor; sob
    # a unidade já travada pelo chamador.
    def self.ticket_for(unit, at:, waiting_room:)
      return {} unless waiting_room

      ticket, day = Ticket.issue(unit, at: at)
      { ticket: ticket, ticket_on: day }
    end

    # Outro atendente validou o mesmo cadastro no mesmo instante (índice
    # idx_citizen_verifications_one_active): o cadastro ficou validado por ele,
    # e o check-in segue sem validar de novo. O savepoint mantém a transação
    # do check-in viva.
    def self.verify_once(citizen, by)
      ApplicationRecord.transaction(requires_new: true) { Citizens::Verify.record!(citizen: citizen, by: by) }
      true
    rescue ActiveRecord::RecordNotUnique => e
      raise unless constraint_name(e) == "idx_citizen_verifications_one_active"

      false
    end

    # Corrida no INSERT (a transação já desfez): responde como o caminho sem
    # corrida, com a unidade e a hora do check-in que chegou antes.
    def self.already_checked_in(error, triage_id:, appointment_id:)
      raise error unless ORIGIN_INDEXES.include?(constraint_name(error))

      existing = (triage_id && Attendance.find_by(triage_id: triage_id)) ||
                 (appointment_id && Attendance.find_by(appointment_id: appointment_id))
      return Result.fail(:already_checked_in) unless existing

      Result.fail(:already_checked_in, details: { unit_name: existing.health_unit.name,
                                                  checked_in_at: existing.checked_in_at })
    end

    def self.constraint_name(error)
      pg = error.cause
      name = pg.result&.error_field(PG::Result::PG_DIAG_CONSTRAINT_NAME) if pg.respond_to?(:result)
      name || error.message[/unique constraint "([^"]+)"/, 1]
    end

    # O horário virou atendimento: fecha o horário e o pedido (ADR 0019).
    # Reconfere status, dia e unidade sob lock; levanta AppointmentNotEligible
    # para o chamador desfazer a transação.
    def self.fulfil(appointment, health_unit_id:)
      appointment.lock!
      state = AppointmentCheckInEligibility.check(appointment, health_unit_id: health_unit_id)
      raise AppointmentNotEligible unless state == :ok

      appointment.update!(status: "checked_in", ended_at: Time.current)
      AppointmentRequests::Lifecycle.close!(appointment.request, reason: "fulfilled")
      DomainEvents.publish("appointment.checked_in", appointment_id: appointment.id,
                                                     appointment_request_id: appointment.request_id)
    end

    def self.publish(attendance)
      DomainEvents.publish("attendance.checked_in",
                           attendance_id: attendance.id, triage_id: attendance.triage_id,
                           appointment_id: attendance.appointment_id,
                           citizen_id: attendance.citizen_id, health_unit_id: attendance.health_unit_id,
                           checked_in_by_user_id: attendance.checked_in_by_user_id,
                           check_in_method: attendance.check_in_method)
    end
  end
end
