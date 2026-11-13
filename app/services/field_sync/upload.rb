# Envio do app de campo, POST /field/v1/uploads (módulo 24b, ADR 0052;
# contrato §9.3; Q27, Q31, Q32, Q45, Q46, Q51, Q53, Q54, Q56; preflight 1.9,
# 1.10, 1.11, 1.16, 2.T20c; Ruling A11).
#
# Envelope (`envelope`): objeto só com `items`, lista de 1 a 50 → senão 422
# invalid_request com `path` ("items" ou a chave desconhecida), nada gravado.
#
# Cada item (`call`), em ordem:
# 1. Conferido contra `upload-request-v1.json#/$defs/item` (FieldSync::Schemas,
#    em execução). Fora do esquema → só ele `rejected invalid_request`, com o
#    `path` da Q32/Q46 (relativo ao body; `client_uuid`/`type` omitidos quando
#    inválidos).
# 2. Na SUA transação (`requires_new`): trava consultiva do client_uuid →
#    livro (field_sync_receipts): o mesmo client_uuid do mesmo usuário com o
#    mesmo type → `duplicate` com o id; outro type ou outro usuário →
#    `rejected client_uuid_conflict`. Depois os interruptores e o CBO (lidos uma
#    vez por lote, fora da transação), as citações do livro (Q27: patient e
#    household aceitos antes, do mesmo usuário; senão `rejected not_found` com o
#    path do campo) e o comando, que tem savepoint próprio e devolve Result.
# 3. Aceito → linha no livro na mesma transação. Recusado, duplicate do livro e
#    stale_version → ActiveRecord::Rollback (nada fica; o reenvio é processado
#    de novo). Exceção inesperada (StandardError, Q63 a) desfaz só o item e volta
#    `rejected internal_error`, sem path e fora do livro; o lote continua. O log
#    leva só a classe e o client_uuid (nunca a mensagem, o corpo ou pessoa).
#    stale_version só para domicílio ou cadastro que JÁ EXISTE; cadastro NOVO
#    cujo domicílio mudou → `rejected household_changed` (Q63 b).
#    already_registered leva o `id` do cadastro existente só quando ele está no
#    escopo do aparelho (6A; Q63 c).
# 4. DEPOIS da transação, com qualquer desfecho: a trilha clinical_record.viewed
#    (access field_sync, com o aparelho) dos candidatos do duplicado suspeito e
#    do `current` do stale_version. Os comandos recebem um coletor como `trail:`
#    para a trilha não ir embora com o rollback do item.
#
# Nada de nome, CPF, CNS, motivo, medida ou observação no resultado de erro, no
# log ou em evento: só código, path, ids e a forma `candidate`/`current` do 24a.
module FieldSync
  module Upload
    ITEM_REF = "#/$defs/item".freeze
    # A do esquema (minúsculas): o uuid inválido não volta no resultado.
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
    PATH_MAX = 128
    RESULT_TYPES = { "home_visit" => "HomeVisit", "home_visit_withdrawal" => "HomeVisit",
                     "collective_activity" => "CollectiveActivity", "patient" => "Patient", "household" => "Household",
                     "individual_registration" => "IndividualRegistration" }.freeze
    # Palavras do esquema que são falha do próprio objeto (Q46): o `required`
    # dentro delas não aponta o campo que falta.
    COMPOSITE = %r{/(oneOf|anyOf|not)/}

    # Coletor dos candidatos mostrados (o `trail:` dos comandos), gravados
    # depois da transação do item.
    class Shown
      attr_reader :ids

      def initialize = @ids = []
      def person_viewed!(user:, patient_id:) = @ids << patient_id
    end

    # A trilha do envio: clinical_record.viewed com access field_sync e o aparelho.
    DeviceTrail = Struct.new(:device) do
      def person_viewed!(user:, patient_id:)
        DomainEvents.publish("clinical_record.viewed", patient_id: patient_id, user_id: user.id,
                                                       access: HomeVisits::Catalog::FIELD_TRAIL_ACCESS, reason_code: nil,
                                                       person_ref: "patient:#{patient_id}", field_device_id: device.id)
      end

      def records_viewed!(user:, household_ids:, patient_ids:)
        DomainEvents.publish("clinical_record.viewed", access: HomeVisits::Catalog::FIELD_TRAIL_ACCESS, user_id: user.id,
                                                       field_device_id: device.id, household_ids: household_ids,
                                                       patient_ids: patient_ids.uniq)
      end
    end

    module_function

    # -> Result.ok(items:) | Result.fail(:invalid_request, details: { path: })
    def envelope(body)
      return invalid_envelope("items") unless body.is_a?(Hash)

      unknown = (body.keys - [ "items" ]).first
      return invalid_envelope(unknown.to_s[0, PATH_MAX].presence || "items") if unknown

      items = body["items"]
      return invalid_envelope("items") unless items.is_a?(Array) && (1..Catalog::MAX_ITEMS).cover?(items.size)

      Result.ok(items: items)
    end

    # -> [result] na forma do upload-response-v1 (chaves texto), na ordem dos itens.
    def call(items:, device:, user:)
      raise ArgumentError, "items: 1 a #{Catalog::MAX_ITEMS}" unless items.is_a?(Array) && (1..Catalog::MAX_ITEMS).cover?(items.size)

      context = { device: device, user: user, trail: DeviceTrail.new(device), acs: acs?(user),
                  collective: CollectiveActivities::Gate.usable?(Current.city),
                  registry: TerritoryRegistry::Gate.usable?(Current.city) }
      items.map { |item| process(item, context) }
    end

    # --- um item -----------------------------------------------------------------

    def process(item, context)
      errors = Schemas.failures("upload-request-v1", item, ref: ITEM_REF)
      return invalid_item(item, errors) if errors.any?

      uuid, type, body = item.values_at("client_uuid", "type", "body")
      shown = Shown.new
      outcome = nil
      begin
        ApplicationRecord.transaction(requires_new: true) do
          lock!(uuid)
          outcome = ledger(uuid, type, context[:user]) || dispatch(type, uuid, body, context, shown)
          raise ActiveRecord::Rollback unless outcome[:receipt]

          FieldSyncReceipt.create!(client_uuid: uuid, item_type: type, result_type: RESULT_TYPES.fetch(type), result_id: outcome[:id],
                                   field_device: context[:device], user: context[:user])
        end
      rescue StandardError => e
        # Q63 a: só a classe e o client_uuid (a mensagem pode trazer valor do corpo).
        Rails.logger.error("[field_sync.upload] internal_error class=#{e.class.name} client_uuid=#{uuid}")
        outcome = rejected("internal_error")
      end
      trail!(context, shown.ids, outcome[:viewed])
      result_json(uuid, type, outcome)
    end

    # Serializa o mesmo client_uuid entre lotes simultâneos (a chave é o uuid,
    # já conferido pelo esquema); dura até o fim da transação do item.
    def lock!(uuid)
      connection = ApplicationRecord.connection
      connection.execute("SELECT pg_advisory_xact_lock(hashtextextended(#{connection.quote("field_sync_receipt:#{uuid}")}, 0))")
    end

    def ledger(uuid, type, user)
      receipt = FieldSyncReceipt.find_by(client_uuid: uuid)
      return nil unless receipt
      return rejected("client_uuid_conflict") unless receipt.item_type == type && receipt.user_id == user.id

      { status: "duplicate", id: receipt.result_id, receipt: false }
    end

    def dispatch(type, uuid, body, context, shown)
      case type
      when "home_visit" then home_visit(uuid, body, context, shown)
      when "home_visit_withdrawal" then withdrawal(body, context)
      when "collective_activity" then collective_activity(uuid, body, context, shown)
      when "patient" then patient(body, context, shown)
      when "household" then household(body, context)
      when "individual_registration" then registration(body, context, shown)
      else raise ArgumentError, "type fora do esquema"
      end
    end

    # --- tipos -------------------------------------------------------------------

    def home_visit(uuid, body, context, shown)
      params, missing = cite(body, context[:user])
      return missing if missing

      result = HomeVisits::Record.call(params: params.merge("client_uuid" => uuid), by: context[:user], origin: "field_app",
                                       device: context[:device], trail: shown)
      return failure(result) if result.failure?

      accepted(result.payload[:visit].id, replayed: result.payload[:replayed])
    end

    # Q45: retirada pela visita do app (visit_client_uuid) ou pelo id, com
    # expected_state "recorded" implícito; day_closed e visit_changed como na
    # rota da equipe.
    def withdrawal(body, context)
      keys = %w[visit_client_uuid visit_id].select { |key| body.key?(key) }
      return rejected("invalid_request", "body") unless keys.one?

      key = keys.first
      visit = key == "visit_id" ? HomeVisit.find_by(id: body[key]) : HomeVisit.find_by(client_uuid: body[key])
      return rejected("not_found", key) unless visit

      result = HomeVisits::Withdraw.call(visit, by: context[:user], expected_state: "recorded", reason: body["reason"])
      return failure(result, path: (key if result.reason == :not_found)) if result.failure?

      accepted(visit.id)
    end

    # Preflight 1.11: participants[i].patient_client_uuid pelo livro.
    def collective_activity(uuid, body, context, shown)
      return rejected("feature_disabled") unless context[:collective]

      params = body.deep_dup
      if params["participants"].is_a?(Array)
        params["participants"] = params["participants"].each_with_index.map do |participant, index|
          next participant unless participant.is_a?(Hash) && participant.key?("patient_client_uuid")
          return rejected("invalid_collective_activity", "participants[#{index}]") if participant.key?("patient_id") || participant.key?("new_patient")

          id = cited_id(participant["patient_client_uuid"], "patient", context[:user])
          return rejected("not_found", "participants[#{index}].patient_client_uuid") unless id

          participant.except("patient_client_uuid").merge("patient_id" => id)
        end
      end
      result = CollectiveActivities::Record.call(params: params.merge("client_uuid" => uuid), by: context[:user], origin: "field_app",
                                                 device: context[:device], trail: shown)
      return failure(result) if result.failure?

      accepted(result.payload[:activity].id, replayed: result.payload[:replayed])
    end

    def patient(body, context, shown)
      result = HomeVisits::People.resolve(by: context[:user], new_patient: body["new_patient"], reviewed: body["duplicates_reviewed"])
      if result.failure?
        shown.ids.concat(Array(result.details[:candidate_ids]))
        return failure(result)
      end

      accepted(result.payload[:patient].id)
    end

    # 24a: na atualização, household_id + version; o domicílio é carregado aqui
    # e só vale se o usuário cadastra na microárea dele (visible_micro_area_ids;
    # senão not_found). stale_version leva o `current` (2.T20c).
    def household(body, context)
      refusal = registry_refusal(context)
      return refusal if refusal

      user = context[:user]
      household = nil
      if body.key?("household_id")
        household = Household.includes(micro_area: :team).find_by(id: body["household_id"])
        visible = household && TerritoryRegistry::Access.visible_micro_area_ids(user, household.micro_area.team).include?(household.micro_area_id)
        return rejected("not_found", "household_id") unless visible
      end
      result = TerritoryRegistry::SaveHousehold.call(params: body.except("household_id"), by: user, household: household)
      return stale_household(household) if result.failure? && result.reason == :stale_version && household
      return failure(result) if result.failure?

      accepted(result.payload[:household].id)
    end

    # 24a: na atualização, registration_id + version (o cadastro que o usuário
    # lê: reads_registration?, senão not_found); household_client_uuid e
    # patient_client_uuid pelo livro (Q27).
    def registration(body, context, shown)
      refusal = registry_refusal(context)
      return refusal if refusal

      user = context[:user]
      params, missing = cite(body, user)
      return missing if missing

      registration = nil
      if params.key?("registration_id")
        registration = IndividualRegistration.includes(:team, :micro_area).find_by(id: params["registration_id"])
        return rejected("not_found", "registration_id") unless registration && TerritoryRegistry::Access.reads_registration?(user, registration)
      end
      result = TerritoryRegistry::SaveRegistration.call(params: params.except("registration_id"), by: user, registration: registration)
      if result.failure?
        return stale_registration(registration) if result.reason == :stale_version && registration
        # Q63 b: cadastro novo cujo domicílio mudou depois da leitura.
        return rejected("household_changed", "household_id") if result.reason == :stale_version
        return already_registered(result, user) if result.reason == :already_registered
        return registration_duplicate(params["new_patient"], shown) if result.reason == :duplicate_suspected && params["new_patient"].is_a?(Hash)

        return failure(result)
      end

      accepted(result.payload[:registration].id)
    end

    # --- apoio -------------------------------------------------------------------

    # household e individual_registration: territory_registry utilizável e só
    # o ACS (W-9; Q11).
    def registry_refusal(context)
      return rejected("feature_disabled") unless context[:registry]

      rejected("cbo_not_allowed") unless context[:acs]
    end

    # Q27: patient_client_uuid → patient_id e household_client_uuid →
    # household_id pelo livro. -> [params, nil] | [nil, rejected]
    def cite(body, user)
      params = body.dup
      %w[patient household].each do |kind|
        key = "#{kind}_client_uuid"
        next unless params.key?(key)

        id = cited_id(params.delete(key), kind, user)
        return [ nil, rejected("not_found", key) ] unless id

        params["#{kind}_id"] = id
      end
      [ params, nil ]
    end

    def cited_id(uuid, item_type, user) = FieldSyncReceipt.where(client_uuid: uuid, item_type: item_type, user_id: user.id).pick(:result_id)

    def acs?(user)
      return false unless user&.professional

      HealthTeamMember.active.joins(:health_team)
                      .where(professional_id: user.professional.id, cbo_code: HomeVisits::Catalog::ACS_CBO,
                             health_teams: { active: true, kind: TerritoryRegistry::Catalog::TEAM_KINDS })
                      .exists?
    end

    def stale_household(household)
      household.reload
      version = HouseholdVersion.find_by!(household_id: household.id, version: household.version)
      families = Family.where(household_id: household.id).includes(:responsible_patient).order(:created_at, :id).to_a
      exited = TerritoryRegistry::Families.responsible_exited_ids(families)
      current = TerritoryRegistry::Json.household(household, version, families: families, exited: exited, full: true)
      { status: "stale_version", id: household.id, current_version: household.version, current: current, receipt: false,
        viewed: { household_ids: [ household.id ], patient_ids: families.map(&:responsible_patient_id).compact } }
    end

    def stale_registration(registration)
      registration.reload
      version = IndividualRegistrationVersion.find_by!(registration_id: registration.id, version: registration.version)
      locked = Patients::Pairs.patient_ids_with_pairs([ registration.patient ]).include?(registration.patient_id)
      current = TerritoryRegistry::Json.registration(registration, version, identity_locked: locked)
      { status: "stale_version", id: registration.id, current_version: registration.version, current: current, receipt: false,
        viewed: { household_ids: [ registration.household_id ].compact, patient_ids: [ registration.patient_id ] } }
    end

    # O SaveRegistration recusa o duplicado sem candidatos; o app não tem a
    # busca do 24a, então eles vão no resultado (forma `candidate` com o
    # registration_id, Q26), com a trilha.
    def registration_duplicate(typed, shown)
      strings = %w[full_name birth_date mother_name cpf].map { |key| typed[key] }
      patients = Patients::Duplicates.call(full_name: strings[0], birth_date: strings[1], mother_name: strings[2],
                                           limit: HomeVisits::People::CANDIDATES_MAX, only_without_cpf: strings[3].present?)
                                     .first(HomeVisits::People::CANDIDATES_MAX)
      shown.ids.concat(patients.map(&:id))
      rejected("duplicate_suspected", "new_patient", candidates: patients.map { |patient| HomeVisits::People.candidate(patient, registration: true) })
    end

    # Q63 c: o id do cadastro ativo só quando ele está no escopo do aparelho
    # (6A: as microáreas que o aparelho baixa, HomeVisits::Access.scope);
    # fora dele (ou fora de área), sem id.
    def already_registered(result, user)
      existing = IndividualRegistration.includes(:team).find_by(id: result.details[:registration_id])
      in_scope = existing&.micro_area_id && HomeVisits::Access.scope(user, existing.team)[:micro_area_ids].include?(existing.micro_area_id)
      rejected("already_registered", id: (existing.id if in_scope))
    end

    def trail!(context, candidate_ids, viewed)
      HomeVisits::People.candidates_viewed!(candidate_ids: candidate_ids.uniq, by: context[:user], trail: context[:trail]) if candidate_ids.any?
      context[:trail].records_viewed!(user: context[:user], **viewed) if viewed
    end

    def accepted(id, replayed: false) = { status: replayed ? "duplicate" : "accepted", id: id, receipt: true }

    # O código e o path do Result; candidates só no duplicate_suspected,
    # confirmable só no duplicate_participant (o resto dos details fica fora).
    def failure(result, path: nil)
      reason = result.reason.to_s
      rejected(reason, path || result.details[:path],
               candidates: (result.details[:candidates] if reason == "duplicate_suspected"),
               confirmable: (result.details[:confirmable] == true if reason == "duplicate_participant"))
    end

    # `id` só no already_registered (Q63 c; o esquema o proíbe nos outros).
    def rejected(error, path = nil, candidates: nil, confirmable: nil, id: nil)
      { status: "rejected", error: error, path: path.to_s.presence&.slice(0, PATH_MAX), candidates: candidates,
        confirmable: confirmable, id: (id if error == "already_registered"), receipt: false }
    end

    def result_json(uuid, type, outcome)
      json = { "client_uuid" => uuid, "status" => outcome[:status], "type" => type }
      case outcome[:status]
      when "accepted", "duplicate" then json["id"] = outcome[:id]
      when "stale_version"
        json.merge!("id" => outcome[:id], "current_version" => outcome[:current_version], "current" => outcome[:current])
      else
        json["error"] = outcome[:error]
        json["id"] = outcome[:id] if outcome[:id]
        json["path"] = outcome[:path] if outcome[:path]
        json["candidates"] = outcome[:candidates] if outcome[:candidates]
        json["confirmable"] = outcome[:confirmable] unless outcome[:confirmable].nil?
      end
      json.as_json
    end

    # --- item fora do esquema (Q31, Q32, Q46) ------------------------------------

    def invalid_item(item, errors)
      json = { "status" => "rejected", "error" => "invalid_request", "path" => schema_path(errors.first) }
      if item.is_a?(Hash)
        json = { "client_uuid" => item["client_uuid"] }.merge(json) if item["client_uuid"].is_a?(String) && item["client_uuid"].match?(UUID)
        json["type"] = item["type"] if Catalog::ITEM_TYPES.include?(item["type"])
      end
      json
    end

    # Ponteiro JSON do erro → notação do contrato, relativa ao body:
    #   /body/participants/1/new_patient → participants[1].new_patient;
    #   /client_uuid → client_uuid; /body → body.
    # `required` simples → o caminho do campo que falta (Q46); dentro de
    # oneOf/not, e o dependentRequired (par), → o caminho do objeto.
    def schema_path(error)
      segments = error[:pointer].to_s.split("/").drop(1).map { |part| part.gsub("~1", "/").gsub("~0", "~") }
      segments.pop if error[:type] == "dependentRequired"
      segments << error[:missing].first if error[:type] == "required" && error[:missing].any? && !error[:schema_pointer].match?(COMPOSITE)
      body = segments.first == "body"
      segments = segments.drop(1) if body
      path = segments.each_with_object(+"") do |part, out|
        if part.match?(/\A\d+\z/) then out << "[#{part}]"
        else out << (out.empty? ? part : ".#{part}")
        end
      end
      path.presence&.slice(0, PATH_MAX) || "body"
    end

    def invalid_envelope(path) = Result.fail(:invalid_request, details: { path: path })
    private_class_method :process, :lock!, :ledger, :dispatch, :home_visit, :withdrawal, :collective_activity, :patient, :household,
                         :registration, :registry_refusal, :cite, :cited_id, :acs?, :stale_household, :stale_registration,
                         :registration_duplicate, :already_registered, :trail!, :accepted, :failure, :rejected, :result_json, :invalid_item, :schema_path,
                         :invalid_envelope
  end
end
