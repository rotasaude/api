# Escuta inicial (ADR 0030; spec §7; contratos §3). Profissional com vínculo e
# CBO permitido (conferidos nos comandos); a fila do acolhimento também para o
# balcão. Ler a escuta deixa trilha (screening.viewed); a recepção nunca lê.
class ScreeningsController < ApplicationController
  include Authentication
  include AttendanceAccess

  wrap_parameters false

  ERROR_STATUS = {
    missing_role: :forbidden, missing_link: :forbidden, cbo_not_allowed: :forbidden,
    already_screening: :conflict, not_waiting: :conflict, screening_not_required: :conflict,
    not_in_progress: :conflict, attendance_not_waiting: :conflict, not_reassessable: :conflict,
    invalid_ciap2: :unprocessable_entity, implausible_vital: :unprocessable_entity, bp_incomplete: :unprocessable_entity,
    invalid_color: :unprocessable_entity, color_change_reason_required: :unprocessable_entity,
    invalid_destination: :unprocessable_entity, orientation_required: :unprocessable_entity,
    invalid_schedule: :unprocessable_entity, referral_required: :unprocessable_entity,
    invalid_unit: :unprocessable_entity, note_too_long: :unprocessable_entity
  }.freeze
  REVISION_KEYS = %w[ciap2_code complaint_note vitals final_color color_change_reason].freeze
  DESTINATION_KEYS = %w[orientation_note schedule referral].freeze

  before_action :require_attendance_staff, only: :queue
  before_action :require_professional, except: :queue
  before_action :set_screening, only: %i[show abandon complete reassess]

  def queue
    unit = HealthUnit.find_by(id: params[:id])
    return not_found unless unit

    render json: { items: Screenings::Queue.items(unit).map { |a| Screenings::Json.queue_item(a) } }
  end

  def create
    attendance = Attendance.find_by(id: params[:id])
    return not_found unless attendance

    respond(Screenings::Start.call(attendance: attendance, by: Current.user), status: :created)
  end

  def abandon = respond(Screenings::Abandon.call(screening: @screening, by: Current.user))

  def complete
    respond(Screenings::Complete.call(screening: @screening, revision_params: body_slice(REVISION_KEYS),
                                      destination: params[:destination], destination_params: body_slice(DESTINATION_KEYS),
                                      by: Current.user))
  end

  def reassess
    respond(Screenings::Reassess.call(screening: @screening, revision_params: body_slice(REVISION_KEYS), by: Current.user))
  end

  def show
    status = ApplicationRecord.transaction do
      Professionals::ClinicalAuthorization.check(user: Current.user, health_unit_id: @screening.attendance.health_unit_id)
    end
    return forbid(status.to_s) unless status == :ok

    DomainEvents.publish("screening.viewed", screening_id: @screening.id, user_id: Current.user.id)
    render json: Screenings::Json.screening(@screening, with_revisions: true)
  end

  # Cor sugerida sem gravar (contratos §3 e §9): o simulador da tela de escuta.
  # Pelo atendimento (não pelo cidadão): só quem tem vínculo ativo na unidade
  # dele lê o perfil do par.
  def suggest
    attendance = Attendance.find_by(id: params[:attendance_id])
    return not_found unless attendance

    status = ApplicationRecord.transaction do
      Professionals::ClinicalAuthorization.check(user: Current.user, health_unit_id: attendance.health_unit_id)
    end
    return forbid(status.to_s) unless status == :ok

    vitals = Screenings::VitalSigns.parse(body_slice(%w[vitals])["vitals"])
    return render_failure(vitals, ERROR_STATUS) if vitals.failure?

    code = params[:ciap2_code].presence
    ciap = code && Screenings::Ciap2.find(code)
    return render json: { error: "invalid_ciap2" }, status: :unprocessable_entity if code && ciap.nil?

    suggestion = Screenings::Suggest.call(citizen: attendance.citizen, ciap2_code: ciap&.code, vitals: vitals.payload[:values],
                                          bmi: vitals.payload[:bmi])
    rules = suggestion[:protocol_definition_id] && ProtocolDefinition.find(suggestion[:protocol_definition_id]).definition["risk_rules"]
    render json: {
      suggested_color: suggestion[:color], matched_rules: Screenings::Json.matched_rules_for(suggestion[:matched], rules),
      alerts: vitals.payload[:alerts], bmi: vitals.payload[:bmi]
    }
  end

  private

  def set_screening
    @screening = Screening.find_by(id: params[:id])
    not_found unless @screening
  end

  def respond(result, status: :ok)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: Screenings::Json.screening(result.payload[:screening].reload), status: status
  end

  def body_slice(keys) = params.to_unsafe_h.slice(*keys)

  def not_found = render(json: { error: "not_found" }, status: :not_found)
end
