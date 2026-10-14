# Nome do exame (SIGTAP da competência gravada) e rótulos de etapa. O que o
# cidadão vê mora em Exams::Release (um lugar só).
module Exams
  module Labels
    STAGE = { "authorize" => "Autorização", "schedule" => "Agendamento", "collect" => "Coleta", "result" => "Resultado",
              "acknowledge" => "Ciência" }.freeze

    module_function

    # Memorizado por [cidade, código, competência] dentro de Release.cached
    # (duas leituras por linha viram uma por exame distinto da página).
    def exam(code, competence)
      memo = ActiveSupport::IsolatedExecutionState[:exam_label_memo]
      return lookup(code, competence) unless memo

      memo.fetch([ Current.city&.id, code, competence ]) { memo[[ Current.city&.id, code, competence ]] = lookup(code, competence) }
    end

    def lookup(code, competence) = ClinicalTerms::SigtapExams.label(code, competence) || "Procedimento #{code}"
    private_class_method :lookup
  end
end
