# Coleta (spec §5.2): leitura da etiqueta registra quem e quando; no 21a os
# exames da amostra vão a `collected`. Quem coleta: a UBS de origem (coleta
# na unidade) ou o lab_staff (posto do laboratório).
module Lab
  module CollectSample
    module_function

    def collector?(user, sample)
      req = sample.lab_requisition
      if req.collection_place == "lab"
        Access.staff?(user) && Access.member?(user, req.exam_provider_id)
      else
        Access.collecting_unit_ids(user).include?(req.origin_unit_id)
      end
    end

    def call(sample:, by:, collected_at: nil, now: Time.current)
      return Result.fail(:missing_role) unless collector?(by, sample)

      at = collected_at.nil? ? now : (Time.iso8601(collected_at.to_s) rescue nil)
      return Result.fail(:invalid_collected_at) unless at && at <= now && at >= sample.lab_requisition.created_at

      ApplicationRecord.transaction do
        sample.lock!
        next Result.fail(:invalid_transition, details: { status: sample.status }) if sample.collected? || sample.status != "awaiting"

        sample.update!(collected_by_user: by, collected_at: at)
        sample.items.select(&:active?).each do |item|
          order = item.exam_order
          next unless order.status == "scheduled"

          moved = Exams::Transition.call(order: order, kind: "collected", actor_user: by, now: at)
          raise ActiveRecord::Rollback if moved.failure?
        end
        DomainEvents.publish("lab_sample.collected", lab_sample_id: sample.id, lab_requisition_id: sample.lab_requisition_id)
        Result.ok(sample: sample)
      end || Result.fail(:invalid_transition, details: { status: sample.reload.status })
    end
  end
end
