# "Chamar próximo": trava o primeiro da fila que ninguém mais está chamando
# (FOR UPDATE SKIP LOCKED) e chama esse. Dois profissionais ao mesmo tempo
# levam atendimentos diferentes, sem esperar um pelo outro; queue_empty só
# quando não sobra ninguém disponível.
module Attendances
  class CallNext
    def self.call(health_unit_id:, by:)
      # Atalho: sem papel ou vínculo, não trava ninguém. Quem garante é o
      # Call, que reconfere sob lock (FOR SHARE no vínculo).
      authorization = Professionals::ClinicalAuthorization.check(user: by, health_unit_id: health_unit_id)
      return Result.fail(authorization) unless authorization == :ok

      ApplicationRecord.transaction do
        candidate = UnitQueue.lock_next_waiting(health_unit_id)
        # Com SKIP LOCKED, queue_empty momentâneo é possível quando todas as
        # linhas aguardando estão travadas por outra transação (milissegundos);
        # o dashboard recarrega a fila.
        next Result.fail(:queue_empty) unless candidate

        # Call trava de novo a mesma linha (já nossa) e reconfere papel, vínculo
        # e status na mesma transação.
        Call.call(attendance: candidate, health_unit_id: health_unit_id, by: by)
      end
    end
  end
end
