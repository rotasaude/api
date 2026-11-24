# Prevalência do inquérito de leishmaniose visceral canina (módulo 35b, ADR
# 0054; contrato §6): reagentes ÷ examinados com resultado final, em %, com
# uma casa. Reagente = DPP e ELISA reagentes. Examinado com resultado final =
# ELISA lançado (qualquer resultado) ou DPP não reagente (negativo); DPP
# reagente sem ELISA, DPP inválido e coleta sem DPP ainda não contam. Sem
# examinado, prevalência nil. Conta coletas (não animais): um reteste do
# mesmo cão com resultado final conta de novo.
module Zoonoses
  module Prevalence
    module_function

    # -> { examined:, reactive:, prevalence: Float | nil }
    def for(survey)
      tests = LeishTest.where(leish_survey_id: survey.id)
      examined = tests.where.not(elisa_result: nil).or(tests.where(dpp_result: "non_reactive")).count
      reactive = tests.where(dpp_result: "reactive", elisa_result: "reactive").count
      { examined: examined, reactive: reactive, prevalence: examined.zero? ? nil : (reactive * 100.0 / examined).round(1) }
    end
  end
end
