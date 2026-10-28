# POST /surveillance/person_lookup (contrato §5, K4; plano, V4): a pessoa pelo
# CPF, só no corpo (query → 422 invalid_request), para começar a notificação
# manual: paciente ou par validado sem paciente (buscar não cria paciente; ele
# nasce na notificação, pelo Resolve). Par só declarado → 409
# citizen_not_verified; ninguém → 404 person_not_found. A mesma forma e as
# mesmas recusas do 24a, papel `surveillance`, SEM exigir territory_registry.
# 30 por minuto por usuário; trilha por pessoa mostrada.
module Surveillance
  class PersonLookupsController < BaseController
    # `store:` é avaliado no carregamento; o delegador resolve Rails.cache a
    # cada requisição (o padrão do TerritoryRegistry::PersonLookupsController).
    module RateLimitStore
      def self.increment(...) = Rails.cache.increment(...)
    end

    rate_limit to: 30, within: 1.minute, only: :create, name: "surveillance_person_lookup", store: RateLimitStore,
               by: -> { Current.user&.id || request.remote_ip },
               with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

    def create
      return forbid unless surveillance?
      return unless query_only!

      raw = body_param("cpf")
      cpf = raw.is_a?(String) ? CitizenIdentity::Cpf.normalize(raw) : nil
      return render_error("invalid_cpf") unless cpf

      patient = Patient.find_by(cpf: cpf)
      citizen = Patients::Pairs.of_cpf(cpf).order(:created_at, :id).first unless patient
      unless patient || citizen
        return render_error("citizen_not_verified", :conflict) if Citizen.not_erased.where(cpf: cpf).exists?

        return render_error("person_not_found", :not_found)
      end

      Trail.person_viewed!(user: Current.user, patient_id: patient&.id, citizen_id: citizen&.id)
      person = patient || citizen
      render json: { patient_id: patient&.id, citizen_id: citizen&.id, display_name: person.display_name }
                     .merge(Patients::IdentifierJson.call(person))
    end
  end
end
