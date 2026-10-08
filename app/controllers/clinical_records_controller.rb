# O prontuário (ADR 0031; spec §5; contratos §3): em contexto pelo atendimento,
# ou fora dele só com abertura justificada válida. Toda leitura deixa trilha;
# a escuta do dia (módulo 18) publica screening.viewed.
class ClinicalRecordsController < ApplicationController
  include Authentication
  include AttendanceAccess
  include ClinicalRecordGate

  before_action :require_clinical_record!
  before_action :require_professional

  def context
    attendance = Attendance.find_by(id: params[:id])
    return not_found unless attendance

    citizen = attendance.citizen
    return render(json: { error: "citizen_not_verified" }, status: :conflict) unless citizen.verification_level_verified?

    patient = (citizen.patient_id && Patient.find_by(id: citizen.patient_id)) || Patient.find_by(cpf: citizen.cpf)
    grant = ClinicalRecord::Access.call(user: Current.user, patient: patient, attendance: attendance)
    return forbid(grant.reason.to_s) unless grant.allowed?

    ClinicalRecord::Trail.viewed!(patient: patient, user: Current.user, grant: grant)
    screening = attendance.screening
    screening = nil unless screening&.completed?
    DomainEvents.publish("screening.viewed", screening_id: screening.id, user_id: Current.user.id) if screening
    render json: ClinicalRecord::Json.record(patient: patient, citizen: citizen, grant: grant, screening: screening)
  end

  def patient
    patient = Patient.find_by(id: params[:id])
    return not_found unless patient

    opening = ClinicalRecordOpening.valid_for(user_id: Current.user.id, patient_id: patient.id).order(created_at: :desc).first
    return forbid("opening_required") unless opening

    grant = ClinicalRecord::Access::Grant.new(kind: :justified, opening: opening, reason: nil)
    ClinicalRecord::Trail.viewed!(patient: patient, user: Current.user, grant: grant)
    citizen = Citizen.not_erased.where(cpf: patient.cpf).order(:created_at).first
    render json: ClinicalRecord::Json.record(patient: patient, citizen: citizen, grant: grant)
  end

  private

  def not_found = render(json: { error: "not_found" }, status: :not_found)
end
