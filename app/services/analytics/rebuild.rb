# app/services/analytics/rebuild.rb
module Analytics
  # Reconsolida um período longo (spec §4.3): primeiro deploy e correção de bug
  # de consolidação. Blocos de 30 dias com o mesmo Analytics::Run do job
  # (kind rebuild), cada um publicando as próprias semanas. Limitado ao cru que
  # ainda existe: o que foi anonimizado ou purgado não volta, e um período
  # antigo refeito perde o que saiu do cru desde então (desvio 14 do plano).
  class Rebuild
    BLOCK_DAYS = 30
    Report = Struct.new(:from, :to, :runs, :failed, :busy, keyword_init: true)

    # Primeiro dia local com dado cru que o Analytics lê.
    EARLIEST_SQL = <<~SQL.squish
      SELECT MIN(((moment AT TIME ZONE 'UTC') AT TIME ZONE :tz)::date)::text FROM (
        SELECT MIN(created_at) AS moment FROM triages
        UNION ALL SELECT MIN(checked_in_at) FROM attendances
        UNION ALL SELECT MIN(created_at) FROM appointment_requests
        UNION ALL SELECT MIN(ended_at) FROM appointments
      ) raw
    SQL

    def self.earliest_raw_day
      value = ApplicationRecord.connection.select_value(ApplicationRecord.sanitize_sql_array([ EARLIEST_SQL, { tz: Analytics.tz } ]))
      value && Date.iso8601(value)
    end

    def self.call(from: nil, to: nil)
      yesterday = Time.zone.yesterday
      to = [ to || yesterday, yesterday ].min
      from ||= earliest_raw_day
      runs = []
      return Report.new(from: from, to: to, runs: runs, failed: nil, busy: false) if from.nil? || from > to

      cursor = from
      while cursor <= to
        block_to = [ cursor + BLOCK_DAYS - 1, to ].min
        run = Run.call(kind: "rebuild", from: cursor, to: block_to)
        return Report.new(from: from, to: to, runs: runs, failed: nil, busy: true) if run.nil?

        runs << run
        return Report.new(from: from, to: to, runs: runs, failed: run, busy: false) if run.status == "failed"

        cursor = block_to + 1
      end
      Report.new(from: from, to: to, runs: runs, failed: nil, busy: false)
    end
  end
end
