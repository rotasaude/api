# Quem lê o exame (ADR 0036; spec §7; Desvios 9 e 10). Clínica: o
# solicitante (com health_professional), a leitura do 19a sobre o paciente
# (em contexto ou abertura justificada) e, com o exame escalado, a equipe
# da unidade do exame. Administrativa: a unidade (recepção ou profissional
# com vínculo nela) e o regulador. Prestador só pelo portal.
module Exams
  module Access
    Grant = Data.define(:view, :kind, :opening)
    NURSE_PREFIX = "2235".freeze

    module_function

    def for_order(user:, order:)
      professional = user.has_role?("health_professional")
      return Grant.new(view: :clinical, kind: :author, opening: nil) if professional && order.requester_user_id == user.id

      if professional
        grant = ClinicalRecord::Access.call(user: user, patient: order.patient)
        return Grant.new(view: :clinical, kind: grant.kind, opening: grant.opening) if grant.allowed?
        return Grant.new(view: :clinical, kind: :team, opening: nil) if order.escalated? && team_member?(user, order.unit_id)
      end
      return Grant.new(view: :administrative, kind: :unit, opening: nil) if unit_staff?(user, order.unit_id)
      return Grant.new(view: :administrative, kind: :regulator, opening: nil) if regulator?(user)

      nil
    end

    def unit_staff?(user, unit_id)
      return true if user.has_role?("citizen_verifier")

      user.has_role?("health_professional") &&
        ProfessionalLink.active.joins(:professional).where(professionals: { user_id: user.id }, health_unit_id: unit_id).exists?
    end

    # A42: quem lê o detalhe como regulador (exam_regulator) recebe o CID; o
    # municipal_admin só o recebe pela fila de regulação.
    def cid10_reader?(user, grant) = grant&.kind == :regulator && user.has_role?("exam_regulator")

    def regulator?(user) = user.has_role?("exam_regulator") || user.has_role?("municipal_admin")

    def team_member?(user, unit_id) = team_unit_ids(user).include?(unit_id)

    def team_unit_ids(user)
      return [] unless user.has_role?("health_professional") && user.professional

      HealthTeamMember.active.joins(:health_team)
                      .where(professional_id: user.professional.id, health_teams: { active: true })
                      .pluck(:cbo_code, "health_teams.health_unit_id")
                      .select { |cbo, _| clinician?(cbo) }.map(&:last).uniq
    end

    def clinician?(cbo) = Ledi::ConsultationMapping.cid10_allowed?(cbo) || cbo.to_s.start_with?(NURSE_PREFIX)

    def provider_of(user)
      return nil unless user.has_role?("exam_provider")

      provider = ExamProviderUser.find_by(user_id: user.id)&.exam_provider
      provider if provider&.active
    end
  end
end
