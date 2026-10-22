# Página do painel (contrato §5 e §11 L6; plano, Desvio 9): blocos de `limit`
# inscrições avaliados em lote (SQL por bloco constante); com filtro, até
# MAX_CHUNKS blocos. A página pode vir curta com next_before não nulo: ele
# aponta para a última inscrição varrida.
module CareLines
  module Board
    MAX_CHUNKS = 5
    COUNT_CHUNK = 200
    COUNT_TTL = 60.seconds
    FILTERS = %w[all overdue due_soon].freeze

    module_function

    def page(team:, line_id:, status:, before:, limit:, today:)
      scope = CareLineEnrollment.active_enrollments.where(team_id: team.id).includes(:team)
      scope = scope.where(care_line_id: line_id) if line_id
      scope = scope.order(enrolled_at: :desc, id: :desc)
      rows = []
      last = nil
      MAX_CHUNKS.times do
        chunk = Cursor.before(scope, last ? Cursor::Position.new(at: last.enrolled_at, id: last.id) : before, :enrolled_at).limit(limit).to_a
        return { rows: rows, next_before: nil } if chunk.empty?

        evaluated = Evaluation.enrollments(chunk, today: today)
        chunk.each do |enrollment|
          last = enrollment
          row = evaluated.fetch(enrollment.id)
          rows << [ enrollment, row ] if keep?(status, row.worst)
          return { rows: rows, next_before: Cursor.encode(enrollment.enrolled_at, enrollment.id) } if rows.size == limit
        end
        return { rows: rows, next_before: nil } if chunk.size < limit
      end
      { rows: rows, next_before: Cursor.encode(last.enrolled_at, last.id) }
    end

    # Contador sem trilha (nada nominal sai daqui). O dashboard o relê a cada
    # 60 s por aba: o valor (agregado, sem dado pessoal) fica 60 s no cache
    # compartilhado (solid_cache no banco de plataforma, por isso a cidade na chave).
    def overdue_count(team, today:)
      key = [ "care_lines/overdue_count", Current.city&.slug, team.id, today.iso8601 ]
      Rails.cache.fetch(key, expires_in: COUNT_TTL) do
        CareLineEnrollment.active_enrollments.where(team_id: team.id).in_batches(of: COUNT_CHUNK).sum do |batch|
          Evaluation.enrollments(batch.to_a, today: today).count { |_, row| row.worst == "overdue" }
        end
      end
    end

    def keep?(status, worst) = status == "all" || worst == status
    private_class_method :keep?
  end
end
