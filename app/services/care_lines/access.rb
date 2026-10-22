# Quem faz o quê nas linhas de cuidado (ADR 0040; spec §2, decisões do
# coordenador; contrato §3–§6). Painel e contato: health_professional com
# vínculo ativo na unidade da equipe. Confirmar: esse vínculo com CBO de
# médico (225*), da família 2231 ou enfermeiro (2235*) — Catalog::CONFIRM_CBO_PREFIXES.
# Linhas: municipal_admin. Prévia: municipal_admin ou analyst.
module CareLines
  module Access
    module_function

    def admin?(user) = user.has_role?("municipal_admin")
    def preview?(user) = admin?(user) || user.has_role?("analyst")

    def professional_links(user)
      return ProfessionalLink.none unless user.has_role?("health_professional") && user.professional

      user.professional.links.active
    end

    def professional_unit_ids(user) = professional_links(user).distinct.pluck(:health_unit_id)

    def panel?(user, team) = team.present? && professional_unit_ids(user).include?(team.health_unit_id)

    # Unidades onde o usuário confirma inscrição (vínculo ativo com CBO de
    # médico ou enfermeiro, §11 L3): uma consulta, usada pela lista de equipes
    # (can_confirm, §11 T2) e por confirmer?.
    def confirm_unit_ids(user)
      professional_links(user).pluck(:health_unit_id, :cbo_code)
                              .select { |_, cbo| Catalog::CONFIRM_CBO_PREFIXES.any? { |prefix| cbo.start_with?(prefix) } }
                              .map(&:first).uniq
    end

    def confirmer?(user, team) = team.present? && confirm_unit_ids(user).include?(team.health_unit_id)

    # Equipes que aparecem nos filtros: as das unidades do profissional; a
    # gestão (admin, analyst) vê todas as ativas.
    def visible_teams(user)
      scope = HealthTeam.where(active: true).includes(:health_unit).order(:name, :ine)
      preview?(user) ? scope : scope.where(health_unit_id: professional_unit_ids(user))
    end
  end
end
