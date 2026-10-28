# POST /surveillance/patients/duplicates (contrato §5, K4; plano, V4): possíveis
# duplicados da pessoa que vai ser digitada na notificação manual — a busca é
# da cidade, a mesma regra do 24a (Patients::Duplicates), papel `surveillance`
# e SEM exigir territory_registry. Nome, nascimento e mãe só no corpo: qualquer
# coisa na query → 422 invalid_request. No máximo 10 candidatos; trilha por
# candidato mostrado; 30 por minuto por usuário.
module Surveillance
  class DuplicatesController < BaseController
    LIMIT = 10

    rate_limit to: 30, within: 1.minute, only: :create, name: "surveillance_duplicates", store: PersonLookupsController::RateLimitStore,
               by: -> { Current.user&.id || request.remote_ip },
               with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

    def create
      return forbid unless surveillance?
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
