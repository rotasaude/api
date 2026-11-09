# Senha da sala de espera (módulo 32a, ADR 0050; plano, Desvio 1 e Valor
# fixado 5): "#{prefixo da unidade}-#{NNN}", contada por unidade e dia LOCAL
# — `ticket_on` é a data de `at` no fuso da cidade (CityConnection.with fixa
# Time.zone): 23:59 local é do dia, 00:01 local recomeça, mesmo que em UTC
# seja o mesmo dia.
#
# Chame dentro da transação que grava o atendimento, depois de
# HealthUnit.lock_active!, e só se o chamador já leu WaitingRoom::Gate.usable?
# fora da transação. A trava consultiva por unidade (liberada no commit ou no
# rollback) faz a segunda chegada simultânea esperar a primeira e contar a
# senha que ela gravou: duas chegadas nunca repetem a senha (o índice único
# idx_attendances_ticket é a última palavra). A chave é o id da unidade, nunca
# dado de pessoa.
module Attendances
  module Ticket
    module_function

    def issue(unit, at: Time.current)
      lock!(unit)
      day = at.in_time_zone.to_date
      n = Attendance.where(health_unit_id: unit.id, ticket_on: day).count + 1
      [ "#{unit.ticket_prefix}-#{format('%03d', n)}", day ]
    end

    def lock!(unit)
      conn = ApplicationRecord.connection
      conn.execute("SELECT pg_advisory_xact_lock(hashtext(#{conn.quote("attendance_ticket:#{unit.id}")}))")
    end
  end
end
