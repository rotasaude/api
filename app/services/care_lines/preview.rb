# Prévia de C2–C7 por equipe (ADR 0040; spec §2 decisão 9; plano, Desvio
# 13). ESTIMATIVA: regras da versão mais recente do template; população
# elegível da equipe, inscrita ou não; práticas não rastreadas fora, com os
# pesos restantes redistribuídos; denominador por prática (faixa da C7).
# Também saem da conta (e do peso): a prática rastreada sem ninguém no
# denominador (`no_eligible`) e, em `end_of_window`, quem ainda não cumpriu
# enquanto a janela está aberta (ainda dá tempo).
# Agregado, sem nome e sem trilha (não há leitura nominal): a resposta traz
# só contagens, a nota e a equipe. O oficial é do SIAPS.
module CareLines
  module Preview
    INDICATORS = %w[C2 C3 C4 C5 C6 C7].freeze
    # NT 8/2026: Ótimo > 75; Bom > 50; Suficiente > 25; Regular ≤ 25.
    CONCEPTS = [ [ 75, "optimal" ], [ 50, "good" ], [ 25, "sufficient" ] ].freeze

    module_function

    # nil quando o catálogo-base do indicador não está carregado.
    def call(team:, indicator:, today:)
      key = Catalog::INDICATORS.key(indicator)
      template = key && CareLineTemplate.current(key)
      return nil unless template

      practices = template.practices
      line = CareLine.find_by(source: "template", template_key: key)
      population = TeamPopulation.call(team: team, line: line, rules: template.eligibility, on: today)
      items = population.map do |person, enrollment|
        { key: person.key, practices: practices, person: person,
          anchors: { "enrollment" => enrollment&.enrolled_at&.in_time_zone&.to_date, "birth" => person.birth_date, "lmp" => enrollment&.anchor_on } }
      end
      rows = Evaluation.items(items, today: today).values

      per_practice = per_practice(practices, rows)
      # Sem nenhuma prática rastreada com denominador: "sem dados" (nil), nunca 0.
      counted = per_practice.select { |p| p[:tracked] && p[:denominator].positive? }
      score = counted.empty? ? nil : counted.sum { |p| p[:weight_value] * p[:achieved] / p[:denominator] }

      grade = score && grade(score)
      { indicator: indicator, team: { id: team.id, ine: team.ine, name: team.name }, template_version: template.version,
        denominator: rows.size, score: grade&.first, max_score: 100, concept: grade&.last,
        practices: per_practice.map { |p| p.except(:weight_value) },
        excluded: practices.select { |p| Catalog.untracked?(p["source"]) }.map { |p| p["source"].split(":").first }.uniq,
        excluded_practices: per_practice.filter_map { |p| exclusion(p) }, estimate: true }
    end

    # Pesos das práticas rastreadas COM denominador redistribuídos para somar
    # 100 (Rational: sem erro de ponto flutuante na borda dos conceitos).
    def per_practice(practices, rows)
      rows_by_practice = practices.map do |practice|
        statuses = rows.filter_map { |row| row.practices.find { |s| s.key == practice["key"] } }
        tracked = !Catalog.untracked?(practice["source"])
        [ practice, tracked, tracked ? statuses.reject { |s| open_window?(practice, s) } : statuses ]
      end
      base = rows_by_practice.sum { |practice, tracked, list| tracked && list.any? ? practice["points"].to_i : 0 }
      rows_by_practice.map do |practice, tracked, list|
        weight = tracked && list.any? && base.positive? ? Rational(practice["points"].to_i * 100, base) : 0r
        { key: practice["key"], label: practice["label"], tracked: tracked, points: practice["points"], weight_value: weight,
          weight: one_decimal(weight), achieved: list.count(&:met), denominator: list.size }
      end
    end

    # `end_of_window` com a janela ainda aberta e não cumprida: ainda dá tempo,
    # a pessoa sai do denominador da prática (quem cumpriu fica). Usa o
    # PracticeStatus do Evaluate (status ≠ overdue = prazo não venceu); janela
    # móvel (`rolling`) e `proportional` ficam como estão.
    def open_window?(practice, status)
      practice["schedule"] == "end_of_window" && practice["anchor"] != "rolling" && !status.met && status.status != "overdue"
    end

    # Motivo de a prática ficar fora da conta (`excluded_practices`).
    def exclusion(practice)
      return { key: practice[:key], reason: "untracked" } unless practice[:tracked]

      { key: practice[:key], reason: "no_eligible" } if practice[:denominator].zero?
    end

    # Nota e conceito saem do MESMO valor arredondado (uma casa, half-up): o
    # "75,0" da tela nunca vem com "Ótimo" (> 75). Recebe Rational.
    def grade(score)
      rounded = score.round(1, half: :up)
      [ format("%.1f", rounded.to_f), concept(rounded) ]
    end

    def one_decimal(value) = format("%.1f", value.round(1, half: :up).to_f)

    def concept(score) = CONCEPTS.find { |limit, _| score > limit }&.last || "regular"
    private_class_method :per_practice, :open_window?, :exclusion, :one_decimal, :concept
  end
end
