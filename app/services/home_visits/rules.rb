# Regras puras da visita domiciliar (módulo 24b, ADR 0052; contrato §3). Quem
# chama passa `today` já no fuso da cidade (Time.zone.today dentro do
# CityConnection.with; plano, Desvio 10).
module HomeVisits
  module Rules
    module_function

    # Pre-flight 4.2: o primeiro dia aceito pelo prazo do SIAPS — o 1º dia da
    # competência mais antiga com Ledi::Deadline.on(c) > today (a ficha precisa
    # sair antes do prazo; C2). A mesma data no contexto (§6), nas regras da
    # visita e da atividade (*_date_out_of_range) e na sessão do app (§9).
    def min_date(today)
      competence = today.beginning_of_month
      loop do
        previous = competence.prev_month
        break unless Ledi::Deadline.on(previous.strftime("%Y%m")) > today

        competence = previous
      end
      competence
    end
  end
end
