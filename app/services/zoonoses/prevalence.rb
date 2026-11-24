# Prevalência do inquérito de leishmaniose visceral canina (módulo 35b, ADR
# 0054; contrato §6; decisão do coordenador na revisão da Task 13), POR CÃO:
# reagentes ÷ examinados, em %, com uma casa.
#   - Resultado final: ELISA reagente ou não reagente, ou DPP não reagente
#     (negativo). O ELISA inconclusivo não é final (o cão espera reteste), nem
#     DPP reagente sem ELISA, DPP inválido ou coleta sem DPP.
#   - Por animal, vale a última coleta com resultado final do inquérito
#     (collected_on, depois created_at, mais recentes): examinados = os cães
#     com resultado final; reagentes = aqueles cujo último final é DPP e ELISA
#     reagentes. O reteste nunca conta duas vezes.
#   - Sem examinado, prevalência nil.
module Zoonoses
  module Prevalence
    FINAL_ELISA = %w[reactive non_reactive].freeze

    module_function

    # -> { examined:, reactive:, prevalence: Float | nil }
    def for(survey)
      tests = LeishTest.where(leish_survey_id: survey.id)
      finals = tests.where(elisa_result: FINAL_ELISA).or(tests.where(dpp_result: "non_reactive"))
      latest = finals.select("DISTINCT ON (leish_tests.animal_id) leish_tests.elisa_result")
                     .reorder(:animal_id, collected_on: :desc, created_at: :desc, id: :desc).map(&:elisa_result)
      examined = latest.size
      reactive = latest.count("reactive")
      { examined: examined, reactive: reactive, prevalence: examined.zero? ? nil : (reactive * 100.0 / examined).round(1) }
    end
  end
end
