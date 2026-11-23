# Quem faz o quê no centro de zoonoses (módulo 35b, ADR 0054; contrato §1,
# tabela de acesso, Q12; plano, Desvios 1–2). Os papéis valem para a cidade
# inteira (papel ativo em memberships):
#   - coordinator? → endemic_coordinator (a "Coordenação de vigilância
#     ambiental" do 35a, Q1): campanha, inquérito, parâmetros e relatórios;
#   - team? → zoonoses_team ou a coordenação;
#   - veterinarian? → team? (Q12: a veterinária precisa do papel) e o perfil
#     profissional com CRMV completo (conselho, UF e registro) e vínculo ativo
#     (ProfessionalLink) de CBO 223305 numa unidade environmental_surveillance
#     ativa. Só ela registra eutanásia;
#   - reader? → team? ou municipal_admin (lê os relatórios, não escreve);
#   - field_agent?(user, household) → o ACE (515140) ou o ACS (515105) no
#     escopo da visita do domicílio (HomeVisits::Access.registers? na equipe e
#     na microárea do domicílio), com o CBO do vínculo NA EQUIPE;
#   - collector?(user, household) → o mesmo, só o ACE (a coleta da sorologia).
module Zoonoses
  module Access
    COORDINATOR = VectorControl::Access::COORDINATOR
    TEAM_ROLES = [ Catalog::ROLE, COORDINATOR ].freeze
    READER_ROLES = (TEAM_ROLES + %w[municipal_admin]).freeze
    VETERINARIAN_COUNCIL = "CRMV".freeze
    UNIT_KIND = "environmental_surveillance".freeze

    module_function

    def coordinator?(user) = roles?(user, [ COORDINATOR ])

    def team?(user) = roles?(user, TEAM_ROLES)

    def reader?(user) = roles?(user, READER_ROLES)

    def veterinarian?(user)
      return false unless team?(user)

      professional = user.professional
      return false unless professional&.council == VETERINARIAN_COUNCIL
      return false if professional.council_state.blank? || professional.registration_number.blank?

      ProfessionalLink.active.joins(:health_unit)
                      .where(professional_id: professional.id, cbo_code: Catalog::VETERINARIAN_CBO,
                             health_units: { kind: UNIT_KIND, active: true })
                      .exists?
    end

    def field_agent?(user, household) = field_cbo?(user, household, Catalog::FIELD_CBOS)

    def collector?(user, household) = field_cbo?(user, household, [ TerritoryRegistry::Catalog::ENDEMIC_AGENT_CBO ])

    # -> [uuid] dos usuários ativos com team? (em lote; o encaminhamento
    # automático da Task 9 confere se a UVZ tem quem atenda).
    def team_user_ids
      User.where(deactivated_at: nil).joins(:memberships).merge(Membership.active.where(role: TEAM_ROLES)).distinct.pluck(:id)
    end

    def field_cbo?(user, household, cbos)
      area = household&.micro_area
      return false if user.nil? || area.nil?
      return false unless HomeVisits::Access.registers?(user, area.team, micro_area: area, out_of_area: false) == :ok

      cbos.include?(HomeVisits::Access.member(user, area.team)&.cbo_code)
    end

    def roles?(user, roles) = !user.nil? && user.memberships.active.exists?(role: roles)
    private_class_method :field_cbo?, :roles?
  end
end
