# Regras puras da visita domiciliar (módulo 24b, ADR 0052; contrato §3, §13,
# §16 Q21, Q34–Q36, Q40, Q44). Quem chama passa `today` já no fuso da cidade
# (Time.zone.today dentro do CityConnection.with; plano, Desvio 10) e os fatos
# já lidos e travados (HomeVisits::Record): nenhuma consulta ao banco aqui.
#
# `check` recebe o corpo efetivo (chaves texto; `occurred_at` já um Time; o
# `subject` já derivado pela Q43) e devolve [] ou [{ error:, path: }] com o
# primeiro problema, na ordem do §3: domínio dos campos, data, imóvel e
# microárea, pessoa, desfecho × motivos × medidas, medidas, observação. Os
# códigos e listas vêm de config/ledi/visit_activity_dictionaries.yml (a prova
# da Task 1) e do HomeVisits::Catalog. Nunca o valor no erro: só código e path.
module HomeVisits
  module Rules
    DICTIONARY = YAML.load_file(Rails.root.join("config/ledi/visit_activity_dictionaries.yml")).fetch("home_visit").freeze
    REASON_CODES = DICTIONARY.dig("domains", "motivo_visita").keys.freeze
    REASONS_MAX = DICTIONARY.dig("rules", "reasons_max")
    NO_REASONS_OUTCOMES = DICTIONARY.dig("rules", "outcomes_without_reasons_and_measurements").freeze
    WITHOUT_PERSON_FORBIDDEN_MEASUREMENTS = DICTIONARY.dig("rules", "without_person_forbidden_measurements").freeze
    # chave => { "min", "max", "decimals", "requires", "domain" } (o que houver).
    MEASUREMENTS = DICTIONARY.fetch("measurements").transform_values(&:freeze).freeze
    GLUCOSE_TYPES = DICTIONARY.dig("domains", "tipo_glicemia").keys.freeze
    PERSON_KEYS = %w[patient_id new_patient family_id].freeze
    KEY_PATH_MAX = 64

    # Os fatos lidos pelo Record. Sexo e ids nunca no inspect.
    module Opaque
      def inspect = "#<#{self.class.name}>"
      def to_s = inspect
      def pretty_print(pp) = pp.text(inspect)
    end

    # Domicílio: status ativo, tipo de imóvel da última versão (texto) e se
    # há família ativa (não em mudança) nele.
    HouseholdFacts = Data.define(:id, :active, :property_type, :active_families) { include Opaque }
    # Microárea herdada do domicílio ou escolhida.
    AreaFacts = Data.define(:id, :active) { include Opaque }
    # Família: responsible_exited pelo TerritoryRegistry::Families.
    FamilyFacts = Data.define(:id, :household_id, :moved_out, :responsible_exited) { include Opaque }
    # Pessoa da ficha (o morador, o paciente novo ou o responsável): sexo e o
    # domicílio do cadastro individual ativo (nil = sem cadastro ativo ou
    # cadastro sem domicílio).
    PersonFacts = Data.define(:sex, :household_id) { include Opaque }

    module_function

    # Pre-flight 4.2: o primeiro dia aceito pelo prazo do SIAPS — o 1º dia da
    # competência mais antiga com Ledi::Deadline.on(c) > today (a ficha precisa
    # sair antes do prazo; C2). A mesma data no contexto (§6), nas regras da
    # visita e da atividade (*_date_out_of_range) e na sessão do app (§9).
    def min_date(today)
      competence = today.beginning_of_month
      loop do
        previous = competence.prev_month
        break unless Ledi::Deadline.on(previous.strftime("%Y%m")) > today

        competence = previous
      end
      competence
    end

    # Turno pelo relógio da cidade: antes de 12h Manhã (1), antes de 18h Tarde (2), senão Noite (3).
    def shift(occurred_at)
      hour = occurred_at.in_time_zone.hour
      return 1 if hour < 12

      hour < 18 ? 2 : 3
    end

    # -> [] | [{ error:, path: }]
    # `without_family`: a visita sem pessoa veio de um morador sem família ativa
    # no domicílio (Q51; HomeVisits::Record) — 29 e 34–37 valem como na Q44,
    # mesmo com outra família ativa no domicílio.
    def check(input, household:, family:, patient:, today:, micro_area: nil, now: Time.current, without_family: false)
      error = fields(input) || date(input["occurred_at"], today, now) || place(input, household, micro_area) ||
              person(input, household, family, patient) || outcome_rules(input, household, patient, without_family) ||
              measurement_values(input["measurements"]) || note_rule(input["note"])
      error ? [ error ] : []
    end

    # As medidas arredondadas pelas casas do YAML (decimals 0 → inteiro), na
    # ordem do YAML; vazias → nil. Só para o corpo que passou no `check`.
    def measurements(values)
      return nil if values.blank?

      MEASUREMENTS.each_with_object({}) do |(key, spec), rounded|
        next unless values.key?(key)

        rounded[key] = round(values[key], spec.fetch("decimals", 0))
      end
    end

    # A observação depois do strip; vazia → nil (nunca cortada: o `check` recusa acima de 500).
    def note(value) = value&.strip.presence

    def fields(input)
      return err(:invalid_home_visit, "outcome") unless Catalog::OUTCOMES.key?(input["outcome"])
      return err(:invalid_home_visit, "subject") unless Catalog::SUBJECTS.include?(input["subject"])
      return err(:invalid_home_visit, "shared") unless [ true, false, nil ].include?(input["shared"])

      err(:invalid_home_visit, "out_of_area") unless [ true, false, nil ].include?(input["out_of_area"])
    end

    # occurred_at ≤ agora e o prazo do SIAPS da competência do dia ainda por vir.
    def date(occurred_at, today, now)
      return err(:invalid_home_visit, "occurred_at") unless occurred_at.is_a?(ActiveSupport::TimeWithZone) || occurred_at.is_a?(Time)

      day = occurred_at.in_time_zone.to_date
      return nil if occurred_at <= now && Ledi::Deadline.on(day.strftime("%Y%m")) > today

      err(:visit_date_out_of_range, "occurred_at")
    end

    def place(input, household, area)
      if household
        %w[property_type micro_area_id].each { |key| return err(:invalid_home_visit, key) unless input[key].nil? }
        return err(:invalid_home_visit, "out_of_area") if input["out_of_area"] == true
        return err(:household_inactive, "household_id") unless household.active
        return err(:micro_area_inactive, "household_id") if area && !area.active

        return nil
      end

      return err(:invalid_home_visit, "property_type") unless TerritoryRegistry::Catalog::PROPERTY_TYPES.include?(input["property_type"])

      out = input["out_of_area"] == true
      return err(:invalid_home_visit, "out_of_area") if out && !input["micro_area_id"].nil?
      return err(:invalid_home_visit, "micro_area_id") if !out && input["micro_area_id"].nil?

      err(:micro_area_inactive, "micro_area_id") if area && !area.active
    end

    def person(input, household, family, patient)
      present = ->(key) { !input[key].nil? }
      if non_residential?(input, household)
        PERSON_KEYS.each { |key| return err(:non_residential_with_person, key) if present[key] }
        return input["subject"] == "none" ? nil : err(:non_residential_with_person, "subject")
      end

      case input["subject"]
      when "resident"
        return err(:invalid_home_visit, "family_id") if present["family_id"]
        return err(:invalid_home_visit, "patient_id") unless present["patient_id"] || present["new_patient"]
        return err(:invalid_home_visit, "new_patient") if present["patient_id"] && present["new_patient"]
        return nil unless household && patient&.household_id && patient.household_id != household.id

        err(:patient_in_other_household, present["new_patient"] ? "new_patient" : "patient_id")
      when "family_responsible"
        %w[patient_id new_patient].each { |key| return err(:invalid_home_visit, key) if present[key] }
        return err(:invalid_home_visit, "household_id") unless household
        return err(:invalid_home_visit, "family_id") unless family && input["family_id"] == family.id && family.household_id == household.id
        return err(:family_moved_out, "family_id") if family.moved_out

        err(:family_without_responsible, "family_id") if family.responsible_exited
      else
        PERSON_KEYS.each { |key| return err(:invalid_home_visit, key) if present[key] }
        nil
      end
    end

    def outcome_rules(input, household, patient, without_family)
      reasons = input["reasons"].nil? ? [] : input["reasons"]
      return err(:invalid_home_visit, "reasons") unless reasons.is_a?(Array) && reasons.size <= REASONS_MAX

      reasons.each_with_index do |code, index|
        return err(:invalid_home_visit, "reasons[#{index}]") unless REASON_CODES.include?(code) && code.is_a?(Integer) &&
                                                                    reasons.index(code) == index
      end
      values = input["measurements"]
      return err(:invalid_home_visit, "measurements") unless values.nil? || values.is_a?(Hash)

      if NO_REASONS_OUTCOMES.include?(input["outcome"])
        return err(:reasons_forbidden, "reasons") if reasons.any?
        return err(:measurements_forbidden, "measurements") if values.present?
      end
      allowed_reasons(input, household, reasons, values, patient, without_family)
    end

    def allowed_reasons(input, household, reasons, values, patient, without_family)
      if non_residential?(input, household)
        return not_allowed(reasons, Catalog::NON_RESIDENTIAL_REASONS) ||
               (err(:measurements_forbidden, "measurements") if values.present?)
      end
      if input["subject"] == "none"
        # Q44: sem família ativa no domicílio (ou sem domicílio), 29 e 34–37 vão
        # sem pessoa; Q51: idem para o morador sem família ativa ali.
        allowed = Catalog::WITHOUT_PERSON_ALLOWED_REASONS
        allowed += Catalog::RESPONSIBLE_DOCUMENT_REASONS if without_family || !household&.active_families
        error = not_allowed(reasons, allowed)
        return error if error

        forbidden = WITHOUT_PERSON_FORBIDDEN_MEASUREMENTS.find { |key| values&.key?(key) }
        return forbidden ? err(:measurements_forbidden, "measurements.#{forbidden}") : nil
      end
      return nil unless patient&.sex == "male"

      index = reasons.index { |code| Catalog::MALE_FORBIDDEN_REASONS.include?(code) }
      index && err(:reason_not_allowed, "reasons[#{index}]")
    end

    def measurement_values(values)
      return nil if values.blank?

      unknown = (values.keys - MEASUREMENTS.keys).first
      return err(:invalid_home_visit, "measurements.#{unknown}"[0, KEY_PATH_MAX]) if unknown

      MEASUREMENTS.each do |key, spec|
        next unless values.key?(key)

        return err(:invalid_home_visit, "measurements.#{key}") unless valid_measure?(values[key], spec)
        return err(:invalid_home_visit, "measurements.#{spec['requires']}") if spec["requires"] && !values.key?(spec["requires"])
      end
      nil
    end

    def valid_measure?(value, spec)
      return value.is_a?(Integer) && GLUCOSE_TYPES.include?(value) if spec["domain"]
      return false unless value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)

      (spec.fetch("min")..spec.fetch("max")).cover?(round(value, spec.fetch("decimals", 0)))
    end

    # Até 500 code points depois do strip (String#length conta code points em UTF-8).
    def note_rule(value)
      return nil if value.nil?
      return nil if value.is_a?(String) && value.strip.length <= Catalog::NOTE_MAX

      err(:invalid_home_visit, "note")
    end

    def non_residential?(input, household)
      Catalog::NON_RESIDENTIAL.include?(household ? household.property_type : input["property_type"])
    end

    def not_allowed(reasons, allowed)
      index = reasons.index { |code| !allowed.include?(code) }
      index && err(:reason_not_allowed, "reasons[#{index}]")
    end

    def round(value, decimals) = decimals.zero? ? value.round : value.to_f.round(decimals)

    def err(code, path) = { error: code, path: path }
    private_class_method :fields, :date, :place, :person, :outcome_rules, :allowed_reasons, :measurement_values, :valid_measure?,
                         :note_rule, :non_residential?, :not_allowed, :round, :err
  end
end
