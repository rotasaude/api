# POST /vaccination/rooms/:room_id/card (contrato §2, §5; §15 V3, V14): a
# caderneta da pessoa, lida no contexto da sala (vacinador ou responsável da
# sala; fora da equipe → 403). Exatamente um de:
#  - `patient_id` (inexistente ou malformado → 404);
#  - `new_patient` (recém-nascido sem cadastro, a forma do 24a: as recusas de
#    Patients::CreateTyped com o path `new_patient.<campo>`) com
#    `duplicates_reviewed` opcional (booleano): nome + nascimento de paciente já
#    gravado → 409 duplicate_suspected, salvo `duplicates_reviewed: true`; os
#    candidatos vêm do POST /territory/patients/duplicates existente.
# Os dois ou nenhum → 422 invalid_request (path patient_id).
#
# Pessoa sem conferência: a situação é recalculada antes (a conferência
# born_after_go_live nasce aqui quando cabe — o recém-nascido já sai conferido).
# Uma trilha clinical_record.viewed (access "vaccination") pela pessoa
# mostrada. Tudo do paciente só no corpo (query → 422).
module Vaccination
  class CardsController < BaseController
    def create
      # A sala só autoriza: a caderneta é da pessoa, não da sala.
      return unless member_room
      return unless query_only!

      patient_id = body_param("patient_id")
      new_patient = body_param("new_patient")
      return render_refusal("patient_id") if patient_id.nil? == new_patient.nil?

      patient = patient_id.nil? ? created_patient(new_patient) : body_patient
      return unless patient

      today = Time.zone.today
      Statuses.refresh!(patient, today: today) unless Statuses.checked?(patient.id)
      Trail.person_viewed!(user: Current.user, patient_id: patient.id)
      render json: Card.call(patient: patient, today: today, rnds_usable: Rnds::Gate.usable?(Current.city), viewer: Current.user)
    end

    private

    # Patient | nil (já respondeu).
    def created_patient(new_patient)
      return render_refusal("new_patient") && nil unless new_patient.is_a?(Hash)

      reviewed = request.request_parameters.fetch("duplicates_reviewed", false)
      return render_refusal("duplicates_reviewed") && nil unless [ true, false ].include?(reviewed)

      shape = Patients::CreateTyped.check(new_patient)
      return render_typed_refusal(shape) && nil if shape.failure?

      created = Patients::CreateReviewed.call(new_patient: new_patient, reviewed: reviewed, by: Current.user)
      return created.payload.fetch(:patient) if created.ok?

      case created.reason
      when :duplicate_suspected then render_error("duplicate_suspected", :conflict)
      when :cpf_taken, :cns_taken then render(json: { error: created.reason.to_s, path: created.details[:path] }, status: :conflict)
      else render_typed_refusal(created)
      end
      nil
    end

    # A recusa de forma do CreateTyped com o path do corpo (new_patient.*).
    def render_typed_refusal(result)
      path = { invalid_cpf: "new_patient.cpf", invalid_cns: "new_patient.cns",
               cpf_or_reason_required: "new_patient.no_cpf_reason" }[result.reason] || result.details.fetch(:path, "new_patient")
      render_refusal(path, result.reason)
    end
  end
end
