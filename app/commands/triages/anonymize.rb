# ADR 0026: apaga o conteúdo clínico de uma triagem.
#   clear!  — limpa incondicionalmente (sem trava, sem checar atendimento); a
#             exclusão do cadastro usa, pois ali o atendimento também é apagado.
#   call    — o caminho da revogação: trava a linha e reconfere o atendimento.
#             O check-in trava a mesma linha (Attendances::CheckIn), então um
#             dos dois vence, nunca os dois.
module Triages
  module Anonymize
    module_function

    def clear!(triage)
      now = Time.current
      triage.update_columns(answers: {}, outcome: nil, tier: nil, priority: nil, current_step: nil,
                            neighborhood_id: nil, anonymized_at: triage.anonymized_at || now, updated_at: now)
    end

    def call(triage)
      triage.with_lock do
        next false if triage.anonymized_at.present? || Attendance.exists?(triage_id: triage.id)

        clear!(triage)
        true
      end
    end
  end
end
