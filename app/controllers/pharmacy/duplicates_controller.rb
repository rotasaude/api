# POST /pharmacy/patients/duplicates (contrato §13 H2, H12): possíveis
# duplicados do paciente que vai ser digitado na receita externa (`new_patient`),
# na forma e com a trilha do Surveillance::DuplicatesController do módulo 25: a
# busca é da cidade (Patients::Duplicates, a regra do 24a), candidato =
# `{ patient_id, display_name, birth_date, has_cpf }`. Nome, nascimento e mãe só
# no corpo: qualquer coisa na query → 422 invalid_request. No máximo 10
# candidatos; trilha por candidato mostrado; 30 por minuto por usuário.
# `pharmacist` ou `pharmacy_assistant` de algum local `unit` ativo.
module Pharmacy
  class DuplicatesController < BaseController
    LIMIT = 10

    rate_limit to: 30, within: 1.minute, only: :create, name: "pharmacy_duplicates", store: RateLimitStore,
               by: -> { Current.user&.id || request.remote_ip },
               with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

    def create
      return forbid unless dispenser_anywhere?
      return unless query_only!

      full_name = body_param("full_name")
      birth_date = body_param("birth_date")
      mother_name = body_param("mother_name")
      return render_refusal("full_name") unless full_name.is_a?(String)
      return render_refusal("birth_date") unless Patients::MatchKey.iso_date(birth_date)
      return render_refusal("mother_name") unless mother_name.nil? || mother_name.is_a?(String)

      candidates = Patients::Duplicates.call(full_name: full_name, birth_date: birth_date, mother_name: mother_name, limit: LIMIT).first(LIMIT)
      candidates.each { |patient| Trail.person_viewed!(user: Current.user, patient_id: patient.id) }
      render json: { candidates: candidates.map { |patient| Json.duplicate(patient) } }
    end
  end
end
