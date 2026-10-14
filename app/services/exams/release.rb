# Liberação ao cidadão (ADR 0036; spec §6; contrato §9, A23/A29/A32), aplicada
# no servidor: política do exame no catálogo da cidade (padrão
# after_acknowledgement). Único lugar da situação que o cidadão vê — a lista
# "Meus exames" e a linha do tempo (Task 19) chamam citizen_label e
# citizen_result daqui. Antes de o cidadão poder saber do resultado, `result`
# é null e o rótulo é o da etapa anterior ao resultado; nunca motivo algum.
module Exams
  module Release
    DEFAULT = "after_acknowledgement".freeze
    STATUS_LABELS = {
      "awaiting_authorization" => "Aguardando autorização", "denied" => "Pedido não autorizado — procure sua unidade",
      "awaiting_schedule" => "Pedido registrado", "scheduled" => "Agendado", "collected" => "Coletado",
      "cancelled" => "Cancelado"
    }.freeze
    AVAILABLE = "Resultado disponível".freeze
    PICKUP = "Retire o resultado na sua unidade".freeze

    module_function

    def policy(sigtap_code) = ExamCatalogItem.find_by(sigtap_code: sigtap_code)&.release_policy || DEFAULT
    def pickup_at_unit?(sigtap_code) = policy(sigtap_code) == "never_citizen"

    # O cidadão pode ver o laudo (PDF e data). Externo nasce com ciência (A9).
    def available?(result)
      return false unless result

      rule = policy(result.sigtap_code)
      return false if rule == "never_citizen"
      return true if result.external?

      status = result.exam_order.status
      return false unless %w[resulted acknowledged].include?(status)

      rule == "immediate" || status == "acknowledged"
    end

    # subject: ExamOrder, ou ExamResult externo.
    def citizen_label(subject)
      result = result_of(subject)
      return PICKUP if known?(result) && pickup_at_unit?(result.sigtap_code)
      return AVAILABLE if known?(result)
      return previous_stage(subject) if result

      STATUS_LABELS.fetch(subject.status)
    end

    def citizen_result(subject)
      result = result_of(subject)
      return nil unless known?(result)

      available = available?(result)
      { available: available, pickup_at_unit: pickup_at_unit?(result.sigtap_code),
        released_on: available ? result.released_on.iso8601 : nil, pdf_available: available }
    end

    # O cidadão pode saber que há resultado: liberado, ou never_citizen
    # (só "retire na unidade", sem data nem PDF).
    def known?(result)
      return false unless result
      return true if result.external?
      return false unless %w[resulted acknowledged].include?(result.exam_order.status)

      available?(result) || pickup_at_unit?(result.sigtap_code)
    end

    def result_of(subject) = subject.is_a?(ExamResult) ? subject : subject.result

    # Resultado registrado mas ainda não liberado: a etapa de antes (o
    # resultado só nasce de agendado ou coletado — Transition).
    def previous_stage(order)
      STATUS_LABELS.fetch(order.events.any? { |event| event.kind == "collected" } ? "collected" : "scheduled")
    end
    private_class_method :result_of, :previous_stage
  end
end
