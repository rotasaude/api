# Exames (ADR 0036; contrato §10 com A23/A24/A29/A32/A37; fecha api#71 para
# exames): um por pedido (exam_orders.created_at) e um por resultado externo
# (exam_results.created_at). Profissional: exame, situação e etapa pendente
# (ou "Resultado registrado"); nunca valores, crítico nem motivo. Cidadão:
# situação, rótulo e laudo SÓ por Exams::Release (o mesmo lugar de "Meus
# exames"). Vazio sem exam_tracking utilizável ou sem paciente. A trilha é do
# controlador (uma por leitura).
module Timeline
  module Sources
    module ExamSource
      KIND = "exam".freeze
      CLOSED = { "denied" => "Pedido negado", "cancelled" => "Pedido cancelado" }.freeze
      RESULTED = "Resultado registrado".freeze

      module_function

      def entries(person:, before:, limit:, from:, to:)
        return [] unless person.patient_id && Exams::Gate.usable?(Current.city)

        orders = ::ExamOrder.where(patient_id: person.patient_id)
                            .includes(:unit, :events, result: :exam_order, requester_user: :professional)
        externals = ::ExamResult.where(patient_id: person.patient_id, origin: "external").includes(registered_by_user: :professional)
        rows = window(orders, "exam_orders", before, from, to, limit) + window(externals, "exam_results", before, from, to, limit)
        Exams::Release.cached do
          rows.map { |row| row.is_a?(::ExamOrder) ? order_entry(row) : external_entry(row) }
        end.sort_by(&:sort_key).first(limit)
      end

      def window(scope, table, before, from, to, limit)
        Window.apply(scope, kind: KIND, column: "#{table}.created_at", id_column: "#{table}.id", before: before, from: from, to: to)
              .limit(limit).to_a
      end

      def order_entry(order)
        title = Exams::Labels.exam(order.sigtap_code, order.sigtap_competence)
        name = Labels.professional_name(order.requester_user)
        Entry.new(kind: KIND, source_id: order.id, occurred_at: order.created_at, unit: { id: order.unit_id, name: order.unit.name },
                  professional: { name: name, cbo_code: nil }, title: title, summary: professional_summary(order),
                  status: order.status, detail_ref: { type: "exam_order", id: order.id },
                  citizen: citizen(order, title, name), document: document(order, order.id))
      end

      def external_entry(result)
        title = Exams::Labels.exam(result.sigtap_code, result.released_on.strftime("%Y%m"))
        name = Labels.professional_name(result.registered_by_user)
        Entry.new(kind: KIND, source_id: result.id, occurred_at: result.created_at, unit: nil,
                  professional: name && { name: name, cbo_code: nil }, title: title, summary: "Resultado externo — #{result.laboratory_name}",
                  status: "external", detail_ref: { type: "exam_result", id: result.id },
                  citizen: citizen(result, title, nil), document: document(result, result.id))
      end

      def professional_summary(order)
        return RESULTED if order.result
        return "#{Exams::Labels::STAGE.fetch(order.stage)} pendente" if order.stage

        CLOSED.fetch(order.status, order.status)
      end

      def citizen(subject, title, professional_name)
        label = Exams::Release.citizen_label(subject)
        { title: title, summary: label, status: Exams::Release.citizen_status(subject), status_label: label,
          professional_name: professional_name }
      end

      # A24: o PDF sai por /citizen/exams/:id/pdf (id do pedido, ou do
      # resultado externo), só quando a política deixa.
      def document(subject, id)
        return nil unless Exams::Release.citizen_result(subject)&.dig(:pdf_available)

        { id: id, short_code: nil, verification_url: nil, downloadable: true }
      end
      private_class_method :window, :order_entry, :external_entry, :professional_summary, :citizen, :document
    end
  end
end
