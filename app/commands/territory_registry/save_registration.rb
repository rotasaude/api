# Cadastro individual (contrato §5, §14 L4, L5, L7, L17; plano, Desvios 3, 5,
# 8 e 12; F-24.3). Toda gravação é uma IndividualRegistrationVersion imutável
# nova (version + 1) com as seções do corpo (nunca query), o retrato da
# identidade do paciente (TerritoryRegistry::Identity) e a ficha de cadastro
# individual; o cabeçalho IndividualRegistration aponta a última. PATCH exige
# `version` (a esperada; outra → stale_version); cadastro que saiu congela
# (invalid_transition).
#
#   - Pessoa (só no POST): patient_id | citizen_id (par validado →
#     Patients::Resolve; não validado → citizen_not_verified) | new_patient
#     (Patients::CreateTyped). No PATCH a pessoa é a do cadastro.
#   - Identidade (L4): `patient: { full_name, social_name, birth_date, sex,
#     mother_name }` só para paciente SEM par validado; com par validado,
#     valor diferente → identity_locked (os dados validados mandam). `cpf`
#     (paciente sem CPF) → Patients::AddCpf (cpf_taken); `cns` → no paciente
#     (cns_taken). `patient_demographics: { race_color, ethnicity }` →
#     Patients::Demographics, códigos do BPA (uma fonte por dado: o paciente);
#     etnia só fica com raça/cor 05 (L17: sem código LEDI → invalid_ethnicity).
#   - Onde (L7): household_id (+ family_id do domicílio, ativa; is_responsible
#     bate com o responsável) → microárea e equipe do domicílio; sem domicílio,
#     team_id (fora de área). Microárea inativa nunca é destino.
#   - Escopo: Access.registrar?(ficha: :individual) — out_of_scope |
#     cbo_not_allowed.
#   - Travas (Desvio 12): AddCpf (lock do CPF → pares → paciente) → paciente →
#     domicílio (FOR SHARE) → família (FOR SHARE) → cadastro. Um ativo por
#     paciente: checado sob a trava do paciente e, por último, pelo índice
#     único parcial (RecordNotUnique → already_registered, com o id do ativo).
#   - Endereço (Desvio 8): entrando num domicílio (criação ou troca), o
#     paciente recebe o endereço da última versão dele (update! direto, sob a
#     trava do paciente — o mesmo motivo do SaveHousehold).
#   - Validação no posto durante a gravação (AddCpf/Resolve → refresh!): a
#     IdentityRefresh fica suspensa — esta versão já leva a identidade
#     validada — e o cadastro ganha identity_changed_at.
#   - Ficha: Ledi::IndividualRegistrationFicha.generate dentro da transação
#     (sem identificador → "não gerada" patient_without_identifier, L5).
#   - Evento territory_registration.saved só com ids.
#
# `append!` grava uma versão derivada da última (troca de microárea do
# domicílio, IdentityRefresh, ExitRegistration), com a ficha.
module TerritoryRegistry
  module SaveRegistration
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    SECTIONS = %w[identification sociodemographic health_conditions street_situation].freeze
    IDENTITY_FIELDS = %w[full_name social_name birth_date sex mother_name].freeze
    DEMOGRAPHICS = %w[race_color ethnicity].freeze
    PERSON_KEYS = %w[patient_id citizen_id new_patient].freeze
    ONE_ACTIVE = "idx_individual_registrations_one_active".freeze
    CNS_INDEX = "idx_patients_cns".freeze
    INDIGENOUS = "05".freeze
    # O que a versão derivada copia da última.
    COPIED = %w[patient_id team_id micro_area_id household_id family_id is_responsible identification sociodemographic
                health_conditions street_situation refused].freeze

    # Desfaz a transação levando a recusa para fora.
    class Refused < StandardError
      attr_reader :result

      def initialize(result)
        @result = result
        super(result.reason.to_s)
      end
    end

    module_function

    def call(params:, by:, registration: nil)
      params = params.to_h.deep_stringify_keys
      parsed = parse(params, registration, by)
      return parsed if parsed.failure?

      refreshed = []
      IdentityRefresh.suppressing(refreshed) do
        ApplicationRecord.transaction(requires_new: true) { write(parsed.payload, registration, by, refreshed) }
      end
    rescue Refused => e
      e.result
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?(ONE_ACTIVE)

      Result.fail(:already_registered, details: { registration_id: active_id(parsed.payload) }.compact)
    end

    # Nova versão a partir da última (mesmas seções), com `changes` na versão
    # e `header` no cabeçalho; o retrato da identidade é o do paciente agora.
    # Quem chama trava o paciente e o cadastro. Gera a ficha.
    def append!(registration, origin:, saved_by_user_id:, saved_by_professional_id:, saved_cbo:, changes: {}, header: {}, at: Time.current)
      latest = registration.latest_version
      attrs = COPIED.to_h { |column| [ column, latest.public_send(column) ] }
      version = IndividualRegistrationVersion.create!(
        attrs.merge("registration_id" => registration.id, "version" => registration.version + 1, "origin" => origin,
                    "identity" => Identity.snapshot(registration.patient), "saved_by_user_id" => saved_by_user_id,
                    "saved_by_professional_id" => saved_by_professional_id, "saved_cbo" => saved_cbo, "created_at" => at)
             .merge(changes.stringify_keys)
      )
      registration.update!(header.merge(version: version.version))
      Ledi::IndividualRegistrationFicha.generate(version)
      version
    end

    # --- validação sem transação --------------------------------------------

    def parse(params, registration, by)
      expected = params["version"]
      return invalid("version") if registration && !expected.is_a?(Integer)
      return Result.fail(:invalid_transition) if registration&.exited?

      person = parse_person(params, registration)
      return person if person.failure?

      flags = parse_flags(params)
      return flags if flags.failure?

      place = parse_place(params, registration)
      return place if place.failure?

      area = place.payload[:area]
      team = place.payload[:team]
      scope = Access.registrar?(by, team, ficha: :individual, micro_area: area)
      return Result.fail(scope) unless scope == :ok
      # Microárea inativa nunca é destino (cadastro novo ou que muda de lugar).
      return invalid("micro_area_id") if area && !area.active && registration&.micro_area_id != area.id

      sections = parse_sections(params)
      return sections if sections.failure?

      identity = parse_identity(params, person.payload)
      return identity if identity.failure?

      demographics = parse_demographics(params["patient_demographics"])
      return demographics if demographics.failure?

      Result.ok(person.payload.merge(flags.payload, place.payload, sections.payload, identity.payload, demographics.payload,
                                     cbo: Access.membership(by, team).cbo_code, expected: expected))
    end

    def parse_person(params, registration)
      given = PERSON_KEYS.select { |key| params.key?(key) && !params[key].nil? }
      if registration
        extra = (given - [ "patient_id" ]).first
        return invalid(extra) if extra
        return invalid("patient_id") if given.any? && params["patient_id"] != registration.patient_id

        return Result.ok(person: :patient, patient_id: registration.patient_id)
      end
      return invalid(given.second || "patient_id") unless given.one?

      key = given.first
      value = params[key]
      case key
      when "patient_id"
        uuid?(value) && Patient.exists?(id: value) ? Result.ok(person: :patient, patient_id: value) : invalid(key)
      when "citizen_id"
        citizen = uuid?(value) && Citizen.find_by(id: value)
        citizen ? Result.ok(person: :citizen, citizen: citizen) : invalid(key)
      else
        value.is_a?(Hash) ? Result.ok(person: :new, new_patient: value) : invalid(key)
      end
    end

    def parse_flags(params)
      refused = params.fetch("refused", false)
      return invalid("refused") unless [ true, false ].include?(refused)

      responsible = params.fetch("is_responsible", false)
      return invalid("is_responsible") unless [ true, false ].include?(responsible)

      Result.ok(refused: refused, is_responsible: responsible)
    end

    # Domicílio (+ família) ou, sem domicílio, a equipe (fora de área, L7).
    def parse_place(params, registration)
      household_id = params["household_id"]
      family_id = params["family_id"]
      return invalid("family_id") unless family_id.nil? || uuid?(family_id)

      if household_id.nil?
        return invalid("family_id") if family_id
        team = uuid?(params["team_id"]) && HealthTeam.find_by(id: params["team_id"], active: true, kind: Catalog::TEAM_KINDS)
        return invalid("team_id") unless team

        return Result.ok(household: nil, family_id: nil, area: nil, team: team)
      end

      household = uuid?(household_id) && Household.includes(micro_area: :team).find_by(id: household_id)
      return invalid("household_id") unless household
      # Domicílio inativo não recebe morador novo.
      return invalid("household_id") if household.status != "active" && registration&.household_id != household.id

      area = household.micro_area
      return invalid("team_id") if !params["team_id"].nil? && params["team_id"] != area.team_id

      Result.ok(household: household, family_id: family_id, area: area, team: area.team)
    end

    def parse_sections(params)
      values = {}
      SECTIONS.each do |name|
        parsed = Dictionary.parse(name, params[name], prefix: name)
        return parsed if parsed.failure?

        values[name.to_sym] = parsed.payload[:values]
      end
      Result.ok(sections: values)
    end

    # `patient` (identidade digitada de paciente existente) e `cpf`/`cns` na
    # raiz; com new_patient, tudo vai dentro dele.
    def parse_identity(params, person)
      if person[:person] == :new
        %w[patient cpf cns].each { |key| return invalid(key) unless params[key].nil? }
        return Result.ok(identity: {}, cpf: nil, cns: nil)
      end

      raw = params["patient"]
      return invalid("patient") unless raw.nil? || raw.is_a?(Hash)

      identity = {}
      (raw || {}).each do |key, value|
        return invalid("patient.#{key}") unless IDENTITY_FIELDS.include?(key) && (value.nil? || value.is_a?(String))

        identity[key] = value&.squish.presence
      end
      checked = check_identity(identity)
      return checked if checked.failure?

      %w[cpf cns].each { |key| return invalid(key) unless params[key].nil? || params[key].is_a?(String) }
      cpf = params["cpf"].presence && CitizenIdentity::Cpf.normalize(params["cpf"])
      return invalid("cpf") if params["cpf"].present? && cpf.nil?

      cns = params["cns"]&.delete(" ").presence
      return invalid("cns") if cns && !Professionals::Cns.valid?(cns)

      Result.ok(identity: identity, cpf: cpf, cns: cns)
    end

    # As mesmas regras do Patients::CreateTyped (o "Validar nome" do LEDI).
    def check_identity(identity)
      at = ->(key) { invalid("patient.#{key}") }
      return at["full_name"] if identity.key?("full_name") && !Dictionary.valid_name?(identity["full_name"])
      if identity["social_name"] && identity["social_name"].length > Patients::CreateTyped::SOCIAL_NAME_MAX
        return at["social_name"]
      end
      if identity.key?("birth_date")
        birth = Patients::MatchKey.iso_date(identity["birth_date"])
        return at["birth_date"] if birth.nil? || Date.iso8601(birth) > Time.zone.today

        identity["birth_date"] = birth
      end
      return at["sex"] if identity.key?("sex") && !Citizen::SEXES.include?(identity["sex"])
      return at["mother_name"] if identity["mother_name"] && !Dictionary.valid_name?(identity["mother_name"])

      Result.ok
    end

    def parse_demographics(raw)
      return Result.ok(demographics: {}) if raw.nil?
      return invalid("patient_demographics") unless raw.is_a?(Hash)

      unknown = (raw.keys - DEMOGRAPHICS).first
      return invalid("patient_demographics.#{unknown}") if unknown

      parsed = Patients::Demographics.parse(raw)
      return demographics_failure(parsed) if parsed.failure?

      Result.ok(demographics: parsed.payload[:values])
    end

    # --- gravação (transação) -----------------------------------------------

    def write(attrs, registration, by, refreshed)
      patient = person!(attrs, registration, by)
      add_cpf!(patient, attrs[:cpf], by)
      patient.lock!
      household = attrs[:household] && Household.lock("FOR SHARE").find(attrs[:household].id)
      family = attrs[:family_id] && Family.lock("FOR SHARE").find_by(id: attrs[:family_id])
      if registration
        registration.lock!
        refuse!(Result.fail(:invalid_transition)) if registration.exited?
        refuse!(Result.fail(:stale_version)) if registration.version != attrs[:expected]
      else
        active = IndividualRegistration.active_registrations.where(patient_id: patient.id).pick(:id)
        refuse!(Result.fail(:already_registered, details: { registration_id: active })) if active
      end

      check_family!(family, household, patient, attrs) if attrs[:family_id]
      identity!(patient, attrs[:identity])
      cns!(patient, attrs[:cns])
      demographics = final_demographics(patient, attrs[:demographics])
      ruled = Rules.individual(attrs[:sections].merge(refused: attrs[:refused], is_responsible: attrs[:is_responsible]),
                               person: person_facts(patient).merge(demographics.to_h.symbolize_keys), on: Time.zone.today)
      refuse!(request_path(ruled, attrs)) if ruled.failure?
      save_demographics!(patient, demographics) if demographics

      moved_in = household && registration&.household_id != household.id
      registration, version = persist!(attrs, registration, patient, household, family, by, refreshed.include?(patient.id))
      copy_address!(patient, household) if moved_in
      Ledi::IndividualRegistrationFicha.generate(version)
      DomainEvents.publish("territory_registration.saved", registration_id: registration.id, registration_version_id: version.id,
                                                           patient_id: patient.id, user_id: by.id)
      Result.ok(registration: registration, version: version)
    end

    def person!(attrs, registration, by)
      return Patient.find(registration.patient_id) if registration

      case attrs[:person]
      when :patient then Patient.find(attrs[:patient_id])
      when :citizen
        resolved = Patients::Resolve.call(attrs[:citizen])
        refuse!(resolved) if resolved.failure?
        resolved.payload[:patient]
      else
        created = Patients::CreateTyped.call(attrs: attrs[:new_patient].to_h, by: by)
        refuse!(typed_failure(created)) if created.failure?
        created.payload[:patient]
      end
    end

    # CPF que o paciente sem CPF ganha agora (o mesmo CPF dele: nada a fazer).
    def add_cpf!(patient, cpf, by)
      return if cpf.nil? || patient.cpf == cpf

      added = Patients::AddCpf.call(patient: patient, cpf: cpf, by: by)
      return if added.ok?

      refuse!(added.reason == :cpf_taken ? added : invalid("cpf"))
    end

    def check_family!(family, household, patient, attrs)
      refuse!(invalid("family_id")) unless family && family.household_id == household.id && !family.moved_out
      refuse!(invalid("is_responsible")) unless attrs[:is_responsible] == (family.responsible_patient_id == patient.id)
    end

    # L4: com par validado os dados validados mandam (só leitura); sem par, a
    # identidade digitada vai para o paciente (sob a trava dele).
    def identity!(patient, identity)
      return if identity.empty?

      if Patients::Pairs.of(patient).exists?
        key = identity.keys.find { |field| identity[field] != current_identity(patient, field) }
        refuse!(Result.fail(:identity_locked, details: { path: "patient.#{key}" })) if key
        return
      end
      patient.update!(identity)
    end

    def current_identity(patient, field)
      value = patient.public_send(field)
      field == "birth_date" ? Patients::MatchKey.iso_date(value) : value
    end

    def cns!(patient, cns)
      return if cns.nil? || patient.cns == cns

      refuse!(Result.fail(:cns_taken)) if Patient.where(cns: cns).where.not(id: patient.id).exists?
      ApplicationRecord.transaction(requires_new: true) { patient.update!(cns: cns) }
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?(CNS_INDEX)

      refuse!(Result.fail(:cns_taken))
    end

    # Raça/cor e etnia que o paciente terá (nil sem patient_demographics): a
    # etnia só fica com raça/cor 05 (L17: com outra, não vai na ficha nem
    # recusa). A regra da ficha (Rules.individual) confere a combinação antes
    # de gravar — 05 sem etnia com código LEDI → invalid_ethnicity.
    def final_demographics(patient, given)
      return nil if given.empty?

      final = Patients::Demographics.current(patient).slice(*DEMOGRAPHICS).merge(given)
      final["ethnicity"] = nil unless final["race_color"] == INDIGENOUS
      final
    end

    def save_demographics!(patient, values)
      saved = Patients::Demographics.save!(patient, values)
      refuse!(demographics_failure(saved)) if saved.failure?
    end

    def person_facts(patient)
      { sex: patient.sex, birth_date: patient.birth_date, race_color: patient.race_color, ethnicity: patient.ethnicity,
        has_cpf: patient.cpf.present?, mother_name_present: patient.mother_name.present? }
    end

    def persist!(attrs, registration, patient, household, family, by, identity_changed)
      now = Time.current
      area = attrs[:area]
      team = attrs[:team]
      registration ||= IndividualRegistration.new(patient: patient, version: 0)
      registration.assign_attributes(
        team: team, micro_area: area, household: household, family: family, is_responsible: attrs[:is_responsible],
        refused: attrs[:refused].to_s, version: registration.version + 1, registered_at: now, registered_by_user: by
      )
      registration.identity_changed_at = now if identity_changed
      ApplicationRecord.transaction(requires_new: true) { registration.save! }
      sections = attrs[:sections]
      version = IndividualRegistrationVersion.create!(
        registration: registration, version: registration.version, patient: patient, team: team, micro_area: area, household: household,
        family: family, is_responsible: attrs[:is_responsible], identity: Identity.snapshot(patient),
        identification: sections[:identification] || {}, sociodemographic: sections[:sociodemographic],
        health_conditions: sections[:health_conditions], street_situation: sections[:street_situation], refused: attrs[:refused].to_s,
        origin: "save", saved_by_user: by, saved_by_professional: by.professional, saved_cbo: attrs[:cbo], created_at: now
      )
      [ registration, version ]
    end

    # Desvio 8: update! direto sob a trava do paciente (Demographics.save!
    # recusaria: o paciente já tem cadastro ativo no domicílio).
    def copy_address!(patient, household)
      latest = household.latest_version
      return if latest.address.blank?

      patient.update!(Address.to_patient(latest.address, neighborhood: latest.neighborhood))
    end

    # --- recusas ------------------------------------------------------------

    # As recusas do paciente digitado com o caminho do corpo (new_patient.*).
    def typed_failure(result)
      case result.reason
      when :invalid_patient then Result.fail(:invalid_registration, details: result.details)
      when :invalid_cpf then invalid("new_patient.cpf")
      when :invalid_cns then invalid("new_patient.cns")
      else result
      end
    end

    def demographics_failure(result)
      field = result.details[:field] || "race_color"
      reason = result.reason == :invalid_ethnicity ? :invalid_ethnicity : :invalid_registration
      Result.fail(reason, details: { path: "patient_demographics.#{field}" })
    end

    # Rules.individual fala de nascimento e mãe sem prefixo (moram no
    # paciente): o caminho do corpo é new_patient.<campo> ou patient.<campo>.
    def request_path(result, attrs)
      path = result.details[:path]
      return result unless %w[birth_date mother_name].include?(path)

      Result.fail(result.reason, details: { path: "#{attrs[:person] == :new ? 'new_patient' : 'patient'}.#{path}" })
    end

    def active_id(attrs)
      patient_id = attrs && attrs[:patient_id]
      patient_id && IndividualRegistration.active_registrations.where(patient_id: patient_id).pick(:id)
    end

    def refuse!(result) = raise(Refused, result)
    def invalid(path) = Result.fail(:invalid_registration, details: { path: path })
    def uuid?(value) = value.is_a?(String) && value.match?(UUID)
    private_class_method :parse, :parse_person, :parse_flags, :parse_place, :parse_sections, :parse_identity, :check_identity,
                         :parse_demographics, :write, :person!, :add_cpf!, :check_family!, :identity!, :current_identity, :cns!,
                         :final_demographics, :save_demographics!, :person_facts, :persist!, :copy_address!, :typed_failure, :demographics_failure,
                         :request_path, :active_id, :refuse!, :invalid, :uuid?
  end
end
