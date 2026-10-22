# Equipe de cada pessoa e população de uma equipe (ADR 0040; spec §2
# decisões 8 e 9; plano, Desvio 5). Inscrito → equipe da inscrição;
# paciente → equipe ativa do profissional da consulta finalizada mais
# recente (24 meses), na unidade do vínculo; par validado sem paciente → a
# única equipe ativa das unidades de referência do bairro.
module CareLines
  module TeamPopulation
    LOOKBACK = 24.months

    module_function

    # `involving_team:` pré-filtra os pacientes que tiveram consulta finalizada
    # (24 meses) de membro ativo daquela equipe, na unidade dela: quem é da
    # equipe só pode estar aí. O filtro só escolhe QUEM entra; a equipe de cada
    # um segue sendo a da consulta mais recente (o resultado não muda).
    def patient_teams(patient_ids = nil, involving_team: nil)
      return {} if patient_ids&.empty?

      filter = patient_ids ? ApplicationRecord.sanitize_sql([ "AND c.patient_id IN (?)", patient_ids ]) : ""
      filter += involving(involving_team) if involving_team
      # A equipe vem da consulta finalizada mais recente cujo profissional tem
      # equipe ativa na unidade do vínculo: o plantonista sem equipe (o JOIN o
      # descarta) não tira a pessoa da equipe dela.
      sql = ApplicationRecord.sanitize_sql([ <<~SQL, LOOKBACK.ago ])
        SELECT DISTINCT ON (c.patient_id) c.patient_id, ht.id
          FROM consultations c
          JOIN professional_links pl ON pl.id = c.professional_link_id
          JOIN health_team_members m ON m.professional_id = pl.professional_id AND m.ended_on IS NULL
          JOIN health_teams ht ON ht.id = m.health_team_id AND ht.active AND ht.health_unit_id = pl.health_unit_id
         WHERE c.status = 'finalized' AND c.finalized_at >= ? #{filter}
         ORDER BY c.patient_id, c.finalized_at DESC, ht.ine
      SQL
      ApplicationRecord.connection.select_rows(sql).to_h
    end

    def involving(team)
      ApplicationRecord.sanitize_sql([ <<~SQL, team.id, team.health_unit_id, LOOKBACK.ago ])
        AND c.patient_id IN (
          SELECT tc.patient_id
            FROM consultations tc
            JOIN professional_links tpl ON tpl.id = tc.professional_link_id
            JOIN health_team_members tm ON tm.professional_id = tpl.professional_id AND tm.ended_on IS NULL AND tm.health_team_id = ?
           WHERE tc.status = 'finalized' AND tpl.health_unit_id = ? AND tc.finalized_at >= ?)
      SQL
    end
    private_class_method :involving

    def citizen_teams(citizens)
      units = Territory::ReferenceUnits.ids_by_neighborhood(citizens.map(&:neighborhood_id))
      teams = HealthTeam.where(active: true, health_unit_id: units.values.flatten.uniq).pluck(:id, :health_unit_id)
      citizens.each_with_object({}) do |citizen, out|
        unit_ids = units.fetch(citizen.neighborhood_id, [])
        candidates = teams.select { |_, unit_id| unit_ids.include?(unit_id) }.map(&:first)
        out[citizen.id] = candidates.first if candidates.size == 1
      end
    end

    # Pessoas da equipe, elegíveis para o denominador das regras, com a
    # inscrição ativa delas na linha (ou nil). A inscrita é avaliada com a DUM
    # decifrada (Eligibility: o excludente só vale na gestação da DUM).
    def call(team:, line:, rules:, on: Time.zone.today)
      enrolled = line ? CareLineEnrollment.active_enrollments.where(care_line: line).to_a.index_by(&:patient_id) : {}
      patient_ids = enrolled.select { |_, e| e.team_id == team.id }.keys
      patient_ids += patient_teams(involving_team: team).select { |id, team_id| team_id == team.id && !enrolled.key?(id) }.keys
      # Regra por problema: só quem tem problema ativo casando entra no denominador.
      patient_ids &= Facts.problem_candidates(rules["problems"]) if rules["problems"]
      neighborhoods = NeighborhoodCoverage.where(health_unit_id: team.health_unit_id).pluck(:neighborhood_id)
      candidates = Citizen.not_erased.verification_level_verified.where(patient_id: nil, neighborhood_id: neighborhoods).to_a
      citizen_ids = citizen_teams(candidates).select { |_, team_id| team_id == team.id }.keys

      people = Facts.patients(patient_ids).values + Facts.citizens(citizen_ids).values
      people.select { |person| Eligibility.denominator?(rules, person, on: on, lmp: enrolled[person.patient_id]&.anchor_on) }
            .map { |person| [ person.with(team_id: team.id), person.patient_id && enrolled[person.patient_id] ] }
    end
  end
end
