# Relatório de conferência (ADR 0036; spec §6): por prestador (o do pedido)
# e mês no fuso da cidade. "No prazo" = o evento resulted aconteceu até o
# prazo da etapa que ele fechou (closed_stage_due_on, Desvio 7).
module Exams
  module Report
    MONTH = /\A(\d{4})-(0[1-9]|1[0-2])\z/
    DETAIL_HEADERS = %w[short_code sigtap_code authorized_on scheduled_on collected_on resulted_on on_time].freeze
    SUMMARY_HEADERS = %w[provider authorized collected resulted_on_time resulted_late pending].freeze
    FORMULA_START = /\A[=+\-@\t\r]/

    module_function

    def month_range(raw)
      match = raw.to_s.match(MONTH)
      match && Time.zone.local(match[1].to_i, match[2].to_i).all_month
    end

    # Pedidos DISTINTOS por tipo de evento (o último de cada tipo por pedido,
    # a mesma regra do detalhe): reagendar ou repetir um evento não conta de
    # novo. Mês e datas no fuso da cidade (Time.zone, posto por CityConnection.with).
    # `pending` NÃO é do mês: é o retrato de agora (agendados e coletados sem
    # resultado), do prestador do pedido.
    def rows(month:, provider_id: nil)
      providers = ExamProvider.order(:name)
      providers = providers.where(id: provider_id) if provider_id
      by_provider = latest_by_order(month, provider_id).group_by { |order, _| order.exam_provider_id }
      pending = ExamOrder.where(status: %w[scheduled collected]).group(:exam_provider_id).count
      providers.filter_map do |provider|
        own = by_provider.fetch(provider.id, [])
        next if own.empty? && pending[provider.id].to_i.zero?

        resulted = own.filter_map { |_, latest| latest["resulted"] }
        { provider: { id: provider.id, name: provider.name }, authorized: own.count { |_, l| l["authorized"] },
          collected: own.count { |_, l| l["collected"] }, resulted_on_time: resulted.count { |e| on_time?(e) },
          resulted_late: resulted.count { |e| !on_time?(e) }, pending: pending[provider.id].to_i }
      end
    end

    def detail(month:, provider_id: nil)
      latest_by_order(month, provider_id).sort_by { |order, _| order.short_code }.map do |order, latest|
        [ order.short_code, order.sigtap_code, *%w[authorized scheduled collected resulted].map { |k| latest[k]&.occurred_at&.in_time_zone&.to_date&.iso8601 },
          latest["resulted"] ? on_time?(latest["resulted"]).to_s : nil ]
      end
    end

    def latest_by_order(month, provider_id)
      events(month, provider_id).group_by(&:exam_order).map do |order, list|
        [ order, list.group_by(&:kind).transform_values { |same| same.max_by(&:occurred_at) } ]
      end
    end

    # Célula de texto vinda de entrada humana (nome do prestador): o Excel
    # trata =, +, - e @ iniciais como fórmula; o apóstrofo a neutraliza.
    def safe_cell(value)
      text = value.to_s
      text.match?(FORMULA_START) ? "'#{text}" : text
    end

    def events(month, provider_id)
      scope = ExamOrderEvent.joins(:exam_order).includes(:exam_order)
                            .where(kind: %w[authorized scheduled collected resulted], occurred_at: month)
                            .where.not(exam_orders: { exam_provider_id: nil })
      scope = scope.where(exam_orders: { exam_provider_id: provider_id }) if provider_id
      scope.to_a
    end

    def on_time?(event) = event.closed_stage_due_on.nil? || event.occurred_at.in_time_zone.to_date <= event.closed_stage_due_on
    private_class_method :events, :on_time?, :latest_by_order
  end
end
