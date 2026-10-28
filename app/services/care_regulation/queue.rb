# A fila do regulador (módulo 26a; contrato §4, §13 G2) e os contadores. Ordem,
# numa leitura só: vencidos primeiro, depois a cor efetiva (vermelho <
# amarelo < verde < azul), depois requested_at, depois id —
# `overdue_key ASC, rank ASC, requested_at ASC, id ASC` —, paginada por cursor
# (CareRegulation::Cursor) com comparação de linha. O cursor leva o dia usado na
# conta de "vencido": a página 2 usa o dia do cursor, então na virada da
# meia-noite não repete nem pula linha.
#
# "Vencido" em SQL é RegulationRequest.overdue_sql (a única definição; o espelho
# em Ruby é #overdue?). Escopo: a cidade toda (o regulador não tem unidade).
# Nada aqui lê dado do paciente além de ids; sem log.
module CareRegulation
  module Queue
    class InvalidFilter < StandardError
      attr_reader :field

      def initialize(field)
        @field = field
        super("filtro inválido")
      end
    end

    FILTERS = %w[status type target_code color overdue].freeze
    DEFAULT_STATUS = "pending".freeze
    RANK_SQL = "CASE COALESCE(regulation_requests.color, regulation_requests.suggested_color) " \
               "#{Catalog::COLOR_RANK.map { |color, rank| "WHEN '#{color}' THEN #{rank}" }.join(' ')} END".freeze
    PRELOAD = [ :patient, { requester_user: :professional }, :requester_unit,
                { authorizations: [ { care_offer: :care_provider }, { authorized_by_user: :professional } ] } ].freeze

    module_function

    # filters: Hash de texto (a query). -> { rows: [RegulationRequest], next_before: String | nil };
    # levanta InvalidFilter (field) ou Cursor::Invalid.
    def page(filters:, before:, limit:, today: Time.zone.today)
      filters = filters.to_h.stringify_keys
      scope = filtered(filters)
      cursor = before.nil? || before == "" ? nil : Cursor.decode(before)
      day = cursor ? cursor.first : today
      overdue_key = overdue_key_sql(day)
      scope = filtered_by_day(scope, filters["overdue"], day)
      scope = after(scope, cursor, overdue_key) if cursor
      fetched = scope.preload(*PRELOAD)
                     .select("regulation_requests.*, #{overdue_key} AS q_overdue_key, #{RANK_SQL} AS q_rank")
                     .order(Arel.sql("q_overdue_key ASC, q_rank ASC, regulation_requests.requested_at ASC, regulation_requests.id ASC"))
                     .limit(limit + 1).to_a
      rows = fetched.first(limit)
      last = rows.last
      next_before = Cursor.encode([ day, last.q_overdue_key, last.q_rank, last.requested_at, last.id ]) if fetched.size > limit
      { rows: rows, next_before: next_before }
    end

    # { pending:, overdue:, returned:, authorized:, external: } numa consulta
    # agregada (contrato §4; sem trilha). `overdue` sobre WAITING_STATUSES.
    def counts(today: Time.zone.today)
      overdue = RegulationRequest.overdue_sql(today)
      selects = %w[pending returned authorized external].map { |status| "COUNT(*) FILTER (WHERE regulation_requests.status = '#{status}')" }
      pending, returned, authorized, external, overdue_count = RegulationRequest.pick(*selects.map { |sql| Arel.sql(sql) },
                                                                                     Arel.sql("COUNT(*) FILTER (WHERE #{overdue})"))
      { pending: pending, overdue: overdue_count, returned: returned, authorized: authorized, external: external }
    end

    def overdue_key_sql(day) = "(CASE WHEN #{RegulationRequest.overdue_sql(day)} THEN 0 ELSE 1 END)"

    # Valida os filtros e monta o escopo (o filtro `overdue` entra depois, com o dia).
    def filtered(filters)
      values = filters.slice(*FILTERS).transform_values { |value| value == "" ? nil : value }.compact
      field = values.find { |_key, value| !value.is_a?(String) }&.first
      raise InvalidFilter, field if field

      status = values.fetch("status", DEFAULT_STATUS)
      type, target_code, color, overdue = values.values_at("type", "target_code", "color", "overdue")
      raise InvalidFilter, "status" unless Catalog::QUEUE_STATUSES.include?(status)
      raise InvalidFilter, "type" if type && Catalog::TYPES.exclude?(type)
      raise InvalidFilter, "target_code" if target_code && !target_code.match?(Catalog::SPECIALTY_CODE) && !target_code.match?(Catalog::PROCEDURE_CODE)
      raise InvalidFilter, "color" if color && Catalog::COLORS.exclude?(color)
      raise InvalidFilter, "overdue" if overdue && %w[true false].exclude?(overdue)

      scope = RegulationRequest.where(status: status)
      scope = scope.where(target_type: type) if type
      scope = scope.where(target_code: target_code) if target_code
      scope = scope.where("COALESCE(regulation_requests.color, regulation_requests.suggested_color) = ?", color) if color
      scope
    end

    # O filtro `overdue` conta com o mesmo dia da ordenação (o do cursor, se houver).
    def filtered_by_day(scope, overdue, day)
      case overdue.presence
      when "true" then scope.where(RegulationRequest.overdue_sql(day))
      when "false" then scope.where.not(RegulationRequest.overdue_sql(day))
      else scope
      end
    end

    # Linhas depois do cursor, por comparação de linha:
    # (overdue_key, rank, requested_at, id) > (?, ?, ?, ?).
    def after(scope, cursor, overdue_key)
      _day, was_overdue, rank, requested_at, id = cursor
      scope.where("(#{overdue_key}, #{RANK_SQL}, regulation_requests.requested_at, regulation_requests.id) > (?, ?, ?::timestamptz, ?::uuid)",
                  was_overdue, rank, requested_at.utc.iso8601(6), id)
    end

    private_class_method :filtered, :filtered_by_day, :after
  end
end
