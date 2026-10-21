# Buscas de apoio do dashboard (B3, B4, B5): paciente pelo CPF (no corpo,
# nunca na URL; trilha com ids), estabelecimentos faturantes (unidade
# não-APS ativa e laboratório municipal ativo) e profissionais do
# estabelecimento (vínculos ativos; liberadores no laboratório).
module Billing
  class LookupsController < BaseController
    def patient
      allowed = Access.clerk?(Current.user) ||
                (Current.user.has_role?("health_professional") && Staff.non_aps_units(Current.user).any?)
      return forbid unless allowed

      cpf = params[:cpf].is_a?(String) ? CitizenIdentity::Cpf.normalize(params[:cpf]) : nil
      return render_error(:invalid_cpf) unless cpf

      found = Patient.find_by(cpf: cpf)
      return render_error(:patient_not_found, :not_found) unless found

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
