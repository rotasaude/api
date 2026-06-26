# GET /admin/api/consent — LGPD (§4.3).
#
# Schema real: Consent#version (integer), `revoked_at` (nullable).
# NÃO existe coluna `status` nem sinal de "declined" — "declined" sai
# null até existir consent.declined em domain_events ou flag explícita.
class Admin::ConsentQuery
  def self.call(municipality:, period:)
    new(municipality, period).call
  end

  def initialize(municipality, period)
    @muni = municipality
    @period = period
  end

  def call
    base = Admin::Scoped.consents(@muni)
    in_period = base.where(given_at: @period.from..@period.to)
    given_count = in_period.where(revoked_at: nil).count
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
