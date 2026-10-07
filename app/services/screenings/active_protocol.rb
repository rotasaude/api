# app/services/screenings/active_protocol.rb
# O protocolo de acolhimento em vigor na cidade (ADR 0030): a versão active
# do nome reservado, da variante screening. Sem ele, não há sugestão.
module Screenings
  module ActiveProtocol
    module_function

    def current
      ProtocolDefinition.screening_protocols.find_by(name: Protocols::Validation::Screening::NAME, status: "active")
    end
  end
end
