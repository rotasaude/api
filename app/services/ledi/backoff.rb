# Espera entre tentativas de uma ficha com falha transitória (5xx, timeout):
# 1, 2, 4... minutos, até 2 h; desistência (failed) 24 h depois da primeira
# tentativa (spec §6.4; desvio 3 do plano).
module Ledi
  module Backoff
    CAP = 2.hours
    GIVE_UP_AFTER = 24.hours

    module_function

    def wait(attempts)
      [ 1.minute * (2**(attempts - 1)), CAP ].min
    end
  end
end
