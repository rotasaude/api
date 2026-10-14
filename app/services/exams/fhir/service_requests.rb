# GET /fhir/ServiceRequest?status=active (contrato §7): as guias agendadas
# ou coletadas do prestador do token, como Bundle searchset.
module Exams
  module Fhir
    module ServiceRequests
      SIGTAP_SYSTEM = "http://www.saude.gov.br/fhir/r4/CodeSystem/BRTabelaSUS".freeze
      LIMIT = 200

      module_function

      def bundle(provider:)
        orders = ExamOrder.where(exam_provider_id: provider.id, status: %w[scheduled collected])
                          .includes(:patient).order(:scheduled_at, :id).limit(LIMIT).to_a
        { resourceType: "Bundle", type: "searchset", total: orders.size,
          entry: orders.map { |order| { resource: resource(order) } } }
      end

      def resource(order)
        { resourceType: "ServiceRequest", id: order.id,
          identifier: [ { system: "urn:rotasaude:exam-order", value: order.short_code } ],
          status: "active", intent: "order", priority: order.priority,
          code: { coding: [ { system: SIGTAP_SYSTEM, code: order.sigtap_code,
                              display: Labels.exam(order.sigtap_code, order.sigtap_competence) } ] },
          subject: { identifier: Identifiers.for_patient(order.patient) },
          authoredOn: order.created_at.iso8601, occurrenceDateTime: order.scheduled_at&.iso8601 }.compact
      end
      private_class_method :resource
    end
  end
end
