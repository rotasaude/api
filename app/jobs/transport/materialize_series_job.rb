# Job diário das séries recorrentes (ADR 0048; contrato §4): por cidade
# (EachCityJob), só com `sanitary_transport` utilizável (lido fora de qualquer
# transação da cidade). Séries ativas hoje (TransportSeries#active_on?, a
# mesma regra da leitura e do AddPassenger) que começam até o fim do horizonte;
# uma transação por série, com a série travada e a regra conferida de novo, e
# um savepoint por dia (Transport::MaterializeSeries). A falha de um dia ou de
# uma série não para os outros: vai ao log só com o id (e a data) e a classe
# do erro, e o job falha no fim com a contagem (o EachCityJob junta as cidades). Log de sucesso só
# com contagens.
module Transport
  class MaterializeSeriesJob < ApplicationJob
    prepend EachCityJob
    queue_as :housekeeping

    def perform
      return unless Gate.usable?(Current.city)

      today = Time.zone.today
      totals = Hash.new(0)
      failed = 0
      TransportSeries.where(starts_on: ..(today + Catalog::SERIES_HORIZON_DAYS - 1)).find_each do |series|
        next unless series.active_on?(today)

        # Travada e relida: uma suspensão ou edição concorrente espera ou já
        # vale (a regra é conferida de novo com a linha atual).
        counts = TransportSeries.transaction do
          series.lock!
          series.active_on?(today) ? MaterializeSeries.call(series: series, today: today) : {}
        end
        counts.each { |key, value| totals[key] += value }
      rescue => e
        failed += 1
        Rails.logger.error("[#{self.class.name}] series=#{series.id} failed: #{e.class}")
      end
      failed += totals[:failed]
      Rails.logger.info("[#{self.class.name}] city=#{Current.city.slug} added=#{totals[:added]} " \
                        "created_trips=#{totals[:created_trips]} pending=#{totals[:pending]} failed=#{failed}")
      raise "#{failed} series day(s) failed" if failed.positive?
    end
  end
end
