# Metas mensais do CEO (ADR 0046; spec decisão 12; contrato §10, §16 O15/O24):
# por especialidade, a soma de `dental_procedures.quantity` das consultas
# `dental` finalizadas, não `baseline`, da unidade, no mês (fuso da cidade),
# contra a meta do tipo do CEO em config/dental/ceo_goals.yml. Básico só de
# consulta `special_needs`. `met` = quantidade e composição. Faltas e
# `history` sobre os 12 meses fechados antes de `month`, só dos meses avaliados
# (O35): do mês seguinte ao da criação do perfil, ou do próprio mês quando o
# perfil nasceu no dia 1 — mês parcial nunca é falta (o CEO cadastrado no meio
# do ano não tem falta antes disso). Suspensão (O36): 2 faltas seguidas, ou 3
# alternadas nos 11 meses fechados antes de `month` mais o próprio `month`.
# Só contagens: nada do paciente.
module DentalCare
  module CeoGoals
    PATH = Rails.root.join("config/dental/ceo_goals.yml")
    KEYS = %w[basic periodontics endodontics oral_surgery].freeze

    module_function

    def config = (@config ||= deep_freeze(YAML.load_file(PATH)))

    def deep_freeze(value)
      case value
      when Hash then value.each_value { |item| deep_freeze(item) }
      when Array then value.each { |item| deep_freeze(item) }
      end
      value.freeze
    end

    def codes(rows) = rows.map { |row| row.fetch("code") }

    # `month`: o primeiro dia do mês. `unit` com `ceo_profile`.
    def call(unit:, month:)
      profile = unit.ceo_profile
      since = first_evaluated(profile)
      closed = (1..12).map { |back| month << back }.reverse
      totals = sums(unit, closed.first, month.next_month)
      current = specialties(profile.ceo_type, totals[key_of(month)])
      counted = closed.select { |m| m >= since }.map { |m| [ m, specialties(profile.ceo_type, totals[key_of(m)]) ] }
      misses = KEYS.index_with { |key| misses_of(mets(counted, key)) }
      alternate_from = month << (config.dig("suspension", "window_months") - 1)
      recent = counted.select { |m, _| m >= alternate_from }
      risk = month >= since && current.any? do |row|
        !row[:met] && at_risk?(misses.fetch(row[:key])[:consecutive], mets(recent, row[:key]).count(false))
      end
      { ceo_type: profile.ceo_type,
        specialties: current,
        misses_last_12: misses,
        suspension_risk: risk,
        history: counted.map { |m, rows| { month: key_of(m), specialties: rows.map { |row| row.slice(:key, :done, :met) } } } }
    end

    # O35: primeiro mês avaliado (mês inteiro sob o perfil).
    def first_evaluated(profile)
      created = profile.created_at.in_time_zone.to_date
      created.day == 1 ? created : created.next_month.beginning_of_month
    end

    def mets(counted, key) = counted.map { |_, rows| rows.find { |row| row[:key] == key }.fetch(:met) }

    # A falta do mês suspende: o mês anterior já faltou (vira a 2ª seguida) ou
    # já são 2 nos 11 meses fechados anteriores (vira a 3ª alternada em 12).
    def at_risk?(consecutive, recent_misses)
      rule = config.fetch("suspension")
      consecutive >= rule.fetch("consecutive") - 1 || recent_misses >= rule.fetch("alternate") - 1
    end

    # Faltas na ordem do mais antigo: total e a sequência que termina no mês anterior.
    def misses_of(mets)
      { consecutive: mets.reverse.take_while { |met| !met }.size, total: mets.count(false) }
    end

    def specialties(ceo_type, sums)
      sums ||= {}
      KEYS.map do |key|
        done = done_of(key, sums)
        composition = composition_of(key, sums, done)
        goal = config.dig("goals", key).fetch(ceo_type)
        { key: key, goal: goal, done: done, composition: composition, met: done >= goal && (composition.nil? || composition[:ok]) }
      end
    end

    # sums: { [code, special_needs] => quantidade }.
    def done_of(key, sums, only: nil)
      wanted = only || codes(config.dig("groups", key))
      special_only = key == "basic" && config.fetch("basic_requires_special_needs")
      sums.sum { |(code, special), quantity| wanted.include?(code) && (special || !special_only) ? quantity : 0 }
    end

    def composition_of(key, sums, done)
      rule = config.dig("composition", key) or return nil
      part = done_of(key, sums, only: codes(rule.fetch("codes")))
      percent = done.zero? ? 0r : Rational(part * 100, done)
      { rule: rule.fetch("rule"), ok: done.positive? && percent >= rule.fetch("min_percent"), value: format("%.2f", percent.round(2)) }
    end

    # { "AAAA-MM" => { [code, special_needs] => quantidade } } numa consulta só.
    def sums(unit, from, to)
      all = codes(config.fetch("groups").values.flatten)
      month = "to_char((consultations.finalized_at AT TIME ZONE 'UTC') AT TIME ZONE #{Consultation.connection.quote(Time.zone.tzinfo.name)}, 'YYYY-MM')"
      DentalProcedure.joins(consultation: :attendance)
                     .where(procedure_code: all,
                            consultations: { kind: "dental", status: "finalized", baseline: false,
                                             finalized_at: from.in_time_zone...to.in_time_zone },
                            attendances: { health_unit_id: unit.id })
                     .group(Arel.sql(month), "dental_procedures.procedure_code", "consultations.special_needs")
                     .sum(:quantity)
                     .each_with_object(Hash.new { |hash, key| hash[key] = {} }) do |((m, code, special), quantity), out|
                       out[m][[ code, special ]] = quantity
                     end
    end

    def key_of(month) = month.strftime("%Y-%m")
  end
end
