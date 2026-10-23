# Busca de pessoa pelo CPF para a inscrição manual (contrato §11 T3, §12 P1;
# padrão do patient_lookup do 21a/22: CPF só no corpo, 30 por minuto por
# usuário, par só declarado → 409). Diferente do 21a/22, NÃO chama
# Patients::Resolve: buscar não cria paciente — ele nasce na inscrição.
# Trilha: um clinical_record.viewed (access care_line) para a pessoa mostrada (L7).
module CareLines
  class PersonLookupsController < BaseController
    # `store:` é avaliado no carregamento da classe; o delegador resolve
    # Rails.cache a cada requisição (mesmo padrão do Billing::LookupsController).
    module RateLimitStore
      def self.increment(...) = Rails.cache.increment(...)
    end

    rate_limit to: 30, within: 1.minute, only: :create, name: "care_line_person_lookup", store: RateLimitStore,
               by: -> { Current.user&.id || request.remote_ip },
               with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

    def create
      return forbid unless Access.professional_unit_ids(Current.user).any?

      raw = body_param("cpf")
      cpf = raw.is_a?(String) ? CitizenIdentity::Cpf.normalize(raw) : nil
      return render_error(:invalid_cpf) unless cpf

      pairs = Citizen.not_erased.where(cpf: cpf)
      citizen = pairs.verification_level_verified.order(:created_at, :id).first
      unless citizen
        return render_error(:citizen_not_verified, :conflict) if pairs.exists?

        return render_error(:person_not_found, :not_found)
      end
      patient = citizen.patient_id && Patient.find_by(id: citizen.patient_id)
      Trail.viewed!(user: Current.user, patient_id: patient&.id, citizen_id: citizen.id)
      render json: { person: Json.lookup(patient: patient, citizen: citizen) }
    end
  end
end
