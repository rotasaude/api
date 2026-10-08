# O prontuário só existe com o interruptor clinical_record LIGADO e
# UTILIZÁVEL (ADR 0031; modo record). Relido da plataforma a cada chamada
# (Platform::Features relê record_mode por id).
module ClinicalRecord
  module Gate
    KEY = "clinical_record".freeze

    module_function

    def usable?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.usable?(city, KEY)
    end
  end
end
