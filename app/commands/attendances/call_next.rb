# "Chamar próximo": trava o primeiro da fila que ninguém mais está chamando
# (FOR UPDATE SKIP LOCKED) e chama esse. Dois profissionais ao mesmo tempo
# levam atendimentos diferentes, sem esperar um pelo outro; queue_empty só
# quando não sobra ninguém disponível.
#
# Módulo 32a (ADR 0050; plano, Desvio 11): numa UPA com `urgency`
# (urgency_care utilizável, lido pelo chamador fora da transação), a fila é a
# por cor (Urgency::Queue.lock_next_classified) e só o médico (225*) chama;
# quem só tem não classificados recebe queue_empty. Sem classificado
# disponível, cai no lock do 13 sem walk_ins (atendimentos do check-in do 13
# feitos antes de ligar o urgency_care). Fora disso, o lock do 13 nunca pega
# walk_in (UnitQueue.lock_next_waiting_without_walk_ins). `call_location_id`
# e `waiting_room` seguem para o Call.
module Attendances
  class CallNext
    def self.call(health_unit_id:, by:, call_location_id: nil, waiting_room: false, urgency: false)
      # Atalho: sem papel ou vínculo, não trava ninguém. Quem garante é o
      # Call, que reconfere sob lock (FOR SHARE no vínculo).
      authorization = Professionals::ClinicalAuthorization.check(user: by, health_unit_id: health_unit_id)
      return Result.fail(authorization) unless authorization == :ok

      by_color = urgency && HealthUnit.find_by(id: health_unit_id)&.upa?
      return Result.fail(:cbo_not_allowed) if by_color && !Urgency::Access.physician_link(by, health_unit_id)

      ApplicationRecord.transaction do
        candidate = (Urgency::Queue.lock_next_classified(health_unit_id) if by_color) ||
                    UnitQueue.lock_next_waiting_without_walk_ins(health_unit_id)
        # Com SKIP LOCKED, queue_empty momentâneo é possível quando todas as
        # linhas aguardando estão travadas por outra transação (milissegundos);
        # o dashboard recarrega a fila.
        next Result.fail(:queue_empty) unless candidate

        # Call trava de novo a mesma linha (já nossa) e reconfere papel, vínculo
        # e status na mesma transação.
        Call.call(attendance: candidate, health_unit_id: health_unit_id, by: by, call_location_id: call_location_id,
                  waiting_room: waiting_room)
      end
    end
  end
end
