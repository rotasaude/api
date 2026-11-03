# Aviso de viagem ao cidadão (ADR 0048; Desvio 8; contrato §8; §14 T15).
# Um aviso por par validado do paciente (Patients::Pairs.of) e por (passageiro,
# cidadão, tipo, chave do evento) — índice único, INSERT ... ON CONFLICT DO
# NOTHING: evento repetido não duplica. Só em viagem `confirmed`/`in_progress`
# (passageiro ativo; `removed`: o retirado); `cancelled` só da viagem que tinha
# `confirmed_at` (a planned cancelada não avisa). Passageiro anonimizado: nada.
#
# Mudanças (Ruling I-2): o aviso guarda a saída e o rótulo da parada do
# momento; `departure_changed` só sai quando a saída atual difere 30 min ou
# mais da do ÚLTIMO aviso daquele (passageiro, cidadão), e `boarding_changed`
# quando o rótulo atual difere do último avisado — idas e voltas (A→B→A→B) e
# mudanças graduais saem certas, e uma volta ao valor já avisado não avisa.
# Sem aviso anterior para o par, não há de onde "mudar": nada. A chave dessas
# duas é o id do evento de domínio (Transport::NoticeJob).
#
# Ordem de trava do Appointments::Remind: os cidadãos em FOR KEY SHARE antes
# da viagem (a exclusão segura o cidadão em FOR UPDATE antes do resto); depois
# o passageiro (FOR UPDATE), que serializa os avisos dele (a comparação com o
# último aviso não corre).
#
# SMS (regras do 17 + T15) só quando o aviso nasce: chave de SMS da cidade,
# provedor, janela 8h–20h no fuso da cidade, opt-in, sem `notices_muted` nem
# `appointment_reminders_muted`. A linha só muda `read_at` (trigger), por isso
# `sms` é gravado já no INSERT: num savepoint, o aviso nasce com `sms: true`, o
# texto sai e, se o provedor falha, o savepoint é desfeito e o aviso nasce com
# `sms: false`. Falha do provedor só com a classe no log; erro de banco segue.
module Transport
  module Notify
    OPEN = %w[confirmed in_progress].freeze
    CHANGES = %w[departure_changed boarding_changed].freeze
    UNIQUE = :idx_transport_trip_notices_once

    module_function

    # -> Integer (avisos criados)
    def call(passenger:, kind:, event_key: "once", now: Time.current)
      kind = kind.to_s
      raise ArgumentError, "kind" unless Catalog::NOTICE_KINDS.include?(kind)

      ApplicationRecord.transaction(requires_new: true) do
        citizens = Patients::Pairs.of(passenger.patient).order(:id).lock("FOR KEY SHARE").to_a
        trip = TransportTrip.lock("FOR SHARE").find(passenger.transport_trip_id)
        rider = TransportTripPassenger.lock.find(passenger.id)
        next 0 unless due?(trip, rider, kind)

        label = rider.transport_trip_stop.label
        citizens.count do |citizen|
          changed?(citizen, rider, trip, label, kind) && notify(citizen, rider, trip, label, kind, event_key, now)
        end
      end
    end

    def due?(trip, rider, kind)
      return false if rider.anonymized_at

      case kind
      when "cancelled" then trip.status == "cancelled" && trip.confirmed_at.present? && !rider.removed?
      when "removed" then rider.removed? && OPEN.include?(trip.status)
      else !rider.removed? && OPEN.include?(trip.status)
      end
    end

    # Só para departure_changed/boarding_changed: compara com o último aviso do par.
    def changed?(citizen, rider, trip, label, kind)
      return true unless CHANGES.include?(kind)

      last = TransportTripNotice.where(transport_trip_passenger_id: rider.id, citizen_id: citizen.id)
                                .order(created_at: :desc, id: :desc).first
      return false unless last

      if kind == "departure_changed"
        (trip.departure_at - last.departure_at).abs >= Catalog::DEPARTURE_CHANGE
      else
        last.boarding_label != label
      end
    end

    # -> true quando o aviso nasceu
    def notify(citizen, rider, trip, label, kind, event_key, now)
      row = { transport_trip_passenger_id: rider.id, citizen_id: citizen.id, kind: kind, event_key: event_key,
              departure_at: trip.departure_at, boarding_label: label, created_at: now }
      if sms_allowed?(citizen, now)
        sent = false
        ApplicationRecord.transaction(requires_new: true) do
          next unless insert?(row.merge(sms: true))

          sent = deliver(citizen, rider, kind)
          raise ActiveRecord::Rollback unless sent
        end
        return true if sent
      end
      insert?(row.merge(sms: false))
    end

    def insert?(row)
      TransportTripNotice.insert(row, unique_by: UNIQUE, returning: :id).rows.any?
    end

    def sms_allowed?(citizen, now)
      return false unless Campaigns::SmsSetting.enabled? && SmsGateway.configured?
      return false unless Campaigns::SmsBatchJob::WINDOW_HOURS.cover?(now.in_time_zone.hour)

      preference = CitizenContactPreference.find_by(citizen_id: citizen.id)
      preference.present? && preference.sms_opt_in && !preference.notices_muted && !preference.appointment_reminders_muted
    end

    # Só o provedor é resgatado (como no Appointments::Remind).
    def deliver(citizen, rider, kind)
      SmsGateway.deliver(phone: citizen.phone, body: SmsText.body(kind: kind, passenger: rider))
      true
    rescue ActiveRecord::ActiveRecordError
      raise
    rescue StandardError => e
      Rails.logger.warn("[transport.notice] SMS não saiu: #{e.class}")
      false
    end

    private_class_method :due?, :changed?, :notify, :insert?, :sms_allowed?, :deliver
  end
end
