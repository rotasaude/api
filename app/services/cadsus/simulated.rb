require "digest"

# CADSUS de mentira para development e test (ADR 0028): casos fixos, resposta
# determinística por CPF, sem rede. CPFs com dígito verificador válido.
module Cadsus
  class Simulated
    NOT_FOUND_CPF = "11144477735".freeze
    UNAVAILABLE_CPF = "39053344705".freeze
    REFUSED_USERNAME = "recusado".freeze

    def initialize(username:)
      @username = username
    end

    def health_check
      raise Unauthorized, "o CADSUS recusou a credencial" if @username == REFUSED_USERNAME

      :ok
    end

    def lookup(cpf)
      health_check
      raise Unavailable, "CADSUS simulado fora do ar" if cpf == UNAVAILABLE_CPF
      return nil if cpf == NOT_FOUND_CPF

      seed = Digest::SHA256.hexdigest("cadsus:#{cpf}").to_i(16)
      Record.new(cns: Professionals::Cns.generate("cadsus:#{cpf}"), birth_date: Date.new(1950, 1, 1) + (seed % 25_000),
                 sex: seed.even? ? "female" : "male")
    end
  end
end
