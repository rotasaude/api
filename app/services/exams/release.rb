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

    # Política do exame, memorizada por sigtap_code dentro de `cached` (uma
    # leitura do catálogo por exame da página, não por linha).
    def policy(sigtap_code)
      cache = ActiveSupport::IsolatedExecutionState[:exam_release_policies]
      return lookup(sigtap_code) unless cache

      cache.fetch(sigtap_code) { cache[sigtap_code] = lookup(sigtap_code) }
    end

    def cached
      outer = ActiveSupport::IsolatedExecutionState[:exam_release_policies]
      ActiveSupport::IsolatedExecutionState[:exam_release_policies] = outer || {}
      yield
    ensure
      ActiveSupport::IsolatedExecutionState[:exam_release_policies] = outer
    end

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

    # subject: ExamOrder, ExamResult externo, ou ExamResult de pedido (vale
    # como o pedido dele).
    def citizen_label(subject)
      subject = normalize(subject)
      result = result_of(subject)
      return PICKUP if known?(result) && pickup_at_unit?(result.sigtap_code)
      return AVAILABLE if known?(result)
      return STATUS_LABELS.fetch(previous_stage(subject)) if result

      STATUS_LABELS.fetch(subject.status)
    end

    # Código da situação que o cidadão pode ver (linha do tempo): antes de
    # poder saber do resultado, a etapa anterior; externo = "external".
    def citizen_status(subject)
      subject = normalize(subject)
      result = result_of(subject)
      return result.external? ? "external" : subject.status if known?(result)
      return previous_stage(subject) if result

      subject.status
    end

    def citizen_result(subject)
      result = result_of(normalize(subject))
      return nil unless known?(result)

      available = available?(result)
      { available: available, pickup_at_unit: pickup_at_unit?(result.sigtap_code),
        released_on: available ? result.released_on.iso8601 : nil, pdf_available: available }
    end

    # O cidadão pode saber que há resultado: liberado, ou never_citizen depois
    # da ciência (A37: só "retire na unidade", sem data nem PDF). Externo
    # nasce com ciência.
    def known?(result)
      return false unless result
      return true if result.external?

      status = result.exam_order.status
      return false unless %w[resulted acknowledged].include?(status)

      available?(result) || (pickup_at_unit?(result.sigtap_code) && status == "acknowledged")
    end

    def lookup(sigtap_code) = ExamCatalogItem.find_by(sigtap_code: sigtap_code)&.release_policy || DEFAULT

    def normalize(subject)
      case subject
      when ExamOrder then subject
      when ExamResult then subject.external? ? subject : subject.exam_order
      else raise ArgumentError, "esperado ExamOrder ou ExamResult, veio #{subject.class}"
      end
    end

    def result_of(subject) = subject.is_a?(ExamResult) ? subject : subject.result

    # Resultado registrado mas ainda não liberado: a etapa de antes (o
    # resultado só nasce de agendado ou coletado — Transition).
    def previous_stage(order)
      order.events.any? { |event| event.kind == "collected" } ? "collected" : "scheduled"
    end
    private_class_method :lookup, :normalize, :result_of, :previous_stage
  end
end
