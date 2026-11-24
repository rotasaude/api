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
#    leva só a classe e o client_uuid (nunca a mensagem, o corpo ou pessoa); o
#    Rails.error, o InternalError (classe, frames do app, client_uuid).
#    stale_version só para domicílio ou cadastro que JÁ EXISTE; cadastro NOVO
#    cujo domicílio mudou → `rejected household_changed` (Q63 b).
#    already_registered leva o `id` do cadastro existente só quando ele está no
#    escopo do aparelho (6A; Q63 c). Q67: o item que roda a busca de
#    duplicados ou a checagem de CPF/CNS cobra o orçamento da busca de pessoa
#    (HomeVisits::SearchBudget); estourado → `rejected too_many_requests`, sem
#    path e fora do livro (o reenvio tenta de novo); os outros itens seguem.
#    Q68: o collective_activity cobra, em vez dele, N unidades do
#    CollectiveActivities::ParticipantBudget (no CollectiveActivities::Record).
# 4. DEPOIS da transação, com qualquer desfecho: a trilha clinical_record.viewed
#    (access field_sync, com o aparelho) dos candidatos do duplicado suspeito e
#    do `current` do stale_version. Os comandos recebem um coletor como `trail:`
#    para a trilha não ir embora com o rollback do item.
#
# Módulo 24c (ADR 0053; contrato §2–§4):
#   - item `family` (TerritoryRegistry::SaveFamily; só o ACS): domicílio por
#     `household_id` ou `household_client_uuid`, responsável aninhado por
#     `patient_id` ou `patient_client_uuid` (Q1); `version` é a do domicílio, e
#     vencida volta `stale_version` com o <household> atual e `id` = o
#     domicílio (Q4); `family_id` de outro domicílio → `family_not_found`;
#   - citações: `family_client_uuid` (visita e cadastro) e `patient_client_uuid`
#     resolvido pelo recibo de `patient` ou de `individual_registration` — o
#     client_uuid do cadastro vale pelo paciente dele (Q26, Q51);
#   - erro de esquema sob `/body/location` → `rejected invalid_location`, com o
#     mesmo path que o invalid_request teria (Q2);
#   - `version` no resultado: a versão que o domicílio (household e family) ou o
#     cadastro ficou, gravada no livro (`result_version`); o `duplicate` devolve
#     a do livro, e o recibo anterior à coluna sai sem ela (Q5).
#
# Módulo 35a (ADR 0054; contrato §13; Q6, Q7, Q10, Q13(2); CV-3, CV-4, CV-9):
#   - home_visit: o gate vector_control (lido aqui, fora da transação) vai ao
#     HomeVisits::Record (`vector_control:`); aceito ou duplicate com boletim →
#     `vector_inspection_id` (lido por VectorInspection.where(home_visit_id:));
#     erro de esquema sob /body/vector_inspection → `rejected
#     vector_inspection_invalid` com o mesmo path (CV-4);
#   - ovitrap_installation (VectorControl::InstallOvitrap) e ovitrap_collection
#     (VectorControl::CollectOvitrap), origin field_app com o aparelho, só do
#     agente de endemias com o gate (feature_disabled, cbo_not_allowed); o `id`
#     dos dois é o da ovitrampa (W-9, Q7(2)); `ovitrap_client_uuid` cita a
#     instalação aceita antes, no mesmo lote ou em outro (os itens vão em
#     ordem, Q10); `reinstall` é ignorado com `remove: true` (Q7(5));
#     reinstall false sem remove → rejected invalid_request path reinstall (Q33).
#
# Módulo 35b (ADR 0054; contrato §11, §12; Q19, Q20, Q21, Q22, Q29, Q36), só
# com Zoonoses::Gate.field_usable? (lido aqui, fora da transação; senão
# `rejected feature_disabled`) e só o ACS ou o ACE (cbo_not_allowed; a coleta,
# só o ACE):
#   - animal (Zoonoses::SaveAnimal, origin field): o corpo inteiro (Q20; a
#     chave opcional ausente vale nula); criação sem animal_id, edição com
#     animal_id + version (→ expected_version), do animal cujo domicílio atual
#     o agente alcança (senão out_of_scope; desconhecido → not_found
#     animal_id); status_on é do api (o dia da gravação). Tutor por
#     tutor_patient_id ou tutor_client_uuid: o paciente de um `patient` ou de
#     um `individual_registration` com new_patient aceito antes (Q29; senão
#     `tutor_not_found` path tutor_client_uuid). accepted com `version`; edição
#     vencida → stale_version com o <animal> atual (Json.animal_bodies), sem
#     mescla, e a trilha do tutor mostrado;
#   - rabies_vaccination (Zoonoses::RecordVaccination, modalidade house),
#     leish_collection (Zoonoses::RecordLeishTest, origin field; `label` no
#     accepted e no duplicate, Q21) e collar (Zoonoses::PlaceCollar, origin
#     field) citam o animal por animal_id ou animal_client_uuid (o livro);
#     produto sem a finalidade → `product_not_allowed` path vector_product_id
#     (README v1.4.0). A falta de estoque não é recusa (§3); a segunda dose na
#     campanha só o api barra (Q19).
#
# Nada de nome, CPF, CNS, motivo, medida, observação ou coordenada no resultado
# de erro, no log ou em evento: só código, path, ids e a forma
# `candidate`/`current` do 24a.
module FieldSync
  module Upload
    ITEM_REF = "#/$defs/item".freeze
    # A do esquema (minúsculas): o uuid inválido não volta no resultado.
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
    PATH_MAX = 128
    RESULT_TYPES = { "home_visit" => "HomeVisit", "home_visit_withdrawal" => "HomeVisit",
                     "collective_activity" => "CollectiveActivity", "patient" => "Patient", "household" => "Household",
                     "individual_registration" => "IndividualRegistration", "family" => "Family",
                     "ovitrap_installation" => "Ovitrap", "ovitrap_collection" => "Ovitrap",
                     "animal" => "Animal", "rabies_vaccination" => "RabiesVaccination", "leish_collection" => "LeishTest",
                     "collar" => "Collar" }.freeze
    # Q26, Q51: quem cita uma pessoa pode citar o item que a registrou ou o cadastro dela.
    PERSON_ITEMS = %w[patient individual_registration].freeze
    # Citações pelo livro (Q27; family no 24c; ovitrap no 35a): <tipo>_client_uuid
    # → <tipo>_id, pelo recibo de um destes itens.
    CITATIONS = { "patient" => PERSON_ITEMS, "household" => %w[household], "family" => %w[family],
                  "ovitrap" => %w[ovitrap_installation], "animal" => %w[animal] }.freeze
    # Os itens do 35b com produto (a recusa product_not_allowed).
    PRODUCT_ITEMS = %w[rabies_vaccination collar].freeze
    # O corpo inteiro do animal (Q20): ausente = nulo.
    ANIMAL_OPTIONAL = %w[name size coat breed birth_estimate_month tutor_patient_id].freeze
    LOCATION_POINTER = %r{\A/body/location(/|\z)}
    VECTOR_POINTER = %r{\A/body/vector_inspection(/|\z)}
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

    # B-M4: o que vai ao Rails.error de um internal_error — a classe, os
    # primeiros frames do app (caminho relativo, linha e método, pelo
    # backtrace_locations) e, no contexto, o client_uuid. Nunca a mensagem (pode
    # trazer valor do corpo) nem a causa (nasce sem raise, então sem `cause`).
    class InternalError < StandardError
      FRAMES = 5
      APP_DIRS = %w[app/ lib/].freeze

      def self.from(error)
        root = "#{Rails.root}/"
        frames = Array(error.backtrace_locations).filter_map do |location|
          path = (location.absolute_path || location.path).to_s.delete_prefix(root)
          "#{path}:#{location.lineno}:in '#{location.label}'" if path.start_with?(*APP_DIRS)
        end
        new(error.class.name).tap { |wrapper| wrapper.set_backtrace(frames.first(FRAMES)) }
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
                  endemic: VectorControl::Access.field_agent_somewhere?(user),
                  collective: CollectiveActivities::Gate.usable?(Current.city),
                  registry: TerritoryRegistry::Gate.usable?(Current.city),
                  vector: VectorControl::Gate.usable?(Current.city),
                  zoonoses: Zoonoses::Gate.field_usable?(Current.city) }
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
                                   result_version: outcome[:version], field_device: context[:device], user: context[:user])
        end
      rescue StandardError => e
        # Q63 a: só a classe e o client_uuid (a mensagem pode trazer valor do
        # corpo); B-M4: ao Rails.error, o InternalError sanitizado.
        Rails.logger.error("[field_sync.upload] internal_error class=#{e.class.name} client_uuid=#{uuid}")
        Rails.error.report(InternalError.from(e), handled: true, source: "field_sync.upload",
                                                  context: { client_uuid: uuid, error_class: e.class.name })
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

      # A versão daquele recebimento (Q5): nula no recibo anterior à coluna e nos tipos sem versão.
      { status: "duplicate", id: receipt.result_id, version: receipt.result_version, receipt: false,
        vector_inspection_id: (inspection_id(receipt.result_id) if type == "home_visit"),
        label: (LeishTest.where(id: receipt.result_id).pick(:label) if type == "leish_collection") }
    end

    def dispatch(type, uuid, body, context, shown)
      case type
      when "home_visit" then home_visit(uuid, body, context, shown)
      when "home_visit_withdrawal" then withdrawal(body, context)
      when "collective_activity" then collective_activity(uuid, body, context, shown)
      when "patient" then patient(body, context, shown)
      when "household" then household(body, context)
      when "individual_registration" then registration(body, context, shown)
      when "family" then family(body, context)
      when "ovitrap_installation" then ovitrap_installation(uuid, body, context)
      when "ovitrap_collection" then ovitrap_collection(body, context)
      when "animal" then animal(body, context)
      when "rabies_vaccination" then rabies_vaccination(uuid, body, context)
      when "leish_collection" then leish_collection(uuid, body, context)
      when "collar" then collar(uuid, body, context)
      else raise ArgumentError, "type fora do esquema"
      end
    end

    # --- tipos -------------------------------------------------------------------

    def home_visit(uuid, body, context, shown)
      params, missing = cite(body, context[:user])
      return missing if missing

      result = HomeVisits::Record.call(params: params.merge("client_uuid" => uuid), by: context[:user], origin: "field_app",
                                       device: context[:device], trail: shown, vector_control: context[:vector] == true)
      return failure(result) if result.failure?

      visit = result.payload[:visit]
      accepted(visit.id, replayed: result.payload[:replayed], vector_inspection_id: inspection_id(visit.id))
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

          id = cited_patient_id(participant["patient_client_uuid"], context[:user])
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
      refusal = registry_refusal(context, type: "household")
      return refusal if refusal

      user = context[:user]
      vector = context[:vector] == true
      household = nil
      if body.key?("household_id")
        household = Household.includes(micro_area: :team).find_by(id: body["household_id"])
        visible = household && TerritoryRegistry::Access.visible_micro_area_ids(user, household.micro_area.team, vector_control: vector)
                                                        .include?(household.micro_area_id)
        return rejected("not_found", "household_id") unless visible
      end
      result = TerritoryRegistry::SaveHousehold.call(params: body.except("household_id"), by: user, household: household, vector_control: vector)
      return stale_household(household, context) if result.failure? && result.reason == :stale_version && household
      return failure(result) if result.failure?

      accepted(result.payload[:household].id, version: result.payload[:household].version)
    end

    # 24c: família do domicílio (SaveFamily). O domicílio vem pelo id ou pelo
    # livro, e só vale na microárea que o usuário cadastra; o responsável, pelo
    # id ou pelo livro (Q26). `version` é a do domicílio: vencida → o
    # stale_version do domicílio (Q4). Aceito → a versão nova do domicílio.
    def family(body, context)
      refusal = registry_refusal(context, type: "family")
      return refusal if refusal

      user = context[:user]
      params, missing = cite(body.except("responsible"), user)
      return missing if missing

      household = Household.includes(micro_area: :team).find_by(id: params["household_id"])
      visible = household && TerritoryRegistry::Access.visible_micro_area_ids(user, household.micro_area.team).include?(household.micro_area_id)
      return rejected("not_found", "household_id") unless visible

      responsible = body["responsible"]
      if responsible.is_a?(Hash) && responsible.key?("patient_client_uuid")
        patient_id = cited_patient_id(responsible["patient_client_uuid"], user)
        return rejected("not_found", "responsible.patient_client_uuid") unless patient_id

        responsible = { "patient_id" => patient_id }
      end

      existing = nil
      if params.key?("family_id")
        existing = Family.find_by(id: params["family_id"], household_id: household.id)
        return rejected("family_not_found", "family_id") unless existing
      end

      result = TerritoryRegistry::SaveFamily.call(household: household, by: user, family: existing,
                                                  params: params.except("household_id", "family_id").merge({ "responsible" => responsible }.compact))
      return stale_household(household, context) if result.failure? && result.reason == :stale_version
      return failure(result) if result.failure?

      accepted(result.payload[:family].id, version: result.payload[:household].version)
    end

    # 24a: na atualização, registration_id + version (o cadastro que o usuário
    # lê: reads_registration?, senão not_found); household_client_uuid e
    # patient_client_uuid pelo livro (Q27).
    def registration(body, context, shown)
      refusal = registry_refusal(context, type: "individual_registration")
      return refusal if refusal

      user = context[:user]
      params, missing = cite(body, user)
      return missing if missing

      registration = nil
      if params.key?("registration_id")
        registration = IndividualRegistration.includes(:team, :micro_area).find_by(id: params["registration_id"])
        return rejected("not_found", "registration_id") unless registration && TerritoryRegistry::Access.reads_registration?(user, registration)
      end
      return rejected("too_many_requests") if person_search?(params) && !HomeVisits::SearchBudget.new(user).charge!

      result = TerritoryRegistry::SaveRegistration.call(params: params.except("registration_id"), by: user, registration: registration)
      if result.failure?
        return stale_registration(registration) if result.reason == :stale_version && registration
        # Q63 b: cadastro novo cujo domicílio mudou depois da leitura.
        return rejected("household_changed", "household_id") if result.reason == :stale_version
        return already_registered(result, user) if result.reason == :already_registered
        return registration_duplicate(params["new_patient"], shown) if result.reason == :duplicate_suspected && params["new_patient"].is_a?(Hash)

        return failure(result)
      end

      accepted(result.payload[:registration].id, version: result.payload[:registration].version)
    end

    # Módulo 35a (§6, §13; Q13(2)): a instalação pelo domicílio do id ou do
    # livro (household_client_uuid); o client_uuid do item é o da ovitrampa.
    def ovitrap_installation(uuid, body, context)
      refusal = vector_refusal(context)
      return refusal if refusal

      params, missing = cite(body, context[:user])
      return missing if missing

      result = VectorControl::InstallOvitrap.call(params: params.merge("client_uuid" => uuid), by: context[:user], origin: "field_app",
                                                  device: context[:device])
      return failure(result) if result.failure?

      accepted(result.payload[:ovitrap].id, replayed: result.payload[:replayed])
    end

    # A coleta pela ovitrampa do id ou do livro (ovitrap_client_uuid; falta →
    # not_found com o path da chave usada). O resultado leva o id da ovitrampa.
    def ovitrap_collection(body, context)
      refusal = vector_refusal(context)
      return refusal if refusal

      key = body.key?("ovitrap_client_uuid") ? "ovitrap_client_uuid" : "ovitrap_id"
      params, missing = cite(body, context[:user])
      return missing if missing

      ovitrap = Ovitrap.includes(household: :micro_area).find_by(id: params["ovitrap_id"])
      return rejected("not_found", key) unless ovitrap

      result = VectorControl::CollectOvitrap.call(ovitrap: ovitrap, params: params.except("ovitrap_id"), by: context[:user],
                                                  origin: "field_app", device: context[:device])
      return failure(result) if result.failure?

      accepted(ovitrap.id)
    end

    # Módulo 35b (§11, Q20, Q29): o animal pelo corpo inteiro. Na edição, o
    # animal cujo domicílio atual o agente alcança (o stale_version mostra o
    # tutor só a quem alcança); o SaveAnimal confere o domicílio de antes e o
    # de depois.
    def animal(body, context)
      refusal = zoonoses_refusal(context)
      return refusal if refusal

      user = context[:user]
      params, missing = cite(body.except("tutor_client_uuid"), user)
      return missing if missing

      if body.key?("tutor_client_uuid")
        tutor_id = cited_patient_id(body["tutor_client_uuid"], user)
        return rejected("tutor_not_found", "tutor_client_uuid") unless tutor_id

        params["tutor_patient_id"] = tutor_id
      end
      ANIMAL_OPTIONAL.each { |key| params[key] = nil unless params.key?(key) }

      existing = nil
      if params.key?("animal_id")
        existing = Animal.find_by(id: params["animal_id"])
        return rejected("not_found", "animal_id") unless existing
        return rejected("out_of_scope") unless field_household?(existing.household_id, user)

        params["expected_version"] = params.delete("version")
      end
      result = Zoonoses::SaveAnimal.call(params: params.except("animal_id", "status_on"), by: user, animal: existing, origin: "field")
      return stale_animal(existing) if result.failure? && result.reason == :animal_changed
      return failure(result) if result.failure?

      saved = result.payload[:animal]
      accepted(saved.id, version: saved.version)
    end

    def rabies_vaccination(uuid, body, context)
      refusal = zoonoses_refusal(context)
      return refusal if refusal

      params, missing = cite(body, context[:user])
      return missing if missing

      result = Zoonoses::RecordVaccination.call(params: params.merge("modality" => "house", "client_uuid" => uuid), by: context[:user],
                                                origin: "field", zoonoses_field: context[:zoonoses] == true)
      return zoonoses_failure("rabies_vaccination", result) if result.failure?

      accepted(result.payload[:vaccination].id)
    end

    # Só o ACE (a regra fina, ACS no escopo → cbo_not_allowed, é do comando).
    def leish_collection(uuid, body, context)
      refusal = zoonoses_refusal(context, collector: true)
      return refusal if refusal

      params, missing = cite(body, context[:user])
      return missing if missing

      result = Zoonoses::RecordLeishTest.call(params: params.merge("client_uuid" => uuid), by: context[:user], origin: "field")
      return failure(result) if result.failure?

      test = result.payload[:test]
      accepted(test.id, label: test.label)
    end

    def collar(uuid, body, context)
      refusal = zoonoses_refusal(context)
      return refusal if refusal

      params, missing = cite(body, context[:user])
      return missing if missing

      result = Zoonoses::PlaceCollar.call(params: params.merge("client_uuid" => uuid), by: context[:user], origin: "field",
                                          zoonoses_field: context[:zoonoses] == true)
      return zoonoses_failure("collar", result) if result.failure?

      accepted(result.payload[:collar].id)
    end

    # --- apoio -------------------------------------------------------------------

    # Os itens do 35b: o gate de campo e só o ACS ou o ACE (a coleta, só o ACE).
    def zoonoses_refusal(context, collector: false)
      return rejected("feature_disabled") unless context[:zoonoses]
      return nil if context[:endemic]
      return nil if context[:acs] && !collector

      rejected("cbo_not_allowed")
    end

    # O produto sem a finalidade do item (ou desconhecido) → product_not_allowed (README v1.4.0).
    def zoonoses_failure(type, result)
      if PRODUCT_ITEMS.include?(type) && result.reason == :invalid_request && result.details[:path] == "vector_product_id"
        return rejected("product_not_allowed", "vector_product_id")
      end

      failure(result)
    end

    def field_household?(household_id, user)
      household = household_id && Household.includes(micro_area: :team).find_by(id: household_id)
      household.present? && Zoonoses::Access.field_agent?(user, household)
    end

    # O <animal> atual (Q20, D3), com a trilha do tutor mostrado.
    def stale_animal(animal)
      animal.reload
      current = Json.animal_bodies([ animal ]).fetch(animal.id)
      { status: "stale_version", id: animal.id, current_version: animal.version, current: current, receipt: false,
        viewed: (if current[:tutor]
                   { household_ids: [ animal.household_id ].compact, patient_ids: [ current.dig(:tutor, :patient_id) ] }
                 end) }
    end


    # Os itens de ovitrampa: gate utilizável e só o agente de endemias.
    def vector_refusal(context)
      return rejected("feature_disabled") unless context[:vector]

      rejected("cbo_not_allowed") unless context[:endemic]
    end

    def inspection_id(home_visit_id) = VectorInspection.where(home_visit_id: home_visit_id).pick(:id)

    # household, family e individual_registration: territory_registry
    # utilizável e só o ACS (W-9; Q11). Módulo 35a (Q13(1)): o item household
    # também do agente de endemias com vector_control utilizável (o
    # SaveHousehold recusa o residencial e a microárea não atribuída).
    def registry_refusal(context, type:)
      return rejected("feature_disabled") unless context[:registry]
      return nil if context[:acs]
      return nil if type == "household" && context[:endemic] && context[:vector]

      rejected("cbo_not_allowed")
    end

    # Q27: patient_client_uuid → patient_id, household_client_uuid →
    # household_id, (24c) family_client_uuid → family_id e (35a)
    # ovitrap_client_uuid → ovitrap_id, pelo livro.
    # -> [params, nil] | [nil, rejected]
    def cite(body, user)
      params = body.dup
      CITATIONS.each do |kind, item_types|
        key = "#{kind}_client_uuid"
        next unless params.key?(key)

        uuid = params.delete(key)
        id = kind == "patient" ? cited_patient_id(uuid, user) : cited_id(uuid, item_types, user)
        return [ nil, rejected("not_found", key) ] unless id

        params["#{kind}_id"] = id
      end
      [ params, nil ]
    end

    # Q67: o cadastro do 24a roda a busca de duplicados (new_patient) ou a
    # checagem de CPF/CNS (`cpf`/`cns` na raiz: Patients::AddCpf, cns_taken);
    # o paciente existente por patient_id sem documento novo não consome.
    def person_search?(params) = params["new_patient"].is_a?(Hash) || %w[cpf cns].any? { |key| params[key].present? }

    def cited_id(uuid, item_types, user) = FieldSyncReceipt.where(client_uuid: uuid, item_type: item_types, user_id: user.id).pick(:result_id)

    # Q26, Q51: o client_uuid de um item `patient` aceito vale pelo paciente
    # criado; o de um `individual_registration` aceito, pelo paciente daquele
    # cadastro (sem coluna nova no livro).
    def cited_patient_id(uuid, user)
      type, id = FieldSyncReceipt.where(client_uuid: uuid, item_type: PERSON_ITEMS, user_id: user.id).pick(:item_type, :result_id)
      return id if type == "patient"

      IndividualRegistration.where(id: id).pick(:patient_id) if type
    end

    def acs?(user)
      return false unless user&.professional

      HealthTeamMember.active.joins(:health_team)
                      .where(professional_id: user.professional.id, cbo_code: HomeVisits::Catalog::ACS_CBO,
                             health_teams: { active: true, kind: TerritoryRegistry::Catalog::TEAM_KINDS })
                      .exists?
    end

    # O `current` é o <household> do download (Json.household_body: sem a
    # família de responsável provisório da UPA, Q47; com `vector` só com o
    # gate, 35a), e a trilha lista só os responsáveis mostrados.
    def stale_household(household, context)
      household.reload
      families = Family.where(household_id: household.id).includes(:responsible_patient).order(:created_at, :id).to_a
      current = Json.household_body(household, families, vector_control: context[:vector] == true)
      { status: "stale_version", id: household.id, current_version: household.version, current: current, receipt: false,
        viewed: { household_ids: [ household.id ], patient_ids: Json.household_responsible_ids(current).compact } }
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

    # `version`: só household, family (a do domicílio), individual_registration
    # e animal; `vector_inspection_id`: só home_visit com boletim; `label`: só
    # leish_collection.
    def accepted(id, version: nil, replayed: false, vector_inspection_id: nil, label: nil)
      { status: replayed ? "duplicate" : "accepted", id: id, version: version, vector_inspection_id: vector_inspection_id, label: label,
        receipt: true }
    end

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
      when "accepted", "duplicate"
        json["id"] = outcome[:id]
        json["version"] = outcome[:version] if outcome[:version]
        json["vector_inspection_id"] = outcome[:vector_inspection_id] if outcome[:vector_inspection_id]
        json["label"] = outcome[:label] if outcome[:label]
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

    # Q2 (24c): quando o primeiro erro está sob /body/location, o código é
    # invalid_location e o path é o do erro mais fundo dali (o domicílio aceita
    # objeto ou null, e o json_schemer reporta os dois ramos). Módulo 35a
    # (CV-4, Q7(7)): o mesmo sob /body/vector_inspection, com o código
    # vector_inspection_invalid.
    def invalid_item(item, errors)
      error = errors.first
      code = "invalid_request"
      { LOCATION_POINTER => "invalid_location", VECTOR_POINTER => "vector_inspection_invalid" }.each do |pointer, name|
        next unless error[:pointer].to_s.match?(pointer)

        code = name
        error = errors.select { |e| e[:pointer].to_s.match?(pointer) }.max_by { |e| e[:pointer].to_s.count("/") }
        break
      end
      json = { "status" => "rejected", "error" => code, "path" => schema_path(error) }
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
                         :family, :registration, :ovitrap_installation, :ovitrap_collection, :animal, :rabies_vaccination,
                         :leish_collection, :collar, :zoonoses_refusal, :zoonoses_failure, :field_household?, :stale_animal, :vector_refusal, :inspection_id, :registry_refusal, :cite, :person_search?, :cited_id, :cited_patient_id, :acs?, :stale_household, :stale_registration,
                         :registration_duplicate, :already_registered, :trail!, :accepted, :failure, :rejected, :result_json, :invalid_item, :schema_path,
                         :invalid_envelope
  end
end
