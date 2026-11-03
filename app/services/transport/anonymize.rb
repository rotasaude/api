# Exclusão LGPD do transporte sanitário (ADR 0048; Desvio 17; contrato §12;
# §14 T23). Só no ramo NÃO retido do Citizens::Erase (quem tem processo de TFD
# é retido inteiro: processo, trechos, passageiros de origem tfd, ajudas,
# pagamentos e o comprovante da prestação de contas com o nome do arquivo —
# T39). Na transação da exclusão, nesta ordem (o trigger congela a linha
# anonimizada: retirar ou suspender depois daria erro):
#   1. séries ativas do paciente suspensas a partir de hoje pelo
#      Transport::SuspendSeries (motivo fixo; tira o paciente das viagens
#      abertas da série a partir de hoje); a já suspensa guarda a data e troca
#      o motivo livre pelo fixo;
#   2. o paciente sai de toda viagem aberta (planned/confirmed) pelo
#      Transport::RemovePassenger, e da `in_progress` com a mesma escrita
#      (removed_at, quem, motivo fixo; evento passenger_removed só com ids) — o
#      RemovePassenger recusa a in_progress, e o passageiro anonimizado ali
#      travaria a presença e o fechamento da viagem;
#   3. um update_all em todas as linhas do paciente ainda não anonimizadas:
#      cifradas → NULL e anonymized_at (uma vez, filtro anonymized_at IS NULL);
#      presença, retirada e contagens ficam;
#   4. as cifradas da série (prestador, endereço, acompanhante) → NULL.
#
# Ordem de travas: o Citizens::Erase chama lock! ANTES de travar o paciente
# (séries → viagens abertas do paciente → paciente), a ordem do
# MaterializeSeriesJob (série → viagem → FK do paciente) e do AddPassenger
# (viagem → FK do paciente). O aviso (Transport::Notify) trava cidadão → viagem
# → passageiro; a exclusão trava os cidadãos antes de tudo: sem inversão.
# Nada do paciente em log nem em evento.
module Transport
  module Anonymize
    REASON = "Exclusão do cadastro (LGPD)".freeze
    PASSENGER_ENCRYPTED = %i[provider_name address companion_name companion_document companion_reason exception_note
                             remove_reason].freeze
    SERIES_ENCRYPTED = %i[provider_name address companion_name companion_document companion_reason].freeze
    REMOVABLE = (Catalog::OPEN_STATUSES + %w[in_progress]).freeze

    module_function

    # Trava as séries e as viagens abertas (com o paciente ativo) antes do paciente.
    def lock!(patient_ids)
      ids = Array(patient_ids)
      return if ids.empty?

      TransportSeries.where(patient_id: ids).order(:id).lock.to_a
      TransportTrip.where(id: removable(ids).select(:transport_trip_id)).order(:id).lock.to_a
    end

    # -> Integer (linhas de passageiro anonimizadas)
    def patients!(patient_ids, by:, now: Time.current)
      ids = Array(patient_ids).uniq
      return 0 if ids.empty?

      today = now.in_time_zone.to_date
      ApplicationRecord.transaction(requires_new: true) do
        lock!(ids)
        series = TransportSeries.where(patient_id: ids).order(:id).to_a
        series.each { |record| suspend!(record, today, by) }
        removable(ids).order(:id).each { |passenger| remove!(passenger, by, now) }
        count = TransportTripPassenger.where(patient_id: ids, anonymized_at: nil)
                                      .update_all(PASSENGER_ENCRYPTED.index_with(nil).merge(anonymized_at: now, updated_at: now))
        series.each { |record| record.update_columns(SERIES_ENCRYPTED.index_with(nil).merge(updated_at: now)) }
        count
      end
    end

    def removable(ids)
      TransportTripPassenger.active.where(patient_id: ids, anonymized_at: nil).joins(:transport_trip)
                            .where(transport_trips: { status: REMOVABLE })
    end

    def suspend!(series, today, by)
      if series.active_on?(today)
        result = SuspendSeries.call(series: series, from_on: today, reason: REASON, by: by)
        raise "transport: erasure could not suspend series #{series.id}: #{result.reason}" if result.failure?
      elsif series.suspended_from
        # update_columns cifra (o tipo cifrado serializa).
        series.update_columns(suspend_reason: REASON)
      end
    end

    def remove!(passenger, by, now)
      trip = passenger.transport_trip
      if trip.status == "in_progress"
        passenger.update!(removed_at: now, removed_by_user: by, remove_reason: REASON)
        DomainEvents.publish("transport.passenger_removed", trip_id: trip.id, passenger_id: passenger.id)
        return
      end

      result = RemovePassenger.call(passenger: passenger, reason: REASON, by: by)
      raise "transport: erasure could not remove passenger #{passenger.id}: #{result.reason}" if result.failure?
    end

    private_class_method :removable, :suspend!, :remove!
  end
end
