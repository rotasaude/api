# Entrega do impresso (spec §5.10; F-21.24): só com ao menos um laudo
# liberado (como o dashboard); quem retirou (cifrado) e quando; situação
# delivered. Segunda entrega → invalid_transition. delivered_to nunca vai
# a log nem a evento.
module Lab
  module Deliver
    module_function

    def call(requisition:, delivered_to:, by:, now: Time.current)
      return Result.fail(:missing_role) unless Access.member?(by, requisition.exam_provider_id) ||
                                                Exams::Access.unit_staff?(by, requisition.origin_unit_id)

      name = delivered_to.is_a?(String) ? delivered_to.strip : ""
      return Result.fail(:invalid_delivered_to) unless name.length.between?(1, 120)

      ApplicationRecord.transaction do
        requisition.lock!
        released = requisition.status != "delivered" && requisition.reports.where(status: "released").exists?
        next Result.fail(:invalid_transition, details: { status: requisition.status }) unless released

        requisition.update!(status: "delivered", delivered_to: name, delivered_at: now, delivered_by_user: by)
        RequisitionStatus.refresh!(requisition)
        DomainEvents.publish("lab_requisition.delivered", lab_requisition_id: requisition.id)
        Result.ok(requisition: requisition)
      end
    end
  end
end
