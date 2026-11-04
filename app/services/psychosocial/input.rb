# Leitura dos campos do corpo JSON do CAPS (ADR 0049): id, data e data/hora
# ISO 8601. Valor fora da forma → nil (quem chama recusa com o path).
module Psychosocial
  module Input
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    DATE = /\A\d{4}-\d{2}-\d{2}\z/
    # Data e hora: exige a hora (só a data não é um instante).
    TIME = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/

    module_function

    def uuid?(value) = value.is_a?(String) && value.match?(UUID)

    # -> Date | nil
    def date(value)
      return nil unless value.is_a?(String) && value.match?(DATE)

      Date.iso8601(value)
    rescue Date::Error
      nil
    end

    # -> ActiveSupport::TimeWithZone (no fuso da cidade) | nil
    def time(value)
      return nil unless value.is_a?(String) && value.match?(TIME)

      DateTime.iso8601(value).to_time.in_time_zone
    rescue Date::Error
      nil
    end
  end
end
