# O profissional no faturamento (plano do módulo 22, Desvio 9): CBO pelo
# vínculo ativo mais antigo na unidade (no laboratório, em qualquer unidade:
# o liberador não tem vínculo com o laboratório) e CNS do perfil (módulo 10).
module Billing
  module Staff
    module_function

    def cbo_for(user, establishment)
      return nil unless user

      links = ProfessionalLink.active.joins(:professional).where(professionals: { user_id: user.id })
      links = links.where(health_unit_id: establishment.id) if establishment.type == "health_unit"
      links.order(:started_at, :id).pick(:cbo_code)
    end

    def linked?(user, unit_id)
      ProfessionalLink.active.joins(:professional).where(professionals: { user_id: user.id }, health_unit_id: unit_id).exists?
    end

    def cns(user) = user&.professional&.cns.presence

    # CBOs dos vínculos ativos que valem no estabelecimento (B5).
    def cbos_for(user, establishment)
      links = ProfessionalLink.active.joins(:professional).where(professionals: { user_id: user.id })
      links = links.where(health_unit_id: establishment.id) if establishment.type == "health_unit"
      links.order(:started_at, :id).pluck(:cbo_code).uniq
    end

    # Pode ser o "quem fez" do lançamento manual: vínculo ativo na unidade, ou liberador ativo do laboratório (B5).
    def eligible?(user, establishment)
      return linked?(user, establishment.id) if establishment.type == "health_unit"

      LabReleaser.active.exists?(user_id: user.id, exam_provider_id: establishment.id)
    end

    # Unidades não-APS em que o usuário tem vínculo ativo (busca de paciente, B3).
    def non_aps_units(user)
      HealthUnit.where(active: true).where.not(kind: "ubs")
                .where(id: ProfessionalLink.active.joins(:professional).where(professionals: { user_id: user.id }).select(:health_unit_id))
    end
  end
end
