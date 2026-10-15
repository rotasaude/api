# Situação da requisição (spec §5, item 11), recalculada dos itens e das
# amostras a cada passo: open → in_analysis → typed → released → delivered.
module Lab
  module RequisitionStatus
    module_function

    def refresh!(requisition)
      items = requisition.items.reload.select(&:active?)
      status = if requisition.delivered_at then "delivered"
               elsif items.any? && items.all? { |i| i.status == "released" } then "released"
               elsif items.any? && items.all? { |i| %w[typed released].include?(i.status) } then "typed"
               elsif requisition.samples.reload.any?(&:accepted?) then "in_analysis"
               else "open"
               end
      requisition.update!(status: status) unless requisition.status == status
      requisition
    end
  end
end

