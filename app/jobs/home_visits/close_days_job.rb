# Fecha, toda noite, as folhas de visita domiciliar ainda abertas de dias
# anteriores (módulo 24b, ADR 0052; contrato §2, §16; decisão 22). Por cidade
# (EachCityJob), SEM consultar o interruptor home_visits: a folha que já existe
# fecha e gera a ficha com o recurso ligado ou não. "Dia anterior" é o dia da
# cidade (Time.zone). Uma transação por folha (HomeVisits::CloseDay); a que
# levanta ou falha não para as outras: o log leva só o id e a classe do erro, e
# o job falha no fim com a contagem. Rodar de novo não refaz nada (day_changed).
# Log de sucesso só com contagens.
module HomeVisits
  class CloseDaysJob < ApplicationJob
    prepend EachCityJob
    queue_as :housekeeping

    def perform
      today = Time.zone.today
      closed = 0
      failed = 0
      HomeVisitDay.where(state: "open").where(day: ...today).find_each do |day|
        result = HomeVisits::CloseDay.call(day, by: nil, closed_by: "job")
        if result.ok?
          closed += 1
        elsif result.reason != :day_changed # fechada por outro no meio do caminho: nada a fazer
          failed += 1
          Rails.logger.error("[#{self.class.name}] sheet=#{day.id} failed: #{result.reason}")
        end
      rescue => e
        failed += 1
        Rails.logger.error("[#{self.class.name}] sheet=#{day.id} failed: #{e.class}")
      end
      Rails.logger.info("[#{self.class.name}] city=#{Current.city.slug} closed=#{closed} failed=#{failed}")
      raise "#{failed} sheet(s) failed" if failed.positive?
    end
  end
end
