# O protocolo de classificação de risco em vigor na cidade (ADR 0050; §14
# Q16): o único `active` do kind urgency_classification, qualquer que seja o
# nome (não há nome reservado). Sem ele, a classificação é manual.
module Urgency
  module ActiveProtocol
    module_function

    def current = ProtocolDefinition.urgency_protocols.find_by(status: "active")
  end
end
