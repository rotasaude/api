# Linha do tempo do profissional (ADR 0035; spec §5–§6; contrato §3): a pessoa
# pelo atendimento (em contexto), pelo paciente ou pela abertura justificada;
# as regras de leitura do 19a sobre a pessoa (ClinicalRecord::Access.for_person);
# toda leitura deixa trilha `timeline`. Sem texto clínico livre: o detalhe
# abre as telas existentes, com as regras delas.
class TimelinesController < ApplicationController
  include Authentication
  include AttendanceAccess
  include FeatureGate
  include ReportPeriod

  require_feature :patient_timeline
  before_action :require_professional

  def show
    from, to = period
    return render_invalid_period if invalid_period?(from, to) || (from && to && from > to)

    kinds = requested_kinds
    return render(json: { error: "invalid_kinds" }, status: :unprocessable_entity) unless kinds

    before = Timeline::Cursor.decode(params[:before])
    person, grant = target
    return if performed?
    # Nunca trilha de pessoa vazia (ex.: par da abertura excluído pela LGPD).
    return not_found if person.empty?

    page = Timeline::Query.call(person: person, kinds: kinds, before: before, limit: Timeline::Query.limit(params[:limit]),
                                from: from, to: to)
    Timeline::Trail.viewed!(person: person, access: "timeline", user: Current.user, reason_code: grant.opening&.reason_code)
    render json: { person: { display_name: person.display_name, partial: Timeline::Gate.partial?(Current.city),
                             patient_id: person.patient_id },
                   entries: page.entries.map { |entry| Timeline::Json.professional(entry) }, next_before: page.next_before }
  rescue Timeline::Cursor::Invalid
    render json: { error: "invalid_cursor" }, status: :unprocessable_entity
  end

  private

  # kinds[] ausente = todos; qualquer valor fora da lista (ou kinds escalar) = nil.
  def requested_kinds
    raw = params[:kinds]
    return Timeline::KINDS if raw.blank?
    return nil unless raw.is_a?(Array) && raw.all? { |kind| Timeline::KINDS.include?(kind) }

    Timeline::KINDS & raw
  end

  # [pessoa, grant]; senão a resposta de erro já saiu.
  def target
    if params[:opening_id].present? then by_opening
    elsif params[:patient_id].present? then by_patient
    elsif params[:attendance_id].present? then by_attendance
    else not_found
    end
  end

  def by_opening
    id = params[:opening_id]
    opening = uuid?(id) && ClinicalRecordOpening.where(user_id: Current.user.id).where("expires_at > ?", Time.current).find_by(id: id)
    return forbid("opening_required") unless opening

    return not_found unless opening.patient || opening.citizen

    person = opening.patient ? Timeline::Person.for_patient(opening.patient) : Timeline::Person.for_cpf(opening.citizen.cpf)
    [ person, ClinicalRecord::Access::Grant.new(kind: :justified, opening: opening, reason: nil) ]
  end

  def by_patient
    patient = uuid?(params[:patient_id]) && Patient.find_by(id: params[:patient_id])
    return not_found unless patient

    person = Timeline::Person.for_patient(patient)
    granted(person, ClinicalRecord::Access.for_person(user: Current.user, person: person))
  end

  def by_attendance
    attendance = uuid?(params[:attendance_id]) && Attendance.find_by(id: params[:attendance_id])
    return not_found unless attendance
    return render(json: { error: "citizen_not_verified" }, status: :conflict) unless attendance.citizen.verification_level_verified?

    person = Timeline::Person.for_citizen(attendance.citizen)
    granted(person, ClinicalRecord::Access.for_person(user: Current.user, person: person, attendance: attendance))
  end

  def granted(person, grant)
    return forbid(grant.reason.to_s) unless grant.allowed?

    [ person, grant ]
  end

  def uuid?(value) = value.is_a?(String) && ClinicalDocuments::Uuid.valid?(value)
  def not_found = render(json: { error: "not_found" }, status: :not_found)
end
