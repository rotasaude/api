# POST /transport/series/:id/suspend { from_on, reason } (contrato §4; ADR
# 0048; preflight R7). Grava `suspended_from` e o motivo (10..500, cifrado) e,
# a partir de `from_on` (hoje ou depois):
#   - retira o paciente das viagens `planned`/`confirmed` da série pelo
#     Transport::RemovePassenger (mesmo motivo; evento passenger_removed, o
#     aviso `removed` é do consumidor, só na confirmada — T15); passageiro
#     anonimizado fica (congelado, T23);
#   - resolve as pendências abertas da série.
# Suspender de novo troca a data e o motivo. O job para de criar a partir da
# data (TransportSeries#runs_on?). Nada do paciente em Result.details.
module Transport
  module SuspendSeries
    module_function

    # -> Result.ok(series:) | fail(:invalid_request, details: { path:, problems: })
    def call(series:, from_on:, reason:, by:)
      date = from_on.is_a?(Date) ? from_on : Support.date(from_on)
      text = Support.text(reason, Catalog::REASON)
      bad = []
      bad << "from_on" unless date && date >= Time.zone.today
      bad << "reason" unless text
      return Support.refuse(bad) if bad.any?

      TransportSeries.transaction(requires_new: true) do
        series.lock!
        series.update!(suspended_from: date, suspend_reason: text)
        # A recusa do RemovePassenger aqui só significa que o passageiro já
        # não está ativo numa viagem aberta (retirado ou viagem que mudou de
        # situação no meio): nada a retirar.
        future_passengers(series, date).each { |passenger| RemovePassenger.call(passenger: passenger, reason: text, by: by) }
        series.transport_pending_items.where(resolved_at: nil).where(date: date..).update_all(resolved_at: Time.current)
        Result.ok(series: series)
      end
    end

    def future_passengers(series, date)
      TransportTripPassenger.active.where(transport_series_id: series.id, anonymized_at: nil)
                            .joins(:transport_trip)
                            .where(transport_trips: { status: Catalog::OPEN_STATUSES })
                            .where("transport_trips.date >= ?", date)
                            .order(:id).to_a
    end

    private_class_method :future_passengers
  end
end
