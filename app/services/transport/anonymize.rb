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
#      Transport::RemovePassenger (motivo fixo; evento passenger_removed só com
#      ids). Viagem `in_progress` com o paciente ativo nunca chega aqui: o
#      Citizens::Erase recusa antes (`patient_on_trip`, on_trip?) — retirar
#      quem está a bordo mudaria a lista do motorista e as contagens;
#   3. o motivo de cada correção de presença das linhas do paciente regravado
#      uma vez com o texto fixo (TransportAttendanceCorrection.with_erasure);
#   4. um update_all em todas as linhas do paciente ainda não anonimizadas
#      (abertas já retiradas, feitas, canceladas): cifradas → NULL e
#      anonymized_at (uma vez, filtro anonymized_at IS NULL); presença,
#      retirada e contagens ficam;
#   5. as cifradas da série (prestador, endereço, acompanhante) → NULL.
#
# Ordem de travas: o Citizens::Erase chama lock! ANTES de travar o paciente
# (séries → viagens abertas ou em andamento do paciente → paciente), a ordem
# do MaterializeSeriesJob (série → viagem → FK do paciente) e do AddPassenger
# (viagem → FK do paciente). Janela conhecida: um passageiro gravado entre o
# lock! do Erase e a trava do paciente tem a viagem travada aqui DEPOIS do
# paciente (o lock! de patients! a pega). Inverter de fato exige outra
# transação segurando essa viagem e esperando ESTE paciente — só um
# AddPassenger do mesmo paciente na mesma viagem, impossível (índice único do
# passageiro ativo). O pior caso é um deadlock que o Postgres desfaz e o
# controller devolve como try_again. O aviso (Transport::Notify) trava cidadão → viagem
# → passageiro; a exclusão trava os cidadãos antes de tudo: sem inversão.
# Nada do paciente em log nem em evento.
module Transport
  module Anonymize
    REASON = "Exclusão do cadastro (LGPD)".freeze
    PASSENGER_ENCRYPTED = %i[provider_name address companion_name companion_document companion_reason exception_note
                             remove_reason].freeze
    SERIES_ENCRYPTED = %i[provider_name address companion_name companion_document companion_reason].freeze
    LOCKED = (Catalog::OPEN_STATUSES + %w[in_progress]).freeze

    module_function

    # Trava as séries e as viagens abertas (com o paciente ativo) antes do paciente.
    def lock!(patient_ids)
      ids = Array(patient_ids)
      return if ids.empty?

      TransportSeries.where(patient_id: ids).order(:id).lock.to_a
      TransportTrip.where(id: active_rows(ids).select(:transport_trip_id), status: LOCKED).order(:id).lock.to_a
    end

    # Paciente ativo numa viagem em andamento: a exclusão espera o fechamento.
    def on_trip?(patient_ids)
      active_rows(Array(patient_ids)).joins(:transport_trip).where(transport_trips: { status: "in_progress" }).exists?
    end

    # -> Integer (linhas de passageiro anonimizadas)
    def patients!(patient_ids, by:, now: Time.current)
      ids = Array(patient_ids).uniq
      return 0 if ids.empty?

      today = now.in_time_zone.to_date
      ApplicationRecord.transaction(requires_new: true) do
        lock!(ids)
        raise "transport: erasure with the patient on a trip in progress" if on_trip?(ids) # o Erase recusa antes
        series = TransportSeries.where(patient_id: ids).order(:id).to_a
        series.each { |record| suspend!(record, today, by) }
        removable(ids).order(:id).each { |passenger| remove!(passenger, by) }
        scrub_corrections!(ids)
        count = TransportTripPassenger.where(patient_id: ids, anonymized_at: nil)
                                      .update_all(PASSENGER_ENCRYPTED.index_with(nil).merge(anonymized_at: now, updated_at: now))
        series.each { |record| record.update_columns(SERIES_ENCRYPTED.index_with(nil).merge(updated_at: now)) }
        count
      end
    end

    def active_rows(ids) = TransportTripPassenger.active.where(patient_id: ids, anonymized_at: nil)

    def removable(ids) = active_rows(ids).joins(:transport_trip).where(transport_trips: { status: Catalog::OPEN_STATUSES })

    # update_columns cifra (o tipo cifrado serializa); antes da anonimização (o trigger exige o passageiro não anonimizado).
    def scrub_corrections!(ids)
      rows = TransportTripPassenger.where(patient_id: ids, anonymized_at: nil).select(:id)
      corrections = TransportAttendanceCorrection.where(transport_trip_passenger_id: rows).order(:id).to_a
      return if corrections.empty?

      TransportAttendanceCorrection.with_erasure { corrections.each { |row| row.update_columns(reason: REASON) } }
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

    def remove!(passenger, by)
      result = RemovePassenger.call(passenger: passenger, reason: REASON, by: by)
      raise "transport: erasure could not remove passenger #{passenger.id}: #{result.reason}" if result.failure?
    end

    private_class_method :active_rows, :removable, :scrub_corrections!, :suspend!, :remove!
  end
end
