module Regulation
  # Alarme D-1 do envio da regulação à RNDS (módulo 26c, Task 13; Q11). A
  # portaria federal pede o envio diário: a mudança de um dia tem até as
  # `RndsLimits::LATE_HOUR`:00 do dia seguinte, no fuso da cidade (`Time.zone`,
  # dentro de `CityConnection.with`), para chegar à RNDS. O `enqueued_at` é a
  # régua (desistir de uma linha não muda o alarme). A linha da carga inicial
  # ganha `INITIAL_GRACE` a contar do `created_at`. `idle`, `excluded` e
  # `erased` nunca atrasam. As contagens são em SQL, por status.
  module RndsAlert
    LATE_STATUSES = (RndsCatalog::SYNC_STATUSES - %w[idle excluded erased]).freeze

    module_function

    # `queued` inclui `sending`; `accepted` = `idle` com `last_rnds_id` (Q11).
    def counts(scope = RegulationRndsSync.all, now:)
      by_status = scope.group(:status).count
      {
        queued: by_status.fetch("queued", 0) + by_status.fetch("sending", 0),
        blocked: by_status.fetch("blocked", 0),
        rejected: by_status.fetch("rejected", 0),
        failed: by_status.fetch("failed", 0),
        late: late_scope(scope, now: now).count,
        accepted: scope.where(status: "idle").where.not(last_rnds_id: nil).count
      }
    end

    # O mesmo critério, para a linha da lista.
    def late?(sync, now:)
      return false unless LATE_STATUSES.include?(sync.status)
      return false if sync.initial_load && sync.created_at > now - RndsLimits::INITIAL_GRACE

      now >= deadline(sync.enqueued_at)
    end

    # LATE_HOUR:00 do dia seguinte ao do `enqueued_at`, no fuso da cidade.
    def deadline(enqueued_at)
      (enqueued_at.in_time_zone.to_date + 1).in_time_zone.change(hour: RndsLimits::LATE_HOUR)
    end

    def late_scope(scope, now:)
      zone = Time.zone.tzinfo.name
      deadline_sql = "((date_trunc('day', (regulation_rnds_syncs.enqueued_at AT TIME ZONE 'UTC') AT TIME ZONE :zone) " \
                     "+ interval '1 day' + make_interval(hours => :hour)) AT TIME ZONE :zone) <= :now"
      scope.where(status: LATE_STATUSES)
           .where(RegulationRndsSync.sanitize_sql_array([ deadline_sql, { zone: zone, hour: RndsLimits::LATE_HOUR, now: now.utc } ]))
           .where.not(initial_load: true, created_at: (now - RndsLimits::INITIAL_GRACE)..)
    end
    private_class_method :late_scope
  end
end
