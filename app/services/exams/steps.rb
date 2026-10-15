# Agendar, coletar e cancelar (contrato §3, §6): a mesma regra para a
# unidade e para o prestador. Trava o pedido; a transição faz o resto.
module Exams
  module Steps
    module_function

    def schedule(order:, params:, actor_user: nil, actor_provider: nil)
      # A unidade e o portal nunca reabrem a coleta (só o laboratório; Desvio 3). Repetido
      # sob trava abaixo, para a corrida.
      return Result.fail(:invalid_transition, details: { status: order.status }) if order.status == "collected"

      provider = actor_provider || (params[:provider_id].is_a?(String) && ExamProvider.find_by(id: params[:provider_id], active: true))
      return Result.fail(:provider_not_enabled_for_exam) unless provider && enabled?(provider, order)
      # A15: o laboratório simulado só recebe com fake_lab utilizável.
      return Result.fail(:provider_not_enabled_for_exam) if provider.simulated && !Gate.fake_lab_usable?(Current.city)

      at = parse_time(params[:scheduled_at])
      place = params[:scheduled_place].is_a?(String) ? params[:scheduled_place].strip : ""
      return Result.fail(:invalid_schedule) unless at && place.length.between?(1, 200)

      locked(order) do
        next Result.fail(:invalid_transition, details: { status: order.status }) if order.status == "collected"

        # O portal só reagenda o que já é dele; a unidade pode trocar de prestador.
        next Result.fail(:provider_not_enabled_for_exam) if actor_provider && order.exam_provider_id && order.exam_provider_id != provider.id

        Transition.call(order: order, kind: "scheduled", actor_user: actor_user, actor_provider: actor_provider,
                        changes: { exam_provider_id: provider.id, scheduled_at: at, scheduled_place: place })
      end
    end

    def collect(order:, actor_user: nil, actor_provider: nil)
      locked(order) { Transition.call(order: order, kind: "collected", actor_user: actor_user, actor_provider: actor_provider) }
    end

    # ADR 0037 (Desvio 16): exame na requisição do laboratório — item pendente
    # é cancelado junto; digitado ou liberado, o laboratório já trabalhou: 409.
    # Ordem de trava (E2), a mesma de Lab::Release: requisição → itens → pedido.
    def cancel(order:, reason:, actor_user:)
      item = LabRequisitionItem.find_by(exam_order_id: order.id)
      ApplicationRecord.transaction do
        requisition = item && LabRequisition.lock.find(item.lab_requisition_id)
        item = LabRequisitionItem.lock.find_by(exam_order_id: order.id) if item
        order.lock!
        next Result.fail(:invalid_transition, details: { status: order.status }) if item && %w[typed released].include?(item.status)

        moved = Transition.call(order: order, kind: "cancelled", actor_user: actor_user, reason: reason)
        if moved.ok? && item
          item.update!(status: "cancelled")
          Lab::RequisitionStatus.refresh!(requisition)
        end
        moved
      end
    end

    # Prestador faz o exame: tem o item, ou o exame não está no catálogo.
    def enabled?(provider, order)
      item = ExamCatalogItem.find_by(sigtap_code: order.sigtap_code)
      item.nil? || ExamProviderItem.exists?(exam_provider_id: provider.id, exam_catalog_item_id: item.id)
    end

    def locked(order)
      ApplicationRecord.transaction do
        order.lock!
        yield
      end
    end

    def parse_time(raw)
      raw.is_a?(String) && raw.match?(/\A\d{4}-\d{2}-\d{2}T/) ? Time.iso8601(raw) : nil
    rescue ArgumentError
      nil
    end
    private_class_method :locked, :parse_time
  end
end
