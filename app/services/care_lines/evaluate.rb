# Avaliação de cada boa prática (ADR 0040; spec §5; plano, Desvios 2–3).
# PURA: recebe as regras, a pessoa, as âncoras e os eventos já carregados;
# devolve PracticeStatus. Fonte fora do sistema → untracked (nunca atraso).
module CareLines
  module Evaluate
    RANK = { "ok" => 0, "due_soon" => 1, "overdue" => 2 }.freeze

    module_function

    def call(practices:, person:, anchors:, events:, today:)
      practices.filter_map do |practice|
        next unless applies?(practice["applies_to"], person, today)

        evaluate(practice, anchors, events, today)
      end
    end

    def worst(statuses)
      tracked = statuses.select(&:tracked)
      return "untracked" if tracked.empty?

      tracked.map(&:status).max_by { |status| RANK.fetch(status) }
    end

    def applies?(rule, person, on)
      return true if rule.nil?

      age = person.age_years(on)
      if rule["age_min_years"] || rule["age_max_years"]
        return false if age.nil?
        return false if rule["age_min_years"] && age < rule["age_min_years"]
        return false if rule["age_max_years"] && age > rule["age_max_years"]
      end
      rule["sex"].nil? || person.sex == rule["sex"]
    end

    def sources_of(practice)
      return [] if Catalog.untracked?(practice["source"])

      groups(practice).flatten.map { |alt| alt["source"] }.uniq
    end

    def since(practices, anchors, today)
      starts = practices.reject { |p| Catalog.untracked?(p["source"]) }.filter_map do |p|
        if p["anchor"] == "rolling"
          today - (groups(p).flatten.map { |alt| alt["window_days"] || p["window_days"] }.max - 1)
        elsif (anchor = anchors[p["anchor"]])
          anchor + p["window_start_days"].to_i
        end
      end
      starts.min || today
    end

    def evaluate(practice, anchors, events, today)
      base = { key: practice["key"], label: practice["label"], citizen_label: practice["citizen_label"], source: practice["source"],
               points: practice["points"] }
      if Catalog.untracked?(practice["source"])
        return PracticeStatus.new(**base, tracked: false, status: "untracked", done_at: nil, due_on: nil, count: nil, expected: nil, met: false)
      end
      return rolling(practice, events, today, base) if practice["anchor"] == "rolling"

      anchor = anchors[practice["anchor"]]
      return PracticeStatus.new(**base, tracked: true, status: "overdue", done_at: nil, due_on: nil, count: 0, expected: practice["min_count"], met: false) unless anchor

      fixed(practice, anchor, events, today, base)
    end

    # Janela móvel: cada alternativa com a própria janela (HPV 60 meses).
    def rolling(practice, events, today, base)
      matched = groups(practice).map do |group|
        group.flat_map do |alt|
          window = alt["window_days"] || practice["window_days"]
          dates(practice, alt["source"], events, today - (window - 1), today).map { |d| [ d, d + window ] }
        end
      end
      need = matched.size > 1 ? 1 : practice["min_count"]
      met = matched.all? { |items| items.size >= need }
      done_at = matched.flatten(1).map(&:first).max
      count, expected = counts(matched, need)
      return PracticeStatus.new(**base, tracked: true, status: "overdue", done_at: done_at, due_on: nil, count: count, expected: expected, met: false) unless met

      due_on = matched.map { |items| items.map(&:last).sort.reverse[need - 1] }.min
      status = (due_on - today).to_i <= Catalog::DUE_SOON_DAYS ? "due_soon" : "ok"
      PracticeStatus.new(**base, tracked: true, status: status, done_at: done_at, due_on: due_on, count: count, expected: expected, met: true)
    end

    # Âncora fixa: [âncora + início, âncora + fim].
    def fixed(practice, anchor, events, today, base)
      start = anchor + practice["window_start_days"].to_i
      finish = anchor + practice["window_days"]
      matched = groups(practice).map do |group|
        group.flat_map { |alt| dates(practice, alt["source"], events, start, [ finish, today ].min) }
      end
      done_at = matched.flatten.max
      return proportional(practice, matched.first, start, finish, today, base, done_at) if practice["schedule"] == "proportional"

      need = matched.size > 1 ? 1 : practice["min_count"]
      count, expected = counts(matched, need)
      met = matched.all? { |items| items.size >= need }
      status, due_on = if met then [ "ok", nil ]
                       elsif today > finish then [ "overdue", finish ]
                       elsif (finish - today).to_i <= Catalog::DUE_SOON_DAYS then [ "due_soon", finish ]
                       else [ "ok", finish ]
                       end
      PracticeStatus.new(**base, tracked: true, status: status, done_at: done_at, due_on: due_on, count: count, expected: expected, met: met)
    end

    # Esperado hoje = ceil(min × decorrido / duração); próximo marco =
    # início + floor(feitas × duração / min) + 1 (spec, decisão do coordenador).
    def proportional(practice, items, start, finish, today, base, done_at)
      min = practice["min_count"]
      span = (finish - start).to_i
      elapsed = (today - start).to_i.clamp(0, span)
      expected = (min * elapsed + span - 1) / span
      count = items.size
      if count >= min
        return PracticeStatus.new(**base, tracked: true, status: "ok", done_at: done_at, due_on: nil, count: count, expected: min, met: true)
      end

      milestone = [ start + (count * span / min) + 1, finish ].min
      status, due_on = if today > finish || milestone <= today then [ "overdue", today > finish ? finish : milestone ]
                       elsif (milestone - today).to_i <= Catalog::DUE_SOON_DAYS then [ "due_soon", milestone ]
                       else [ "ok", milestone ]
                       end
      PracticeStatus.new(**base, tracked: true, status: status, done_at: done_at, due_on: due_on, count: count, expected: expected,
                         met: count >= expected)
    end

    def groups(practice) = practice["all_of"] || [ [ { "source" => practice["source"] } ] ]

    def counts(matched, need)
      matched.size > 1 ? [ matched.count { |items| items.size >= need }, matched.size ] : [ matched.first.size, need ]
    end

    # Datas de uma fonte na janela; consulta filtra CBO (prefixo) e código
    # (prefixo, só na lista da MESMA terminologia: CIAP N95 não casa com CID N95),
    # só nela.
    def dates(practice, source, events, from, to)
      list = events.fetch(source, [])
      if source == "consultation"
        cbos = practice["cbo_filter"]
        codes = practice["code_filter"]
        list = list.select { |e| cbos.nil? || cbos.any? { |prefix| e.cbo.to_s.start_with?(prefix) } }
        list = list.select { |e| e.codes.any? { |terminology, code| Array(codes[terminology]).any? { |prefix| code.start_with?(prefix) } } } if codes
      end
      list.map(&:on).select { |d| d >= from && d <= to }.uniq.sort
    end
    private_class_method :evaluate, :rolling, :fixed, :proportional, :groups, :counts, :dates
  end
end
