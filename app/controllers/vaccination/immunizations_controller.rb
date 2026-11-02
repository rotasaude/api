# Dose aplicada na sala (contrato §2, §5; §15 V5, V6, V10):
#   POST /vaccination/rooms/:room_id/immunizations  { patient_id, immunobiological_code, dose_code, strategy, care_group,
#        route, site, maternal_condition?, applied_at, lot_id, vial_id?, campaign_id?, override_reason? } → 201 <immunization>
#   GET  /vaccination/immunizations/:id → <immunization>
# Registrar: vacinador ou responsável da sala (fora da equipe → 403). Recusas
# 422 com todos os `problems` de uma vez; os avisos (intervalo, idade) com
# `overridable: true` até vir `override_reason`.
# Ler (V10): a equipe da sala da dose, ou quem lê a linha do tempo do
# paciente (patient_timeline ligado e a regra do 19a/20 sobre a pessoa:
# contexto ou abertura justificada); fora disso → 404. Ambas nominais: uma
# trilha clinical_record.viewed (access "vaccination"). Dado do paciente só no
# corpo (query → 422).
module Vaccination
  class ImmunizationsController < BaseController
    def create
      room = member_room or return
      return unless query_only!

      patient = body_patient or return
      rnds_usable = Rnds::Gate.usable?(Current.city)
      result = RecordImmunization.call(room: room, patient: patient, attrs: body.except("patient_id"), by: Current.user)
      return render_dose_failure(result) if result.failure?

      dose = result.payload[:immunization]
      render json: Json.immunization(dose, entry: dose.rnds_outbox_entries.find_by(kind: "application"), rnds_usable: rnds_usable,
                                           viewer: Current.user),
             status: :created
    end

    def show
      return unless query_only!

      dose = uuid?(params[:id]) ? Immunization.includes(:patient, vaccine_room: :health_unit).find_by(id: params[:id]) : nil
      return not_found unless dose && readable?(dose)

      Trail.person_viewed!(user: Current.user, patient_id: dose.patient_id)
      render json: Json.immunization(dose, entry: dose.rnds_outbox_entries.find_by(kind: "application"),
                                           rnds_usable: Rnds::Gate.usable?(Current.city), viewer: Current.user)
    end

    private

    def readable?(dose)
      return true if dose.vaccine_room && Access.room_roles(user: Current.user, room: dose.vaccine_room).any?
      return false unless Timeline::Gate.enabled?(Current.city)

      person = Timeline::Person.for_patient(dose.patient)
      ClinicalRecord::Access.for_person(user: Current.user, person: person).allowed?
    end

    def render_dose_failure(result)
      return forbid if result.reason == :missing_role

      problems = result.details.fetch(:problems)
      render json: { error: problems.first[:error], path: problems.first[:path], problems: problems }, status: :unprocessable_entity
    end
  end
end
