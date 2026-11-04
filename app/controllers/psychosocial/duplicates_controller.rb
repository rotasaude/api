# POST /psychosocial/patients/duplicates { full_name, birth_date, mother_name? }
# (ADR 0049; contrato §15 "Busca de paciente", P30): possíveis duplicados, como
# o /transport/patients/duplicates do 30 — a busca da cidade
# (Patients::Duplicates, a regra do 24a), candidato `{ patient_id,
# display_name, birth_date, has_cpf }` em `{ candidates }`. Tudo no corpo
# (query ou chave desconhecida → 422). No máximo 10; trilha por candidato
# mostrado; 30 por minuto por usuário. Quem busca: o mesmo do person_lookup.
module Psychosocial
  class DuplicatesController < BaseController
    LIMIT = 10
    ALLOWED = %w[full_name birth_date mother_name].freeze

    before_action { forbid unless Access.person_searcher?(Current.user) }

    rate_limit to: 30, within: 1.minute, only: :create, name: "psychosocial_duplicates", store: PersonLookupsController::RateLimitStore,
               by: -> { Current.user&.id || request.remote_ip },
               with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

    def create
      return unless query_only!

      unknown = (body.keys - ALLOWED).first
      return render_refusal(unknown.to_s[0, KEY_PATH_MAX]) if unknown

      full_name = body_param("full_name")
      birth_date = body_param("birth_date")
      mother_name = body_param("mother_name")
      return render_refusal("full_name") unless full_name.is_a?(String)
      return render_refusal("birth_date") unless Patients::MatchKey.iso_date(birth_date)
      return render_refusal("mother_name") unless mother_name.nil? || mother_name.is_a?(String)

      candidates = Patients::Duplicates.call(full_name: full_name, birth_date: birth_date, mother_name: mother_name, limit: LIMIT).first(LIMIT)
      candidates.each { |patient| Trail.person_viewed!(user: Current.user, patient_id: patient.id, resource: "patient_duplicates") }
      render json: { candidates: candidates.map { |patient| Pharmacy::Json.duplicate(patient) } }
    end
  end
end
