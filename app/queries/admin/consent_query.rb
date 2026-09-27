# GET /admin/api/consent — LGPD (§4.3; F-05.7).
#
# Schema real: Consent#version (integer), `revoked_at` (nullable).
# "given" conta todo consentimento dado no período, mesmo o revogado depois;
# "revoked" conta as revogações do período. "declined" sai nil: na web (ADR
# 0017) quem não aceita o termo não deixa registro — sem consentimento nada é
# gravado. A recusa só existia no WhatsApp, canal descontinuado.
class Admin::ConsentQuery
  def self.call(period:)
    new(period).call
  end

  def initialize(period)
    @period = period
  end

  def call
    base = Consent.all
    in_period = base.where(given_at: @period.from..@period.to)
    given_count = in_period.count
    revoked_count = base.where(revoked_at: @period.from..@period.to).count

    {
      given: given_count,
      revoked: revoked_count,
      declined: nil,
      byVersion: by_version(in_period, given_count),
      revocationsSeries: @period.series(base.where.not(revoked_at: nil), :revoked_at)
    }
  end

  private

  def by_version(scope, total)
    counts = scope.group(:version).count
    counts.sort_by { |v, _| -v }.map do |v, c|
      {
        version: "v#{v}",
        given: c,
        share: total.zero? ? 0 : (c.to_f / total * 100).round
      }
    end
  end
end
