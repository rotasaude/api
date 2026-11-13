# Regras puras da atividade coletiva (módulo 24b, ADR 0052; contrato §4, §7,
# §11, §16 Q15, Q32, Q36–Q38, Q42; pre-flight "| 13 |"). Dirigidas pelo dado:
# `collective_activity.rules` e `collective_activity.domains` de
# config/ledi/visit_activity_dictionaries.yml (a prova da Task 1; Ruling A1) —
# a tabela por tipo, os tamanhos máximos, as práticas só do tipo 6, o
# procedimento da prática 30 (lista fechada de 58 SIGTAP, Q37), o tabagismo
# das práticas 25–28 e o tema 18 recusado. O mesmo YAML vai ao
# `options.domains` (Task 15) e ao domains-v1.json do contracts (Q13).
#
# `check` recebe o corpo plano do §7 (chaves texto; Q15: lista ausente =
# vazia) e o `today` da cidade (Time.zone.today dentro do CityConnection.with)
# e devolve [] ou [{ error:, path: }] com o primeiro problema: chaves e ids,
# tipo e turno, data, local, contagem, listas (domínio, tamanho, repetição),
# a tabela do tipo, práticas e procedimento, profissionais, participantes. Sem
# banco: a unidade ativa com CNES, os profissionais e os pacientes ficam com o
# CollectiveActivities::Record. Nunca o valor no erro: só código e path.
module CollectiveActivities
  module Rules
    DICTIONARY = YAML.load_file(Rails.root.join("config/ledi/visit_activity_dictionaries.yml")).fetch("collective_activity").freeze
    RULES = DICTIONARY.fetch("rules").freeze
    # campo do corpo → os códigos do domínio (na ordem do dicionário).
    DOMAINS = {
      "meeting_topics" => DICTIONARY.dig("domains", "temas_para_reuniao").keys,
      "target_audience" => DICTIONARY.dig("domains", "publico_alvo").keys,
      "health_topics" => DICTIONARY.dig("domains", "temas_para_saude").keys,
      "health_practices" => DICTIONARY.dig("domains", "praticas_em_saude").keys
    }.transform_values(&:freeze).freeze
    LISTS = DOMAINS.keys.freeze
    PROCEDURES = DICTIONARY.dig("domains", "outro_procedimento_coletivo").keys.map(&:to_s).freeze
    BY_TYPE = RULES.fetch("by_activity_type").transform_keys(&:to_i).freeze
    LIST_MAX = RULES.fetch("list_max").freeze
    MEETING_EXCEPTION = RULES.fetch("health_topics_meeting_exception")
    TYPE6_ONLY = RULES.fetch("type6_only_practices").freeze
    PROCEDURE_PRACTICE = RULES.fetch("procedure_practice")
    SMOKING_PRACTICES = RULES.fetch("smoking_practices").freeze
    FORBIDDEN_HEALTH_TOPICS = RULES.fetch("forbidden_health_topics").freeze
    # chave → { "min", "max", "decimals" }.
    PARTICIPANT_MEASUREMENTS = RULES.fetch("participant_measurements").transform_values(&:freeze).freeze
    COUNT = (RULES.dig("participants_count", "min")..RULES.dig("participants_count", "max"))
    SHIFTS = [ 1, 2, 3 ].freeze
    SMOKING_KEYS = %w[quit dropped_out].freeze

    # O corpo do POST /collective_activities (§7, Q15). `altered_count` não
    # vem (Q38); `patient_client_uuid` é do envio do app (Task 20).
    ALLOWED = %w[
      client_uuid team_id held_on shift activity_type place_health_unit_id place_text participants_count meeting_topics
      target_audience health_topics health_practices procedure_code professionals participants
    ].freeze
    PARTICIPANT_KEYS = %w[patient_id new_patient duplicates_reviewed altered_evaluation measurements smoking].freeze
    PROFESSIONAL_KEYS = %w[professional_id].freeze
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    DATE = /\A\d{4}-\d{2}-\d{2}\z/
    KEY_PATH_MAX = 64

    module_function

    # -> [] | [{ error:, path: }]
    def check(input, today:)
      error = keys(input) || fields(input) || date(input["held_on"], today) || place(input) || lists(input) ||
              by_type(input) || practices(input) || professionals(input["professionals"]) ||
              participants(input) || count(input)
      error ? [ error ] : []
    end

    # A data do corpo que passou no `check`.
    def held_on(value) = Date.iso8601(value)

    # A lista do corpo (ausente = vazia; Q15).
    def list(value) = value.nil? ? [] : value

    # O texto do local depois do strip (nunca cortado: o `check` recusa acima de 250).
    def place_text(value) = value&.strip.presence

    # numAvaliacoesAlteradas: participantes com altered_evaluation = true (Q38).
    def altered_count(participants) = list(participants).count { |item| item["altered_evaluation"] == true }

    # As medidas do participante arredondadas pelas casas do YAML; vazias → nil.
    def measurements(values)
      return nil if values.blank?

      PARTICIPANT_MEASUREMENTS.each_with_object({}) do |(key, spec), rounded|
        rounded[key] = values[key].to_f.round(spec.fetch("decimals")) if values.key?(key)
      end
    end

    # Tabagismo do participante (só as chaves dadas); vazio → nil.
    def smoking(values) = values.presence&.slice(*SMOKING_KEYS)

    def keys(input)
      unknown = (input.keys - ALLOWED).first
      return err(:invalid_collective_activity, unknown.to_s[0, KEY_PATH_MAX]) if unknown

      %w[team_id place_health_unit_id].each do |key|
        return err(:invalid_collective_activity, key) unless input[key].nil? || uuid?(input[key])
      end
      err(:invalid_collective_activity, "team_id") if input["team_id"].nil?
    end

    def fields(input)
      return err(:invalid_collective_activity, "activity_type") unless BY_TYPE.key?(input["activity_type"]) && input["activity_type"].is_a?(Integer)

      err(:invalid_collective_activity, "shift") unless SHIFTS.include?(input["shift"]) && input["shift"].is_a?(Integer)
    end

    # held_on ≤ hoje e o prazo do SIAPS da competência ainda por vir (o mesmo
    # min_date da visita, C2).
    def date(value, today)
      day = value.is_a?(String) && value.match?(DATE) ? held_on(value) : nil
      return err(:invalid_collective_activity, "held_on") unless day
      return nil if day <= today && Ledi::Deadline.on(day.strftime("%Y%m")) > today

      err(:activity_date_out_of_range, "held_on")
    rescue Date::Error
      err(:invalid_collective_activity, "held_on")
    end

    # Exatamente um: unidade (o Record confere ativa com CNES) ou texto até 250
    # (Q15, Q32: os dois → place_text; nenhum → place_health_unit_id).
    def place(input)
      unit, text = input.values_at("place_health_unit_id", "place_text")
      return err(:invalid_collective_activity, "place_text") if unit && !text.nil?
      return nil if unit

      return err(:invalid_collective_activity, "place_health_unit_id") if text.nil?

      valid = text.is_a?(String) && (1..Catalog::PLACE_TEXT_MAX).cover?(text.strip.length)
      err(:invalid_collective_activity, "place_text") unless valid
    end

    # Cada lista: ausente = vazia; senão lista de inteiros do domínio, sem
    # repetição, até o máximo do dicionário (Q36); o tema 18 nunca.
    def lists(input)
      LISTS.each do |field|
        values = input[field]
        next if values.nil?
        return err(:invalid_collective_activity, field) unless values.is_a?(Array) && values.size <= LIST_MAX.fetch(field)

        values.each_with_index do |code, index|
          valid = code.is_a?(Integer) && DOMAINS.fetch(field).include?(code) && values.index(code) == index &&
                  !(field == "health_topics" && FORBIDDEN_HEALTH_TOPICS.include?(code))
          return err(:invalid_collective_activity, "#{field}[#{index}]") unless valid
        end
      end
      nil
    end

    # A tabela do §4 (YAML by_activity_type): required → não vazia; forbidden
    # → vazia. health_topics nas reuniões: proibido salvo com o tema de reunião 6.
    def by_type(input)
      row = BY_TYPE.fetch(input["activity_type"])
      (LISTS + %w[participants]).each do |field|
        present = list(input[field]).is_a?(Array) && list(input[field]).any?
        rule = row.fetch(field)
        rule = "optional" if field == "health_topics" && rule == "forbidden" && list(input["meeting_topics"]).include?(MEETING_EXCEPTION)
        return err(:invalid_collective_activity, field) if (rule == "required" && !present) || (rule == "forbidden" && present)
      end
      nil
    end

    # Práticas 2, 9 e 33 só no tipo 6; procedure_code obrigatório com a 30 e
    # proibido sem ela, da lista fechada (Q37).
    def practices(input)
      practices = list(input["health_practices"])
      if input["activity_type"] != 6
        index = practices.index { |code| TYPE6_ONLY.include?(code) }
        return err(:invalid_collective_activity, "health_practices[#{index}]") if index
      end
      code = input["procedure_code"]
      return nil if practices.include?(PROCEDURE_PRACTICE) ? PROCEDURES.include?(code) : code.nil?

      err(:invalid_collective_activity, "procedure_code")
    end

    def professionals(items)
      return nil if items.nil?
      return err(:invalid_collective_activity, "professionals") unless items.is_a?(Array)

      seen = []
      items.each_with_index do |item, index|
        at = "professionals[#{index}]"
        return err(:invalid_collective_activity, at) unless item.is_a?(Hash)

        unknown = (item.keys - PROFESSIONAL_KEYS).first
        return err(:invalid_collective_activity, "#{at}.#{unknown}"[0, KEY_PATH_MAX]) if unknown

        id = item["professional_id"]
        return err(:invalid_collective_activity, "#{at}.professional_id") unless uuid?(id) && !seen.include?(id)

        seen << id
      end
      nil
    end

    # Participantes: a lista é uma (a tabela do tipo já viu se vazia pode);
    # patient_id ou new_patient, exatamente um (a forma do new_patient é do
    # HomeVisits::People). A mesma pessoa duas vezes → duplicate_participant
    # em participants[i] (Ruling T13-DUP), antes de qualquer escrita: o mesmo
    # patient_id, ou dois new_patient com a mesma chave (`identity`).
    def participants(input)
      items = input["participants"]
      return nil if items.nil?
      return err(:invalid_collective_activity, "participants") unless items.is_a?(Array)

      smoking_allowed = list(input["health_practices"]).intersect?(SMOKING_PRACTICES)
      seen = []
      items.each_with_index do |item, index|
        at = "participants[#{index}]"
        error = participant(item, at, smoking_allowed)
        return error if error

        key = item["patient_id"] ? [ :patient, item["patient_id"] ] : identity(item["new_patient"])
        return err(:duplicate_participant, at) if key && seen.include?(key)

        seen << key if key
      end
      nil
    end

    # A chave de pessoa do new_patient: o CPF; sem ele, o CNS (só dígitos);
    # sem documento, a chave do 24a (Patients::MatchKey: nome normalizado +
    # nascimento) e a mãe normalizada. nil se a forma não dá chave (o
    # HomeVisits::People recusa a forma depois).
    def identity(typed)
      return nil unless typed.is_a?(Hash)

      %w[cpf cns].each do |doc|
        digits = typed[doc].is_a?(String) ? typed[doc].gsub(/\D/, "") : ""
        return [ doc.to_sym, digits ] if digits.present?
      end
      name, birth, mother = typed.values_at("full_name", "birth_date", "mother_name")
      key = Patients::MatchKey.for(name, birth) if name.is_a?(String) && birth.is_a?(String)
      key && [ :match_key, key, mother.is_a?(String) ? Patients::MatchKey.normalize(mother) : nil ]
    end

    def participant(item, at, smoking_allowed)
      return err(:invalid_collective_activity, at) unless item.is_a?(Hash)

      unknown = (item.keys - PARTICIPANT_KEYS).first
      return err(:invalid_collective_activity, "#{at}.#{unknown}"[0, KEY_PATH_MAX]) if unknown

      id, typed = item.values_at("patient_id", "new_patient")
      return err(:invalid_collective_activity, "#{at}.patient_id") if id.nil? && typed.nil?
      return err(:invalid_collective_activity, "#{at}.new_patient") if !id.nil? && !typed.nil?
      return err(:invalid_collective_activity, "#{at}.patient_id") unless id.nil? || uuid?(id)

      %w[duplicates_reviewed altered_evaluation].each do |key|
        return err(:invalid_collective_activity, "#{at}.#{key}") unless [ true, false, nil ].include?(item[key])
      end
      participant_measurements(item["measurements"], at) || participant_smoking(item["smoking"], at, smoking_allowed)
    end

    def participant_measurements(values, at)
      return nil if values.nil?
      return err(:invalid_collective_activity, "#{at}.measurements") unless values.is_a?(Hash)

      values.each do |key, value|
        spec = PARTICIPANT_MEASUREMENTS[key]
        path = "#{at}.measurements.#{key}"[0, KEY_PATH_MAX]
        return err(:invalid_collective_activity, path) unless spec && valid_measure?(value, spec)
      end
      nil
    end

    # cessouHabitoFumar/abandonouGrupo só com as práticas 25–28 (a 34 fora).
    def participant_smoking(values, at, allowed)
      return nil if values.nil?
      return err(:invalid_collective_activity, "#{at}.smoking") unless values.is_a?(Hash) && allowed

      values.each do |key, value|
        valid = SMOKING_KEYS.include?(key) && [ true, false ].include?(value)
        return err(:invalid_collective_activity, "#{at}.smoking.#{key}"[0, KEY_PATH_MAX]) unless valid
      end
      nil
    end

    # participants_count 1–999 e ≥ participantes listados (§4).
    def count(input)
      value = input["participants_count"]
      valid = value.is_a?(Integer) && COUNT.cover?(value) && value >= list(input["participants"]).size
      err(:invalid_collective_activity, "participants_count") unless valid
    end

    def valid_measure?(value, spec)
      return false unless value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)

      (spec.fetch("min")..spec.fetch("max")).cover?(value.to_f.round(spec.fetch("decimals")))
    end

    def uuid?(value) = value.is_a?(String) && value.match?(UUID)
    def err(code, path) = { error: code, path: path }
    private_class_method :keys, :fields, :date, :place, :lists, :by_type, :practices, :professionals, :participants,
                         :participant, :identity, :participant_measurements, :participant_smoking, :count, :valid_measure?, :uuid?, :err
  end
end
