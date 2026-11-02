# POST /vaccination/rooms/:room_id/patients/duplicates (§15 V21): possíveis
# duplicados do recém-nascido que vai ser digitado no card (`new_patient`),
# no padrão do /pharmacy/patients/duplicates do 27a: a busca é da cidade
# (Patients::Duplicates, a regra do 24a), candidato = a forma do módulo 25
# (`{ patient_id, display_name, birth_date, has_cpf }`, Pharmacy::Json.duplicate).
# Nome, nascimento e mãe só no corpo (query → 422 invalid_request). No máximo
# 10 candidatos; trilha por candidato mostrado; 30 por minuto por usuário.
# Portão: `vaccination` utilizável e vacinador ou responsável da sala — não
# depende de territory_registry.
module Vaccination
  class DuplicatesController < BaseController
    LIMIT = 10

    rate_limit to: 30, within: 1.minute, only: :create, name: "vaccination_duplicates", store: PersonLookupsController::RateLimitStore,
               by: -> { Current.user&.id || request.remote_ip },
               with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

    def create
      return unless member_room
      return unless query_only!

      full_name = body_param("full_name")
      birth_date = body_param("birth_date")
      mother_name = body_param("mother_name")
      return render_refusal("full_name") unless full_name.is_a?(String)
      return render_refusal("birth_date") unless Patients::MatchKey.iso_date(birth_date)
      return render_refusal("mother_name") unless mother_name.nil? || mother_name.is_a?(String)

      candidates = Patients::Duplicates.call(full_name: full_name, birth_date: birth_date, mother_name: mother_name, limit: LIMIT).first(LIMIT)
      candidates.each { |patient| Trail.person_viewed!(user: Current.user, patient_id: patient.id) }
      render json: { candidates: candidates.map { |patient| Pharmacy::Json.duplicate(patient) } }
    end
  end
end
