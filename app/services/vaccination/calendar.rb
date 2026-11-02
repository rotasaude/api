# Calendário vacinal vigente (config/vaccination/calendar-2026.yml). Mudança de
# calendário = arquivo novo com versão; a cidade usa o vigente.
module Vaccination
  module Calendar
    Dose = Data.define(:dose_code, :min_age_days, :max_age_days, :recommended_age_days, :min_interval_days,
                       :recommended_interval_days, :review, :source)
    # age_window: { min_days:, max_days: (nil = sem teto), review:, source: } | nil (série decidida pelas `rules`).
    AgeWindow = Data.define(:min_days, :max_days, :review, :source) do
      def cover?(age_days) = age_days >= min_days && (max_days.nil? || age_days <= max_days)
    end
    Series = Data.define(:key, :public, :accepts, :doses, :sex, :repeat_every_days, :rules, :age_window)
    Version = Data.define(:version, :due_window_days, :series) do
      # [Series, Dose] da primeira série que aceita o imunobiológico e tem a dose; nil se não houver.
      def entry(immunobiological_code, dose_code)
        series.each do |s|
          next unless s.accepts.include?(Immunobiologicals.normalize(immunobiological_code))

          dose = s.doses.find { |d| d.dose_code == dose_code.to_s }
          return [ s, dose ] if dose
        end
        nil
      end
    end

    module_function

    def current = (@current ||= build)

    def build
      raw = YamlFiles.load("calendar-2026")
      series = raw.fetch("series").map do |s|
        doses = s.fetch("doses").map do |d|
          Dose.new(dose_code: d.fetch("dose_code"), min_age_days: d["min_age_days"], max_age_days: d["max_age_days"],
                   recommended_age_days: d["recommended_age_days"], min_interval_days: d["min_interval_days"],
                   recommended_interval_days: d["recommended_interval_days"], review: d.fetch("review"), source: d.fetch("source"))
        end
        Series.new(key: s.fetch("key"), public: s.fetch("public"), accepts: s.fetch("accepts"), doses: doses.freeze,
                   sex: s["sex"], repeat_every_days: s["repeat_every_days"], rules: s.fetch("rules", {}),
                   age_window: age_window(s.fetch("age_window")))
      end
      Version.new(version: raw.fetch("version"), due_window_days: raw.fetch("due_window_days"), series: series.freeze)
    end
    def age_window(raw)
      raw && AgeWindow.new(min_days: raw.fetch("min_days"), max_days: raw["max_days"], review: raw.fetch("review"), source: raw.fetch("source"))
    end
    private_class_method :build, :age_window
  end
end
