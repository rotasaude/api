# Equipe de cada pessoa e população de uma equipe (ADR 0040; spec §2
# decisões 8 e 9; plano, Desvio 5). Inscrito → equipe da inscrição;
# paciente → equipe ativa do profissional da consulta finalizada mais
# recente (24 meses), na unidade do vínculo; par validado sem paciente → a
# única equipe ativa das unidades de referência do bairro. P18 (contrato
# §12): o paciente cuja consulta finalizada nos 24 meses NÃO dá equipe
# (nenhuma, ou só com plantonista sem equipe) segue a regra do par sem
# paciente, pelo bairro do par validado mais antigo dele.
module CareLines
  module TeamPopulation
    LOOKBACK = 24.months
    # Consultas finalizadas no corte (bind: o corte) cujo profissional tem
    # equipe ativa na unidade do vínculo: a mesma cadeia dá a equipe da
    # consulta e decide quem segue o território.
    TEAMED_CONSULTATIONS = <<~SQL.freeze
      FROM consultations c
      JOIN professional_links pl ON pl.id = c.professional_link_id
      JOIN health_team_members m ON m.professional_id = pl.professional_id AND m.ended_on IS NULL
      JOIN health_teams ht ON ht.id = m.health_team_id AND ht.active AND ht.health_unit_id = pl.health_unit_id
     WHERE c.status = 'finalized' AND c.finalized_at >= ?
    SQL

    module_function

    # `involving_team:` pré-filtra os pacientes que tiveram consulta finalizada
    # (24 meses) de membro ativo daquela equipe, na unidade dela, e os sem
    # equipe pela consulta (P18) cujo par validado mais antigo mora num bairro
    # coberto pela unidade dela: quem é da equipe só pode estar aí. O filtro só
    # escolhe QUEM entra; a equipe de cada um não muda.
    def patient_teams(patient_ids = nil, involving_team: nil)
      return {} if patient_ids && patient_ids.empty?

      filter = patient_ids ? ApplicationRecord.sanitize_sql([ "AND c.patient_id IN (?)", patient_ids ]) : ""
      cutoff = LOOKBACK.ago
      territorial = territory_neighborhoods(patient_ids, involving_team, cutoff)
      filter += involving(involving_team, cutoff) if involving_team
      # A equipe vem da consulta finalizada mais recente cujo profissional tem
      # equipe ativa na unidade do vínculo: o plantonista sem equipe (o JOIN o
      # descarta) não tira a pessoa da equipe dela.
      sql = ApplicationRecord.sanitize_sql([ <<~SQL, cutoff ])
        SELECT DISTINCT ON (c.patient_id) c.patient_id, ht.id
        #{TEAMED_CONSULTATIONS} #{filter}
         ORDER BY c.patient_id, c.finalized_at DESC, ht.ine
      SQL
      # Os do território não têm consulta que dê equipe no corte (mesma cadeia,
      # mesmo corte): nunca colidem com as chaves da consulta.
      ApplicationRecord.connection.select_rows(sql).to_h.merge(territory_teams(territorial))
    end

    # P18: paciente sem consulta finalizada no corte que dê equipe (nenhuma
    # consulta, ou só com plantonista sem equipe, membro desligado, equipe
    # inativa ou de outra unidade) → bairro do par validado mais antigo
    # (created_at, id), como no "Agendar". Bairro nulo ou sem par validado →
    # sem equipe (territory_teams descarta). Não depende do `involving`: quem
    # tem equipe pela consulta, de qualquer equipe, nunca entra aqui.
    #
    # Com equipe, o semi-join por bairro coberto entra ANTES do DISTINCT ON
    # (revisão final, I3): só os pacientes com ALGUM par validado num bairro
    # coberto pela unidade são ordenados, em vez de todos os pares da cidade.
    # Não muda qual par é o mais antigo (o DISTINCT ON segue vendo todos os
    # pares do paciente); o filtro de fora confere o bairro DESSE par.
    def territory_neighborhoods(patient_ids, team, cutoff)
      pairs = patient_ids ? ApplicationRecord.sanitize_sql([ "AND ci.patient_id IN (?)", patient_ids ]) : ""
      covered_ids = "SELECT nc.neighborhood_id FROM neighborhood_coverages nc WHERE nc.health_unit_id = ?"
      covered = team ? ApplicationRecord.sanitize_sql([ "AND p.neighborhood_id IN (#{covered_ids})", team.health_unit_id ]) : ""
      near = team ? ApplicationRecord.sanitize_sql([ <<~SQL, team.health_unit_id ]) : ""
        AND ci.patient_id IN (SELECT cc.patient_id FROM citizens cc
                               WHERE cc.patient_id IS NOT NULL AND cc.erased_at IS NULL AND cc.verification_level = 'verified'
                                 AND cc.neighborhood_id IN (#{covered_ids}))
      SQL
      sql = ApplicationRecord.sanitize_sql([ <<~SQL, cutoff ])
        SELECT p.patient_id, p.neighborhood_id
          FROM (SELECT DISTINCT ON (ci.patient_id) ci.patient_id, ci.neighborhood_id
                  FROM citizens ci
                 WHERE ci.patient_id IS NOT NULL AND ci.erased_at IS NULL AND ci.verification_level = 'verified' #{pairs} #{near}
                 ORDER BY ci.patient_id, ci.created_at, ci.id) p
         WHERE NOT EXISTS (SELECT 1 #{TEAMED_CONSULTATIONS} AND c.patient_id = p.patient_id)
               #{covered}
      SQL
      ApplicationRecord.connection.select_rows(sql).to_h
    end
    private_class_method :territory_neighborhoods

    def involving(team, cutoff)
      ApplicationRecord.sanitize_sql([ <<~SQL, team.id, team.health_unit_id, cutoff ])
        AND c.patient_id IN (
          SELECT tc.patient_id
            FROM consultations tc
            JOIN professional_links tpl ON tpl.id = tc.professional_link_id
            JOIN health_team_members tm ON tm.professional_id = tpl.professional_id AND tm.ended_on IS NULL AND tm.health_team_id = ?
           WHERE tc.status = 'finalized' AND tpl.health_unit_id = ? AND tc.finalized_at >= ?)
      SQL
    end
    private_class_method :involving

    def citizen_teams(citizens) = territory_teams(citizens.to_h { |citizen| [ citizen.id, citizen.neighborhood_id ] })

    # { id => bairro } → { id => a única equipe ativa das unidades de
    # referência do bairro }; zero ou mais de uma (ou bairro nulo) → fora.
    def territory_teams(neighborhood_by_id)
      return {} if neighborhood_by_id.empty?

      units = Territory::ReferenceUnits.ids_by_neighborhood(neighborhood_by_id.values)
      teams = HealthTeam.where(active: true, health_unit_id: units.values.flatten.uniq).pluck(:id, :health_unit_id)
      neighborhood_by_id.each_with_object({}) do |(id, neighborhood_id), out|
        unit_ids = units.fetch(neighborhood_id, [])
        candidates = teams.select { |_, unit_id| unit_ids.include?(unit_id) }.map(&:first)
        out[id] = candidates.first if candidates.size == 1
      end
    end
    private_class_method :territory_teams

    # Pessoas da equipe, elegíveis para o denominador das regras, com a
    # inscrição ativa delas na linha (ou nil). A inscrita é avaliada com a DUM
    # decifrada (Eligibility: o excludente só vale na gestação da DUM).
    # Revisão final (I3): só as inscrições DA EQUIPE viram objeto (a DUM); das
    # outras equipes, só os ids, restritos aos candidatos da equipe (a
    # inscrição em outra equipe tira a pessoa daqui); o filtro por problema
    # cruza com os ids no SQL.
    def call(team:, line:, rules:, on: Time.zone.today)
      enrolled = line ? CareLineEnrollment.active_enrollments.where(care_line: line, team_id: team.id).to_a.index_by(&:patient_id) : {}
      prospects = patient_teams(involving_team: team).select { |id, team_id| team_id == team.id && !enrolled.key?(id) }.keys
      if line
        elsewhere = CareLineEnrollment.active_enrollments.where(care_line: line, patient_id: prospects).pluck(:patient_id, :team_id)
        prospects -= elsewhere.map(&:first)
      end
      patient_ids = enrolled.keys + prospects
      # Regra por problema: só quem tem problema ativo casando entra no denominador.
      if rules["problems"]
        matching = Facts.problem_candidates(rules["problems"], among: patient_ids).to_set
        patient_ids = patient_ids.select { |id| matching.include?(id) }
      end
      neighborhoods = NeighborhoodCoverage.where(health_unit_id: team.health_unit_id).pluck(:neighborhood_id)
      candidates = Citizen.not_erased.verification_level_verified.where(patient_id: nil, neighborhood_id: neighborhoods).to_a
      citizen_ids = citizen_teams(candidates).select { |_, team_id| team_id == team.id }.keys

      people = Facts.patients(patient_ids).values + Facts.citizens(citizen_ids).values
      people.select { |person| Eligibility.denominator?(rules, person, on: on, lmp: enrolled[person.patient_id]&.anchor_on) }
            .map { |person| [ person.with(team_id: team.id), person.patient_id && enrolled[person.patient_id] ] }
    end
  end
end
