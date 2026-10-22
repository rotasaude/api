# Equipe de cada pessoa e população de uma equipe (ADR 0040; spec §2
# decisões 8 e 9; plano, Desvio 5). Inscrito → equipe da inscrição;
# paciente → equipe ativa do profissional da consulta finalizada mais
# recente (24 meses), na unidade do vínculo; par validado sem paciente → a
# única equipe ativa das unidades de referência do bairro.
module CareLines
  module TeamPopulation
    LOOKBACK = 24.months

    module_function

    def patient_teams(patient_ids = nil)
      return {} if patient_ids&.empty?

      filter = patient_ids ? ApplicationRecord.sanitize_sql([ "AND c.patient_id IN (?)", patient_ids ]) : ""
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
    # inscrição ativa delas na linha (ou nil).
    def call(team:, line:, rules:, on: Time.zone.today)
      enrolled = line ? CareLineEnrollment.active_enrollments.where(care_line: line).to_a.index_by(&:patient_id) : {}
      patient_ids = enrolled.select { |_, e| e.team_id == team.id }.keys
      patient_ids += patient_teams.select { |id, team_id| team_id == team.id && !enrolled.key?(id) }.keys
      # Regra por problema: só quem tem problema ativo casando entra no denominador.
      patient_ids &= Facts.problem_candidates(rules["problems"]) if rules["problems"]
      neighborhoods = NeighborhoodCoverage.where(health_unit_id: team.health_unit_id).pluck(:neighborhood_id)
      candidates = Citizen.not_erased.verification_level_verified.where(patient_id: nil, neighborhood_id: neighborhoods).to_a
      citizen_ids = citizen_teams(candidates).select { |_, team_id| team_id == team.id }.keys

      people = Facts.patients(patient_ids).values + Facts.citizens(citizen_ids).values
      people.select { |person| Eligibility.denominator?(rules, person, on: on) }
            .map { |person| [ person.with(team_id: team.id), person.patient_id && enrolled[person.patient_id] ] }
    end
  end
end
