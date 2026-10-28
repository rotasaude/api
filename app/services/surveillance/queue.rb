# A fila da vigilância (módulo 25; contrato §5, K5–K7, K12(c)) e os
# contadores. Ordem: vencidas, depois imediatas, depois o prazo mais antigo e
# o id — `overdue DESC, deadline = 'immediate' DESC, due_at ASC, id ASC` —,
# paginada por cursor (Surveillance::Cursor), porque a ordem não é por id.
#
# "Vencida" em SQL é a mesma regra de DiseaseNotification#overdue?: prazo
# passado e situação possible/notified (Catalog::OVERDUE_STATUSES).
# Filtros (valor vazio = ausente): status (um de STATUSES; padrão: todos
# menos entered e dismissed), disease (código), overdue ("true"), unit_id
# (uuid) e without_official_number ("true" = status closed, o relatório "sem
# número", V12). Nada aqui lê dado do paciente além de ids; sem log.
module Surveillance
  module Queue
    FILTERS = %w[status disease overdue unit_id without_official_number].freeze
    HIDDEN_BY_DEFAULT = %w[entered dismissed].freeze
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    IMMEDIATE = "(disease_notifications.deadline = 'immediate')".freeze
    INCLUDES = %i[patient health_unit notifier_user neighborhood].freeze

    module_function

    # filters: Hash de texto (a query); before: o cursor da página anterior.
    # -> Result.ok(rows:, next_before:) | fail(:invalid_filter, details: { field: }) | fail(:invalid_cursor).
    def call(filters:, limit:, before: nil, now: Time.current)
      scope = filtered(filters.to_h.stringify_keys, now)
      return scope if scope.is_a?(Result)

      cursor = nil
      unless before.nil? || before == ""
        cursor = Cursor.decode(before)
        return Result.fail(:invalid_cursor) unless cursor
      end

      overdue = overdue_sql(now)
      scope = after(scope, cursor, overdue) if cursor
      fetched = scope.includes(*INCLUDES)
                     .select("disease_notifications.*, #{overdue} AS q_overdue, #{IMMEDIATE} AS q_immediate")
                     .order(Arel.sql("q_overdue DESC, q_immediate DESC, disease_notifications.due_at ASC, disease_notifications.id ASC"))
                     .limit(limit + 1).to_a
      rows = fetched.first(limit)
      last = rows.last
      next_before = Cursor.encode([ last.q_overdue, last.q_immediate, last.due_at, last.id ]) if fetched.size > limit
      Result.ok(rows: rows, next_before: next_before)
    end

    # { possible:, notified:, investigating:, overdue:, immediate_open:, without_official_number: }
    # (contrato §5; sem trilha: só números).
    def counts(now: Time.current)
      by_status = DiseaseNotification.group(:status).count
      { possible: by_status.fetch("possible", 0), notified: by_status.fetch("notified", 0),
        investigating: by_status.fetch("investigating", 0),
        overdue: DiseaseNotification.where(overdue_sql(now)).count,
        immediate_open: DiseaseNotification.where(deadline: "immediate", status: Catalog::OPEN_STATUSES).count,
        without_official_number: by_status.fetch("closed", 0) }
    end

    # -> Relation | Result.fail(:invalid_filter, field:).
    def filtered(filters, now)
      values = filters.slice(*FILTERS).transform_values { |value| value == "" ? nil : value }.compact
      field = values.find { |_key, value| !value.is_a?(String) }&.first
      return invalid(field) if field

      status, disease, unit_id, overdue, without_number = values.values_at("status", "disease", "unit_id", "overdue", "without_official_number")
      return invalid("status") if status && Catalog::STATUSES.exclude?(status)
      return invalid("disease") if disease && !disease.match?(Catalog::PLATFORM_CODE) && !disease.match?(Catalog::LOCAL_CODE)
      return invalid("unit_id") if unit_id && !unit_id.match?(UUID)
      return invalid("overdue") if overdue && overdue != "true"
      return invalid("without_official_number") if without_number && (without_number != "true" || (status && status != "closed"))

      status = "closed" if without_number
      scope = DiseaseNotification.all
      scope = scope.where(status: status || (Catalog::STATUSES - HIDDEN_BY_DEFAULT))
      scope = scope.where(disease_code: disease) if disease
      scope = scope.where(health_unit_id: unit_id) if unit_id
      scope = scope.where(overdue_sql(now)) if overdue
      scope
    end

    # Linhas depois do cursor, na ordem (vencida DESC, imediata DESC, due_at, id).
    def after(scope, cursor, overdue)
      was_overdue, was_immediate, due_at, id = cursor
      scope.where(
        "(#{overdue})::int < :o OR ((#{overdue})::int = :o AND ((#{IMMEDIATE})::int < :i OR ((#{IMMEDIATE})::int = :i AND " \
        "(disease_notifications.due_at > :d OR (disease_notifications.due_at = :d AND disease_notifications.id > :id)))))",
        o: was_overdue ? 1 : 0, i: was_immediate ? 1 : 0, d: due_at, id: id
      )
    end

    def overdue_sql(now)
      DiseaseNotification.sanitize_sql_array([ "(disease_notifications.due_at < ? AND disease_notifications.status IN (?))",
                                               now, Catalog::OVERDUE_STATUSES ])
    end

    def invalid(field) = Result.fail(:invalid_filter, details: { field: field })
    private_class_method :filtered, :after, :overdue_sql, :invalid
  end
end
