# Fila (espera/atendimento), chamada e encerramento do atendimento (spec
# 2026-09-25-citizen-appointments §2, §4).
class AttendancesController < ApplicationController
  include Authentication
  include AttendanceAccess

  ERROR_STATUS = {
    invalid_outcome: :unprocessable_entity, referral_required: :unprocessable_entity,
    invalid_unit: :unprocessable_entity, already_closed: :conflict, already_called: :conflict,
    wrong_unit: :unprocessable_entity, invalid_transition: :unprocessable_entity, queue_empty: :not_found,
    missing_role: :forbidden, missing_link: :forbidden
  }.freeze

  before_action :require_attendance_staff, only: %i[queue close]
  before_action :require_professional, only: %i[call call_next]

  def queue
    unit = HealthUnit.find_by(id: params[:id])
    return render json: { error: "not_found" }, status: :not_found unless unit

    waiting = Attendances::UnitQueue.waiting(unit.id)
    in_care = Attendances::UnitQueue.in_care(unit.id)
    # ADR 0023: o formulário de desfecho (dashboard) pré-seleciona a primeira
    # por nome; informa e sugere, nunca restringe. A própria unidade da linha
    # nunca entra (decisão de 2026-09-28): encaminhar para si mesma não é
    # encaminhamento.
    refs = Territory::ReferenceUnits.ids_by_neighborhood((waiting + in_care).map(&:territory_neighborhood_id))
    screening_active = Screenings::ActiveProtocol.current.present?
    render json: { waiting: waiting.map { |a| queue_json(a, refs, screening_active) },
                   in_care: in_care.map { |a| queue_json(a, refs, screening_active) } }
  end

  def call
    attendance = Attendance.find_by(id: params[:id])
    return render json: { error: "not_found" }, status: :not_found unless attendance

    result = Attendances::Call.call(attendance: attendance, health_unit_id: params[:health_unit_id], by: Current.user)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: { attendance: called_json(result.payload[:attendance]) }
  end

  def call_next
    result = Attendances::CallNext.call(health_unit_id: params[:id], by: Current.user)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: { attendance: called_json(result.payload[:attendance]) }
  end

  def close
    attendance = Attendance.find_by(id: params[:id])
    return render json: { error: "not_found" }, status: :not_found unless attendance
    return forbid("missing_role") unless params[:outcome].to_s == "left" || CitizenVerificationPolicy.new(Current.user, nil).care?

    result = Attendances::Close.call(attendance: attendance, outcome: params[:outcome],
                                     referral_unit_id: params[:referral_unit_id],
                                     referral_note: params[:referral_note], by: Current.user)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: { attendance: attendance_json(result.payload[:attendance]),
                   appointment_request: request_json(result.payload[:appointment_request]) }
  end

  private

  def queue_json(a, refs, screening_active)
    {
      id: a.id, cpf_masked: a.citizen.cpf_masked, checked_in_at: a.checked_in_at&.iso8601,
      protocol_name: a.root_triage&.protocol_name, priority: a.priority,
      source: a.appointment_id ? "appointment" : "triage", appointment_time: a.appointment&.scheduled_at&.iso8601,
      called_at: a.called_at&.iso8601, called_by_name: Screenings::Json.staff_name(a.called_by_user),
      reference_unit_ids: refs.fetch(a.territory_neighborhood_id, []) - [ a.health_unit_id ],
      # ADR 0030 (contratos §4 e §9): só cor, destino e espera — nunca queixa
      # nem sinais, nem para a recepção; quem ainda aguarda acolhimento vem
      # marcado (e por último, Attendances::UnitQueue) — só com protocolo de
      # acolhimento ativo na cidade (spec §11.4).
      screening: Screenings::Json.queue_block(a),
      awaiting_screening: Screenings::Queue.awaiting?(a, active: screening_active)
    }
  end

  # ADR 0030 (contratos §4 e §9): quem chamou recebe a escuta concluída (leitura
  # auditada). Só a rota da chamada; o balcão não passa por aqui.
  def called_json(attendance)
    screening = attendance.screening
    screening = nil unless screening&.completed?
    DomainEvents.publish("screening.viewed", screening_id: screening.id, user_id: Current.user.id) if screening
    attendance_json(attendance).merge(screening: screening && Screenings::Json.screening(screening))
  end

  def attendance_json(a)
    {
      id: a.id, triage_id: a.triage_id, appointment_id: a.appointment_id, health_unit_id: a.health_unit_id,
      unit_name: a.health_unit.name, status: a.status, checked_in_at: a.checked_in_at&.iso8601,
      check_in_method: a.check_in_method, called_at: a.called_at&.iso8601, outcome: a.outcome,
      referral_unit_name: a.referral_unit&.name, referral_note: a.referral_note, closed_at: a.closed_at&.iso8601,
      called_by_name: Screenings::Json.staff_name(a.called_by_user), closed_by_name: Screenings::Json.staff_name(a.closed_by_user)
    }
  end

  def request_json(r)
    return nil unless r

    { id: r.id, kind: r.kind, target_unit_name: r.target_unit.name, status: r.status }
  end
end
