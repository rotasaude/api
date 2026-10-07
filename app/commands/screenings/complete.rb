# app/commands/screenings/complete.rb
# Concluir a escuta (ADR 0030; spec §4): grava a revisão, define o destino e,
# fora do same_day, fecha o atendimento a partir de waiting — exceção da trava
# do módulo 13 que o trigger attendances_screening_close_guard confere.
# Ordem de travas: atendimento → escuta → unidade (FOR SHARE).
module Screenings
  class Complete
    DESTINATIONS = Screening::DESTINATIONS
    DEFAULT_DUE_IN_DAYS = { "yellow" => 7, "green" => 15, "blue" => 30 }.freeze
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    def self.call(screening:, revision_params:, destination:, destination_params:, by:)
      attendance = screening.attendance
      input = RevisionInput.call(revision_params, citizen: attendance.citizen)
      return input if input.failure?

      destination = destination.to_s
      plan = plan_for(destination, destination_params, input.payload[:attrs]["final_color"])
      return plan if plan.failure?

      ApplicationRecord.transaction do
        attendance.lock!
        screening.lock!
        status, link = Authorization.check(user: by, health_unit_id: attendance.health_unit_id)
        next Result.fail(status) unless status == :ok
        next Result.fail(:not_in_progress) unless screening.status == "in_progress"
        next Result.fail(:attendance_not_waiting) unless attendance.status == "waiting"

        referral_unit = plan.payload[:referral_unit_id] && HealthUnit.lock_active!(plan.payload[:referral_unit_id])
        revision = ScreeningRevision.create!(input.payload[:attrs].merge(screening: screening, by_user: by))
        request = destination == "schedule" ? schedule_request!(attendance, screening, plan.payload) : nil
        screening.update!(status: "completed", completed_at: Time.current, destination: destination,
                          orientation_note: plan.payload[:orientation_note], current_revision: revision,
                          appointment_request: request, professional_link: link, cbo_code: link.cbo_code)
        request = close!(attendance, destination, referral_unit, plan.payload, by) || request unless destination == "same_day"
        DomainEvents.publish("screening.completed", screening_id: screening.id, attendance_id: attendance.id,
                                                    destination: destination, final_color: revision.final_color)
        Result.ok(screening: screening, attendance: attendance, appointment_request: request)
      end
    rescue HealthUnit::Inactive
      Result.fail(:invalid_unit)
    end

    def self.plan_for(destination, params, color)
      params = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params
      params = params.is_a?(Hash) ? params.deep_stringify_keys : {}
      case destination
      when "same_day" then Result.ok({})
      when "schedule" then schedule_plan(params["schedule"], color)
      when "oriented" then oriented_plan(params["orientation_note"])
      when "referred" then referral_plan(params["referral"])
      else Result.fail(:invalid_destination)
      end
    end

    def self.schedule_plan(raw, color)
      raw = raw.is_a?(Hash) ? raw : {}
      type = AppointmentType.active_types.find_by(key: raw["appointment_type_key"].to_s)
      priority = raw["priority"].to_s
      days = raw["due_in_days"].nil? ? DEFAULT_DUE_IN_DAYS[color] : Integer(raw["due_in_days"].to_s, 10, exception: false)
      valid = type && AppointmentRequest::PRIORITIES.include?(priority) && days&.between?(1, 365)
      valid ? Result.ok(appointment_type_key: type.key, priority: priority, due_in_days: days) : Result.fail(:invalid_schedule)
    end

    def self.oriented_plan(raw)
      note = raw.to_s.strip
      return Result.fail(:orientation_required) if note.empty?
      return Result.fail(:note_too_long, details: { field: "orientation_note" }) if note.length > RevisionInput::MAX_NOTE

      Result.ok(orientation_note: note)
    end

    def self.referral_plan(raw)
      raw = raw.is_a?(Hash) ? raw : {}
      unit_id = raw["referral_unit_id"].presence
      note = raw["referral_note"].to_s.strip.presence
      return Result.fail(:referral_required) if unit_id.nil? && note.nil?
      return Result.fail(:invalid_unit) if unit_id && !(unit_id.to_s.match?(UUID) && HealthUnit.active_units.exists?(id: unit_id))

      Result.ok(referral_unit_id: unit_id, referral_note: note)
    end

    # Pedido do módulo 17 com origem na escuta, na unidade do atendimento.
    def self.schedule_request!(attendance, screening, plan)
      HealthUnit.lock_active!(attendance.health_unit_id)
      request = AppointmentRequest.create!(
        kind: "screening", origin_attendance: attendance, origin_screening: screening, citizen: attendance.citizen,
        root_triage: attendance.root_triage, origin_unit: attendance.health_unit, target_unit: attendance.health_unit,
        appointment_type_key: plan[:appointment_type_key], priority: plan[:priority],
        due_on: Time.zone.today + plan[:due_in_days]
      )
      DomainEvents.publish("appointment_request.created", appointment_request_id: request.id,
                                                          origin_attendance_id: attendance.id,
                                                          target_unit_id: attendance.health_unit_id, kind: request.kind)
      request
    end

    # Fecha de waiting com o desfecho do destino; encaminhamento com unidade
    # abre o pedido como o desfecho do módulo 13. Devolve o pedido aberto.
    def self.close!(attendance, destination, referral_unit, plan, by)
      outcome = Attendance::SCREENING_OUTCOMES.fetch(destination)
      attendance.update!(status: "closed", outcome: outcome, closed_by_user: by, closed_at: Time.current,
                         referral_unit: referral_unit,
                         referral_note: destination == "referred" ? plan[:referral_note] : nil)
      request = destination == "referred" ? AppointmentRequests::Lifecycle.open_for!(attendance, outcome: "referred", unit: referral_unit) : nil
      DomainEvents.publish("attendance.closed", attendance_id: attendance.id, outcome: outcome, closed_by_user_id: by.id)
      request
    end
    private_class_method :plan_for, :schedule_plan, :oriented_plan, :referral_plan, :schedule_request!, :close!
  end
end
