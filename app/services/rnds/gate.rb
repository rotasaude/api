# Interruptor do envio das doses à RNDS (ADR 0047).
module Rnds
  module Gate
    KEY = "rnds_immunization".freeze

    module_function

    def usable?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.usable?(city, KEY)
    end

    # Só o interruptor (sem credencial nem catálogo): o que a sala lê como
    # "envio desligado". Ligado e inutilizável (credencial ausente ou recusada)
    # continua contando prazo e atraso.
    def enabled?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.enabled?(city, KEY)
    end
  end
end
