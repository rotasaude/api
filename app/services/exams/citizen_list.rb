# "Meus exames" (contrato §9 com A23/A29/A32): pedidos e resultados externos
# do paciente da pessoa, mais novos primeiro. Situação e resultado só por
# Exams::Release; nada de motivo, crítico, valores, laboratório nem
# solicitante. Cursor das listas do exame (created_at, id).
module Exams
  module CitizenList
    module_function

    def call(person:, before:, limit:)
      return { exams: [], next_before: nil } unless person.patient_id

      at, id = Cursor.decode(before)
      orders = ExamOrder.where(patient_id: person.patient_id).includes(:events, result: :exam_order)
      externals = ExamResult.where(patient_id: person.patient_id, origin: "external")
      if at
        orders = orders.where("(exam_orders.created_at, exam_orders.id) < (?, ?)", at, id)
        externals = externals.where("(exam_results.created_at, exam_results.id) < (?, ?)", at, id)
      end
      rows = (orders.order(created_at: :desc, id: :desc).limit(limit + 1).to_a +
              externals.order(created_at: :desc, id: :desc).limit(limit + 1).to_a)
             .sort { |a, b| [ b.created_at, b.id ] <=> [ a.created_at, a.id ] }
      page = rows.first(limit)
      { exams: page.map { |row| row.is_a?(ExamOrder) ? order(row) : external(row) },
        next_before: rows.size > limit ? Cursor.encode(page.last) : nil }
    end

    def order(order)
      { id: order.id, kind: "order", label: Labels.exam(order.sigtap_code, order.sigtap_competence),
        status_label: Release.citizen_label(order), requested_at: order.created_at.iso8601,
        scheduled_at: order.scheduled_at&.iso8601, scheduled_place: order.scheduled_place, result: Release.citizen_result(order) }
    end

    def external(result)
      { id: result.id, kind: "external_result", label: Labels.exam(result.sigtap_code, result.released_on.strftime("%Y%m")),
        status_label: Release.citizen_label(result), requested_at: result.created_at.iso8601,
        scheduled_at: nil, scheduled_place: nil, result: Release.citizen_result(result) }
    end
    private_class_method :order, :external
  end
end
