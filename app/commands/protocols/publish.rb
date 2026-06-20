# Stub. Phase 4+ traz authorization + Platform.audit; ADR-0016 entrega corpo real.
# Por ora só atualiza status = 'active' do protocolo da versão.
module Protocols
  module Publish
    def self.call(version:, by:)
      ProtocolDefinition.where(version: version).update_all(status: "active")
      true
    end
  end
end
