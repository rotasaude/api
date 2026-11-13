# O que faria a ficha da folha sair "não gerada" se ela fechasse agora (módulo
# 24b, ADR 0052; contrato §6, §10; plano, Task 10). Os mesmos códigos do build
# (HomeVisits::Catalog::NOT_GENERATED), com o visit_id da visita que segura a
# folha (nulo nos da folha: unidade, profissional, CBO, perfil, prazo). Não
# grava nada. Só faz sentido com a folha aberta: fechada, a situação está em
# ficha.status/reasons (HomeVisits::Json.day) e aqui volta [].
module HomeVisits
  module Blockers
    module_function

    # -> [{ code:, visit_id: }]
    def for(day) = day.open? ? Ledi::HomeVisitDayFicha.blockers(day) : []
  end
end
