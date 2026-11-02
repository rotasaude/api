# Motor do calendário (ADR 0047; Desvio 10): Ruby puro sobre o calendário
# vigente. Recebe as doses ATIVAS da pessoa e devolve um Item por dose do
# calendário que cabe a ela, com a situação em `today`.
#
# Regras:
#  - dose aplicada da série (qualquer código de `accepts`) casa com a dose de
#    mesmo `dose_code`; dose cujo código não está na série conta para a menor
#    dose pendente (pela data); repetição de um código já casado não avança;
#  - idades por aritmética de calendário (Calendar::Age; nunca dias corridos);
#  - due_on = max(nascimento + recommended_age, anterior.on +
#    recommended_interval_days (ou min_interval_days)); dose anterior pendente
#    → upcoming sem data. SEM CONFERÊNCIA, a dose de anterior pendente cuja
#    idade recomendada já passou da janela vira `unchecked` (Review Focus 2:
#    a caderneta pode ter a anterior; nenhum item passado fica "a vir");
#  - passou da max_age (completa, inclusiva) sem a dose → not_applicable;
#  - today < due_on → upcoming; até due_on + due_window_days → due; depois →
#    overdue, ou unchecked sem conferência (nunca overdue sem conferência);
#  - série que se repete (repeat_every_days): a última dose de qualquer código
#    de `accepts` + o período;
#    nenhuma → devida a partir da idade mínima da faixa da pessoa;
#  - dtpa_pregnancy (regra pregnant_from_week): só com `pregnant_since` e a
#    partir de pregnant_since + semanas; só conta a dose desta gestação.
#
# Quem entra na série vem só do YAML do calendário (revisão de enfermagem,
# gate de go-live): a `age_window` da série (com `review`/`source`); as
# `age_bands` (influenza) quando houver; "pregnant" exige
# `pregnant_since`; `sex` da série, se houver.
module Vaccination
  module Schedule
    # Vacina e dose da pessoa: nada em inspect, to_s, pretty_print nem as_json.
    Item = Data.define(:series, :immunobiological_code, :dose_code, :status, :due_on, :applied_id) do
      def inspect = "#<Vaccination::Schedule::Item>"
      def to_s = inspect
      def pretty_print(pp) = pp.text(inspect)
      def as_json(*) = {}
    end

    PREGNANT = "pregnant".freeze

    module_function

    # doses: [ { id:, code:, dose_code:, on: Date } ] (só ativas).
    def call(birth_date:, sex:, pregnant_since:, doses:, checked:, today:, calendar:)
      ctx = { birth: birth_date, today: today, checked: checked, window: calendar.due_window_days, pregnant_since: pregnant_since }
      calendar.series.flat_map do |series|
        start = entry_start(series, sex: sex, pregnant_since: pregnant_since, birth: birth_date, today: today)
        next [] unless start

        applied = doses.select { |dose| series.accepts.include?(Immunobiologicals.normalize(dose[:code])) }
                       .sort_by { |dose| [ dose[:on], dose[:id].to_s ] }
        if series.rules["pregnant_from_week"]
          [ pregnancy_item(series, applied, ctx) ]
        elsif series.repeat_every_days
          [ repeat_item(series, applied, start, ctx) ]
        else
          series_items(series, applied, ctx)
        end
      end
    end

    # Data a partir da qual a série vale para a pessoa (nil = não entra).
    def entry_start(series, sex:, pregnant_since:, birth:, today:)
      return nil if series.sex && series.sex != sex

      publics = Array(series.public)
      starts = []
      starts << pregnant_since if publics.include?(PREGNANT) && pregnant_since
      windows = series.age_bands.any? ? series.age_bands.values : [ series.age_window ].compact
      windows.each { |window| starts << window.starts_on(birth) if window.cover?(birth: birth, on: today) }
      starts.compact.min
    end

    def series_items(series, applied, ctx)
      assigned = assign(series, applied)
      previous = nil # [ :complete, Date ] | [ :pending ]
      series.doses.each_with_index.map do |dose, index|
        code = series.accepts.first
        if (taken = assigned[dose.dose_code])
          previous = [ :complete, taken[:on] ]
          next Item.new(series: series.key, immunobiological_code: Immunobiologicals.normalize(taken[:code]), dose_code: dose.dose_code,
                        status: "complete", due_on: nil, applied_id: taken[:id])
        end

        status, due_on =
          if dose.max_age&.exceeded?(ctx[:birth], ctx[:today])
            [ "not_applicable", nil ]
          elsif index.positive? && previous&.first != :complete
            after_pending(dose, ctx)
          else
            due_on = [ (dose.recommended_on(ctx[:birth]) || ctx[:birth]),
                       (previous && previous.last + (dose.recommended_interval_days || dose.min_interval_days || 0)) ].compact.max
            [ situation(due_on, ctx), due_on ]
          end
        previous = [ :pending ]
        Item.new(series: series.key, immunobiological_code: code, dose_code: dose.dose_code, status: status, due_on: due_on, applied_id: nil)
      end
    end

    # { dose_code => dose aplicada }: primeiro pelo código; depois, as doses com
    # código fora da série preenchem as pendentes pela ordem.
    def assign(series, applied)
      codes = series.doses.map(&:dose_code)
      assigned = {}
      loose = []
      applied.each do |dose|
        code = dose[:dose_code].to_s
        if codes.include?(code)
          assigned[code] ||= dose
        else
          loose << dose
        end
      end
      loose.each do |dose|
        pending = codes.find { |code| !assigned.key?(code) }
        break unless pending

        assigned[pending] = dose
      end
      assigned
    end

    # Dose de anterior pendente: upcoming sem data; sem conferência, a de
    # idade recomendada já passada da janela vira unchecked (com a data).
    def after_pending(dose, ctx)
      return [ "upcoming", nil ] if ctx[:checked] || dose.recommended_age.nil?

      due_on = dose.recommended_age.from(ctx[:birth])
      ctx[:today] >= due_on + ctx[:window] ? [ "unchecked", due_on ] : [ "upcoming", nil ]
    end

    def repeat_item(series, applied, start, ctx)
      dose = series.doses.first
      last = applied.last
      due_on = last ? last[:on] + series.repeat_every_days : [ start, dose.min_age&.from(ctx[:birth]) || ctx[:birth] ].max
      # O código é o da dose a aplicar (o primeiro de `accepts`); a última dose
      # pode ser de outro produto da série (ex.: DTP aos 4 anos para o dT).
      Item.new(series: series.key, immunobiological_code: series.accepts.first,
               dose_code: dose.dose_code, status: situation(due_on, ctx), due_on: due_on, applied_id: last&.dig(:id))
    end

    def pregnancy_item(series, applied, ctx)
      dose = series.doses.first
      taken = applied.reverse.find { |d| d[:on] >= ctx[:pregnant_since] }
      if taken
        return Item.new(series: series.key, immunobiological_code: Immunobiologicals.normalize(taken[:code]), dose_code: dose.dose_code,
                        status: "complete", due_on: nil, applied_id: taken[:id])
      end

      due_on = ctx[:pregnant_since] + (series.rules["pregnant_from_week"] * 7)
      Item.new(series: series.key, immunobiological_code: series.accepts.first, dose_code: dose.dose_code,
               status: situation(due_on, ctx), due_on: due_on, applied_id: nil)
    end

    def situation(due_on, ctx)
      return "upcoming" if ctx[:today] < due_on
      return "due" if ctx[:today] < due_on + ctx[:window]

      ctx[:checked] ? "overdue" : "unchecked"
    end

    private_class_method :entry_start, :series_items, :assign, :after_pending, :repeat_item, :pregnancy_item, :situation
  end
end
