# Receita de controle especial e de antimicrobiano digitais e registro da
# Notificação (ADR 0034) só com controlled_prescriptions LIGADO e UTILIZÁVEL
# (requer clinical_documents utilizável). Relido da plataforma a cada chamada.
module ControlledPrescriptions
  module Gate
    KEY = "controlled_prescriptions".freeze

    module_function

    def usable?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.usable?(city, KEY)
    end
  end
end
