# Equipe de cada pessoa e população de uma equipe (ADR 0040; spec §2
# decisões 8 e 9; plano, Desvio 5). Inscrito → equipe da inscrição;
# paciente → equipe ativa do profissional da consulta finalizada mais
# recente (24 meses), na unidade do vínculo; par validado sem paciente → a
# única equipe ativa das unidades de referência do bairro. P18 (contrato
# §12): o paciente cuja consulta finalizada nos 24 meses NÃO dá equipe
# (nenhuma, ou só com plantonista sem equipe) segue a regra do par sem
# paciente, pelo bairro do par validado mais antigo dele.
# Cadastro individual ativo (24a, ADR 0042) → equipe da microárea; P18/P22
# para quem não tem. Com o interruptor territory_registry ligado (Gate, só a
# plataforma), o cadastro sem saída de equipe ativa vence a consulta e o
# território (contrato §9): a equipe da microárea do domicílio ou, fora de
# área, a do cadastro (TerritoryRegistry::Teams); vale desde a gravação, sem
# esperar o SIAPS. Saída por mudança devolve as regras de antes; desligado, a
# regra de antes, sem ler o cadastro.
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
    #
    # Cadastro ligado: a precedência do cadastro fica no SQL (revisão final,
    # M2 — nenhuma lista de ids sai do Ruby para o banco): a consulta e o
    # território só olham quem NÃO tem cadastro ativo em equipe ativa
    # (UNREGISTERED), e o cadastro entra por Teams.for_patients. Com
    # `involving_team:`, os cadastrados da equipe (o paciente sem CPF, sem
    # consulta nem par, só entra assim); quem tem cadastro em outra equipe
    # fica de fora (não é desta equipe). O interruptor e uma consulta a
    # mais, constantes.
    def patient_teams(patient_ids = nil, involving_team: nil)
      return {} if patient_ids && patient_ids.empty?

      registry = TerritoryRegistry::Gate.enabled?(Current.city)
      teams = consultation_teams(patient_ids, involving_team, registry: registry)
      return teams unless registry

      teams.merge(TerritoryRegistry::Teams.for_patients(patient_ids, team: involving_team))
    end

    # Sem cadastro ativo (sem saída) em equipe ativa — o mesmo critério de
    # TerritoryRegistry::Teams. %s = a coluna do paciente na consulta de fora.
    UNREGISTERED = <<~SQL.freeze
      AND NOT EXISTS (SELECT 1 FROM individual_registrations ir
                        JOIN health_teams irt ON irt.id = ir.team_id AND irt.active
                       WHERE ir.patient_id = %s AND ir.exit_reason IS NULL)
    SQL

    # A regra do módulo 23 (consulta e território); com `registry:`, só para
    # quem não tem cadastro ativo.
    def consultation_teams(patient_ids, involving_team, registry: false)
      filter = patient_ids ? ApplicationRecord.sanitize_sql([ "AND c.patient_id IN (?)", patient_ids ]) : ""
      cutoff = LOOKBACK.ago
      territorial = territory_neighborhoods(patient_ids, involving_team, cutoff, registry: registry)
      filter += involving(involving_team, cutoff) if involving_team
      filter += format(UNREGISTERED, "c.patient_id") if registry
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
    private_class_method :consultation_teams

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
    def territory_neighborhoods(patient_ids, team, cutoff, registry: false)
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
               #{covered} #{format(UNREGISTERED, 'p.patient_id') if registry}
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

    # A população da equipe sem regra de linha (módulo 24a, F-24.6: a
    # validade do cadastro): pacientes cuja equipe é ela (patient_teams, com o
    # cadastro quando ligado) e pares validados sem paciente cuja única equipe
    # do bairro é ela. Sem óbito nem elegibilidade (quem chama decide); o par
    # cujo CPF já tem paciente e o par repetido do mesmo CPF ficam de fora no
    # SQL (Facts.one_per_cpf). Os pares em tuplas (pluck), nunca objetos.
    def members(team:)
      patient_ids = patient_teams(involving_team: team).select { |_, team_id| team_id == team.id }.keys
      covered = NeighborhoodCoverage.where(health_unit_id: team.health_unit_id).select(:neighborhood_id)
      candidates = Facts.one_per_cpf(Citizen.not_erased.verification_level_verified.where(patient_id: nil, neighborhood_id: covered))
                        .pluck(:id, :neighborhood_id).to_h
      citizen_ids = territory_teams(candidates).select { |_, team_id| team_id == team.id }.keys
      { patient_ids: patient_ids, citizen_ids: citizen_ids }
    end

    # Pessoas da equipe, elegíveis para o denominador das regras, com a
    # inscrição ativa delas na linha (ou nil). A inscrita é avaliada com a DUM
    # decifrada (Eligibility: o excludente só vale na gestação da DUM).
    # Revisão final (I3): só as inscrições DA EQUIPE viram objeto (a DUM); das
    # outras equipes, só os ids, restritos aos candidatos da equipe (a
    # inscrição em outra equipe tira a pessoa daqui); o filtro por problema
    # cruza com os ids no SQL.
    def call(team:, line:, rules:, on: Time.zone.today)
      enrolled = line ? CareLineEnrollment.active_enrollments.where(care_line: line, team_id: team.id).to_a.index_by(&:patient_id) : {}
      population = members(team: team)
      prospects = population[:patient_ids] - enrolled.keys
      if line
        elsewhere = CareLineEnrollment.active_enrollments.where(care_line: line)
                                      .where(Facts.any_uuid(CareLineEnrollment.arel_table[:patient_id], prospects)).pluck(:patient_id, :team_id)
        prospects -= elsewhere.map(&:first)
      end
      # P21: óbito em qualquer linha tira a pessoa do denominador de todas.
      patient_ids = enrolled.keys + prospects
      patient_ids -= Facts.deceased(patient_ids).to_a
      # Regra por problema: só quem tem problema ativo casando entra no denominador.
      if rules["problems"]
        matching = Facts.problem_candidates(rules["problems"], among: patient_ids).to_set
        patient_ids = patient_ids.select { |id| matching.include?(id) }
      end
      people = Facts.patients(patient_ids).values + Facts.citizens(population[:citizen_ids]).values
      people.select { |person| Eligibility.denominator?(rules, person, on: on, lmp: enrolled[person.patient_id]&.anchor_on) }
            .map { |person| [ person.with(team_id: team.id), person.patient_id && enrolled[person.patient_id] ] }
    end
  end
end
