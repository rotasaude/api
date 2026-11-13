# GET /collective_activities/options (contrato §4, §7; Q13, Q14, Q57): o que o
# formulário e a lista precisam, sem dado de cidadão e sem trilha.
#   teams          as equipes ativas do vínculo de quem lê em que ele lê
#                  atividades (Tabela 5, enfermeiro, médico), com can_register
#                  (Tabela 5 no vínculo da equipe); sem nenhuma → [] (200, como
#                  o /home_visits/context; Q57 b). Cada equipe traz
#                  `professionals`: quem pode entrar em `professionals` de uma
#                  atividade dela (vínculo ativo em qualquer equipe ativa), com
#                  o CBO que o Record grava para ela — o mesmo
#                  Access.professional_memberships (o vínculo na equipe; sem
#                  ele, o mais antigo; Q57 c) —, in_team e has_cns (CNS
#                  válido; o Record recusa o inválido). Membros da equipe
#                  primeiro, depois por nome; sem quem lê (o cabeçalho)
#   units          as unidades ativas (local da atividade), com has_cnes (o
#                  Record recusa a sem CNES)
#   domains        a forma `collective_activity` do YAML da task 1, com as
#                  regras do §4 (o dashboard não as copia à mão)
# O api continua recusando o que as capacidades negam.
module CollectiveActivities
  class OptionsController < BaseController
    def show
      return unless query_only!

      today = Time.zone.today
      render json: { today: today.iso8601, min_date: HomeVisits::Rules.min_date(today).iso8601,
                     teams: readable_teams.map { |team, member| team_json(team, member) }, units: units, domains: Json.domains }
    end

    private

    # [[equipe, vínculo]] (ordem: nome, INE). Um vínculo ativo por equipe
    # (idx_health_team_members_one_active).
    def readable_teams
      professional = Current.user.professional
      return [] unless professional && Current.user.has_role?("health_professional")

      members = HealthTeamMember.active.where(professional: professional).index_by(&:health_team_id)
      HealthTeam.where(id: members.keys, active: true).order(:name, :ine)
                .select { |team| Access.reads?(Current.user, team) }.map { |team| [ team, members.fetch(team.id) ] }
    end

    def team_json(team, member)
      { id: team.id, ine: team.ine, name: team.name, cbo: member.cbo_code, can_register: Access.registers?(Current.user, team),
        professionals: professionals(team) }
    end

    def units
      HealthUnit.where(active: true).order(:name, :id).map { |unit| { id: unit.id, name: unit.name, has_cnes: unit.cnes.present? } }
    end

    def professionals(team)
      Access.professional_memberships(team).except(Current.user.professional.id).values.map do |member|
        professional = member.professional
        { id: professional.id, name: professional.professional_name, cbo: member.cbo_code,
          has_cns: Professionals::Cns.valid?(professional.cns), in_team: member.health_team_id == team.id }
      end.sort_by { |row| [ row[:in_team] ? 0 : 1, row[:name].to_s, row[:id] ] }
    end
  end
end
