# Quem faz o quê na visita domiciliar (módulo 24b, ADR 0052; contrato §1,
# tabela "Acesso à visita"; 6A; ruling A3). Sempre papel health_professional e
# vínculo ativo (HealthTeamMember, sem ended_on) em equipe ativa 70/76; o papel
# sai do CBO do vínculo NA EQUIPE:
#   - :acs (515105) → registra na microárea em que é o responsável e fora de
#     área; lê as suas;
#   - :field (outro CBO da Tabela 7) → registra e lê só nas microáreas
#     atribuídas a ele (micro_area_field_assignments ativas); nunca fora de área;
#   - :reader (enfermeiro/médico, TerritoryRegistry::Catalog::REGISTRAR_CBO_PREFIXES)
#     → lê a equipe toda, não registra (cbo_not_allowed); o enfermeiro atribui.
# O ACS nunca é atribuído (A3): o escopo tem um tipo só por equipe.
# TerritoryRegistry::Access.role é privado: o papel é refeito aqui pelo Catalog.
module HomeVisits
  module Access
    NURSE_PREFIX = "2235".freeze
    SCOPE_KINDS = { acs: "responsible", field: "assigned", reader: "team" }.freeze

    module_function

    # Vínculo ativo na equipe ativa 70/76 (TerritoryRegistry::Access.membership
    # já exige perfil, papel health_professional e vínculo sem ended_on).
    def member(user, team)
      return nil unless team&.active && TerritoryRegistry::Catalog::TEAM_KINDS.include?(team.kind)

      TerritoryRegistry::Access.membership(user, team)
    end

    def role(member)
      cbo = member&.cbo_code.to_s
      return nil if cbo.empty?
      return :acs if cbo == Catalog::ACS_CBO
      return :field if Catalog::HOME_VISIT_CBOS.include?(cbo)

      :reader if TerritoryRegistry::Catalog::REGISTRAR_CBO_PREFIXES.any? { |prefix| cbo.start_with?(prefix) }
    end

    # { micro_area_ids:, kind: } — as microáreas da equipe (ativas ou não; a
    # inativa é recusada pela regra da visita, não pelo escopo) que o usuário
    # alcança, e por quê. Sem papel: { micro_area_ids: [], kind: nil }.
    def scope(user, team)
      member = member(user, team)
      kind = role(member)
      areas = MicroArea.where(team_id: team&.id)
      ids = case kind
            when :acs then areas.where(acs_professional_id: member.professional_id).order(:code).pluck(:id)
            when :field
              assigned = MicroAreaFieldAssignment.active.where(professional_id: member.professional_id).select(:micro_area_id)
              areas.where(id: assigned).order(:code).pluck(:id)
            when :reader then areas.order(:code).pluck(:id)
            else []
            end
      { micro_area_ids: ids, kind: SCOPE_KINDS[kind] }
    end

    # :ok | :out_of_scope | :cbo_not_allowed. Fora da equipe → out_of_scope;
    # enfermeiro/médico ou CBO fora da Tabela 7 → cbo_not_allowed; fora de
    # área (micro_area nil ou out_of_area) só o ACS.
    def registers?(user, team, micro_area:, out_of_area:)
      member = member(user, team)
      return :out_of_scope unless member

      kind = role(member)
      return :cbo_not_allowed unless %i[acs field].include?(kind)
      return(kind == :acs ? :ok : :out_of_scope) if out_of_area || micro_area.nil?
      return :out_of_scope unless micro_area.team_id == team.id

      scope(user, team)[:micro_area_ids].include?(micro_area.id) ? :ok : :out_of_scope
    end

    def reads_micro_area?(user, micro_area)
      return false unless micro_area

      scope(user, micro_area.team)[:micro_area_ids].include?(micro_area.id)
    end

    # Lê a equipe toda (visitas, folhas e "quem visitar" de qualquer microárea).
    def reads_team?(user, team) = role(member(user, team)) == :reader

    # Atribui e encerra microárea na equipe: o enfermeiro (2235*) dela.
    def assigner?(user, team) = member(user, team)&.cbo_code.to_s.start_with?(NURSE_PREFIX) == true

    # Registra visita em alguma equipe (as buscas de pessoa do §5, que não têm
    # equipe): o mesmo vínculo do aparelho (Tabela 7 em equipe ativa 70/76).
    def registers_somewhere?(user) = device_owner?(user).present?

    # Cadastra aparelho de campo: Tabela 7 com vínculo ativo em equipe ativa
    # 70/76 → esse vínculo (o mais antigo, se houver mais de um); senão nil.
    # Usuário inativo fica para quem chama (o aparelho distingue user_disabled).
    def device_owner?(user)
      return nil unless user&.professional && user.has_role?("health_professional")

      HealthTeamMember.active.joins(:health_team)
                      .where(professional_id: user.professional.id, cbo_code: Catalog::HOME_VISIT_CBOS.to_a,
                             health_teams: { active: true, kind: TerritoryRegistry::Catalog::TEAM_KINDS })
                      .order(:started_on, :id).first
    end
  end
end
