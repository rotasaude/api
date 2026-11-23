# POST /zoonoses/person_lookup (módulo 35b, ADR 0054; contrato §2, Q25): o
# tutor (ou o adotante) pelo CPF ou pelo CNS, só no corpo (query → 422
# invalid_request; chave fora de cpf/cns → 422 com o path), no molde do
# TerritoryRegistry::PersonLookupsController, com a regra comum do 27a/29
# (Patients::LookupByIdentifier: o par validado sem paciente vira paciente —
# o tutor é sempre um Patient). → `{ patient: { id, display_name }, household:
# { id, address_short } | null }`: o domicílio ativo do cadastro individual
# ativo da pessoa no 24a (não há lista de domicílios). Par só declarado → 409
# citizen_not_verified; ninguém → 404 person_not_found. team?; 30 por minuto
# por usuário; trilha por pessoa mostrada e pelo domicílio mostrado
# (Zoonoses::Trail), nenhuma quando não achou. Nunca CPF nem CNS na resposta.
module Zoonoses
  class PersonLookupsController < BaseController
    ALLOWED = %w[cpf cns].freeze
    KEY_PATH_MAX = 64

    # `store:` é avaliado no carregamento; o delegador resolve Rails.cache a
    # cada requisição (o padrão do TerritoryRegistry::PersonLookupsController).
    module RateLimitStore
      def self.increment(...) = Rails.cache.increment(...)
    end

    before_action :team!

    rate_limit to: 30, within: 1.minute, only: :create, name: "zoonoses_person_lookup", store: RateLimitStore,
               by: -> { Current.user&.id || request.remote_ip },
               with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

    def create
      return unless query_only!

      unknown = (body.keys - ALLOWED).first
      return render_refusal("invalid_request", path: unknown.to_s[0, KEY_PATH_MAX]) if unknown

      found = Patients::LookupByIdentifier.call(cpf: body_param("cpf"), cns: body_param("cns"))
      return render_failure(found) if found.failure?

      patient = found.payload.fetch(:patient)
      household_id = IndividualRegistration.active_registrations.joins(:household)
                                            .where(patient_id: patient.id, households: { status: "active" }).pick(:household_id)
      Trail.person_viewed!(user: Current.user, patient_id: patient.id, household_id: household_id)
      render json: { patient: { id: patient.id, display_name: patient.display_name },
                     household: household_id && { id: household_id,
                                                  address_short: HomeVisits::Json.addresses([ household_id ])[household_id] || "Sem endereço" } }
    end
  end
end
