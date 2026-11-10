# Leitura dos campos do corpo JSON da urgência (ADR 0050; módulo 32b): id e
# data/hora ISO 8601 (hora sem offset = fuso da cidade). Valor fora da forma
# → nil ou false (quem chama recusa com o path). O padrão do Psychosocial::Input.
module Urgency
  module Input
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    # Data e hora: exige a hora (só a data não é um instante).
    TIME = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/

    module_function

    def uuid?(value) = value.is_a?(String) && value.match?(UUID)

    # -> ActiveSupport::TimeWithZone (no fuso da cidade) | nil. Sem offset, é
    # a hora local da cidade (Time.zone), nunca UTC; com offset ou Z, o instante.
    def time(value)
      return nil unless value.is_a?(String) && value.match?(TIME)

      Time.zone.iso8601(value)
    rescue ArgumentError
      nil
    end
  end
end
