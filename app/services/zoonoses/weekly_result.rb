# Resultado semanal da campanha antirrábica (módulo 35b, ADR 0054; contrato
# §3, Q5, Q19): uma linha por semana epidemiológica (Surveillance::EpiWeek, a
# regra da Q22 do 35a), da semana de `starts_on` à de min(ends_on, hoje) —
# estendida até a semana da última dose, se a campanha seguiu aberta depois do
# fim (nenhuma dose fica de fora). Cães e gatos vacinados na semana e o
# acumulado, sem as doses anuladas; a meta; a cobertura sobre a meta
# (acumulado ÷ meta × 100, uma casa decimal; nil com meta 0) e, só quando há
# estimativa de população nos parâmetros (dog/cat_population_estimate > 0), a
# cobertura sobre a estimativa (Q19). Nenhuma contagem é suprimida: não há
# pessoa no agregado (Q5). Campanha ainda não começada → [].
# `today` é o dia da cidade (Time.zone.today dentro de CityConnection.with).
module Zoonoses
  module WeeklyResult
    module_function

    # -> [{ epi_week: "YYYY-WW", dogs:, cats:, dogs_total:, cats_total:, goal_dogs:, goal_cats:, dog_coverage:, cat_coverage:,
    #      dog_coverage_estimate:, cat_coverage_estimate: }]
    def for(campaign:, today: Time.zone.today, parameters: Parameters.current)
      return [] if today < campaign.starts_on

      counts = RabiesVaccination.active.where(campaign_id: campaign.id).group(:vaccinated_on, :species).count
      last_on = [ [ campaign.ends_on, today ].min, counts.keys.map(&:first).max ].compact.max
      per_week = Hash.new { |hash, key| hash[key] = { "dog" => 0, "cat" => 0 } }
      counts.each { |(day, species), count| per_week[Surveillance::EpiWeek.for(day)][species] += count }

      dog_estimate, cat_estimate = parameters.values.values_at("dog_population_estimate", "cat_population_estimate")
      dogs_total = cats_total = 0
      Surveillance::EpiWeek.between(Surveillance::EpiWeek.for(campaign.starts_on), Surveillance::EpiWeek.for(last_on)).map do |week|
        dogs, cats = per_week.fetch(week, { "dog" => 0, "cat" => 0 }).values_at("dog", "cat")
        dogs_total += dogs
        cats_total += cats
        { epi_week: week.to_s, dogs: dogs, cats: cats, dogs_total: dogs_total, cats_total: cats_total,
          goal_dogs: campaign.goal_dogs, goal_cats: campaign.goal_cats,
          dog_coverage: percent(dogs_total, campaign.goal_dogs), cat_coverage: percent(cats_total, campaign.goal_cats),
          dog_coverage_estimate: percent(dogs_total, dog_estimate), cat_coverage_estimate: percent(cats_total, cat_estimate) }
      end
    end

    # Uma casa decimal; nil sem base (meta 0, estimativa nula ou 0).
    def percent(count, base)
      return nil unless base.is_a?(Integer) && base.positive?

      (count * 100.0 / base).round(1)
    end

    private_class_method :percent
  end
end
