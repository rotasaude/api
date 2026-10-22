# Buscas de apoio do dashboard (B3, B4, B5): paciente pelo CPF (no corpo,
# nunca na URL; trilha com ids), estabelecimentos faturantes (unidade
# não-APS ativa e laboratório municipal ativo) e profissionais do
# estabelecimento (vínculos ativos; liberadores no laboratório).
module Billing
  class LookupsController < BaseController
    # Mesmo limite do patient_lookup de exames (`store:` resolve Rails.cache a cada requisição).
    module RateLimitStore
      def self.increment(...) = Rails.cache.increment(...)
    end

    rate_limit to: 30, within: 1.minute, only: :patient, name: "billing_patient_lookup", store: RateLimitStore,
               by: -> { Current.user&.id || request.remote_ip },
               with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

    def patient
      allowed = Access.clerk?(Current.user) ||
                (Current.user.has_role?("health_professional") && Staff.non_aps_units(Current.user).any?)
      return forbid unless allowed

      cpf = params[:cpf].is_a?(String) ? CitizenIdentity::Cpf.normalize(params[:cpf]) : nil
      return render_error(:invalid_cpf) unless cpf

      pairs = Citizen.not_erased.where(cpf: cpf)
      citizen = pairs.verification_level_verified.order(:created_at, :id).first
      unless citizen
        return render_error(:citizen_not_verified, :conflict) if pairs.exists?

        return render_error(:patient_not_found, :not_found)
      end
      resolved = Patients::Resolve.call(citizen)
      return render_error(:citizen_not_verified, :conflict) if resolved.failure?

      found = resolved.payload[:patient]

      DomainEvents.publish("billing_patient.looked_up", patient_id: found.id, user_id: Current.user.id)
      render json: { patient: { id: found.id, display_name: found.display_name, cpf_masked: found.cpf_masked } }
    end

    def establishments
      return forbid unless Access.reader?(Current.user)

      units = HealthUnit.where(active: true).where.not(kind: "ubs").order(:name).map { |unit| Establishment.for_unit(unit).json }
      labs = ExamProvider.where(uses_municipal_lab: true, active: true).order(:name).map { |lab| Establishment.for_lab(lab).json }
      render json: { establishments: units + labs }
    end

    def professionals
      return forbid unless Access.clerk?(Current.user)

      establishment = Establishment.find(params[:establishment_type], params[:establishment_id])
      return invalid_establishment unless establishment

      users = if establishment.type == "health_unit"
                User.where(id: Professional.joins(:links).merge(ProfessionalLink.active.where(health_unit_id: establishment.id)).select(:user_id))
              else
                User.where(id: LabReleaser.active.where(exam_provider_id: establishment.id).select(:user_id))
              end
      rows = users.includes(:professional).select(&:professional).sort_by { |user| user.professional.professional_name }
      render json: { professionals: rows.map { |user| { user_id: user.id, name: user.professional.professional_name,
                                                        cbo_codes: Staff.cbos_for(user, establishment) } } }
    end
  end
end
