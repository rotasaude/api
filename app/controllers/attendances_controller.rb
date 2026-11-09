# Fila (espera/atendimento), chamada e encerramento do atendimento (spec
# 2026-09-25-citizen-appointments §2, §4).
class AttendancesController < ApplicationController
  include Authentication
  include AttendanceAccess

  ERROR_STATUS = {
    invalid_outcome: :unprocessable_entity, referral_required: :unprocessable_entity,
    invalid_unit: :unprocessable_entity, already_closed: :conflict, already_called: :conflict,
    wrong_unit: :unprocessable_entity, invalid_transition: :unprocessable_entity, queue_empty: :not_found,
    missing_role: :forbidden, missing_link: :forbidden, consultation_in_progress: :conflict,
    regulation_request_required: :unprocessable_entity,
    # Módulo 32a (Desvios 11 e 12; contrato §14 Q7, Q15).
    cbo_not_allowed: :forbidden, feature_disabled: :forbidden, not_classified: :unprocessable_entity,
    call_location_required: :unprocessable_entity, invalid_call_location: :unprocessable_entity,
    not_called: :unprocessable_entity, urgency_outcome_required: :unprocessable_entity
  }.freeze

  before_action :require_attendance_staff, only: %i[queue close]
  before_action :require_professional, only: %i[call call_next recall]

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

    result = Attendances::Call.call(attendance: attendance, health_unit_id: params[:health_unit_id], by: Current.user,
                                    call_location_id: request.request_parameters["call_location_id"],
                                    waiting_room: WaitingRoom::Gate.usable?(Current.city))
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: { attendance: called_json(result.payload[:attendance]) }
  end

  # Módulo 32a (Desvio 11): numa UPA com urgency_care utilizável, a fila por
  # cor. Os interruptores são lidos aqui, fora da transação da cidade.
  def call_next
    result = Attendances::CallNext.call(health_unit_id: params[:id], by: Current.user,
                                        call_location_id: request.request_parameters["call_location_id"],
                                        waiting_room: WaitingRoom::Gate.usable?(Current.city),
                                        urgency: Urgency::Gate.usable?(Current.city))
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: { attendance: called_json(result.payload[:attendance]) }
  end

  # "Chamar de novo" (módulo 32a; contrato §6 e §14 Q7): POST
  # /attendance/attendances/:id/recall { call_location_id } → 201
  # `{ call_id, call: { id, kind, ticket, location, called_at } }`. Sem o
  # waiting_room_display utilizável → 403 feature_disabled.
  def recall
    attendance = Attendance.find_by(id: params[:id])
    return render json: { error: "not_found" }, status: :not_found unless attendance

    result = Attendances::Recall.call(attendance: attendance, call_location_id: request.request_parameters["call_location_id"],
                                      by: Current.user, waiting_room: WaitingRoom::Gate.usable?(Current.city))
    return render_failure(result, ERROR_STATUS) if result.failure?

    call = result.payload[:call]
    render json: { call_id: call.id, call: Attendances::CallRecord.json(call) }, status: :created
  end

  def close
    attendance = Attendance.find_by(id: params[:id])
    return render json: { error: "not_found" }, status: :not_found unless attendance
    return forbid("missing_role") unless params[:outcome].to_s == "left" || CitizenVerificationPolicy.new(Current.user, nil).care?

    # Módulo 26a (Desvio 2): sem consulta não há pedido de regulação; com o
    # interruptor utilizável (lido aqui, fora do savepoint), "encaminhado" sem
    # unidade é 422 regulation_request_required.
    regulation = CareRegulation::Gate.usable?(Current.city) ? 0 : nil
    # Módulo 32a (§14 Q10): com urgency_care utilizável, o atendimento da UPA
    # fecha só pelo desfecho da urgência (422 urgency_outcome_required).
    result = Attendances::Close.call(attendance: attendance, outcome: params[:outcome],
                                     referral_unit_id: params[:referral_unit_id],
                                     referral_note: params[:referral_note], by: Current.user, regulation: regulation,
                                     urgency: Urgency::Gate.usable?(Current.city))
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: { attendance: attendance_json(result.payload[:attendance]),
                   appointment_request: request_json(result.payload[:appointment_request]) }
  end

  private

  def queue_json(a, refs, screening_active)
    {
      # Módulo 32a: a pessoa do walk_in é o paciente (nome e CPF mascarado dele).
      id: a.id, cpf_masked: a.person.cpf_masked, display_name: a.person.display_name, checked_in_at: a.checked_in_at&.iso8601,
      ticket: a.ticket, protocol_name: a.root_triage&.protocol_name, priority: a.priority,
      source: a.origin_kind, appointment_time: a.appointment&.scheduled_at&.iso8601,
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
    json = {
      id: a.id, triage_id: a.triage_id, appointment_id: a.appointment_id, health_unit_id: a.health_unit_id,
      unit_name: a.health_unit.name, status: a.status, checked_in_at: a.checked_in_at&.iso8601,
      check_in_method: a.check_in_method, called_at: a.called_at&.iso8601, outcome: a.outcome,
      referral_unit_name: a.referral_unit&.name, referral_note: a.referral_note, closed_at: a.closed_at&.iso8601,
      called_by_name: Screenings::Json.staff_name(a.called_by_user), closed_by_name: Screenings::Json.staff_name(a.closed_by_user)
    }
    # ADR 0039 (contrato §3, E8): procedimentos do atendimento, só com procedure_billing ligado e só para
    # profissional ou leitor do faturamento (a recepção não recebe a chave).
    if Billing::Gate.enabled?(Current.city) && Current.user &&
       (Current.user.has_role?("health_professional") || Billing::Access.reader?(Current.user))
      json[:procedures] = Billing::Json.attached(PerformedProcedure.where(attendance_id: a.id))
    end
    json
  end

  def request_json(r)
    return nil unless r

    { id: r.id, kind: r.kind, target_unit_name: r.target_unit.name, status: r.status }
  end
end
