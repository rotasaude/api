# Calendário vacinal vigente (config/vaccination/calendar-2026.yml). Mudança de
# calendário = arquivo novo com versão; a cidade usa o vigente.
module Vaccination
  module Calendar
    Dose = Data.define(:dose_code, :min_age_days, :max_age_days, :recommended_age_days, :min_interval_days,
                       :recommended_interval_days, :review, :source)
    Series = Data.define(:key, :public, :accepts, :doses, :sex, :repeat_every_days, :rules)
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
                   sex: s["sex"], repeat_every_days: s["repeat_every_days"], rules: s.fetch("rules", {}))
      end
      Version.new(version: raw.fetch("version"), due_window_days: raw.fetch("due_window_days"), series: series.freeze)
    end
    private_class_method :build
  end
end
