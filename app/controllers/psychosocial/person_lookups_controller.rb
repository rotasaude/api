# POST /psychosocial/person_lookup { cpf } | { cns } (ADR 0049; contrato §15
# "Busca de paciente", P30): a pessoa pelo CPF OU pelo CNS (o usuário em
# situação de rua sem CPF), só no corpo, na forma e com as recusas do
# Vaccination::PersonLookupsController (Patients::LookupByIdentifier): os dois,
# nenhum, malformado ou chave desconhecida → 422 com problems; par só
# declarado → 409 citizen_not_verified; ninguém → 404 person_not_found.
# → `{ patient_id, display_name, has_cpf, cns_masked }` (nunca CPF nem CNS
# inteiros). Trilha por pessoa mostrada. 30 por minuto por usuário. Usam a
# equipe lotada num CAPS e o encaminhador da UBS (senão 403 missing_role).
module Psychosocial
  class PersonLookupsController < BaseController
    ALLOWED = %w[cpf cns].freeze

    # `store:` de `rate_limit` é avaliado no carregamento da classe; o delegador
    # resolve Rails.cache a cada requisição (o padrão da farmácia, do 29 e do 30).
    module RateLimitStore
      def self.increment(...) = Rails.cache.increment(...)
    end

    before_action { forbid unless Access.person_searcher?(Current.user) }

    rate_limit to: 30, within: 1.minute, only: :create, name: "psychosocial_person_lookup", store: RateLimitStore,
               by: -> { Current.user&.id || request.remote_ip },
               with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

    def create
      return unless query_only!

      unknown = (body.keys - ALLOWED).first
      return render_refusal(unknown.to_s[0, KEY_PATH_MAX]) if unknown

      found = Patients::LookupByIdentifier.call(cpf: body_param("cpf"), cns: body_param("cns"))
      return render_lookup_failure(found) if found.failure?

      patient = found.payload.fetch(:patient)
      Trail.person_viewed!(user: Current.user, patient_id: patient.id, resource: "person_lookup")
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
