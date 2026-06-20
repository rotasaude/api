# Apaga ReportSnapshot expirado há mais de N dias. Ver ADR-0007.
class PurgeExpiredReportsJob < ApplicationJob
  queue_as :housekeeping

  def perform(older_than_days: 30)
    cutoff = older_than_days.days.ago
    count = ReportSnapshot.where("expires_at < ?", cutoff).delete_all
    Rails.logger.info("[purge_expired_reports] deleted=#{count} cutoff=#{cutoff.iso8601}")
  end
end
