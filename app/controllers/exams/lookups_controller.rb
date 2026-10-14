# Rotas de apoio das telas (pedido do dashboard D2–D5): achar o paciente pelo
# CPF (no corpo, nunca na URL), o catálogo legível, os prestadores de um
# exame e os solicitantes de uma unidade.
#
# O patient_lookup MANTÉM Patients::Resolve (plano, Desvio 3; idempotente, o
# mesmo caminho da guia): para um par validado sem paciente, cria/liga o
# Patient (eventos patient.created/patient.linked). Par declarado ou CPF
# desconhecido não criam nada.
module Exams
  class LookupsController < BaseController
    LOOKUP_ROLES = %w[citizen_verifier health_professional municipal_admin].freeze
    STAFF_ROLES = %w[citizen_verifier health_professional municipal_admin exam_regulator].freeze

    # `store:` de `rate_limit` é avaliado no carregamento da classe; o
    # delegador resolve Rails.cache a cada requisição (mesmo padrão do MfaController).
    module RateLimitStore
      def self.increment(...) = Rails.cache.increment(...)
    end

    rate_limit to: 30, within: 1.minute, only: :patient, name: "exam_patient_lookup", store: RateLimitStore,
               by: -> { Current.user&.id || request.remote_ip },
               with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

    def patient
      return forbid("missing_role") unless LOOKUP_ROLES.any? { |role| Current.user.has_role?(role) }

      digits = params[:cpf].is_a?(String) ? CitizenIdentity::Cpf.normalize(params[:cpf]) : nil
      pairs = digits ? Citizen.not_erased.where(cpf: digits) : Citizen.none
      citizen = pairs.verification_level_verified.order(:created_at, :id).first
      unless citizen
        status, error = pairs.exists? ? [ :conflict, "citizen_not_verified" ] : [ :not_found, "patient_not_found" ]
        return render(json: { error: error }, status: status)
      end
      resolved = Patients::Resolve.call(citizen)
      return render(json: { error: "citizen_not_verified" }, status: :conflict) if resolved.failure?

      patient = resolved.payload[:patient]
      DomainEvents.publish("exam.patient_looked_up", patient_id: patient.id, user_id: Current.user.id)
      render json: { patient: { id: patient.id, display_name: patient.display_name, cpf_masked: patient.cpf_masked } }
    end

    def catalog
      allowed = STAFF_ROLES.any? { |role| Current.user.has_role?(role) } || Exams::Access.provider_of(Current.user)
      return forbid("missing_role") unless allowed

      items = ExamCatalogItem.where(active: true).order(:sigtap_code).map do |item|
        { sigtap_code: item.sigtap_code, label: Exams::AdminJson.label(item.sigtap_code), result_fields: item.result_fields }
      end
      render json: { items: items }
    end

    def providers
      return forbid("missing_role") unless STAFF_ROLES.any? { |role| Current.user.has_role?(role) }

      scope = ExamProvider.where(active: true).order(:name)
      # A34: o laboratório simulado só é oferecido com fake_lab utilizável.
      scope = scope.where(simulated: false) unless Exams::Gate.fake_lab_usable?(Current.city)
      if params[:sigtap_code].present?
        item = ExamCatalogItem.find_by(sigtap_code: params[:sigtap_code].to_s)
        scope = scope.where(id: ExamProviderItem.where(exam_catalog_item_id: item.id).select(:exam_provider_id)) if item
      end
      render json: { providers: scope.map { |p| { id: p.id, name: p.name } } }
    end

    def requesters
      unit_id = params[:unit_id]
      return not_found unless uuid?(unit_id) && HealthUnit.exists?(id: unit_id)
      return forbid("not_unit_staff") unless Exams::Access.unit_staff?(Current.user, unit_id) || Exams::Access.regulator?(Current.user)

      users = User.where(deactivated_at: nil)
                  .where(id: Membership.active.where(role: "health_professional").select(:user_id))
                  .where(id: Professional.joins(:links).merge(ProfessionalLink.active.where(health_unit_id: unit_id)).select(:user_id))
                  .includes(:professional).to_a
      render json: { requesters: users.map { |u| { user_id: u.id, name: Screenings::Json.staff_name(u) } }.sort_by { |r| r[:name].to_s } }
    end
  end
end
