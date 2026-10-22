# Prévia de C2–C7 por equipe (ADR 0040; spec §2 decisão 9; plano, Desvio
# 13). ESTIMATIVA: regras da versão mais recente do template; população
# elegível da equipe, inscrita ou não; práticas não rastreadas fora, com os
# pesos restantes redistribuídos; denominador por prática (faixa da C7).
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
      score = rows.empty? ? nil : per_practice.sum { |p| p[:denominator].zero? ? 0r : p[:weight_value] * p[:achieved] / p[:denominator] }

      grade = score && grade(score)
      { indicator: indicator, team: { id: team.id, ine: team.ine, name: team.name }, template_version: template.version,
        denominator: rows.size, score: grade&.first, max_score: 100, concept: grade&.last,
        practices: per_practice.map { |p| p.except(:weight_value) },
        excluded: practices.select { |p| Catalog.untracked?(p["source"]) }.map { |p| p["source"].split(":").first }.uniq,
        estimate: true }
    end

    # Pesos das práticas rastreadas redistribuídos para somar 100 (Rational:
    # sem erro de ponto flutuante na borda dos conceitos).
    def per_practice(practices, rows)
      tracked_points = practices.reject { |p| Catalog.untracked?(p["source"]) }.sum { |p| p["points"].to_i }
      practices.map do |practice|
        statuses = rows.filter_map { |row| row.practices.find { |s| s.key == practice["key"] } }
        tracked = !Catalog.untracked?(practice["source"])
        weight = tracked && tracked_points.positive? ? Rational(practice["points"].to_i * 100, tracked_points) : 0r
        { key: practice["key"], label: practice["label"], tracked: tracked, points: practice["points"], weight_value: weight,
          weight: one_decimal(weight), achieved: statuses.count(&:met), denominator: statuses.size }
      end
    end

    # Nota e conceito saem do MESMO valor arredondado (uma casa, half-up): o
    # "75,0" da tela nunca vem com "Ótimo" (> 75). Recebe Rational.
    def grade(score)
      rounded = score.round(1, half: :up)
      [ format("%.1f", rounded.to_f), concept(rounded) ]
    end

    def one_decimal(value) = format("%.1f", value.round(1, half: :up).to_f)

    def concept(score) = CONCEPTS.find { |limit, _| score > limit }&.last || "regular"
    private_class_method :per_practice, :one_decimal, :concept
  end
end
