# Desfecho (spec 2026-09-25 §2.1, §2.3): left só de waiting; desfecho
# clínico só de in_care. return e referred com unidade abrem o pedido na
# mesma transação.
# Módulo 26a (ADR 0044; plano do api, Desvio 2; contrato §13 G12 #4):
# `regulation` nil = regra de hoje. Inteiro (o chamador leu o interruptor
# utilizável, fora do savepoint) = quantos pedidos de regulação a finalização
# tinha (enviados ou não): referred SEM unidade exige pelo menos um (0 → 422
# regulation_request_required) e a nota fica opcional, com a marca
# referral_regulated (é ela que satisfaz ck_attendances_referral sem unidade
# nem nota); referred COM unidade segue sendo o referral do 17.
module Attendances
  class Close
    def self.call(attendance:, outcome:, referral_unit_id:, referral_note:, by:, regulation: nil)
      outcome = outcome.to_s
      return Result.fail(:invalid_outcome) unless Attendance::CLOSE_OUTCOMES.include?(outcome)
      raise ArgumentError, "regulation: inteiro >= 0 ou nil" unless regulation.nil? || (regulation.is_a?(Integer) && regulation >= 0)

      note = referral_note.to_s.strip.presence
      unit = nil
      regulated = false
      if outcome == "referred"
        if referral_unit_id.present?
          unit = HealthUnit.active_units.find_by(id: referral_unit_id)
          return Result.fail(:invalid_unit) unless unit
        end
        if unit.nil? && regulation
          return Result.fail(:regulation_request_required) if regulation.zero?

          regulated = true
        elsif unit.nil? && note.nil?
          return Result.fail(:referral_required)
        end
      end

      ApplicationRecord.transaction do
        attendance.lock!
        HealthUnit.lock_active!(unit.id) if unit
        # Desfecho clínico exige papel e vínculo (F-10.5); left é ato de balcão.
        unless outcome == "left"
          authorization = Professionals::ClinicalAuthorization.check(user: by, health_unit_id: attendance.health_unit_id)
          next Result.fail(authorization) unless authorization == :ok
        end
        # ADR 0031 (Desvio 13): com a consulta em rascunho, o desfecho sai pela
        # finalização (Consultations::Finalize vira a consulta antes de chamar aqui).
        next Result.fail(:consultation_in_progress) if Consultation.exists?(attendance_id: attendance.id, status: "draft")
        next Result.fail(:already_closed) unless attendance.open?
        next Result.fail(:invalid_transition) unless allowed?(attendance.status, outcome)

        # ADR 0030 (Desvio 7): quem sai (ou é encerrado) com escuta em curso
        # não deixa a escuta pendurada.
        Screenings::Abandon.release!(attendance, by: by)
        attendance.update!(status: "closed", outcome: outcome, closed_by_user: by, closed_at: Time.current,
                           referral_unit: unit, referral_note: (%w[referred return].include?(outcome) ? note : nil),
                           referral_regulated: regulated)
        request = AppointmentRequests::Lifecycle.open_for!(attendance, outcome: outcome, unit: unit)
        DomainEvents.publish("attendance.closed", attendance_id: attendance.id, outcome: outcome,
                                                  closed_by_user_id: by.id)
        # ADR 0030 (spec §5): escuta concluída (same_day) gera a ficha no fechamento.
        Ledi::ScreeningFichaJob.enqueue_for(attendance.screening) if attendance.screening&.completed?
        Result.ok(attendance: attendance, appointment_request: request)
      end
    rescue HealthUnit::Inactive
      Result.fail(:invalid_unit)
    end

    def self.allowed?(status, outcome)
      outcome == "left" ? status == "waiting" : status == "in_care"
    end
  end
end
