# Cadastro e edição do animal (módulo 35b, ADR 0054; contrato §1, §2, Q20,
# Q22, Q31). Corpo: `species`, `sex` (obrigatórios na criação), `name`,
# `size`, `coat`, `breed`, `birth_estimate_on` ("AAAA-MM" ou "AAAA-MM-DD"; o
# app manda `birth_estimate_month` "AAAA-MM", Q20; o dia vira 1, nunca mês
# futuro), `microchip` (15 dígitos) e `registry_number` só na criação,
# `household_id` (domicílio ativo do 24a), `tutor_patient_id` (paciente
# existente, não fundido), `community`; na edição também `status` e o
# obrigatório `expected_version`. Toda recusa de campo é `invalid_request`
# com o `path`; texto longo é recusado, nunca cortado.
#
#   - Tutor só sem `community` (path community). Com domicílio, o animal pode
#     ficar sem tutor e sem community (tutor não identificado, Q22).
#   - Domicílio e tutor são conferidos quando mudam: o animal de domicílio que
#     ficou inativo continua editável.
#   - Situação (Q31): active → missing | transferred | deceased; missing →
#     active | deceased (senão 409 invalid_transition path status);
#     status_on = o informado (Task 17, fix round 1: a data do campo vale,
#     como as outras datas offline; só junto de `status`, senão path
#     status_on; aplicado só quando o status muda), entre o created_at do
#     animal (o dia da cidade) e hoje (senão date_out_of_range path
#     status_on); sem ele, hoje. Com estada aberta no canil, nenhuma
#     mudança de situação (409 invalid_transition path status, Task 8): a
#     morte no canil vai pela saída death e a transferência pela saída
#     transferred (Zoonoses::ExitShelter), senão a estada não fecharia.
#     A mudança para deceased tira a coleira ativa com removal_reason death
#     no status_on (a parte da coleira da Zoonoses::AnimalDeath; o animal já
#     está travado, animal → coleira; `collar.removed` só com o id).
#     transferred e deceased não se editam
#     (animal_not_active, conferido sob a trava, antes de gravar: o trigger
#     rota_animal_guard é o cinto).
#   - Concorrência: ausente → expected_version_required; diferente da version
#     → animal_changed. version + 1 a cada escrita que muda algo.
#   - origin "field" (o app, Task 17): o domicílio é obrigatório e o agente
#     precisa estar no escopo dele (Access.field_agent?), senão out_of_scope;
#     origin "dashboard": team?, senão missing_role.
#   - Duplicado pelo índice único (RecordNotUnique com o nome do índice):
#     microchip_taken / registry_number_taken, com o path.
#
# Eventos `animal.registered` / `animal.changed` só com animal_id. Nada do
# tutor nem do microchip em Result.details: só o path.
module Zoonoses
  module SaveAnimal
    CREATE_KEYS = %w[species name sex size coat breed birth_estimate_on birth_estimate_month microchip registry_number
                     household_id tutor_patient_id community].freeze
    CREATE_ONLY = %w[microchip registry_number].freeze
    EDIT_ONLY = %w[status status_on expected_version].freeze
    REQUIRED = %w[species sex].freeze
    ORIGINS = %w[dashboard field].freeze
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    MONTH = /\A(\d{4})-(\d{2})(?:-(\d{2}))?\z/
    DATE = /\A\d{4}-\d{2}-\d{2}\z/
    KEY_PATH_MAX = 64
    INDEXES = { "idx_animals_microchip" => [ :microchip_taken, "microchip" ],
                "idx_animals_registry_number" => [ :registry_number_taken, "registry_number" ] }.freeze
    TRANSITIONS = { "active" => %w[missing transferred deceased], "missing" => %w[active deceased] }.freeze
    INVALID = Object.new.freeze

    module_function

    # -> Result.ok(animal:) | fail(:invalid_request, details: { path: }) | fail(:microchip_taken | :registry_number_taken,
    #    details: { path: }) | fail(:expected_version_required, details: { path: "expected_version" }) |
    #    fail(:animal_changed | :animal_not_active | :out_of_scope | :missing_role) | fail(:invalid_transition, details: { path: "status" })
    #    | fail(:date_out_of_range, details: { path: "status_on" })
    def call(params:, by:, animal: nil, origin: "dashboard")
      raise ArgumentError, "origin: #{origin}" unless ORIGINS.include?(origin)
      return Result.fail(:missing_role) if origin == "dashboard" && !Access.team?(by)

      params = params.to_h.stringify_keys
      path = shape(params, editing: !animal.nil?)
      return invalid(path) if path
      return Result.fail(:expected_version_required, details: { path: "expected_version" }) if animal && !params.key?("expected_version")

      attrs, path = parse(params)
      return invalid(path) if path

      animal ? update(animal, attrs, by, origin) : create(attrs, by, origin)
    rescue ActiveRecord::RecordNotUnique => e
      taken = INDEXES.find { |name, _| e.message.include?(name) }
      raise unless taken

      Result.fail(taken.last.first, details: { path: taken.last.last })
    end

    def create(attrs, by, origin)
      attrs = attrs.reverse_merge(community: false)
      Animal.transaction(requires_new: true) do
        failure = references(attrs, attrs, by, origin, nil)
        next failure if failure

        animal = Animal.create!(attrs.merge(status: "active", created_by_user: by))
        DomainEvents.publish("animal.registered", animal_id: animal.id)
        Result.ok(animal: animal)
      end
    end

    def update(animal, attrs, by, origin)
      expected = attrs.delete(:expected_version)
      status = attrs.delete(:status)
      status_on = attrs.delete(:status_on)
      Animal.transaction(requires_new: true) do
        locked = Animal.lock.find(animal.id)
        next Result.fail(:animal_not_active) unless TRANSITIONS.key?(locked.status)
        next Result.fail(:animal_changed) unless locked.version == expected

        before_household_id = locked.household_id
        locked.assign_attributes(attrs)
        changed = locked.changes.transform_keys(&:to_sym).transform_values(&:last)
        failure = references(locked.attributes.symbolize_keys, changed, by, origin, before_household_id)
        next failure if failure

        if status && status != locked.status
          next Result.fail(:invalid_transition, details: { path: "status" }) unless TRANSITIONS.fetch(locked.status).include?(status)
          next Result.fail(:invalid_transition, details: { path: "status" }) if ShelterStay.open_stays.exists?(animal_id: locked.id)

          on = status_on || Time.zone.today
          unless (locked.created_at.in_time_zone.to_date..Time.zone.today).cover?(on)
            next Result.fail(:date_out_of_range, details: { path: "status_on" })
          end

          locked.assign_attributes(status: status, status_on: on)
        end
        next Result.ok(animal: locked) unless locked.changed?

        died = locked.status_changed?(to: "deceased")
        locked.version += 1
        locked.save!
        DomainEvents.publish("animal.changed", animal_id: locked.id)
        AnimalDeath.remove_collar!(animal: locked, on: locked.status_on) if died
        Result.ok(animal: locked)
      end
    end

    # Regras entre campos e com o banco. `final`: o animal como fica; `changed`:
    # o que muda (domicílio e tutor só são conferidos quando mudam).
    def references(final, changed, by, origin, before_household_id)
      return invalid("community") if final[:tutor_patient_id] && final[:community]
      if changed[:household_id] && !Household.exists?(id: changed[:household_id], status: "active")
        return invalid("household_id")
      end
      if changed[:tutor_patient_id] && !Patient.exists?(id: changed[:tutor_patient_id], merged_into_id: nil)
        return invalid("tutor_patient_id")
      end
      return nil unless origin == "field"

      ids = [ final[:household_id], before_household_id ].compact.uniq
      return Result.fail(:out_of_scope) if final[:household_id].nil?

      in_scope = Household.includes(micro_area: :team).where(id: ids).to_a
      Result.fail(:out_of_scope) unless in_scope.size == ids.size && in_scope.all? { |household| Access.field_agent?(by, household) }
    end

    # Chave desconhecida, de criação na edição, de edição na criação ou
    # obrigatória que falta → o path; as duas formas do nascimento → o da segunda.
    def shape(params, editing:)
      allowed = editing ? CREATE_KEYS - CREATE_ONLY + EDIT_ONLY : CREATE_KEYS
      unknown = params.keys.find { |key| !allowed.include?(key) }
      return unknown.to_s[0, KEY_PATH_MAX] if unknown
      return "birth_estimate_month" if params.key?("birth_estimate_on") && params.key?("birth_estimate_month")
      return "status_on" if params.key?("status_on") && !params.key?("status")

      REQUIRED.find { |key| !params.key?(key) } unless editing
    end

    # -> [ { atributo => valor }, path | nil ]
    def parse(params)
      attrs = {}
      params.each do |key, value|
        parsed = parse_value(key, value)
        return [ nil, key ] if parsed.equal?(INVALID)

        attrs[key == "birth_estimate_month" ? :birth_estimate_on : key.to_sym] = parsed
      end
      [ attrs, nil ]
    end

    def parse_value(key, value)
      case key
      when "species" then member(value, Catalog::SPECIES)
      when "sex" then member(value, Catalog::SEXES)
      when "status" then member(value, Catalog::ANIMAL_STATUSES)
      when "size" then value.nil? ? nil : member(value, Catalog::SIZES)
      when "name" then text(value, Catalog::NAME)
      when "coat" then text(value, Catalog::COAT)
      when "breed" then text(value, Catalog::BREED)
      when "registry_number" then text(value, Catalog::REGISTRY_NUMBER)
      when "microchip" then value.nil? || (value.is_a?(String) && value.match?(Catalog::MICROCHIP)) ? value : INVALID
      when "birth_estimate_on" then month(value, day_allowed: true)
      when "birth_estimate_month" then month(value, day_allowed: false)
      when "status_on" then value.nil? ? nil : date(value)
      when "household_id", "tutor_patient_id" then value.nil? || (value.is_a?(String) && value.match?(UUID)) ? value&.downcase : INVALID
      when "community" then [ true, false ].include?(value) ? value : INVALID
      when "expected_version" then value.is_a?(Integer) && value.positive? ? value : INVALID
      end
    end

    def member(value, allowed) = allowed.include?(value) ? value : INVALID

    def date(value)
      return INVALID unless value.is_a?(String) && value.match?(DATE)

      Date.strptime(value, "%Y-%m-%d")
    rescue Date::Error
      INVALID
    end

    def text(value, range)
      return nil if value.nil?
      return INVALID unless value.is_a?(String)

      clean = value.strip
      range.cover?(clean.length) ? clean : INVALID
    end

    # "AAAA-MM" (ou "AAAA-MM-DD" se `day_allowed`) → o dia 1 do mês; nunca
    # mês depois do de hoje.
    def month(value, day_allowed:)
      return nil if value.nil?

      match = value.is_a?(String) && value.match(MONTH)
      return INVALID unless match && (day_allowed || match[3].nil?)

      Date.new(match[1].to_i, match[2].to_i, (match[3] || 1).to_i)
      first = Date.new(match[1].to_i, match[2].to_i, 1)
      first > Time.zone.today.beginning_of_month ? INVALID : first
    rescue Date::Error
      INVALID
    end

    def invalid(path) = Result.fail(:invalid_request, details: { path: path })

    private_class_method :create, :update, :references, :shape, :parse, :parse_value, :member, :date, :text, :month, :invalid
  end
end
