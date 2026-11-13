# Registra a visita domiciliar (módulo 24b, ADR 0052; contrato §1, §2, §3, §5,
# §13; Q6, Q21, Q40–Q44, Q49; plano, Task 8, Desvio 2; pre-flight 1.8, 1.9).
#
# 1. `client_uuid` já gravado pelo mesmo usuário → ok(replayed: true) com a
#    gravada (idempotência do dashboard; o envio do app usa o livro, Task 20);
#    de outro usuário → client_uuid_conflict (nunca mostra a visita alheia).
# 2. Acesso pela equipe (HomeVisits::Access): sem vínculo → out_of_scope;
#    enfermeiro/médico ou CBO fora da Tabela 7 → cbo_not_allowed.
# 3. Transação própria (savepoint `requires_new`: dentro do envio do app, a
#    recusa desfaz só o item). Travas na ordem do §3: paciente(s) FOR UPDATE
#    (o morador e/ou o responsável da família) → domicílio FOR SHARE → folha
#    (pg_advisory_xact_lock por profissional+equipe+dia, depois a folha aberta
#    FOR UPDATE) → visita. Escopo da microárea (herdada ou escolhida) pelo
#    Access; registro de outra equipe por id → not_found.
# 4. Q43/Q51: morador com motivo 29/34–37 (responsible_document_reasons) em
#    imóvel residencial: com o cadastro numa família ativa do domicílio → a
#    visita é da família (subject family_responsible, patient_id = o
#    responsável); sem família ativa dele ali → visita sem pessoa (Q44).
#    family_responsible: o responsável passa pela guarda patient_unidentified
#    do HomeVisits::People (Q41).
# 5. TODAS as regras (HomeVisits::Rules, puras) antes de qualquer escrita; o
#    paciente novo (People.resolve, savepoint próprio; Q49) depois delas; só
#    então a folha: sem aberta, abre a `sequence` seguinte (a principal ou a
#    complementar de um dia já fechado); com 99 visitas válidas na aberta, a
#    100ª fecha a cheia (CloseDay closed_by "full", ficha gerada na mesma
#    transação) e abre a próxima (Desvio 2).
# 6. Grava (has_reason pelo api; medidas arredondadas pelo YAML; observação
#    com strip) e publica home_visit.recorded só com os três ids.
#
# A trilha dos candidatos do duplicado suspeito é gravada DEPOIS da transação,
# com qualquer desfecho (People.candidates_viewed!). Motivo, medida,
# observação, nome e documento nunca em Result.details, log ou evento.
module HomeVisits
  module Record
    EVENT = "home_visit.recorded".freeze
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    # Instante ISO 8601 com fuso (Q26): o dia e o turno são os da cidade.
    INSTANT = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d{1,6})?)?(Z|[+-]\d{2}:\d{2})\z/
    ALLOWED = %w[
      client_uuid team_id occurred_at household_id micro_area_id out_of_area property_type subject patient_id new_patient
      family_id duplicates_reviewed outcome reasons shared measurements note
    ].freeze
    ID_KEYS = %w[team_id household_id micro_area_id patient_id family_id].freeze
    KEY_PATH_MAX = 64

    # Desfaz o savepoint levando a recusa para fora.
    class Refused < StandardError
      attr_reader :result

      def initialize(result)
        @result = result
        super(result.reason.to_s)
      end
    end

    module_function

    # -> Result.ok(visit:, day:, replayed:) | Result.fail(<código>, details: { path: } ...)
    def call(params:, by:, origin: "dashboard", device: nil, trail: Trail)
      raise ArgumentError, "origin" unless Catalog::ORIGINS.include?(origin)
      raise ArgumentError, "device: só (e sempre) com origin field_app" if (origin == "field_app") == device.nil?

      params = params.to_h.deep_stringify_keys
      uuid = params["client_uuid"]
      return refuse(:invalid_request, "client_uuid") unless uuid?(uuid)

      replay = replayed(uuid, by)
      return replay if replay

      shape = shape_error(params)
      return shape if shape

      team = HealthTeam.find_by(id: params["team_id"])
      member = Access.member(by, team)
      return Result.fail(:out_of_scope) unless member
      return Result.fail(:cbo_not_allowed) unless %i[acs field].include?(Access.role(member))

      input = params.merge("occurred_at" => instant(params["occurred_at"]))
      shown = []
      result = begin
        ApplicationRecord.transaction(requires_new: true) { write(input, by, team, member, origin, device, shown) }
      rescue Refused => e
        e.result
      rescue ActiveRecord::RecordNotUnique => e
        raise unless e.message.include?("idx_home_visits_client_uuid")

        replayed(uuid, by) || raise
      end
      People.candidates_viewed!(candidate_ids: shown, by: by, trail: trail) if shown.any?
      result
    end

    def write(input, by, team, member, origin, device, shown)
      locked = lock_patients!(patients_to_lock(input))
      household, area = place!(input, team)
      # Corpo sem lugar coerente (nem microárea nem fora de área, os dois, ou
      # um deles com domicílio) é malformado: as regras recusam com o path,
      # antes do escopo (nunca 403 por um campo que faltou).
      checked = well_placed?(input, household)
      if checked
        access = Access.registers?(by, team, micro_area: area, out_of_area: input["out_of_area"] == true)
        refuse!(Result.fail(access)) unless access == :ok
      end

      family = family!(input, household)
      input, family, conversion = family_visit(input, household, family, by)
      patient = existing_patient!(input, family, by, locked)
      facts = facts(input, household, area, family, patient)
      error = Rules.check(input, **facts, today: Time.zone.today, without_family: conversion == :without_family).first
      path = conversion == :family && error&.dig(:path) == "family_id" ? "patient_id" : error&.dig(:path)
      refuse!(Result.fail(error[:error], details: { path: path })) if error
      raise "lugar malformado passou nas regras" unless checked

      patient ||= new_patient!(input, by, shown)
      day = sheet!(by, team, member, input["occurred_at"].in_time_zone.to_date)
      visit = insert!(input, day, household, area, family, patient, by, origin, device)
      DomainEvents.publish(EVENT, home_visit_id: visit.id, home_visit_day_id: day.id, user_id: by.id)
      Result.ok(visit: visit, day: day, replayed: false)
    end

    # --- antes da transação ---------------------------------------------------

    def shape_error(params)
      unknown = (params.keys - ALLOWED).first
      return refuse(:invalid_home_visit, unknown[0, KEY_PATH_MAX]) if unknown

      # Sem equipe o corpo é malformado (422 com path, não 403; A-M5).
      return refuse(:invalid_home_visit, "team_id") if params["team_id"].nil?

      bad = ID_KEYS.find { |key| !params[key].nil? && !uuid?(params[key]) }
      bad && refuse(:invalid_home_visit, bad)
    end

    def replayed(uuid, by)
      visit = HomeVisit.find_by(client_uuid: uuid)
      return nil unless visit
      return refuse(:client_uuid_conflict, "client_uuid") unless by && visit.recorded_by_user_id == by.id

      Result.ok(visit: visit, day: visit.home_visit_day, replayed: true)
    end

    def instant(value)
      return nil unless value.is_a?(String) && value.match?(INSTANT)

      Time.iso8601(value).in_time_zone
    rescue ArgumentError
      nil
    end

    # --- travas e fatos (na transação) ----------------------------------------

    # Os pacientes que a visita pode citar, lidos sem trava: o morador, o
    # responsável da família escolhida e o da família do cadastro do morador
    # (Q43). Responsável e família nunca mudam (trigger); o cadastro é relido
    # depois da trava.
    def patients_to_lock(input)
      ids = []
      ids << input["patient_id"] if input["patient_id"]
      ids << Family.where(id: input["family_id"]).pick(:responsible_patient_id) if input["family_id"]
      if input["patient_id"]
        family_id = IndividualRegistration.active_registrations.where(patient_id: input["patient_id"]).pick(:family_id)
        ids << Family.where(id: family_id).pick(:responsible_patient_id) if family_id
      end
      ids.compact.uniq
    end

    # FOR UPDATE em ordem de id (dois pacientes sem deadlock entre visitas).
    def lock_patients!(ids)
      return Set.new if ids.empty?

      Patient.where(id: ids).order(:id).lock.pluck(:id).to_set
    end

    # -> [household | nil, micro_area | nil]
    def place!(input, team)
      if input["household_id"]
        household = Household.lock("FOR SHARE").find_by(id: input["household_id"])
        refuse!(refuse(:not_found, "household_id")) unless household && household.micro_area.team_id == team.id
        return [ household, household.micro_area ]
      end
      return [ nil, nil ] if input["micro_area_id"].nil?

      area = MicroArea.find_by(id: input["micro_area_id"], team_id: team.id)
      refuse!(refuse(:not_found, "micro_area_id")) unless area
      [ nil, area ]
    end

    # Família lida depois da trava do domicílio (moved_out muda com ela travada).
    def family!(input, household)
      return nil if input["family_id"].nil?

      family = Family.find_by(id: input["family_id"])
      refuse!(refuse(:not_found, "family_id")) if family.nil? || (household && family.household_id != household.id)
      family
    end

    # Morador com motivo de documento do responsável (29, 34–37) em imóvel
    # residencial. -> [input, family, nil | :family | :without_family]
    #  - Q43: o cadastro ativo dele está numa família ativa deste domicílio → a
    #    visita é da família (family_responsible, patient_id = o responsável);
    #  - Q51/Q44: sem família ativa dele no domicílio (cadastro sem família,
    #    família em mudança, sem cadastro ativo, paciente novo, ou sem
    #    domicílio) → visita sem pessoa (subject none; o paciente novo não é
    #    criado), com as regras da visita sem pessoa e a exceção da Q44.
    # Não converte (as regras recusam o corpo original): family_id no corpo,
    # patient_id e new_patient juntos ou nenhum, cadastro ativo em outro
    # domicílio (patient_in_other_household). O morador existente passa antes
    # pela guarda patient_unidentified.
    def family_visit(input, household, family, by)
      reasons = input["reasons"]
      return [ input, family, nil ] unless input["subject"] == "resident" && reasons.is_a?(Array) &&
                                           reasons.intersect?(Catalog::RESPONSIBLE_DOCUMENT_REASONS)
      property = household ? household.latest_version.property_type : input["property_type"]
      return [ input, family, nil ] unless Catalog::RESIDENTIAL.include?(property)
      return [ input, family, nil ] unless input["family_id"].nil? && input["patient_id"].nil? != input["new_patient"].nil?

      if input["patient_id"]
        resident = People.resolve(by: by, patient_id: input["patient_id"])
        refuse!(resident) if resident.failure?

        registration = IndividualRegistration.active_registrations.find_by(patient_id: input["patient_id"])
        return [ input, family, nil ] if household && registration&.household_id && registration.household_id != household.id

        own = household && registration&.family_id && Family.find_by(id: registration.family_id)
        if own && !own.moved_out && own.household_id == household.id
          return [ input.merge("subject" => "family_responsible", "family_id" => own.id, "patient_id" => nil), own, :family ]
        end
      end
      [ input.merge("subject" => "none", "patient_id" => nil, "new_patient" => nil, "duplicates_reviewed" => nil), family,
        :without_family ]
    end

    # Domicílio: sem microárea e sem fora de área no corpo. Sem domicílio:
    # exatamente um dos dois.
    def well_placed?(input, household)
      return input["micro_area_id"].nil? && input["out_of_area"] != true if household

      input["micro_area_id"].nil? == (input["out_of_area"] == true)
    end

    # O paciente existente da visita, já travado: o morador ou o responsável
    # (guarda patient_unidentified do People). Paciente novo: nil (criado
    # depois das regras).
    def existing_patient!(input, family, by, locked)
      id = case input["subject"]
           when "resident" then input["patient_id"]
           when "family_responsible" then family&.responsible_patient_id
           end
      return nil if id.nil?

      # O cadastro mudou entre a leitura sem trava e a trava: este paciente é
      # travado fora da ordem (depois do domicílio). Raro; no pior caso
      # ActiveRecord::Deadlocked, nunca dado errado.
      Patient.lock.find_by(id: id) unless locked.include?(id)
      resolved = People.resolve(by: by, patient_id: id)
      refuse!(resolved) if resolved.failure?
      resolved.payload[:patient]
    end

    def facts(input, household, area, family, patient)
      household_facts = household && Rules::HouseholdFacts.new(
        id: household.id, active: household.status == "active", property_type: household.latest_version.property_type,
        active_families: household.families.active_families.exists?
      )
      family_facts = family && Rules::FamilyFacts.new(
        id: family.id, household_id: family.household_id, moved_out: family.moved_out,
        responsible_exited: TerritoryRegistry::Families.responsible_exited_ids([ family ]).include?(family.id)
      )
      { household: household_facts, micro_area: area && Rules::AreaFacts.new(id: area.id, active: area.active),
        family: family_facts, patient: person_facts(input, patient) }
    end

    def person_facts(input, patient)
      if patient
        household_id = input["subject"] == "resident" ? IndividualRegistration.active_registrations.where(patient_id: patient.id).pick(:household_id) : nil
        return Rules::PersonFacts.new(sex: patient.sex, household_id: household_id)
      end
      typed = input["new_patient"]
      Rules::PersonFacts.new(sex: typed["sex"], household_id: nil) if input["subject"] == "resident" && typed.is_a?(Hash)
    end

    # --- escritas (depois de todas as regras) ---------------------------------

    def new_patient!(input, by, shown)
      return nil unless input["subject"] == "resident" && !input["new_patient"].nil?

      # Q67: cobra o orçamento da busca de pessoa (uma vez; estourado → 429 /
      # rejected too_many_requests, sem path), antes de qualquer escrita.
      created = People.resolve(by: by, new_patient: input["new_patient"], reviewed: input["duplicates_reviewed"],
                               budget: SearchBudget.new(by))
      return created.payload[:patient] if created.ok?

      shown.concat(Array(created.details[:candidate_ids]))
      refuse!(Result.fail(created.reason, details: created.details.except(:candidate_ids)))
    end

    # A folha aberta do (profissional, equipe, dia), na trava consultiva da
    # chave: sem aberta, a próxima `sequence`; cheia (99 válidas), fecha
    # (closed_by "full", ficha na transação) e abre a próxima.
    def sheet!(by, team, member, day)
      connection = ApplicationRecord.connection
      key = "home_visit_day:#{member.professional_id}:#{team.id}:#{day.iso8601}"
      connection.execute("SELECT pg_advisory_xact_lock(hashtextextended(#{connection.quote(key)}, 0))")
      open = HomeVisitDay.lock.open_on(member.professional, team, day).first
      if open && open.home_visits.valid.count >= Catalog::MAX_VISITS_PER_SHEET
        closed = CloseDay.call(open, by: nil, closed_by: "full")
        raise "folha cheia não fechou: #{closed.reason}" if closed.failure?

        open = nil
      end
      open || HomeVisitDay.create!(
        professional: member.professional, user: by, team: team, cbo: member.cbo_code, day: day, state: "open",
        sequence: HomeVisitDay.where(professional_id: member.professional_id, team_id: team.id, day: day).maximum(:sequence).to_i + 1
      )
    end

    def insert!(input, day, household, area, family, patient, by, origin, device)
      reasons = input["reasons"] || []
      HomeVisit.create!(
        home_visit_day: day, client_uuid: input["client_uuid"], occurred_at: input["occurred_at"],
        shift: Rules.shift(input["occurred_at"]), household: household, micro_area: area, out_of_area: area.nil?,
        property_type: household ? household.latest_version.property_type : input["property_type"],
        subject: input["subject"], family: (family if input["subject"] == "family_responsible"), patient: patient,
        outcome: input["outcome"], has_reason: reasons.any?, reasons: reasons, shared: input["shared"] == true,
        measurements: Rules.measurements(input["measurements"]), note: Rules.note(input["note"]),
        origin: origin, field_device_id: device&.id, recorded_by_user: by
      )
    end

    def uuid?(value) = value.is_a?(String) && value.match?(UUID)
    def refuse(reason, path) = Result.fail(reason, details: { path: path })
    def refuse!(result) = raise(Refused, result)
    private_class_method :write, :shape_error, :replayed, :instant, :patients_to_lock, :lock_patients!, :place!, :family!,
                         :family_visit, :well_placed?, :existing_patient!, :facts, :person_facts, :new_patient!, :sheet!, :insert!,
                         :uuid?, :refuse, :refuse!
  end
end
