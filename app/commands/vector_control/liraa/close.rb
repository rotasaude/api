# Fecha o levantamento LIRAa (módulo 35a, ADR 0054; contrato §7; Q9; A-14).
# Só a coordenação, com step-up (quem chama confere). Trava o levantamento
# FOR UPDATE; fora de drawn → invalid_transition path status (409; Q9:
# survey_not_draft fica para o sorteio e a edição). Grava closed e closed_at:
# daí em diante o Liraa::Index lê as inspeções até closed_at (congeladas) e o
# trigger recusa mudar os itens. `liraa_survey.closed` só com ids.
module VectorControl
  module Liraa
    module Close
      EVENT = "liraa_survey.closed".freeze

      module_function

      # -> Result.ok(survey:) | fail(:invalid_transition, details: { path: "status" })
      def call(survey:, by:)
        LiraaSurvey.transaction(requires_new: true) do
          survey.lock!
          next Result.fail(:invalid_transition, details: { path: "status" }) unless survey.status == "drawn"

          survey.update!(status: "closed", closed_at: Time.current, version: survey.version + 1)
          DomainEvents.publish(EVENT, liraa_survey_id: survey.id, user_id: by.id)
          Result.ok(survey: survey)
        end
      end
    end
  end
end
