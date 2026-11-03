# Mudança de situação do processo de TFD (plano, Desvio 12; §14 T8, T25):
# trava o processo, confere a transição, grava uma linha em tfd_case_events
# (motivo cifrado) e `version += 1`. Quem pode pedir cada uma (autor,
# comissão, o transporte) é dos comandos; aqui só a máquina de estados.
#   draft → submitted · returned → submitted          (autor)
#   submitted → returned | authorized | denied        (comissão)
#   authorized → scheduled → travelling → completed   (trechos e prestação de contas)
#   submitted|returned|authorized|scheduled|travelling → cancelled (só a comissão; T25: rascunho não se cancela)
# Sem `to:`, só o evento `kind:` (appointment_set, inpatient_recorded), sem
# mudar a situação. `submitted_at` fica o do primeiro envio (o reenvio do
# devolvido não perde o lugar na fila); `decided_at` a cada decisão.
module Tfd
  module Transition
    TRANSITIONS = {
      "draft" => %w[submitted],
      "submitted" => %w[returned authorized denied cancelled],
      "returned" => %w[submitted cancelled],
      "authorized" => %w[scheduled cancelled],
      "scheduled" => %w[travelling cancelled],
      "travelling" => %w[completed cancelled]
    }.freeze
    DECIDED = %w[returned authorized denied].freeze
    EVENT_ONLY = %w[appointment_set inpatient_recorded].freeze

    module_function

    # -> Result.ok(tfd_case:) | fail(:invalid_transition)
    def call(tfd_case:, to:, by:, reason: nil, kind: nil)
      TfdCase.transaction(requires_new: true) do
        tfd_case.lock!
        attrs = { version: tfd_case.version + 1 }
        if to
          next Result.fail(:invalid_transition) unless TRANSITIONS.fetch(tfd_case.status, []).include?(to.to_s)

          attrs[:status] = to.to_s
          attrs[:submitted_at] = Time.current if to.to_s == "submitted" && tfd_case.submitted_at.nil?
          attrs[:decided_at] = Time.current if DECIDED.include?(to.to_s)
        elsif !EVENT_ONLY.include?(kind.to_s)
          next Result.fail(:invalid_transition)
        end

        tfd_case.update!(attrs)
        TfdCaseEvent.create!(tfd_case: tfd_case, kind: (kind || to).to_s, by_user: by, reason: reason)
        Result.ok(tfd_case: tfd_case)
      end
    end
  end
end
