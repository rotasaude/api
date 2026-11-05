# Noites e limite do acolhimento noturno (ADR 0049; plano, Desvio 1; contrato
# §5, P13, P36).
#
# Noite (P61) = cada data local D com `início.to_date ≤ D < fim.to_date`
# (meio-aberto); entrada e saída no mesmo dia valem 0 noite. O fim é o
# `effective_end` (P62): a encerrada termina em `ended_at` (as noites reais);
# a aberta, em max(expected_end_at, a noite de hoje) — além do previsto, conta
# até hoje, como o painel (P52). As noites do paciente contam em qualquer CAPS
# da cidade.
#
# Limite por modalidade (PsychosocialSetting#night_limits), numa janela de
# `window_days` dias:
#   AD III/IV — `total`: passa quando alguma janela que contém uma noite nova
#     tem mais de `total` noites;
#   CAPS III — `consecutive`: passa quando a sequência de noites seguidas que
#     contém uma noite nova é maior que `consecutive`; senão `alternate`: o
#     total da janela, como no AD.
# Modalidade sem limite configurado: nunca passa.
module Psychosocial
  module NightLimit
    module_function

    # stay_or_range: PsychosocialNightStay ou Range de instantes (início..fim);
    # `today` só vale para a permanência aberta (effective_end).
    # -> [Date] em ordem (vazio quando entra e sai no mesmo dia).
    def nights(stay_or_range, today: Time.zone.today)
      first, last = if stay_or_range.is_a?(Range)
        [ stay_or_range.begin, stay_or_range.end ]
      else
        [ stay_or_range.started_at, effective_end(stay_or_range, today: today) ]
      end
      (first.in_time_zone.to_date...last.in_time_zone.to_date).to_a
    end

    # Fim efetivo da permanência (P62): `ended_at`; aberta, o maior entre
    # `expected_end_at` e o início do dia seguinte a `today` (a noite de hoje
    # conta). -> Time
    def effective_end(stay, today: Time.zone.today)
      stay.ended_at || [ stay.expected_end_at, (today + 1).in_time_zone ].max
    end

    # -> nil | { used:, limit:, window_days:, rule: "total" | "consecutive" | "alternate" }
    def check(patient_id:, modality:, new_nights:, settings:, except_stay_id: nil)
      limits = settings.night_limits[modality]
      return nil if limits.blank? || new_nights.empty?

      window_days = limits.fetch("window_days")
      fresh = new_nights.uniq.sort
      span = (fresh.first - window_days + 1)..(fresh.last + window_days - 1)
      all = (existing_nights(patient_id, span, except_stay_id) + fresh).uniq.sort

      if limits.key?("total")
        verdict(window_total(all, fresh, window_days), limits["total"], window_days, "total")
      else
        verdict(longest_run(all, fresh), limits["consecutive"], window_days, "consecutive") ||
          verdict(window_total(all, fresh, window_days), limits["alternate"], window_days, "alternate")
      end
    end

    # Noites usadas na janela que termina em `date` (o mapa de leitos): -> nil
    # (sem limite) | { used:, limit: } — o limite é o total da janela (AD) ou
    # as alternadas (CAPS III).
    def used(patient_id:, modality:, date:, settings:)
      limits = settings.night_limits[modality]
      return nil if limits.blank?

      window = (date - limits.fetch("window_days") + 1)..date
      { used: existing_nights(patient_id, window, nil).size, limit: limits["total"] || limits["alternate"] }
    end

    # Noites das permanências do paciente (abertas até o effective_end: a
    # vencida há muito ainda conta) dentro de `window` (Range de Date), sem a
    # permanência `except_stay_id`.
    # -> [Date] sem repetição, em ordem.
    def existing_nights(patient_id, window, except_stay_id)
      from = window.first.in_time_zone.beginning_of_day
      to = (window.last + 1).in_time_zone.beginning_of_day
      scope = PsychosocialNightStay.where(patient_id: patient_id).where(started_at: ...to)
                                   .where("ended_at IS NULL OR ended_at > ?", from)
      scope = scope.where.not(id: except_stay_id) if except_stay_id
      scope.to_a.flat_map { |stay| nights(stay) }.select { |night| window.cover?(night) }.uniq.sort
    end

    def verdict(used, limit, window_days, rule)
      return nil if limit.nil? || used <= limit

      { used: used, limit: limit, window_days: window_days, rule: rule }
    end

    # Maior total entre as janelas de `window_days` que contêm alguma noite nova.
    def window_total(all, fresh, window_days)
      (fresh.first..(fresh.last + window_days - 1)).map do |last|
        first = last - window_days + 1
        next 0 unless fresh.any? { |night| night.between?(first, last) }

        all.count { |night| night.between?(first, last) }
      end.max
    end

    # Maior sequência de noites seguidas que contém alguma noite nova.
    def longest_run(all, fresh)
      runs = all.slice_when { |a, b| b != a + 1 }
      runs.select { |run| run.intersect?(fresh) }.map(&:size).max || 0
    end

    private_class_method :verdict, :window_total, :longest_run
  end
end
