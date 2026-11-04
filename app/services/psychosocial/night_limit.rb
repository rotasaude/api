# Noites e limite do acolhimento noturno (ADR 0049; plano, Desvio 1; contrato
# §5, P13, P36).
#
# Noite = a data local de cada entrada: `início.to_date ... fim.to_date`
# (meio-aberto, no mínimo uma), com `fim = ended_at || expected_end_at`. As
# noites do paciente contam em qualquer CAPS da cidade.
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

    # stay_or_range: PsychosocialNightStay ou Range de instantes (início..fim).
    # -> [Date] em ordem.
    def nights(stay_or_range)
      first, last = if stay_or_range.is_a?(Range)
        [ stay_or_range.begin, stay_or_range.end ]
      else
        [ stay_or_range.started_at, stay_or_range.ended_at || stay_or_range.expected_end_at ]
      end
      from = first.in_time_zone.to_date
      to = [ last.in_time_zone.to_date, from + 1 ].max
      (from...to).to_a
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

    # Noites das permanências do paciente (abertas contam até expected_end_at)
    # dentro de `window` (Range de Date), sem a permanência `except_stay_id`.
    # -> [Date] sem repetição, em ordem.
    def existing_nights(patient_id, window, except_stay_id)
      from = window.first.in_time_zone.beginning_of_day
      to = (window.last + 1).in_time_zone.beginning_of_day
      scope = PsychosocialNightStay.where(patient_id: patient_id).where(started_at: ...to)
                                   .where("COALESCE(ended_at, expected_end_at) > ?", from)
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
