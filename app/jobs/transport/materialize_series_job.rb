# Job diário das séries recorrentes (ADR 0048; contrato §4): por cidade
# (EachCityJob), só com `sanitary_transport` utilizável (lido fora de qualquer
# transação da cidade). Séries ativas hoje (TransportSeries#active_on?, a
# mesma regra da leitura e do AddPassenger) que começam até o fim do horizonte;
# uma transação por série (Transport::MaterializeSeries). A falha de uma série
# não para as outras: vai ao log só com o id e a classe do erro, e o job falha
# no fim com a contagem (o EachCityJob junta as cidades). Log de sucesso só
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
      TransportSeries.where(starts_on: ..(today + Catalog::SERIES_HORIZON_DAYS - 1)).order(:id).find_each do |series|
        next unless series.active_on?(today)

        counts = TransportSeries.transaction { MaterializeSeries.call(series: series, today: today) }
        counts.each { |key, value| totals[key] += value }
      rescue => e
        failed += 1
        Rails.logger.error("[#{self.class.name}] series=#{series.id} failed: #{e.class}")
      end
      Rails.logger.info("[#{self.class.name}] city=#{Current.city.slug} added=#{totals[:added]} " \
                        "created_trips=#{totals[:created_trips]} pending=#{totals[:pending]} failed=#{failed}")
      raise "#{failed} series failed" if failed.positive?
    end
  end
end
