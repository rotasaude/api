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
      # Módulo 32a (ADR 0050; contrato §10 e §14 Q13, Q25): a cor vigente e o
      # desfecho, só para o profissional (o PEC externo não recebe a urgência).
      URGENCY_COLORS = { "red" => "Vermelho", "orange" => "Laranja", "yellow" => "Amarelo", "green" => "Verde",
                         "blue" => "Azul" }.freeze
      URGENCY_OUTCOMES = { "discharged" => "Alta", "discharged_to_primary_care" => "Alta com retorno à UBS",
                           "transferred" => "Transferido(a) para outro serviço", "left_without_care" => "Saiu antes do atendimento",
                           "left_against_advice" => "Saiu antes da alta", "death" => "Óbito",
                           "registered_in_error" => "Registrado por engano" }.freeze
      # O cidadão (tabela W3 do plano do wpda): sem `death` e sem
      # `registered_in_error` — esses encontros não aparecem para ele (Q13, Q25).
      CITIZEN_URGENCY_OUTCOMES = { "discharged" => "Atendimento concluído, com alta",
                                   "discharged_to_primary_care" => "Alta, com orientação para procurar a sua UBS",
                                   "transferred" => "Transferido(a) para outro serviço",
                                   "left_without_care" => "Saiu antes do atendimento",
                                   "left_against_advice" => "Saiu antes da alta médica" }.freeze

      # Módulo 31 (P48, P51): a unidade `caps` nunca sai pelo nome nem pela
      # modalidade nas fontes gerais (profissional da UBS, cidadão e PEC).
      CAPS_UNIT_NAME = ClinicalDocument::CAPS_UNIT_LABEL

      module_function

      def professional_name(user) = user&.professional&.professional_name

      # Contrato §14 Q26: "1 dia" no singular, "N dias" de 2 em diante.
      def days(count) = "#{count} #{count == 1 ? 'dia' : 'dias'}"

      # Ponto comum da unidade das entradas gerais: HealthUnit ou
      # Billing::Establishment (ambos com `kind`). Só a fonte do CAPS
      # (PsychosocialSource, equipe lotada) mostra o nome real.
      def unit(unit) = { id: unit.id, name: unit_name(unit) }
      def unit_name(unit) = unit.kind == "caps" ? CAPS_UNIT_NAME : unit.name
    end
  end
end
