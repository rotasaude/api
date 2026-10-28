# Painel da vigilância por bairro × semana epidemiológica (módulo 25; contrato
# §8, K7; Desvios 9 e 10). Consulta direta no banco da cidade, com a semana
# própria (EpiWeek, domingo a sábado): o Analytics::Params usa a semana ISO e
# não serve aqui.
#   - conta a notificação fora de possible/dismissed e sem classificação
#     `discarded`, na semana dos primeiros sintomas (sem ela, a da suspeita);
#   - o SQL agrupa por dia e bairro; a semana sai em Ruby;
#   - linhas: bairros com pelo menos um caso no intervalo, por nome (sem
#     acento e sem diferenciar maiúsculas, como Surveillance::Diseases), e
#     "Não informado" (id nil) por último quando tem caso;
#   - supressão (Admin::SmallCount.small?) DEPOIS de agregar: 1–4 vira nil, 0
#     continua 0; sem linha nem coluna de total, para a soma não devolver a
#     célula suprimida;
#   - sinal: contagem crua da semana ≥ SIGNAL_MIN e > SIGNAL_FACTOR × média das
#     SIGNAL_BASELINE semanas anteriores (contagem crua; as anteriores a `from`
#     são lidas só para isso e nunca devolvidas). Nunca verdadeiro em célula nil.
# Só ids e nomes de bairro e contagens: nada de pessoa, sem trilha.
module Surveillance
  module Panel
    PANEL_DEFAULT_WEEKS = 12
    PANEL_MAX_WEEKS = 53
    SIGNAL_BASELINE_WEEKS = 4
    SIGNAL_FACTOR = 2
    SIGNAL_MIN = 5
    NOT_COUNTED = %w[possible dismissed].freeze
    UNKNOWN = "Não informado".freeze
    # `symptoms_on <= suspected_on` (CHECK): a data de referência nunca passa da suspeita.
    REFERENCE_DAY = "COALESCE(disease_notifications.symptoms_on, disease_notifications.suspected_on)".freeze

    module_function

    # from/to: EpiWeek (from <= to; a validação do intervalo é de quem chama);
    # disease: código ou nil. -> { weeks:, rows:, suppressed: true }
    def call(from:, to:, disease: nil)
      weeks = EpiWeek.between(from, to)
      raw = raw_counts(from - SIGNAL_BASELINE_WEEKS, to, disease)
      ids = raw.select { |_, by_week| weeks.any? { |w| by_week.key?(w.to_s) } }.keys
      names = Neighborhood.where(id: ids.compact).pluck(:id, :name).to_h

      rows = ids.compact.sort_by { |id| sort_key(names.fetch(id)) }.map { |id| row(id, names.fetch(id), raw.fetch(id), weeks) }
      rows << row(nil, UNKNOWN, raw.fetch(nil), weeks) if ids.include?(nil)
      { weeks: weeks.map(&:to_s), rows: rows, suppressed: true }
    end

    # { neighborhood_id|nil => { "YYYY-WW" => contagem crua } }
    def raw_counts(first_week, last_week, disease)
      scope = DiseaseNotification.where.not(status: NOT_COUNTED)
                                 .where("disease_notifications.classification IS NULL OR disease_notifications.classification <> 'discarded'")
                                 .where("#{REFERENCE_DAY} BETWEEN ? AND ?", first_week.starts_on, last_week.ends_on)
      scope = scope.where(disease_code: disease) if disease
      scope.group(Arel.sql(REFERENCE_DAY), :neighborhood_id).count.each_with_object({}) do |((day, neighborhood_id), count), out|
        week = EpiWeek.for(day.to_date).to_s
        by_week = (out[neighborhood_id] ||= Hash.new(0))
        by_week[week] += count
      end
    end

    def row(id, name, by_week, weeks)
      cells = weeks.map do |week|
        count = by_week[week.to_s]
        visible = Admin::SmallCount.small?(count) ? nil : count
        [ visible, visible && signal?(count, by_week, week) ]
      end
      { neighborhood: { id: id, name: name }, counts: cells.map(&:first), signal: cells.map { |_, s| s == true } }
    end

    def signal?(count, by_week, week)
      return false if count < SIGNAL_MIN

      previous = (1..SIGNAL_BASELINE_WEEKS).sum { |back| by_week[(week - back).to_s] }
      count > SIGNAL_FACTOR * (previous.to_f / SIGNAL_BASELINE_WEEKS)
    end

    def sort_key(name) = [ I18n.transliterate(name).downcase, name ]
    private_class_method :raw_counts, :row, :signal?, :sort_key
  end
end
