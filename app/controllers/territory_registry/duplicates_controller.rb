# POST /territory/patients/duplicates (contrato §5; plano, Desvio 1):
# possíveis duplicados do paciente que vai ser digitado — a busca é da cidade
# (qualquer profissional de saúde, de qualquer equipe). Nome, nascimento e
# mãe só no corpo: qualquer coisa na query → 422 invalid_request. No máximo
# 10 candidatos; trilha clinical_record.viewed por candidato mostrado. O
# limite da busca por CPF: 30 por minuto por usuário (revisão final, m3).
# registration_id (§14 L29): o cadastro ATIVO do candidato (o mesmo do 409
# already_registered) quando o usuário o lê pelo GET do cadastro; senão null.
module TerritoryRegistry
  class DuplicatesController < BaseController
    LIMIT = 10

    rate_limit to: 30, within: 1.minute, only: :create, name: "territory_duplicates", store: PersonLookupsController::RateLimitStore,
               by: -> { Current.user&.id || request.remote_ip },
               with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

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
      registrations = visible_registrations(candidates)
      render json: { candidates: candidates.map { |patient| Json.duplicate(patient, registration_id: registrations[patient.id]) } }
    end

    private

    # patient_id → id do cadastro ativo que o usuário lê.
    def visible_registrations(patients)
      IndividualRegistration.active_registrations.where(patient_id: patients.map(&:id)).includes(:team, :micro_area)
                            .select { |registration| Access.reads_registration?(Current.user, registration) }
                            .to_h { |registration| [ registration.patient_id, registration.id ] }
    end
  end
end
