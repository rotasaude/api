# Cria ou edita o ciclo de trabalho (módulo 35a, ADR 0054; contrato §1, §5;
# Q8). Só a coordenação (quem chama confere). Criar: `{ year, number?,
# starts_on, ends_on }` (sem number, o próximo do ano, D-1; depois do 12 →
# invalid_request path number); editar: as mesmas
# chaves, todas opcionais, ao menos uma. Recusas (só a primeira):
#   - chave desconhecida, year fora de 2000–2100, number fora de 1–12, data
#     que não é AAAA-MM-DD → invalid_request com o path;
#   - year que não é o ano civil nem o ano epidemiológico de starts_on
#     (Surveillance::EpiWeek; Q22) → cycle_invalid path year;
#   - ends_on antes de starts_on → cycle_invalid path ends_on;
#   - (year, number) de outro ciclo → invalid_request path number;
#   - período que cruza outro ciclo (excl_vector_cycles_overlap) → cycle_overlap
#     path starts_on.
# O banco decide a corrida (índice único e exclusion GiST), dentro de um
# savepoint. Editar trava o ciclo e sobe version se algo muda. Sem evento (§17).
module VectorControl
  module SaveCycle
    KEYS = %w[year number starts_on ends_on].freeze
    YEARS = (2000..2100)
    DATE = /\A\d{4}-\d{2}-\d{2}\z/

    module_function

    # -> Result.ok(cycle:) | fail(:invalid_request | :cycle_invalid | :cycle_overlap, details: { path: })
    def call(params:, by:, cycle: nil)
      _ = by
      params = params.to_h.stringify_keys
      values = parse(params, cycle)
      return values if values.is_a?(Result)

      VectorCycle.transaction(requires_new: true) do
        if cycle
          cycle.lock!
          cycle.assign_attributes(values)
          cycle.version += 1 if cycle.changed?
          cycle.save!
        else
          number = values[:number] || next_number(values[:year])
          next fail_with(:invalid_request, "number") unless Catalog::CYCLE_NUMBERS.cover?(number)

          cycle = VectorCycle.create!(values.merge(number: number))
        end
        Result.ok(cycle: cycle)
      end
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?("idx_vector_cycles_number")

      fail_with(:invalid_request, "number")
    rescue ActiveRecord::ExclusionViolation => e
      raise unless e.message.include?("excl_vector_cycles_overlap")

      fail_with(:cycle_overlap, "starts_on")
    end

    # { year:, number:, starts_on:, ends_on: } (o que veio, sobre o ciclo) | Result de recusa.
    def parse(params, cycle)
      unknown = (params.keys - KEYS).first
      return fail_with(:invalid_request, unknown) if unknown
      return fail_with(:invalid_request, nil) if cycle && params.empty?

      required = cycle ? [] : %w[year starts_on ends_on]
      missing = (required - params.keys).first
      return fail_with(:invalid_request, missing) if missing

      values = {}
      if params.key?("year")
        return fail_with(:invalid_request, "year") unless params["year"].is_a?(Integer) && YEARS.cover?(params["year"])

        values[:year] = params["year"]
      end
      if params.key?("number")
        return fail_with(:invalid_request, "number") unless params["number"].is_a?(Integer) && Catalog::CYCLE_NUMBERS.cover?(params["number"])

        values[:number] = params["number"]
      end
      %w[starts_on ends_on].each do |key|
        next unless params.key?(key)

        date = date(params[key])
        return fail_with(:invalid_request, key) unless date

        values[key.to_sym] = date
      end
      starts_on = values.fetch(:starts_on) { cycle&.starts_on }
      ends_on = values.fetch(:ends_on) { cycle&.ends_on }
      return fail_with(:cycle_invalid, "year") unless year_of?(values.fetch(:year) { cycle&.year }, starts_on)
      return fail_with(:cycle_invalid, "ends_on") if ends_on < starts_on

      values
    end

    # O ano civil de starts_on ou o ano epidemiológico dele (Surveillance::EpiWeek:
    # SE 1 contém 4 de janeiro; semanas de domingo a sábado; Q22).
    def year_of?(year, starts_on) = [ starts_on.year, Surveillance::EpiWeek.for(starts_on).year ].include?(year)

    def next_number(year) = VectorCycle.where(year: year).maximum(:number).to_i + 1

    def date(raw)
      raw.is_a?(String) && raw.match?(DATE) && Date.strptime(raw, "%Y-%m-%d")
    rescue Date::Error
      nil
    end

    def fail_with(reason, path) = Result.fail(reason, details: path ? { path: path } : {})
  end
end
