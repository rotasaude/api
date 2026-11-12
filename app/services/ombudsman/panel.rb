# Painel da ouvidoria (ADR 0051; contrato §11; §16 Q17, Q28, Q49). Só
# agregados em SQL, nenhum texto nem dado de pessoa.
#
# Universo = manifestações com `received_at` no período (dias locais da
# cidade, inclusive). Os totais (o de cima, o de cada grupo e
# `satisfaction.responses`) saem sempre: qualquer partição à mostra os
# entrega. Por isso cada partição (tipo, canal, estado, assunto com
# `unclassified`, unidade, `met`, `clear`) leva a supressão COMPLEMENTAR
# (Q53): com ao menos uma célula de 1..4 escondida, esconde-se também a menor
# célula visível não nula até haver 2 escondidas somando 5 ou mais; zeros
# ficam à mostra (`protect`). Taxas (`on_time_rate`, `resolution_rate`)
# escondem também quando o complemento (den - num) está em 1..4; médias
# (`avg_days_to_conclude`, `avg_score`) escondidas com 1..4 casos e `nil` sem
# caso.
#
# - `on_time_rate`: das concluídas (concluded_at), as com data local de
#   conclusão <= due_on. O prazo é SEMPRE o da configuração vigente
#   (Deadlines.due_on_sql, Q17).
# - `avg_days_to_conclude`: dias locais de cycle_started_on a concluded_at.
# - `resolution_rate`: resolvidas sobre as que têm resolutividade.
# - `by_subject`: assunto de 1º nível (o subassunto soma no pai), na ordem
#   do cadastro; as sem assunto fecham a lista (Q49):
#   `{ id: nil, name: nil, unclassified: true, count: }`.
module Ombudsman
  module Panel
    SUPPRESSED = Analytics::Suppression::SUPPRESSED

    module_function

    # -> Hash (chaves simbólicas; datas do período em ISO 8601)
    def call(from:, to:, today:)
      from = from.to_date
      to = to.to_date
      scope = universe(from, to)
      kinds = counts(scope, :kind, Catalog::KINDS)
      channels = counts(scope, :channel, Catalog::CHANNELS)
      states = counts(scope, :state, Catalog::STATES)
      subjects = subject_counts(scope)
      total = scope.count

      { period: { from: from.iso8601, to: to.iso8601 },
        total: total,
        by_kind: cells(kinds, total),
        by_channel: cells(channels, total),
        by_state: cells(states, total),
        by_subject: by_subject(subjects),
        by_health_unit: by_health_unit(scope) }
        .merge(rates(scope, today), satisfaction: satisfaction(scope))
    end

    # -> [{ professional: { id, name }, by_kind: { kind => n }, total: }]: contagem
    # crua por profissional referido e tipo (o painel dele é só do ouvidor), por nome.
    def professionals(from:, to:)
      rows = universe(from.to_date, to.to_date).where.not(referred_professional_id: nil).group(:referred_professional_id, :kind).count
      names = Professional.where(id: rows.keys.map(&:first)).pluck(:id, :professional_name).to_h
      rows.keys.map(&:first).uniq.map do |id|
        by_kind = Catalog::KINDS.index_with { |kind| rows.fetch([ id, kind ], 0) }
        { professional: { id: id, name: names[id] }, by_kind: by_kind, total: by_kind.values.sum }
      end.sort_by { |item| [ item[:professional][:name].to_s, item[:professional][:id] ] }
    end

    def universe(from, to)
      OmbudsmanManifestation.where(received_at: from.in_time_zone.beginning_of_day...(to + 1).in_time_zone.beginning_of_day)
    end

    # { valor => contagem crua }, com 0 para o que não apareceu.
    def counts(scope, column, values)
      found = scope.group(column).count
      values.index_with { |value| found.fetch(value, 0) }
    end

    # Cada contagem como célula (supressão complementar) e o total do grupo.
    def cells(counts, total)
      protect(counts).symbolize_keys.merge(total: total)
    end

    # Q53: { chave => contagem crua } → { chave => célula }. Com ao menos uma
    # de 1..4, esconde também a menor visível não nula até haver 2 escondidas
    # somando 5 ou mais (ou não restar o que esconder). Empate: a primeira.
    def protect(counts)
      hidden = counts.select { |_, count| Admin::SmallCount.small?(count) }.keys
      unless hidden.empty?
        candidates = counts.reject { |key, count| hidden.include?(key) || count.zero? }.sort_by { |_, count| count }.map(&:first)
        hidden << candidates.shift while (hidden.size < 2 || hidden.sum { |key| counts[key] } < 5) && candidates.any?
      end
      counts.to_h { |key, count| [ key, hidden.include?(key) ? SUPPRESSED : count ] }
    end

    # Taxa em %: esconde também quando o complemento está em 1..4.
    def rate(numerator, denominator)
      value = Analytics::Suppression.rate(numerator, denominator)
      value.is_a?(Numeric) && Admin::SmallCount.small?(denominator.to_i - numerator.to_i) ? SUPPRESSED : value
    end

    # { id do assunto de 1º nível (ou nil) => contagem crua }.
    def subject_counts(scope)
      found = scope.left_joins(:subject).group("COALESCE(ombudsman_subjects.parent_id, ombudsman_subjects.id)").count
      OmbudsmanSubject.where(parent_id: nil).order(:position, :name).pluck(:id).index_with { |id| found.fetch(id, 0) }
                      .merge(nil => found.fetch(nil, 0))
    end

    def by_subject(subjects)
      names = OmbudsmanSubject.where(id: subjects.keys.compact).pluck(:id, :name).to_h
      cells = protect(subjects)
      items = cells.except(nil).map { |id, count| { id: id, name: names[id], count: count } }
      items << { id: nil, name: nil, unclassified: true, count: cells.fetch(nil) }
    end

    def by_health_unit(scope)
      found = scope.where.not(referred_health_unit_id: nil).group(:referred_health_unit_id).count
      names = HealthUnit.where(id: found.keys).pluck(:id, :name).to_h
      protect(found).map { |id, count| { id: id, name: names[id], count: count } }
           .sort_by { |item| [ item[:name].to_s, item[:id] ] }
    end

    # on_time_rate, avg_days_to_conclude e resolution_rate.
    def rates(scope, today)
      zone = Time.zone.tzinfo.name
      concluded_on = OmbudsmanManifestation.sanitize_sql_array([ "((ombudsman_manifestations.concluded_at AT TIME ZONE 'UTC') AT TIME ZONE ?)::date", zone ])
      due_on = Deadlines.due_on_sql(OmbudsmanSetting.current, today: today)
      concluded, on_time, days = scope.where.not(concluded_at: nil).pick(
        Arel.sql("COUNT(*)"),
        Arel.sql("COUNT(*) FILTER (WHERE #{concluded_on} <= #{due_on})"),
        Arel.sql("AVG(#{concluded_on} - ombudsman_manifestations.cycle_started_on)")
      )
      with_resolution, resolved = scope.where.not(resolution: nil).pick(
        Arel.sql("COUNT(*)"), Arel.sql("COUNT(*) FILTER (WHERE resolution = 'resolved')")
      )
      { on_time_rate: rate(on_time, concluded),
        avg_days_to_conclude: average(concluded, days),
        resolution_rate: rate(resolved, with_resolution) }
    end

    # `responses`, `met`, `clear` e `avg_score` das respostas das manifestações do universo.
    def satisfaction(scope)
      responses = OmbudsmanSatisfactionResponse.where(ombudsman_manifestation_id: scope.select(:id))
      met = Catalog::MET.index_with { |value| responses.where(met: value).count }
      clear = { yes: responses.where(clear: true).count, no: responses.where(clear: false).count }
      count, score = responses.pick(Arel.sql("COUNT(*)"), Arel.sql("AVG(score)"))
      { responses: count,
        met: protect(met).symbolize_keys,
        clear: protect(clear),
        avg_score: average(count, score) }
    end

    # Média: nil sem caso, escondida com 1..4 casos, senão com 1 casa.
    def average(count, value)
      return nil if count.to_i.zero?
      return SUPPRESSED if Admin::SmallCount.small?(count.to_i)

      value.to_f.round(1)
    end

    private_class_method :universe, :counts, :cells, :protect, :rate, :subject_counts, :by_subject, :by_health_unit, :rates, :satisfaction, :average
  end
end
