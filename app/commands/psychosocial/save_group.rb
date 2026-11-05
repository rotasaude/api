# Cadastra e edita a grade semanal de grupos, oficinas e assembleias do CAPS
# (ADR 0049; contrato §4, P12, P13, P25). Campos:
#   health_unit_id (CAPS ativo; na edição só o mesmo), name (1..NAME_MAX), kind
#   (GROUP_KINDS), weekday (ISO 1..7), starts_at/ends_at ("HH:MM", fim depois do
#   início, path ends_at), responsible_user_id (lotado no CAPS), capacity
#   (CAPACITY), sigtap_code (instrumento 09 ou 01 na SIGTAP da competência de
#   hoje, senão instrument_mismatch), active.
# Na criação todos são obrigatórios (active padrão true); na edição só os
# enviados mudam. O código SIGTAP e o responsável só são conferidos quando
# novos ou trocados (editar o nome não falha porque a SIGTAP mudou) ou quando o
# grupo é reativado (active false → true: os gravados valem como novos). Texto acima
# do limite → too_long; o resto → invalid_request, sempre com o path e todos
# de uma vez. Sem evento (cadastro sem paciente); o grupo nunca é apagado.
module Psychosocial
  module SaveGroup
    KEYS = %w[health_unit_id name kind weekday starts_at ends_at responsible_user_id capacity sigtap_code active].freeze
    REQUIRED = (KEYS - %w[active]).freeze
    KEY_PATH_MAX = 64
    HOUR = /\A([01]\d|2[0-3]):[0-5]\d\z/
    SIGTAP_CODE = /\A\d{10}\z/
    GROUP_INSTRUMENTS = %w[09 01].freeze

    module_function

    # -> Result.ok(group:) | fail(:invalid_request | :too_long | :instrument_mismatch, details: { path:, problems: })
    def call(attrs:, by:, group: nil, today: Time.zone.today)
      attrs = attrs.to_h.stringify_keys
      unit, problems = resolve_unit(attrs, group)
      values, more = check(attrs, unit: unit, group: group, today: today)
      problems += more
      return failure(problems) if problems.any?

      PsychosocialGroup.transaction(requires_new: true) do
        record = group || PsychosocialGroup.new(health_unit: unit)
        record.lock! if group
        record.assign_attributes(values)
        next Result.ok(group: record) if group && !record.changed?

        record.updated_by_user = by
        record.save!
        Result.ok(group: record)
      end
    end

    # -> [HealthUnit | nil, problems] (chave desconhecida, CAPS inválido). Na
    # edição o CAPS é o do grupo.
    def resolve_unit(attrs, group)
      problems = (attrs.keys - KEYS).map { |key| problem(key[0, KEY_PATH_MAX]) }
      if group
        problems << problem("health_unit_id") if attrs.key?("health_unit_id") && attrs["health_unit_id"] != group.health_unit_id
        return [ group.health_unit, problems ]
      end

      id = attrs["health_unit_id"]
      unit = Input.uuid?(id) ? HealthUnit.find_by(id: id, kind: "caps", active: true) : nil
      problems << problem("health_unit_id") unless unit
      [ unit, problems ]
    end

    # -> [values, problems]
    def check(attrs, unit:, group:, today:)
      problems = group ? [] : (REQUIRED - %w[health_unit_id] - attrs.keys).map { |key| problem(key) }
      values = {}
      given = ->(key) { attrs.key?(key) }

      if given.("name")
        text = Catalog.text_problem(attrs["name"], 1..Catalog::NAME_MAX, "name")
        text ? problems << text : values[:name] = attrs["name"].strip
      end
      enum(attrs, "kind", Catalog::GROUP_KINDS, values, problems)
      weekday(attrs, values, problems) if given.("weekday")
      times(attrs, group, values, problems)
      capacity(attrs, values, problems) if given.("capacity")
      if given.("active")
        [ true, false ].include?(attrs["active"]) ? values[:active] = attrs["active"] : problems << problem("active")
      end
      reactivating = group && !group.active && values[:active] == true
      responsible(attrs, unit, group, values, problems, force: reactivating) if (given.("responsible_user_id") || reactivating) && unit
      code(attrs, group, today, values, problems, force: reactivating) if given.("sigtap_code") || reactivating
      [ values, problems ]
    end

    def enum(attrs, key, list, values, problems)
      return unless attrs.key?(key)

      list.include?(attrs[key]) ? values[key.to_sym] = attrs[key] : problems << problem(key)
    end

    def weekday(attrs, values, problems)
      value = attrs["weekday"]
      Catalog::WEEKDAYS.cover?(value) && value.is_a?(Integer) ? values[:weekday] = value : problems << problem("weekday")
    end

    def capacity(attrs, values, problems)
      value = attrs["capacity"]
      Catalog::CAPACITY.cover?(value) && value.is_a?(Integer) ? values[:capacity] = value : problems << problem("capacity")
    end

    # "HH:MM" → hora do dia; com os dois conhecidos (enviados ou do grupo), o
    # fim tem de ser depois do início.
    def times(attrs, group, values, problems)
      invalid = false
      %w[starts_at ends_at].each do |key|
        next unless attrs.key?(key)

        if attrs[key].is_a?(String) && attrs[key].match?(HOUR)
          values[key.to_sym] = attrs[key]
        else
          problems << problem(key)
          invalid = true
        end
      end
      return if invalid

      starts = values[:starts_at] || (group && Json.hour(group.starts_at))
      ends = values[:ends_at] || (group && Json.hour(group.ends_at))
      problems << problem("ends_at") if starts && ends && ends <= starts
    end

    # force: reativação — o responsável gravado (ou o enviado) é conferido mesmo sem troca.
    def responsible(attrs, unit, group, values, problems, force: false)
      id = attrs.fetch("responsible_user_id") { group&.responsible_user_id }
      return if group && id == group.responsible_user_id && !force

      user = Input.uuid?(id) ? User.find_by(id: id) : nil
      if user && Access.link(user, unit.id)
        values[:responsible_user_id] = id
      else
        problems << problem("responsible_user_id")
      end
    end

    # Código novo ou trocado (ou o gravado, na reativação — force): forma e
    # instrumento na SIGTAP da competência de hoje.
    def code(attrs, group, today, values, problems, force: false)
      code = attrs.fetch("sigtap_code") { group&.sigtap_code }
      return if group && code == group.sigtap_code && !force
      return problems << problem("sigtap_code") unless code.is_a?(String) && code.match?(SIGTAP_CODE)

      cache = Billing::SigtapCache.new
      release = cache.release(today.strftime("%Y%m"))
      instruments = release ? cache.instruments(release, code) : []
      if instruments.intersect?(GROUP_INSTRUMENTS)
        values[:sigtap_code] = code
      else
        problems << problem("sigtap_code", "instrument_mismatch")
      end
    end

    def problem(path, error = "invalid_request") = { error: error, path: path }

    def failure(problems)
      first = problems.first
      Result.fail(first[:error].to_sym, details: { path: first[:path], problems: problems })
    end

    private_class_method :resolve_unit, :check, :enum, :weekday, :capacity, :times, :responsible, :code, :problem, :failure
  end
end
