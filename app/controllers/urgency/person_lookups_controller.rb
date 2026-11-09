# POST /urgency/person_lookup { cpf } | { cns } (contrato §4, §14 Q4): a
# pessoa pelo CPF OU pelo CNS, só no corpo, com as recusas de forma do
# Patients::LookupByIdentifier (os dois, nenhum, malformado ou chave
# desconhecida → 422 com problems); par só declarado → 409
# citizen_not_verified. Sempre 200 `{ patient: <patient-ref> | null,
# candidates: [] }`: ninguém é `patient: null`. A pessoa mostrada grava a
# trilha da urgência (resource person_lookup). 30 por minuto por usuário. Só a
# recepção (citizen_verifier). O provisório nunca é achado (sem CPF nem CNS).
module Urgency
  class PersonLookupsController < BaseController
    ALLOWED = %w[cpf cns].freeze

    # `store:` de `rate_limit` é avaliado no carregamento da classe; o delegador
    # resolve Rails.cache a cada requisição (o padrão da farmácia, do 29 e do 30).
    module RateLimitStore
      def self.increment(...) = Rails.cache.increment(...)
    end

    before_action :require_reception!

    rate_limit to: 30, within: 1.minute, only: :create, name: "urgency_person_lookup", store: RateLimitStore,
               by: -> { Current.user&.id || request.remote_ip },
               with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

    def create
      return unless query_only!

      unknown = (body.keys - ALLOWED).first
      return render_refusal(unknown.to_s[0, KEY_PATH_MAX]) if unknown

      found = Patients::LookupByIdentifier.call(cpf: body_param("cpf"), cns: body_param("cns"))
      return render(json: { patient: nil, candidates: [] }) if found.failure? && found.reason == :person_not_found
      return render_lookup_failure(found) if found.failure?

      patient = found.payload.fetch(:patient)
      Trail.viewed!(user: Current.user, patient_id: patient.id, resource: "person_lookup")
      render json: { patient: PatientRef.call(patient), candidates: [] }
    end

    private

    def render_lookup_failure(result)
      return render(json: { error: "citizen_not_verified" }, status: :conflict) if result.reason == :citizen_not_verified

      render_refusal(result.details.fetch(:path), result.reason)
    end
  end
end
