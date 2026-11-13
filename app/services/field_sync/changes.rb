# Download incremental do app de campo, GET /field/v1/changes (módulo 24b,
# ADR 0052; contrato §9.3; §16 Q9, Q33, Q47, Q60, Q61, C12; Ruling A12;
# preflight 22; Review Focus 4).
#
# Escopo: FieldSync::Scope (microáreas ativas em que o dono é o ACS
# responsável ou tem atribuição ativa). Um FLUXO ÚNICO, em ordem (t, id):
#   - micro_area   (t = updated_at) das microáreas do escopo;
#   - household    (t = HOUSEHOLD_T: o domicílio, as famílias, os pacientes
#     responsáveis e os cadastros deles) dos domicílios nelas; a família de
#     responsável provisório da UPA fica fora do corpo (Q47);
#   - registration (t = REGISTRATION_T: o cadastro e o paciente) dos cadastros
#     nelas, menos o paciente provisório da UPA (a guarda da Q41: unidentified
#     no fluxo, e no_cpf_reason "unidentified", que é cifrado, ao montar; Q47);
#   - lápide       (t = created_at) de field_sync_tombstones das microáreas do
#     escopo (Ruling A12): conta no limit e sai em `removals` da página em que
#     cai. A lápide de quem CONTINUA no escopo (mudou de uma microárea do
#     escopo para outra; voltou) não entra: o item dele vem pelo updated_at, e
#     a removal faria o app apagar o que acabou de baixar.
# Empate de t entre item e lápide (ou entre dois itens): o id (uuid, único
# entre as tabelas na prática) decide; a comparação de linha (t, id) > (since,
# after_id) do Postgres é estrita, então nada repete nem pula. Corte em
# agora − 2 s: o que gravou depois (ou numa transação ainda aberta, com t
# anterior) fica para a próxima página.
#
# Sem cursor → carga completa (reset: false). Cursor de outro escopo
# (scope_digest ≠ o atual) → carga completa do escopo novo com reset: true; as
# páginas seguintes, já com o digest novo, voltam reset: false.
# `next_cursor` sempre vem (Q26); `who_to_visit` só quando has_more: false, com
# a lista completa de cada microárea do escopo (HomeVisits::WhoToVisit, Task
# 18), sem o provisório.
#
# Trilha por página com pessoa: clinical_record.viewed access field_sync com
# user_id, field_device_id, household_ids (os domicílios da página) e
# patient_ids (os cadastros, os responsáveis das famílias dos domicílios e, na
# última página, as pessoas do who_to_visit). Página só de microárea ou de
# removal não grava.
#
# Consultas constantes por página (o fluxo numa consulta só; cada tipo
# carregado de uma vez; who_to_visit constante por microárea).
module FieldSync
  module Changes
    Row = Data.define(:kind, :id, :at)
    # O tempo da linha em texto (UTC, microssegundos), igual ao `since` do cursor.
    TIME_FORMAT = "%Y-%m-%dT%H:%M:%S.%6NZ".freeze
    SQL_TIME_FORMAT = 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'.freeze
    # O `t` de cada linha é o instante mais recente de tudo o que o corpo
    # mostra (Fix round 1, I1); o corte, a ordem e o keyset usam esta mesma
    # expressão, então mudar só faz a linha andar para frente (reentrega).
    #   - cadastro: ele e o paciente (<registration>.patient, demografia e
    #     status: nome direto, CPF/CNS que chegou, raça/cor, provisório identificado);
    #   - domicílio: ele, as famílias, os pacientes responsáveis (display_name)
    #     e os cadastros desses responsáveis (responsible_exited, Families).
    REGISTRATION_T = "GREATEST(r.updated_at, p.updated_at)".freeze
    HOUSEHOLD_T = <<~SQL.squish.freeze
      GREATEST(h.updated_at,
        (SELECT max(GREATEST(f.updated_at, fp.updated_at)) FROM families f JOIN patients fp ON fp.id = f.responsible_patient_id
          WHERE f.household_id = h.id),
        (SELECT max(fr.updated_at) FROM families f2 JOIN individual_registrations fr ON fr.patient_id = f2.responsible_patient_id
          WHERE f2.household_id = h.id))
    SQL

    module_function

    def page(user:, device:, cursor:, limit:, now: Time.current)
      raise ArgumentError, "limit: #{Catalog::PAGE_LIMIT}" unless limit.is_a?(Integer) && Catalog::PAGE_LIMIT.cover?(limit)

      position = cursor.nil? ? nil : Cursor.decode(cursor)
      scope = Scope.for(user)
      reset = !position.nil? && position[:scope_digest] != scope[:digest]
      position = nil if reset

      rows = stream(scope[:micro_area_ids], position, cutoff: now - Catalog::CUTOFF, limit: limit + 1)
      more = rows.size > limit
      rows = rows.first(limit)
      items, removals, viewed = render(rows)
      who = more ? nil : who_to_visit(scope[:micro_area_ids], now)
      viewed[:patient_ids].concat(who[:micro_areas].flat_map { |area| area[:people].map { |person| person[:patient_id] } }) if who
      trail!(user, device, viewed)

      last = rows.last
      next_cursor = Cursor.encode(scope_digest: scope[:digest], since: last ? last.at : position&.fetch(:since),
                                  after_id: last ? last.id : position&.fetch(:after_id))
      { reset: reset, items: items, removals: removals, who_to_visit: who, next_cursor: next_cursor, has_more: more }
    end

    # [Row] na ordem do fluxo, até `limit` linhas depois da posição.
    def stream(ids, position, cutoff:, limit:)
      return [] if ids.empty?

      binds = { ids: ids, cutoff: cutoff.utc.strftime(TIME_FORMAT), limit: limit, format: SQL_TIME_FORMAT }
      keyset = ""
      if position && position[:since]
        keyset = "AND (stream.t, stream.id) > (CAST(:since AS timestamp), CAST(:after_id AS uuid))"
        binds.merge!(since: position[:since], after_id: position[:after_id])
      end
      sql = <<~SQL.squish
        SELECT stream.kind, stream.id, to_char(stream.t, :format) FROM (
          SELECT 'micro_area' AS kind, m.id, m.updated_at AS t FROM micro_areas m WHERE m.id IN (:ids)
          UNION ALL
          SELECT 'household', h.id, #{HOUSEHOLD_T} FROM households h WHERE h.micro_area_id IN (:ids)
          UNION ALL
          SELECT 'registration', r.id, #{REGISTRATION_T} FROM individual_registrations r JOIN patients p ON p.id = r.patient_id
           WHERE r.micro_area_id IN (:ids) AND NOT p.unidentified
          UNION ALL
          SELECT 'tombstone', s.id, s.created_at FROM field_sync_tombstones s
           WHERE s.micro_area_id IN (:ids)
             AND NOT (s.entity_type = 'household' AND EXISTS (SELECT 1 FROM households h2 WHERE h2.id = s.entity_id AND h2.micro_area_id IN (:ids)))
             AND NOT (s.entity_type = 'registration' AND EXISTS (SELECT 1 FROM individual_registrations r2 WHERE r2.id = s.entity_id AND r2.micro_area_id IN (:ids)))
        ) stream
        WHERE stream.t <= CAST(:cutoff AS timestamp) #{keyset}
        ORDER BY stream.t, stream.id
        LIMIT :limit
      SQL
      ApplicationRecord.connection.select_rows(ApplicationRecord.sanitize_sql_array([ sql, binds ]), "FieldSync::Changes stream")
                       .map { |kind, id, at| Row.new(kind: kind, id: id, at: at) }
    end

    # -> [items, removals, { household_ids:, patient_ids: }] na ordem do fluxo.
    def render(rows)
      by_kind = rows.group_by(&:kind).transform_values { |list| list.map(&:id) }
      areas = MicroArea.includes(:team, :acs_professional).where(id: by_kind.fetch("micro_area", [])).index_by(&:id)
      households, responsibles = households(by_kind.fetch("household", []))
      registrations = registrations(by_kind.fetch("registration", []))
      stones = FieldSyncTombstone.where(id: by_kind.fetch("tombstone", [])).index_by(&:id)

      items = []
      removals = []
      viewed = { household_ids: [], patient_ids: [] }
      rows.each do |row|
        case row.kind
        when "micro_area"
          area = areas[row.id] or next
          items << { type: "micro_area", id: area.id, body: TerritoryRegistry::Json.micro_area(area) }
        when "household"
          body = households[row.id] or next
          items << { type: "household", id: row.id, version: body[:version], body: body }
          viewed[:household_ids] << row.id
          viewed[:patient_ids].concat(responsibles.fetch(row.id, []))
        when "registration"
          body = registrations[row.id] or next # provisional? já fora (Q47)
          items << { type: "registration", id: row.id, version: body[:version], body: body }
          viewed[:patient_ids] << body.dig(:patient, :id)
        when "tombstone"
          stone = stones[row.id] or next
          removal = { type: stone.entity_type, id: stone.entity_id, reason: stone.reason }
          removals << removal unless removals.include?(removal)
        end
      end
      [ items, removals, viewed ]
    end

    # -> [{ id => <household> }, { id => [responsible patient_id] }] (forma do
    # 24a com famílias e moradia; a mesma montagem do HouseholdsController).
    def households(ids)
      return [ {}, {} ] if ids.empty?

      list = Household.includes(:micro_area, registered_by_user: :professional).where(id: ids).to_a
      versions = HouseholdVersion.joins(:household).where(household_id: ids).where("household_versions.version = households.version")
                                 .index_by(&:household_id)
      rows = Family.where(household_id: ids).includes(:responsible_patient).order(:created_at, :id).to_a
      # Q47 (M3): a família de responsável provisório da UPA fica fora (o
      # <family> exige responsible com patient_id e display_name; a visita
      # family_responsible a ela já é recusada pela guarda da Q41).
      rows.reject! { |family| provisional?(family.responsible_patient) }
      exited = TerritoryRegistry::Families.responsible_exited_ids(rows)
      families = rows.group_by(&:household_id)
      bodies = list.to_h do |household|
        [ household.id, TerritoryRegistry::Json.household(household, versions.fetch(household.id), families: families[household.id] || [],
                                                                                                  exited: exited, full: true) ]
      end
      [ bodies, families.transform_values { |group| group.map(&:responsible_patient_id) } ]
    end

    # -> { id => <registration> } (forma do 24a; a mesma montagem do RegistrationsController).
    def registrations(ids)
      return {} if ids.empty?

      list = IndividualRegistration.includes(:patient, :team, :micro_area, registered_by_user: :professional).where(id: ids).to_a
      versions = IndividualRegistrationVersion.joins(:registration).where(registration_id: ids)
                                              .where("individual_registration_versions.version = individual_registrations.version")
                                              .index_by(&:registration_id)
      list.reject! { |registration| provisional?(registration.patient) }
      locked = Patients::Pairs.patient_ids_with_pairs(list.map(&:patient).uniq)
      list.to_h do |registration|
        [ registration.id, TerritoryRegistry::Json.registration(registration, versions.fetch(registration.id),
                                                                identity_locked: locked.include?(registration.patient_id)) ]
      end
    end

    # A lista completa de cada microárea do escopo (ordem: código, id), sem o
    # provisório da UPA (Q47). Interruptores lidos aqui, fora de transação.
    def who_to_visit(ids, now)
      today = now.in_time_zone.to_date
      flags = { today: today, care_lines: CareLines::Gate.usable?(Current.city), home_visits: HomeVisits::Gate.usable?(Current.city) }
      areas = ids.empty? ? [] : MicroArea.where(id: ids).order(:code, :id).to_a
      lists = areas.map { |area| [ area, HomeVisits::WhoToVisit.page(micro_area: area, before: nil, limit: nil, **flags)[:items] ] }
      people = lists.flat_map { |_, items| items.map { |item| item[:patient_id] } }
      provisional = people.empty? ? Set.new : Patient.where(id: people).select(:id, :unidentified, :no_cpf_reason).select { |patient| provisional?(patient) }.to_set(&:id)
      { generated_at: now.iso8601,
        micro_areas: lists.map do |area, items|
          { micro_area_id: area.id, people: items.reject { |item| provisional.include?(item[:patient_id]) } }
        end }
    end

    # A guarda da Q41 (HomeVisits::People): no_cpf_reason é cifrado, então o
    # fluxo corta só por `unidentified` (indexado) e esta conferência fecha o resto.
    def provisional?(patient) = patient.unidentified || patient.no_cpf_reason == "unidentified"

    def trail!(user, device, viewed)
      household_ids = viewed[:household_ids].uniq
      patient_ids = viewed[:patient_ids].compact.uniq
      return if household_ids.empty? && patient_ids.empty?

      Upload::DeviceTrail.new(device).records_viewed!(user: user, household_ids: household_ids, patient_ids: patient_ids)
    end

    private_class_method :stream, :render, :households, :registrations, :who_to_visit, :provisional?, :trail!
  end
end
