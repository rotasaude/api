# POST /transport/person_lookup { cpf } (§14 T2; preflight §4): a pessoa pelo
# CPF, só no corpo, na forma e com as recusas do Vaccination::
# PersonLookupsController do 29 (Patients::LookupByIdentifier): `invalid_cpf`
# → 422 com problems; sem CPF ou chave desconhecida (o `cns` inclusive: o T2
# só fala de CPF) → 422 invalid_request; par só declarado → 409
# citizen_not_verified; ninguém → 404 person_not_found. O par validado sem
# paciente vira paciente pela regra comum do 27a/29 — a central não digita
# paciente novo (não há new_patient). → `{ patient_id, display_name, has_cpf,
# cns_masked }` (nunca CPF nem CNS inteiros). Trilha por pessoa mostrada.
# 30 por minuto por usuário. Só a central.
module Transport
  class PersonLookupsController < BaseController
    ALLOWED = %w[cpf].freeze

    # `store:` de `rate_limit` é avaliado no carregamento da classe; o delegador
    # resolve Rails.cache a cada requisição (o padrão da farmácia e do 29).
    module RateLimitStore
      def self.increment(...) = Rails.cache.increment(...)
    end

    before_action { forbid unless Access.dispatcher?(Current.user) }

    rate_limit to: 30, within: 1.minute, only: :create, name: "transport_person_lookup", store: RateLimitStore,
               by: -> { Current.user&.id || request.remote_ip },
               with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

    def create
      return unless query_only!

      unknown = (body.keys - ALLOWED).first
      return render_refusal(unknown.to_s[0, KEY_PATH_MAX]) if unknown

      found = Patients::LookupByIdentifier.call(cpf: body_param("cpf"), cns: nil)
      return render_lookup_failure(found) if found.failure?

      patient = found.payload.fetch(:patient)
      Trail.person_viewed!(user: Current.user, patient_id: patient.id)
      render json: { patient_id: patient.id, display_name: patient.display_name, **Patients::IdentifierJson.call(patient) }
    end

    private

    def render_lookup_failure(result)
      case result.reason
      when :citizen_not_verified then render json: { error: "citizen_not_verified" }, status: :conflict
      when :person_not_found then render json: { error: "person_not_found" }, status: :not_found
      else render_refusal(result.details.fetch(:path), result.reason)
      end
    end
  end
end
