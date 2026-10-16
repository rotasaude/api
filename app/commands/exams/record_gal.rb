# Número da requisição no GAL (spec §4; F-21.24; B5; dashboard galProblem):
# registrado uma vez (o gatilho do banco também recusa trocar), pela unidade
# do exame ou por lab_staff. Formato idêntico ao do dashboard. O número nunca
# vai a log nem a evento.
module Exams
  module RecordGal
    FORMAT = /\A[0-9A-Za-z-]{1,30}\z/

    module_function

    def call(order:, value:, by:)
      allowed = Access.unit_staff?(by, order.unit_id) || Lab::Access.staff?(by)
      return Result.fail(:not_unit_staff) unless allowed

      number = value.is_a?(String) ? value.strip : ""
      return Result.fail(:invalid_gal_requisition) unless number.match?(FORMAT)

      ApplicationRecord.transaction do
        order.lock!
        next Result.fail(:gal_already_registered) if order.gal_requisition

        order.update!(gal_requisition: number)
        DomainEvents.publish("exam_order.gal_registered", exam_order_id: order.id)
        Result.ok(order: order)
      end
    end
  end
end
