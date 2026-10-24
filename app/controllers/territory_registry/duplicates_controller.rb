# POST /territory/patients/duplicates (contrato §5; plano, Desvio 1):
# possíveis duplicados do paciente que vai ser digitado — a busca é da cidade
# (qualquer profissional de saúde, de qualquer equipe). Nome, nascimento e
# mãe só no corpo: qualquer coisa na query → 422 invalid_request. No máximo
# 10 candidatos; trilha clinical_record.viewed por candidato mostrado.
module TerritoryRegistry
  class DuplicatesController < BaseController
    LIMIT = 10

    def create
      return forbid unless Current.user.has_role?("health_professional")
      return unless query_only!

      full_name = body_param("full_name")
      birth_date = body_param("birth_date")
      mother_name = body_param("mother_name")
      unless full_name.is_a?(String) && Patients::MatchKey.iso_date(birth_date) && (mother_name.nil? || mother_name.is_a?(String))
        return render_error("invalid_request")
      end

      candidates = Patients::Duplicates.call(full_name: full_name, birth_date: birth_date, mother_name: mother_name, limit: LIMIT)
                                       .first(LIMIT)
      candidates.each { |patient| Trail.person_viewed!(user: Current.user, patient_id: patient.id) }
      render json: { candidates: candidates.map { |patient| Json.duplicate(patient) } }
    end
  end
end
