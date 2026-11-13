# GET /collective_activities/options (contrato §4, §7; Q13, Q14): o que o
# formulário e a lista precisam, sem dado de cidadão e sem trilha.
#   teams          as equipes ativas do vínculo de quem lê em que ele lê
#                  atividades (Tabela 5, enfermeiro, médico), com can_register
#                  (Tabela 5 no vínculo da equipe)
#   units          as unidades ativas (local da atividade), com has_cnes (o
#                  Record recusa a sem CNES)
#   professionals  quem pode entrar em `professionals`: vínculo ativo em
#                  qualquer equipe ativa (o CBO do primeiro vínculo, os
#                  team_ids de todos), has_cns = CNS válido (o Record recusa o
#                  inválido); sem quem lê, que é o cabeçalho da ficha
#   domains        a forma `collective_activity` do YAML da task 1, com as
#                  regras do §4 (o dashboard não as copia à mão)
# Sem equipe em que leia → 403 cbo_not_allowed. O api continua recusando o que
# as capacidades negam.
module CollectiveActivities
  class OptionsController < BaseController
    def show
      return unless query_only!

      teams = readable_teams
      return render_refusal("cbo_not_allowed") if teams.empty?

      today = Time.zone.today
      render json: { today: today.iso8601, min_date: HomeVisits::Rules.min_date(today).iso8601,
                     teams: teams.map { |team, member| team_json(team, member) }, units: units, professionals: professionals,
                     domains: Json.domains }
    end

    private

    # [[equipe, vínculo]] (ordem: nome, INE).
    def readable_teams
      professional = Current.user.professional
      return [] unless professional && Current.user.has_role?("health_professional")

      members = HealthTeamMember.active.where(professional: professional).index_by(&:health_team_id)
      HealthTeam.where(id: members.keys, active: true).order(:name, :ine)
                .select { |team| Access.reads?(Current.user, team) }.map { |team| [ team, members.fetch(team.id) ] }
    end

    def team_json(team, member)
      { id: team.id, ine: team.ine, name: team.name, cbo: member.cbo_code, can_register: Access.registers?(Current.user, team) }
    end

    def units
      HealthUnit.where(active: true).order(:name, :id).map { |unit| { id: unit.id, name: unit.name, has_cnes: unit.cnes.present? } }
    end

    def professionals
      members = HealthTeamMember.active.joins(:health_team).where(health_teams: { active: true })
                                .where.not(professional_id: Current.user.professional.id)
                                .includes(:professional).order(:created_at, :id).group_by(&:professional_id)
      members.values.map do |rows|
        professional = rows.first.professional
        { id: professional.id, name: professional.professional_name, cbo: rows.first.cbo_code,
          has_cns: Professionals::Cns.valid?(professional.cns), team_ids: rows.map(&:health_team_id).uniq }
      end.sort_by { |row| [ row[:name].to_s, row[:id] ] }
    end
  end
end
