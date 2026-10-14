# Nome do exame (SIGTAP da competência gravada) e rótulos de etapa. O que o
# cidadão vê mora em Exams::Release (um lugar só).
module Exams
  module Labels
    STAGE = { "authorize" => "Autorização", "schedule" => "Agendamento", "collect" => "Coleta", "result" => "Resultado",
              "acknowledge" => "Ciência" }.freeze

    module_function

    def exam(code, competence) = ClinicalTerms::SigtapExams.label(code, competence) || "Procedimento #{code}"
  end
end
