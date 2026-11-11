# Denúncia anônima sem login (ADR 0051): exige o próprio interruptor E a
# ouvidoria utilizável (pré-requisito feature:ombudsman). Sem cascata.
module Ombudsman
  module AnonymousGate
    KEY = "ombudsman_anonymous_web".freeze

    module_function

    def usable?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.usable?(city, KEY)
    end
  end
end
