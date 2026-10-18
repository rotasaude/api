# Quem atua no laboratório (ADR 0037; Desvio 2): lab_staff em todo
# laboratório municipal ativo; lab_releaser no laboratório a que está ligado;
# a UBS que coleta (profissional com vínculo ativo em unidade collects_samples).
module Lab
  module Access
    COUNCILS = %w[CRF CRBM CRM].freeze

    module_function

    def labs = ExamProvider.where(uses_municipal_lab: true, active: true).order(:name)
    def staff?(user) = user.has_role?("lab_staff")
    def admin?(user) = user.has_role?("municipal_admin")

    def releaser_link(user, provider_id)
      return nil unless user.has_role?("lab_releaser")

      LabReleaser.active.find_by(user_id: user.id, exam_provider_id: provider_id)
    end

    # RT ou substituto com ligação ativa ao laboratório (ADR 0038 §8: aceitar
    # referência, exceção, revisão, regras, ação corretiva).
    def technical?(user, provider_id)
      return false unless user.has_role?("lab_releaser")

      LabReleaser.active.where(user_id: user.id, exam_provider_id: provider_id).where("technical_lead OR technical_deputy").exists?
    end

    def releaser_provider_ids(user)
      user.has_role?("lab_releaser") ? LabReleaser.active.where(user_id: user.id).pluck(:exam_provider_id) : []
    end

    def provider_ids(user)
      ids = releaser_provider_ids(user)
      staff?(user) ? (labs.pluck(:id) | ids) : ids
    end

    def member?(user, provider_id) = provider_ids(user).include?(provider_id)

    def collecting_unit_ids(user)
      return [] unless user.has_role?("health_professional") && user.professional

      ProfessionalLink.active.joins(:health_unit).where(professional_id: user.professional.id,
                                                        health_units: { collects_samples: true, active: true })
                      .distinct.pluck(:health_unit_id)
    end

    def council(user)
      council = user.professional&.council
      COUNCILS.include?(council) ? council : nil
    end
  end
end
