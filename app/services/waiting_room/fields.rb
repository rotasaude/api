# Campos comuns dos cadastros da sala de espera (locais de chamada e TVs):
# nome aparado no intervalo (recusado, nunca cortado), booleano estrito,
# unidade ativa pelo id e a recusa de campo no formato P23.
module WaitingRoom
  module Fields
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    module_function

    def name(value, range)
      return nil unless value.is_a?(String)

      stripped = value.strip
      range.cover?(stripped.length) ? stripped : nil
    end

    def boolean?(value) = [ true, false ].include?(value)

    def unit(id)
      return nil unless id.is_a?(String) && id.match?(UUID)

      HealthUnit.find_by(id: id, active: true)
    end

    def refuse(path) = Result.fail(:invalid_request, details: { path: path, problems: [ { path: path, error: "invalid_request" } ] })
  end
end
