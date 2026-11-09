# Painel do gestor da UPA (ADR 0050; contrato §11 e §14 Q15, Q25; plano, Task 15):
#   GET /urgency/dashboard?month=YYYY-MM&health_unit_id?
# Só contagens: nenhum nome, CPF, CNS, queixa, descrição nem id de paciente ou
# de encontro. Sem trilha.
#
#   { month:, units: [ { id, name } ],
#     door_to_classification: [ { color, count, median_minutes, p90_minutes } ],
#     classification_to_physician: [ { color, count, median_minutes, p90_minutes } ],
#     over_max_wait: [ { color, count, over } ],
#     by_color: { red:, orange:, yellow:, green:, blue:, unclassified: },
#     by_outcome: { <OUTCOMES sem os NON_CARE_OUTCOMES> },
#     evasion: { before_classification:, after_classification: },
#     stay: { count, median_minutes, p90_minutes } }
#
#  - o recorte: os encontros das `units` (já autorizadas pelo controlador) com
#    chegada (`checked_in_at`) no mês, no calendário do fuso da cidade (o
#    padrão do Psychosocial::Dashboard);
#  - Q25: o encontro com desfecho NON_CARE_OUTCOMES (`registered_in_error`)
#    fica fora de TODA contagem e de todo tempo; o provisório conta como
#    qualquer visita (é uma visita real);
#  - porta → classificação: `first_classified_at - checked_in_at`, pela cor da
#    1ª classificação;
#  - classificação → médico: `called_at - first_classified_at`, e o estouro
#    (minutos inteiros > `max_wait_minutes`, a regra do UrgencyEncounter#overdue?),
#    pela classificação VIGENTE NA CHAMADA (a última com `created_at <=
#    called_at`, com o tempo máximo gravado nela);
#  - por cor: a cor vigente agora (sem classificação → `unclassified`);
#  - por desfecho: os encontros fechados, pelo `kind` do desfecho;
#  - evasão: desfecho `left_*`, antes da classificação (sem nenhuma) ou depois;
#  - permanência: `closed_at - checked_in_at` dos fechados;
#  - mediana e p90 por `percentile_cont` sobre os minutos, arredondados a
#    minutos inteiros;
#  - supressão DEPOIS de agregar (::Admin::SmallCount.small?): toda contagem
#    de 1 a 4 vira "lt5"; mediana e p90 com a contagem de 1 a 4 viram "lt5" e,
#    com 0, nil. 0 fica 0.
module Urgency
  module Dashboard
    LESS_THAN_FIVE = "lt5".freeze
    EVASION_OUTCOMES = %w[left_without_care left_against_advice].freeze
    OUTCOMES = (Catalog::OUTCOMES - Catalog::NON_CARE_OUTCOMES).freeze

    # Uma linha por encontro do recorte, com o que as agregações leem. A
    # classificação vigente na chamada pelo LATERAL (a última criada até a
    # chamada); a 1ª pela posição 1.
    BASE_SQL = <<~SQL.squish.freeze
      SELECT first_c.color AS first_color,
             EXTRACT(EPOCH FROM (e.first_classified_at - a.checked_in_at)) / 60.0 AS door_minutes,
             at_call.color AS call_color,
             at_call.max_wait_minutes AS call_max_wait,
             EXTRACT(EPOCH FROM (a.called_at - e.first_classified_at)) / 60.0 AS physician_minutes,
             current_c.color AS current_color,
             o.kind AS outcome_kind,
             e.first_classified_at IS NOT NULL AS classified,
             CASE WHEN a.closed_at IS NOT NULL THEN EXTRACT(EPOCH FROM (a.closed_at - a.checked_in_at)) / 60.0 END AS stay_minutes
        FROM urgency_encounters e
        JOIN attendances a ON a.id = e.attendance_id
        LEFT JOIN urgency_outcomes o ON o.urgency_encounter_id = e.id
        LEFT JOIN urgency_classifications first_c ON first_c.urgency_encounter_id = e.id AND first_c.position = 1
        LEFT JOIN urgency_classifications current_c ON current_c.id = e.current_classification_id
        LEFT JOIN LATERAL (
          SELECT c.color, c.max_wait_minutes
            FROM urgency_classifications c
           WHERE c.urgency_encounter_id = e.id AND c.created_at <= a.called_at
           ORDER BY c.position DESC
           LIMIT 1
        ) at_call ON a.called_at IS NOT NULL AND e.first_classified_at IS NOT NULL
       WHERE a.health_unit_id IN (:unit_ids)
         AND a.checked_in_at >= :from AND a.checked_in_at < :to
         AND (o.kind IS NULL OR o.kind NOT IN (:non_care))
    SQL

    module_function

    # units: [HealthUnit] UPAs ativas; month: Date. -> Hash
    def call(units:, month:)
      units = units.to_a.sort_by { |unit| [ unit.name, unit.id ] }
      month = month.to_date.beginning_of_month
      binds = { unit_ids: units.map(&:id).presence || [ nil ], from: month.in_time_zone,
                to: (month.end_of_month + 1).in_time_zone, non_care: Catalog::NON_CARE_OUTCOMES }
      { month: month.strftime("%Y-%m"),
        units: units.map { |unit| { id: unit.id, name: unit.name } },
        door_to_classification: times_by_color(binds, color: "first_color", minutes: "door_minutes"),
        classification_to_physician: times_by_color(binds, color: "call_color", minutes: "physician_minutes"),
        over_max_wait: over_max_wait(binds),
        by_color: by_color(binds),
        by_outcome: by_outcome(binds),
        evasion: evasion(binds),
        stay: stay(binds) }
    end

    def suppress(count) = ::Admin::SmallCount.small?(count) ? LESS_THAN_FIVE : count

    # Mediana e p90 de quem tem a contagem: 1 a 4 → "lt5"; 0 → nil.
    def time(count, value)
      return nil if count.zero?
      return LESS_THAN_FIVE if ::Admin::SmallCount.small?(count)

      value.to_f.round
    end

    def times_by_color(binds, color:, minutes:)
      rows = select(binds, <<~SQL.squish).index_by { |row| row["color"] }
        SELECT #{color} AS color, COUNT(*) AS count,
               percentile_cont(0.5) WITHIN GROUP (ORDER BY #{minutes}) AS median,
               percentile_cont(0.9) WITHIN GROUP (ORDER BY #{minutes}) AS p90
          FROM base WHERE #{color} IS NOT NULL AND #{minutes} IS NOT NULL GROUP BY #{color}
      SQL
      Catalog::COLORS.map do |item|
        row = rows[item] || {}
        count = row.fetch("count", 0).to_i
        { color: item, count: suppress(count), median_minutes: time(count, row["median"]), p90_minutes: time(count, row["p90"]) }
      end
    end

    def over_max_wait(binds)
      rows = select(binds, <<~SQL.squish).index_by { |row| row["color"] }
        SELECT call_color AS color, COUNT(*) AS count,
               COUNT(*) FILTER (WHERE FLOOR(physician_minutes) > call_max_wait) AS over
          FROM base WHERE call_color IS NOT NULL AND physician_minutes IS NOT NULL GROUP BY call_color
      SQL
      Catalog::COLORS.map do |item|
        row = rows[item] || {}
        { color: item, count: suppress(row.fetch("count", 0).to_i), over: suppress(row.fetch("over", 0).to_i) }
      end
    end

    def by_color(binds)
      counts = select(binds, "SELECT current_color AS color, COUNT(*) AS count FROM base GROUP BY current_color")
               .to_h { |row| [ row["color"] || "unclassified", row["count"].to_i ] }
      (Catalog::COLORS + [ "unclassified" ]).to_h { |item| [ item.to_sym, suppress(counts.fetch(item, 0)) ] }
    end

    def by_outcome(binds)
      counts = select(binds, "SELECT outcome_kind AS kind, COUNT(*) AS count FROM base WHERE outcome_kind IS NOT NULL GROUP BY outcome_kind")
               .to_h { |row| [ row["kind"], row["count"].to_i ] }
      OUTCOMES.to_h { |kind| [ kind.to_sym, suppress(counts.fetch(kind, 0)) ] }
    end

    def evasion(binds)
      row = select(binds, <<~SQL.squish, evasion: EVASION_OUTCOMES).first
        SELECT COUNT(*) FILTER (WHERE NOT classified) AS before_classification,
               COUNT(*) FILTER (WHERE classified) AS after_classification
          FROM base WHERE outcome_kind IN (:evasion)
      SQL
      { before_classification: suppress(row["before_classification"].to_i), after_classification: suppress(row["after_classification"].to_i) }
    end

    def stay(binds)
      row = select(binds, <<~SQL.squish).first
        SELECT COUNT(*) AS count,
               percentile_cont(0.5) WITHIN GROUP (ORDER BY stay_minutes) AS median,
               percentile_cont(0.9) WITHIN GROUP (ORDER BY stay_minutes) AS p90
          FROM base WHERE stay_minutes IS NOT NULL
      SQL
      count = row["count"].to_i
      { count: suppress(count), median_minutes: time(count, row["median"]), p90_minutes: time(count, row["p90"]) }
    end

    def select(binds, aggregate_sql, **extra)
      sql = ApplicationRecord.sanitize_sql_array([ "WITH base AS (#{BASE_SQL}) #{aggregate_sql}", binds.merge(extra) ])
      ApplicationRecord.connection.select_all(sql).to_a
    end

    private_class_method :time, :times_by_color, :over_max_wait, :by_color, :by_outcome, :evasion, :stay, :select
  end
end
