# Índices do LIRAa por estrato e do município (módulo 35a, ADR 0054; contrato
# §7; Q16(e), Q20(1)). Só as inspeções `worked` ligadas aos itens do
# levantamento, a mais recente de cada item (visita, criação, id):
#   - inspected = itens com inspeção; positivo = amostra com aegypti_larvae > 0
#     (um tubito por depósito); imóvel positivo = com alguma amostra positiva;
#   - IIP = imóveis positivos ÷ inspecionados × 100; IB = recipientes positivos ÷
#     inspecionados × 100; ITR(g) = positivos do grupo g ÷ positivos × 100. Uma
#     casa, meio para cima, ANTES de classificar (Q16(e)); em texto ("3.0"),
#     como os decimais do 27a (Q8); nil sem denominador;
#   - iip_class pelas iip_bands da versão do sorteio: < 1,0 "Satisfatório",
#     1,0–3,9 "Alerta", ≥ 4,0 "Risco";
#   - provisional = há amostra contada sem resultado;
#   - planned = itens do sorteio; substitutions = substitutos; missing =
#     substituídos sem substituto (quarteirão com um a menos, W-13).
# Levantamento fechado: o conjunto de inspeções congela em closed_at (criadas
# até lá; a retirada depois do fechamento não tira a inspeção): o retrato
# oficial do levantamento (Q30). Os resultados
# de laboratório das amostras dessas inspeções seguem valendo.
module VectorControl
  module Liraa
    module Index
      SATISFACTORY = "Satisfatório".freeze
      ALERT = "Alerta".freeze
      RISK = "Risco".freeze

      module_function

      def for(survey)
        strata = survey.strata.order(:created_at, :id).to_a
        items = LiraaDrawItem.where(liraa_stratum_id: strata.map(&:id)).pluck(:id, :liraa_stratum_id, :status, :substitute_of_id)
        latest = latest_inspections(survey, items.map(&:first))
        samples = VectorSample.where(vector_inspection_id: latest.values)
                              .pluck(:vector_inspection_id, :deposit_group, :aegypti_larvae, :result_at)
                              .group_by(&:first)
        parameters = survey.parameters_version ? Parameters.at(survey.parameters_version) : Parameters.current
        bands = parameters.values.fetch("iip_bands") { Parameters.defaults.fetch("iip_bands") }

        by_stratum = items.group_by { |row| row[1] }
        rows = strata.map do |stratum|
          counts = counts(by_stratum.fetch(stratum.id, []), latest, samples)
          { id: stratum.id, name: stratum.name }.merge(summary(counts, bands))
        end
        { strata: rows, municipality: summary(counts(items, latest, samples), bands) }
      end

      # -> { iip:, ib:, itr:, iip_class: } (puro).
      def indices(inspected:, positive_households:, positive_containers:, by_group:, bands:)
        iip = percent(positive_households, inspected)
        { iip: text(iip), ib: text(percent(positive_containers, inspected)),
          itr: Catalog::DEPOSIT_GROUPS.to_h { |group| [ group, text(percent(by_group.fetch(group, 0), positive_containers)) ] },
          iip_class: iip && iip_class(iip, bands) }
      end

      def iip_class(iip, bands)
        low, high = bands.map { |band| BigDecimal(band.to_s) }
        if iip < low then SATISFACTORY
        elsif iip < high then ALERT
        else RISK
        end
      end

      # Uma casa, meio para cima (BigDecimal | nil).
      def percent(part, whole)
        return nil if whole.zero?

        (BigDecimal(part) * 100 / whole).round(1, BigDecimal::ROUND_HALF_UP)
      end

      def text(value) = value&.to_s("F")

      # { item_id => inspection_id } da inspeção worked mais recente de cada item.
      def latest_inspections(survey, item_ids)
        return {} if item_ids.empty?

        scope = VectorInspection.joins(:home_visit).where(liraa_draw_item_id: item_ids, situation: "worked")
        scope = if survey.closed_at
                  scope.where("vector_inspections.created_at <= ?", survey.closed_at)
                       .where("home_visits.withdrawn_at IS NULL OR home_visits.withdrawn_at > ?", survey.closed_at)
                else
                  scope.merge(HomeVisit.valid)
                end
        scope.order(Arel.sql("home_visits.occurred_at DESC, vector_inspections.created_at DESC, vector_inspections.id DESC"))
             .pluck(:id, :liraa_draw_item_id)
             .each_with_object({}) { |(id, item_id), latest| latest[item_id] ||= id }
      end

      def counts(items, latest, samples)
        substituted_ids = items.filter_map { |id, _, status, _| id if status == "substituted" }
        replaced = items.filter_map { |row| row[3] }.to_set
        counts = { inspected: 0, positive_households: 0, positive_containers: 0, by_group: Hash.new(0), provisional: false,
                   planned: items.count { |row| row[3].nil? }, substitutions: replaced.size,
                   missing: substituted_ids.count { |id| !replaced.include?(id) } }
        items.each do |id, *|
          inspection_id = latest[id]
          next unless inspection_id

          counts[:inspected] += 1
          positives = samples.fetch(inspection_id, []).select do |_, _, aegypti, result_at|
            counts[:provisional] = true if result_at.nil?
            aegypti.to_i.positive?
          end
          counts[:positive_households] += 1 if positives.any?
          counts[:positive_containers] += positives.size
          positives.each { |_, group, *| counts[:by_group][group] += 1 }
        end
        counts
      end

      def summary(counts, bands)
        { inspected: counts[:inspected], positive_households: counts[:positive_households],
          positive_containers: counts[:positive_containers] }
          .merge(indices(inspected: counts[:inspected], positive_households: counts[:positive_households],
                         positive_containers: counts[:positive_containers], by_group: counts[:by_group], bands: bands))
          .merge(provisional: counts[:provisional], planned: counts[:planned], substitutions: counts[:substitutions],
                 missing: counts[:missing])
      end
    end
  end
end
