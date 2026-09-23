# "Voltar" do canal web (spec 2026-09-22-web-citizen-channel §2.8): tira a
# última resposta e volta ao passo dela. O caminho é recalculado pelo motor
# (função pura) sobre as respostas gravadas, então o passo desfeito é sempre o
# último da trilha. Depois de concluída, a triagem é imutável.
# Reasons: :not_in_progress, :nothing_to_undo.
class UndoLastAnswer
  def self.call(triage:)
    result = nil
    triage.with_lock do
      result =
        if !triage.status_in_progress?
          Result.fail(:not_in_progress)
        else
          trail = triage.protocol.evaluate(triage.answers).trail
          if trail.empty?
            Result.fail(:nothing_to_undo)
          else
            last_step = trail.last[:step].to_s
            triage.update!(answers: triage.answers.except(last_step), current_step: last_step)
            Result.ok(triage: triage)
          end
        end
    end
    result
  end
end
