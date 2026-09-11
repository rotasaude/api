# Decide se um Outcome terminal merece o alerta urgente à secretaria (F-01/F-03).
# Módulo puro e TOTAL — nunca levanta. Ver ADR-0006 (prioridade clínica nas
# filas) e ADR-0009 (motor de protocolos).
#
# A urgência é lida da `priority`, não do `tier`. `priority` é a única escala
# que o contrato garante nos DOIS modos de scoring (inteiro 1..9, menor = mais
# urgente) e o único valor que `priority_when` consegue escalar. `tier` é
# vocabulário livre do autor (schema.json: "tier": {"type":"string"}, sem enum),
# e usá-lo como gate fazia o alerta silenciar em qualquer cidade cujo protocolo
# não dissesse literalmente "alta".
module Protocols
  module Urgency
    # Política de plataforma: 1 = só a prioridade máxima alerta.
    DEFAULT_MAX_PRIORITY = 1

    module_function

    def max_priority
      Integer(ENV.fetch("URGENT_MAX_PRIORITY", DEFAULT_MAX_PRIORITY), exception: false) ||
        DEFAULT_MAX_PRIORITY
    end

    def urgent?(outcome)
      return false unless outcome.respond_to?(:terminal?) && outcome.terminal?

      priority = Integer(outcome.priority, exception: false)
      return false if priority.nil?

      priority <= max_priority
    end
  end
end
