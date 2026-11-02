# POST /vaccination/rooms/:room_id/person_lookup (§15 V3): a pessoa pelo CPF
# OU pelo CNS, só no corpo, na forma e com as recusas do POST
# /pharmacy/person_lookup do 27a (Patients::LookupByIdentifier): `invalid_cpf`/
# `invalid_cns`/os dois ou nenhum → 422 com problems; par só declarado → 409
# citizen_not_verified; ninguém → 404 person_not_found; o par validado sem
# paciente vira paciente. → `{ patient_id, display_name, has_cpf, cns_masked }`
# (nunca CPF nem CNS inteiros). Trilha por pessoa mostrada (nenhuma quando não
# achou). 30 por minuto por usuário. Vacinador ou responsável da sala.
# Duplicados: o POST /territory/patients/duplicates existente.
module Vaccination
  class PersonLookupsController < BaseController
    # `store:` de `rate_limit` é avaliado no carregamento da classe; o delegador
    # resolve Rails.cache a cada requisição (o padrão da farmácia).
    module RateLimitStore
      def self.increment(...) = Rails.cache.increment(...)
    end

    rate_limit to: 30, within: 1.minute, only: :create, name: "vaccination_person_lookup", store: RateLimitStore,
               by: -> { Current.user&.id || request.remote_ip },
               with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

    def create
      return unless member_room
      return unless query_only!

      found = Patients::LookupByIdentifier.call(cpf: body_param("cpf"), cns: body_param("cns"))
      return render_lookup_failure(found) if found.failure?

      patient = found.payload.fetch(:patient)
      Trail.person_viewed!(user: Current.user, patient_id: patient.id)
      render json: { patient_id: patient.id, display_name: patient.display_name, **Patients::IdentifierJson.call(patient) }
    end

    private

    def render_lookup_failure(result)
      case result.reason
      when :citizen_not_verified then render_error("citizen_not_verified", :conflict)
      when :person_not_found then render_error("person_not_found", :not_found)
      else render_refusal(result.details.fetch(:path), result.reason)
      end
    end
  end
end
