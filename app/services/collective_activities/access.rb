# Quem faz o quê na atividade coletiva (módulo 24b, ADR 0052; contrato §7):
# registra o membro ativo da equipe ativa (papel health_professional, vínculo sem
# ended_on) cujo CBO do vínculo está na Tabela 5 do LEDI; lê quem registra e o
# enfermeiro/médico da equipe (TerritoryRegistry::Catalog::REGISTRAR_CBO_PREFIXES);
# marca "por engano" só quem registrou.
module CollectiveActivities
  module Access
    module_function

    # Equipe ativa (como o HomeVisits::Access.member; revisão final A-M4): a
    # ficha 6 nunca sai com o INE de uma equipe desativada.
    def registers?(user, team) = team&.active == true && table5_member?(user, team)

    # Vínculo ativo na equipe com CBO da Tabela 5, com a equipe ativa ou não
    # (a leitura do histórico de uma equipe desativada segue a de antes).
    def table5_member?(user, team)
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

    def reads?(user, team) = table5_member?(user, team) || supervises?(user, team)

    # Enfermeiro ou médico da equipe (vínculo ativo): lê a equipe toda e vê o
    # motivo do "por engano" (Q17).
    def supervises?(user, team)
      cbo = TerritoryRegistry::Access.membership(user, team)&.cbo_code.to_s
      cbo.present? && TerritoryRegistry::Catalog::REGISTRAR_CBO_PREFIXES.any? { |prefix| cbo.start_with?(prefix) }
    end

    # Q57: o vínculo que dá o CBO de cada profissional numa atividade da
    # equipe `team` — a regra única do Record e das opções: vínculo ativo em
    # equipe ativa; o da própria equipe primeiro; sem ele, o mais antigo
    # (created_at, id). Sem empate na equipe: um vínculo ativo por
    # (profissional, equipe) (idx_health_team_members_one_active).
    # -> { professional_id => HealthTeamMember (com :professional) }
    def professional_memberships(team, professional_ids: nil)
      scope = HealthTeamMember.active.joins(:health_team).where(health_teams: { active: true }).includes(:professional)
      scope = scope.where(professional_id: professional_ids) unless professional_ids.nil?
      scope.order(Arel.sql(HealthTeamMember.sanitize_sql_array([ "health_team_members.health_team_id = ? DESC", team.id ])),
                  :created_at, :id)
           .each_with_object({}) { |member, found| found[member.professional_id] ||= member }
    end

    def marker?(user, activity) = user.present? && activity.recorded_by_user_id == user.id
  end
end
