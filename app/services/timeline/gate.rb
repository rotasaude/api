# Linha do tempo do paciente (ADR 0035): patient_timeline LIGADO (sem
# pré-requisito) e, para a página do PEC, pec_external_view LIGADO E
# UTILIZÁVEL (patient_timeline + modo integrado). Relido da plataforma a cada
# chamada; record_mode relido por id (Platform::Features.settings).
module Timeline
  module Gate
    KEY = "patient_timeline".freeze
    PEC_KEY = "pec_external_view".freeze

    module_function

    def enabled?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.enabled?(city, KEY)
    end

    def pec_usable?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.usable?(city, PEC_KEY)
    end

    # Histórico parcial: fora do modo record as consultas da cidade estão no PEC.
    def partial?(city) = Platform::Features.settings(city)[:record_mode] != "record"
  end
end
