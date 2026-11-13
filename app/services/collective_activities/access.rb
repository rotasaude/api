# Quem faz o quê na atividade coletiva (módulo 24b, ADR 0052; contrato §7):
# registra o membro ativo da equipe (papel health_professional, vínculo sem
# ended_on) cujo CBO do vínculo está na Tabela 5 do LEDI; lê quem registra e o
# enfermeiro/médico da equipe (TerritoryRegistry::Catalog::REGISTRAR_CBO_PREFIXES);
# marca "por engano" só quem registrou.
module CollectiveActivities
  module Access
    module_function

    def registers?(user, team)
      member = TerritoryRegistry::Access.membership(user, team)
      member.present? && Catalog::CBOS.include?(member.cbo_code.to_s)
    end

    # Registra atividade em alguma equipe ativa (as buscas de pessoa do §5,
    # que não têm equipe): vínculo ativo com CBO da Tabela 5.
    def registers_somewhere?(user)
      return false unless user&.professional && user.has_role?("health_professional")

      HealthTeamMember.active.joins(:health_team)
                      .where(professional_id: user.professional.id, cbo_code: Catalog::CBOS.to_a, health_teams: { active: true }).exists?
    end

    def reads?(user, team) = registers?(user, team) || supervises?(user, team)

    # Enfermeiro ou médico da equipe (vínculo ativo): lê a equipe toda e vê o
    # motivo do "por engano" (Q17).
    def supervises?(user, team)
      cbo = TerritoryRegistry::Access.membership(user, team)&.cbo_code.to_s
      cbo.present? && TerritoryRegistry::Catalog::REGISTRAR_CBO_PREFIXES.any? { |prefix| cbo.start_with?(prefix) }
    end

    def marker?(user, activity) = user.present? && activity.recorded_by_user_id == user.id
  end
end
