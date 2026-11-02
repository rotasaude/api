# Espera entre tentativas de envio à RNDS com falha transitória (5xx, timeout,
# CADSUS ou banco da cidade fora do ar): 1, 2, 4... minutos, até 2 h.
# Desistência (`failed`) só 15 dias depois da PRIMEIRA tentativa de envio
# (§15 V7: o prazo da sala sem conectividade); as 24 h são só o prazo do
# alerta. `blocked` (NT 115) revalida a cada hora.
module Rnds
  module Backoff
    CAP = 2.hours
    GIVE_UP_AFTER = Vaccination::Catalog::GIVE_UP_AFTER
    BLOCKED_RECHECK = 1.hour

    module_function

    def wait(attempts)
      [ 1.minute * (2**(attempts.clamp(1, 8) - 1)), CAP ].min
    end
  end
end
