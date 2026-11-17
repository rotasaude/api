# Quem faz o quê na vigilância ambiental (módulo 35a, ADR 0054; contrato §1,
# tabela de acesso). Os papéis valem para a cidade inteira (papel ativo em
# memberships):
#   - coordinator? → endemic_coordinator;
#   - lab? → vector_lab;
#   - reader? → um dos dois, ou municipal_admin (lê os relatórios, não escreve);
#   - field_agent?(user, team) → o agente de combate às endemias (CBO 515140)
#     com papel :field na equipe (HomeVisits::Access: Tabela 7 não ACS, vínculo
#     ativo em equipe ativa 70/76). O escopo de microárea é o da visita
#     (HomeVisits::Access.registers?). Nada muda para o ACS.
module VectorControl
  module Access
    COORDINATOR = "endemic_coordinator".freeze
    LAB = "vector_lab".freeze
    READER_ROLES = [ COORDINATOR, LAB, "municipal_admin" ].freeze

    module_function

    def coordinator?(user) = role?(user, COORDINATOR)

    def lab?(user) = role?(user, LAB)

    def reader?(user) = !user.nil? && user.memberships.active.exists?(role: READER_ROLES)

    def field_agent?(user, team)
      member = HomeVisits::Access.member(user, team)
      HomeVisits::Access.role(member) == :field && member.cbo_code == TerritoryRegistry::Catalog::ENDEMIC_AGENT_CBO
    end

    # Algum vínculo ativo 515140 em equipe ativa 70/76 (as rotas sem equipe).
    def field_agent_somewhere?(user)
      return false unless user&.professional && user.has_role?("health_professional")

      HealthTeamMember.active.joins(:health_team)
                      .where(professional_id: user.professional.id, cbo_code: TerritoryRegistry::Catalog::ENDEMIC_AGENT_CBO,
                             health_teams: { active: true, kind: TerritoryRegistry::Catalog::TEAM_KINDS })
                      .exists?
    end

    # O agente de endemias na microárea (atribuída a ele, escopo de leitura do
    # 24b) → nil. Senão o motivo: agente fora dela → :out_of_scope; outro
    # profissional de campo → :cbo_not_allowed; o resto → :missing_role
    # (ovitrampas, Task 9).
    def agent_refusal(user, micro_area)
      return nil if micro_area && field_agent?(user, micro_area.team) && HomeVisits::Access.reads_micro_area?(user, micro_area)
      return :out_of_scope if field_agent_somewhere?(user)

      HomeVisits::Access.registers_somewhere?(user) ? :cbo_not_allowed : :missing_role
    end

    def role?(user, role) = !user.nil? && user.has_role?(role)
  end
end
