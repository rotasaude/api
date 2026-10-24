# Domicílio (contrato §4, §14 L6/L7; plano, R3, R4 e Desvios 8, 9 e 12;
# F-24.4). Toda gravação é uma HouseholdVersion imutável nova (version + 1)
# com o corpo inteiro (nunca query), o retrato das famílias atuais e a ficha
# de cadastro domiciliar; o cabeçalho Household aponta a última. PATCH exige
# `version` (a esperada; outra → stale_version) e aceita `status`
# (active|inactive; inativo só sem família ativa, Desvio 9).
#
#   - Escopo: Access.registrar?(ficha: :household) na microárea de destino
#     (out_of_scope | cbo_not_allowed). Microárea inativa nunca é destino de
#     domicílio novo ou movido → invalid_household (micro_area_id).
#   - enderecoLocalPermanencia obrigatório sem recusa: `address` exigido com
#     refused false; limites do BPA (TerritoryRegistry::Address).
#   - Endereço nos moradores (Desvio 8): pacientes com cadastro ativo no
#     domicílio recebem o endereço da versão.
#   - Travas (Desvio 12): moradores (pacientes por id) → domicílio; relê os
#     moradores e recomeça (até 3 vezes) se o conjunto cresceu.
#   - Ficha: Ledi::HouseholdRegistrationFicha.generate dentro da transação
#     (sem exportação utilizável a versão grava e a ficha não nasce, L14).
#   - Evento household.saved só com ids.
#
# SaveFamily usa `call` com `lock_patient_ids:` (o responsável, travado com
# os moradores) e `before_version:` (grava a família depois das travas, antes
# do retrato); uma recusa do bloco desfaz tudo.
module TerritoryRegistry
  module SaveHousehold
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    MAX_ATTEMPTS = 3

    # Desfaz a transação (savepoint próprio) levando a recusa para fora.
    class Refused < StandardError
      attr_reader :result

      def initialize(result)
        @result = result
        super(result.reason.to_s)
      end
    end

    class ResidentsChanged < StandardError; end

    module_function

    def call(params:, by:, household: nil, lock_patient_ids: [], before_version: nil)
      params = params.to_h.stringify_keys
      parsed = parse(params, household, by)
      return parsed if parsed.failure?

      attempts = 0
      begin
        ApplicationRecord.transaction(requires_new: true) do
          write(parsed.payload, household, by, lock_patient_ids, before_version)
        end
      rescue Refused => e
        e.result
      rescue ResidentsChanged
        attempts += 1
        raise if attempts >= MAX_ATTEMPTS

        retry
      end
    end

    # O corpo de uma versão gravada (o mesmo formato do POST), para quem
    # regrava o domicílio sem mudar o conteúdo (SaveFamily).
    def params_of(household)
      version = household.latest_version
      { "micro_area_id" => household.micro_area_id, "property_type" => version.property_type, "refused" => version.refused?,
        "contact_phone" => version.contact_phone, "address" => version.address.presence,
        "living_conditions" => version.living_conditions.presence, "status" => household.status }.compact
    end

    # --- validação sem banco aberto em transação ----------------------------

    def parse(params, household, by)
      expected = params["version"]
      return invalid("version") if household && !expected.is_a?(Integer)

      area = uuid?(params["micro_area_id"]) && MicroArea.includes(:team).find_by(id: params["micro_area_id"])
      return invalid("micro_area_id") unless area

      scope = Access.registrar?(by, area.team, ficha: :household, micro_area: area)
      return Result.fail(scope) unless scope == :ok
      # Microárea inativa nunca é destino (domicílio novo ou movido).
      return invalid("micro_area_id") if !area.active && (household.nil? || household.micro_area_id != area.id)

      member = Access.membership(by, area.team)
      fields = parse_fields(params, household)
      return fields if fields.failure?

      Result.ok(fields.payload.merge(area: area, cbo: member.cbo_code, expected: expected))
    end

    def parse_fields(params, household)
      refused = params.fetch("refused", false)
      return invalid("refused") unless [ true, false ].include?(refused)

      type = params["property_type"]
      return invalid("property_type") unless type.is_a?(String)

      phone = params["contact_phone"]
      return invalid("contact_phone") unless phone.nil? || phone.is_a?(String)

      status = params.fetch("status", household&.status || "active")
      # status só no PATCH (L7); o domicílio nasce ativo.
      return invalid("status") unless Household::STATUSES.include?(status) && (household || status == "active")

      address = {}
      if !params["address"].nil? || !refused # enderecoLocalPermanencia: obrigatório sem recusa
        parsed = Address.parse(params["address"])
        return parsed if parsed.failure?

        address = parsed.payload[:values]
      end

      living = Dictionary.parse("living_conditions", params["living_conditions"], prefix: "living_conditions")
      return living if living.failure?

      Result.ok(property_type: type, refused: refused, contact_phone: phone.presence, status: status, address: address,
                living_conditions: living.payload[:values] || {})
    end

    # --- gravação (transação) -----------------------------------------------

    def write(attrs, household, by, lock_patient_ids, before_version)
      residents = lock!(household, lock_patient_ids)
      refuse!(Result.fail(:stale_version)) if household && household.version != attrs[:expected]

      if before_version
        outcome = before_version.call(household)
        refuse!(outcome) if outcome.is_a?(Result) && outcome.failure?
      end

      families = household ? Family.where(household_id: household.id).order(:created_at, :id).to_a : []
      active = families.reject(&:moved_out)
      checked = Rules.household(attrs.slice(:property_type, :living_conditions, :refused, :contact_phone),
                                families: active.map { |f| { members_count: f.members_count, responsible_patient_id: f.responsible_patient_id } })
      refuse!(checked) if checked.failure?
      # Domicílio inativo (Desvio 9): só com todas as famílias em mudança.
      refuse!(invalid("status")) if attrs[:status] == "inactive" && active.any?

      household, version = persist!(attrs, household, by, families)
      copy_address!(residents, attrs[:address], version.neighborhood) if attrs[:address].any?
      Ledi::HouseholdRegistrationFicha.generate(version)
      DomainEvents.publish("household.saved", household_id: household.id, household_version_id: version.id, user_id: by.id)
      Result.ok(household: household, version: version)
    end

    # Pacientes moradores (cadastro ativo no domicílio) + os pedidos, por id;
    # depois o domicílio (FOR UPDATE), e os moradores relidos. Morador novo
    # entre a leitura e a trava (sem trava) → recomeça. Quem saiu nesse meio
    # (mudou de domicílio — o SaveRegistration já lhe copiou o endereço novo
    # — ou teve saída) não recebe o endereço: só os que ainda moram.
    def lock!(household, extra_ids)
      return [] unless household # domicílio novo: sem moradores nem família

      ids = resident_ids(household)
      locked = Patient.where(id: (ids + extra_ids).uniq).order(:id).lock.to_a
      household.lock!
      current = resident_ids(household)
      raise ResidentsChanged unless (current - ids).empty?

      locked.select { |patient| current.include?(patient.id) }
    end

    def resident_ids(household)
      IndividualRegistration.active_registrations.where(household_id: household.id).pluck(:patient_id)
    end

    def persist!(attrs, household, by, families)
      now = Time.current
      area = attrs[:area]
      household ||= Household.new(version: 0)
      household.assign_attributes(micro_area: area, status: attrs[:status], version: household.version + 1, registered_at: now,
                                  registered_by_user: by)
      household.save!
      version = HouseholdVersion.create!(
        household: household, version: household.version, micro_area: area, team: area.team, property_type: attrs[:property_type],
        address: attrs[:address], living_conditions: attrs[:living_conditions], contact_phone: attrs[:contact_phone],
        refused: attrs[:refused].to_s, families_snapshot: families.map { |family| snapshot(family) }, status: attrs[:status],
        neighborhood_id: attrs[:address]["neighborhood_id"], origin: "save", saved_by_user: by,
        saved_by_professional: by.professional, saved_cbo: attrs[:cbo], created_at: now
      )
      [ household, version ]
    end

    def snapshot(family)
      { "family_id" => family.id, "responsible_patient_id" => family.responsible_patient_id, "income_band" => family.income_band,
        "members_count" => family.members_count, "living_since" => family.living_since, "moved_out" => family.moved_out }
    end

    # Desvio 8: update! direto, sob a trava do paciente (lock!), e NÃO
    # Patients::Demographics.save! — que recusa endereço de quem tem cadastro
    # ativo em domicílio (address_from_household): este é o único caminho que
    # grava esse endereço, e os limites já são os do BPA (Address.parse).
    def copy_address!(residents, address, neighborhood)
      values = Address.to_patient(address, neighborhood: neighborhood)
      residents.each { |patient| patient.update!(values) }
    end

    def refuse!(result) = raise(Refused, result)
    def invalid(path) = Result.fail(:invalid_household, details: { path: path })
    def uuid?(value) = value.is_a?(String) && value.match?(UUID)
    private_class_method :parse, :parse_fields, :write, :lock!, :resident_ids, :persist!, :snapshot, :copy_address!,
                         :refuse!, :invalid, :uuid?
  end
end
