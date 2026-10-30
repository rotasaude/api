# Textos pt-BR das entradas (ADR 0035). O cidadão recebe termos simples;
# nada aqui é texto livre gravado por alguém.
module Timeline
  module Sources
    module Labels
      ATTENDANCE_OUTCOMES = { "discharged" => "Alta", "referred" => "Encaminhado", "return" => "Retorno",
                              "left" => "Saiu sem atendimento", "scheduled_from_screening" => "Agendado na escuta",
                              "oriented" => "Orientado na escuta" }.freeze
      CITIZEN_OUTCOMES = { "discharged" => "Atendimento concluído", "referred" => "Encaminhado(a) para outro serviço",
                           "return" => "Retorno combinado", "left" => "Saiu antes do atendimento",
                           "scheduled_from_screening" => "Consulta agendada no acolhimento",
                           "oriented" => "Orientado(a) no acolhimento" }.freeze
      COLORS = { "red" => "vermelha", "yellow" => "amarela", "green" => "verde", "blue" => "azul" }.freeze
      DESTINATIONS = { "same_day" => "Atendimento no dia", "schedule" => "Agendamento", "oriented" => "Orientado",
                       "referred" => "Encaminhado" }.freeze
      DOCUMENT_KINDS = { "sick_note" => "Atestado", "attendance_declaration" => "Declaração de comparecimento",
                         "prescription" => "Receita", "exam_requisition" => "Requisição de exames" }.freeze
      CATEGORIES = { "special_control" => "Receita de controle especial", "antimicrobial" => "Receita de antimicrobiano" }.freeze
      MODES = { "digital" => "Assinado digitalmente", "paper" => "Papel" }.freeze
      DOCUMENT_STATUS = { "issued" => "Emitido", "cancelled" => "Cancelado" }.freeze
      # 27a: só o profissional vê a dispensação (não há texto do cidadão).
      DISPENSATION_TITLE = "Dispensação de medicamentos".freeze

      module_function

      def professional_name(user) = user&.professional&.professional_name
    end
  end
end
