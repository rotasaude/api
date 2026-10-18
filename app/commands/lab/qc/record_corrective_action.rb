# Ação corretiva do bloqueio (spec §5.7; C14; C-E3; C-E4): qualquer membro do
# laboratório (lab_staff ou liberador; quem chama confere), uma vez, texto
# 1..1000 (branco ou longo → invalid_text). Trava só o bloqueio (o
# fechamento, que trava aparelho → bloqueio, nunca espera esta trava ao contrário).
module Lab
  module Qc
    module RecordCorrectiveAction
      MAX_TEXT = 1000

      module_function

      def call(block:, text:, by:, now: Time.current)
        text = text.is_a?(String) ? text.strip : ""
        return Result.fail(:invalid_text) unless text.length.between?(1, MAX_TEXT)

        ApplicationRecord.transaction(requires_new: true) do
          block.lock!
          next Result.fail(:invalid_transition, details: { status: "closed" }) if block.closed_at
          next Result.fail(:conflict) if block.corrective_action

          block.update!(corrective_action: text, corrective_action_by_user: by, corrective_action_at: now)
          DomainEvents.publish("lab_qc_block.action_recorded", lab_qc_block_id: block.id)
          Result.ok(block: block)
        end
      end
    end
  end
end
