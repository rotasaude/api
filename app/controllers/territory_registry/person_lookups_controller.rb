# POST /territory/person_lookup (contrato §14 L3): a pessoa pelo CPF, só no
# corpo (query → 422 invalid_request), para começar a ficha de quem tem CPF:
# paciente (com o cadastro ativo, se houver) ou par validado sem paciente.
# Buscar não cria paciente (ele nasce no cadastro, pelo Resolve). Par só
# declarado → 409 citizen_not_verified; ninguém → 404 person_not_found.
# Profissional de saúde; 30 por minuto por usuário; trilha por pessoa.
module TerritoryRegistry
  class PersonLookupsController < BaseController
    # `store:` é avaliado no carregamento; o delegador resolve Rails.cache a
    # cada requisição (o padrão do CareLines::PersonLookupsController).
    module RateLimitStore
      def self.increment(...) = Rails.cache.increment(...)
    end

    rate_limit to: 30, within: 1.minute, only: :create, name: "territory_person_lookup", store: RateLimitStore,
               by: -> { Current.user&.id || request.remote_ip },
               with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

    def create
      return forbid unless Current.user.has_role?("health_professional")
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
      render json: { patient_id: patient&.id, citizen_id: citizen&.id, display_name: (patient || citizen).display_name,
                     registration_id: patient && IndividualRegistration.active_registrations.where(patient_id: patient.id).pick(:id) }
    end
  end
end
