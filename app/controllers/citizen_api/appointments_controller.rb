# "Seus agendamentos" (spec 2026-09-25 §4, §6). Só pares do celular da sessão (senão 404).
module CitizenApi
  class AppointmentsController < BaseController
    ERROR_STATUS = {
      confirmation_closed: :conflict, appointment_ended: :conflict, reason_too_short: :unprocessable_entity,
      not_today: :unprocessable_entity, appointment_not_eligible: :unprocessable_entity,
      not_reschedulable: :conflict, invalid_reason_code: :unprocessable_entity,
      invalid_period: :unprocessable_entity, note_too_long: :unprocessable_entity
    }.freeze

    rate_limit to: 20, within: 1.hour, only: %i[confirm cancel reschedule_request], name: "citizen_appointment_write",
               by: -> { current_citizen_session&.id || request.remote_ip }, store: RateLimitStore,
               with: -> { render_error("too_many_requests", :too_many_requests) }
    rate_limit to: 10, within: 1.hour, only: :check_in_code, name: "citizen_appointment_check_in_code",
               by: -> { current_citizen_session&.id || request.remote_ip }, store: RateLimitStore,
               with: -> { render_error("too_many_requests", :too_many_requests) }

    def index
      citizen = current_citizen_session.citizens.find_by(id: params[:citizen_id])
      return render_error("not_found", :not_found) unless citizen

      # O pedido movido de unidade (api#29) some da lista: vale o novo, que diz
      # de onde veio (moved_from_unit_name).
      requests = AppointmentRequest.where(citizen: citizen).where("closed_reason IS DISTINCT FROM 'moved'")
                                   .includes(:target_unit, moved_from_request: :target_unit,
                                             appointments: %i[health_unit professional])
                                   .order(created_at: :desc)
      render json: { appointments: requests.map { |r| item_json(r) } }
    end

    def confirm
      with_appointment { |a| Appointments::Confirm.call(appointment: a) }
    end

    def cancel
      with_appointment { |a| Appointments::CancelByCitizen.call(appointment: a, reason: params[:reason]) }
    end

    # "Não posso nesse horário" (ADR 0029 §6). A nota nunca sai em log
    # (`:note` em filter_parameters) nem em evento.
    def reschedule_request
      with_appointment do |a|
        Appointments::RequestReschedule.call(appointment: a, reason_code: params[:reason_code].to_s,
                                             note: params[:note], preferred_period: params[:preferred_period].to_s)
      end
    end

    def check_in_code
      appointment = own_appointment
      return render_error("not_found", :not_found) unless appointment

      result = Citizens::IssueAppointmentCheckInCode.call(citizen: appointment.citizen, appointment: appointment)
      return render_error(result.reason, ERROR_STATUS.fetch(result.reason, :unprocessable_entity)) if result.failure?

      render json: { code: result.payload[:code], expires_at: result.payload[:expires_at].iso8601 }, status: :created
    end

    private

    def own_appointment
      Appointment.where(citizen_id: current_citizen_session.citizens.select(:id)).find_by(id: params[:id])
    end

    def with_appointment
      appointment = own_appointment
      return render_error("not_found", :not_found) unless appointment

      result = yield(appointment)
      return render_error(result.reason, ERROR_STATUS.fetch(result.reason, :unprocessable_entity)) if result.failure?

      render json: { appointment: appointment_json(appointment.reload) }
    end

    def item_json(request)
      latest = request.latest_appointment
      {
        request: { id: request.id, kind: request.kind, target_unit_name: request.target_unit&.name,
                   status: request.status, closed_reason: request.closed_reason,
                   # A remarcação pedida pelo próprio cidadão não é "reaberto" para ele.
                   reopened_reason: request.reopened_reason == "citizen_reschedule" ? nil : request.reopened_reason,
                   moved_from_unit_name: request.moved_from_request&.target_unit&.name,
                   appointment_type_name: catalog.name_for(request.appointment_type_key),
                   due_on: request.due_on.iso8601 },
        appointment: latest && appointment_json(latest)
      }
    end

    # Horário legado (antes do módulo 17) não tem tipo, profissional nem fim.
    def appointment_json(a)
      legacy = a.booking_kind == "legacy"
      { id: a.id, scheduled_at: a.scheduled_at.iso8601, status: a.status,
        confirmation_deadline_at: a.confirmation_deadline_at&.iso8601,
        check_in_available: Attendances::AppointmentCheckInEligibility.check(a) == :ok,
        ends_at: legacy ? nil : a.ends_at&.iso8601,
        appointment_type_name: legacy ? nil : catalog.name_for(a.appointment_type_key),
        professional_name: legacy ? nil : a.professional&.professional_name,
        unit: { name: a.health_unit.name, address: Scheduling::UnitAddress.call(a.health_unit) },
        can_request_reschedule: Appointments::RequestReschedule.reschedulable?(a) }
    end

    def catalog = @catalog ||= Scheduling::AppointmentTypes.catalog
  end
end
