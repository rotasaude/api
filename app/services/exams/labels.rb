# Nome do exame (SIGTAP da competência gravada) e rótulos de situação.
module Exams
  module Labels
    CITIZEN_STATUS = {
      "awaiting_authorization" => "Aguardando autorização", "denied" => "Pedido não autorizado — procure sua unidade",
      "awaiting_schedule" => "Pedido registrado", "scheduled" => "Agendado", "collected" => "Coletado",
      "resulted" => "Resultado registrado", "acknowledged" => "Resultado registrado", "cancelled" => "Cancelado"
    }.freeze
    STAGE = { "authorize" => "Autorização", "schedule" => "Agendamento", "collect" => "Coleta", "result" => "Resultado",
              "acknowledge" => "Ciência" }.freeze

    module_function

    def exam(code, competence) = ClinicalTerms::SigtapExams.label(code, competence) || "Procedimento #{code}"
  end
end
