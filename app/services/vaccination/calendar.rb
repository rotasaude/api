# Calendário vacinal vigente (config/vaccination/calendar-2026.yml). Mudança de
# calendário = arquivo novo com versão; a cidade usa o vigente.
#
# Idades por aritmética de calendário (Age: anos, meses e dias somados ao
# nascimento com Date#advance), nunca em dias corridos: a fronteira cai no
# aniversário, inclusive para quem nasceu em 29/02 (aniversário em 28/02 no ano
# não bissexto). Intervalos seguem em dias. A forma do YAML está no topo dele.
#
# Para perguntar "a idade em tal data está na faixa?" (Schedule, e o
# age_out_of_range da dose na Task 8): Dose#age_status(birth:, on:) e
# AgeWindow#cover?(birth:, on:), ambos sobre Age#reached?/Age#exceeded?.
module Vaccination
  module Calendar
    UNITS = %i[years months days].freeze

    # Idade de calendário. `from(birth)` = a data em que a pessoa a atinge.
    Age = Data.define(:years, :months, :days) do
      def self.parse(raw)
        return nil if raw.nil?
        raise ArgumentError, "age: chaves fora de #{UNITS}" unless raw.is_a?(Hash) && (raw.keys.map(&:to_sym) - UNITS).empty? && raw.any?

        new(years: raw.fetch("years", 0), months: raw.fetch("months", 0), days: raw.fetch("days", 0))
      end

      def from(birth) = birth.advance(years: years, months: months, days: days)

      # Idade mínima/recomendada: atingida em `on`.
      def reached?(birth, on) = on >= from(birth)

      # Idade máxima (completa, inclusiva): passou dela em `on` quando já atingiu
      # a idade + 1 da menor unidade escrita ({ years: 4 } → 5 anos; { months: 3,
      # days: 15 } → 3 meses e 16 dias).
      def exceeded?(birth, on)
        bumped = if days.positive? || (years.zero? && months.zero?) then with(days: days + 1)
                 elsif months.positive? then with(months: months + 1)
                 else with(years: years + 1)
                 end
        on >= bumped.from(birth)
      end
    end

    Dose = Data.define(:dose_code, :min_age, :max_age, :recommended_age, :min_interval_days, :recommended_interval_days, :review, :source) do
      # :too_young | :too_old | :ok — a faixa de idade da dose em `on`.
      def age_status(birth:, on:)
        return :too_young if min_age && !min_age.reached?(birth, on)
        return :too_old if max_age&.exceeded?(birth, on)

        :ok
      end

      def recommended_on(birth) = (recommended_age || min_age)&.from(birth)
    end

    # min: Age; max: Age | nil (sem teto).
    AgeWindow = Data.define(:min, :max, :review, :source) do
      def cover?(birth:, on:) = min.reached?(birth, on) && !max&.exceeded?(birth, on)
      def starts_on(birth) = min.from(birth)
    end

    # age_window: AgeWindow | nil (decidida pelas age_bands ou pela gestação);
    # age_bands: { "child" => AgeWindow, ... } (vazio sem faixas).
    Series = Data.define(:key, :public, :accepts, :doses, :sex, :repeat_every_days, :rules, :age_window, :age_bands)
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

    # Meses completos em `on` (aritmética de calendário: 31/01 + 1 mês = 28/02).
    def completed_months(birth, on)
      months = ((on.year - birth.year) * 12) + (on.month - birth.month)
      months -= 1 while months.positive? && (birth >> months) > on
      [ months, 0 ].max
    end

    def build
      raw = YamlFiles.load("calendar-2026")
      series = raw.fetch("series").map do |s|
        doses = s.fetch("doses").map do |d|
          Dose.new(dose_code: d.fetch("dose_code"), min_age: Age.parse(d["min_age"]), max_age: Age.parse(d["max_age"]),
                   recommended_age: Age.parse(d["recommended_age"]), min_interval_days: d["min_interval_days"],
                   recommended_interval_days: d["recommended_interval_days"], review: d.fetch("review"), source: d.fetch("source"))
        end
        Series.new(key: s.fetch("key"), public: s.fetch("public"), accepts: s.fetch("accepts"), doses: doses.freeze,
                   sex: s["sex"], repeat_every_days: s["repeat_every_days"], rules: s.fetch("rules", {}),
                   age_window: age_window(s.fetch("age_window")),
                   age_bands: s.fetch("age_bands", {}).transform_values { |band| age_window(band) }.freeze)
      end
      Version.new(version: raw.fetch("version"), due_window_days: raw.fetch("due_window_days"), series: series.freeze)
    end

    def age_window(raw)
      raw && AgeWindow.new(min: Age.parse(raw.fetch("min")), max: Age.parse(raw["max"]), review: raw.fetch("review"), source: raw.fetch("source"))
    end
    private_class_method :build, :age_window
  end
end
