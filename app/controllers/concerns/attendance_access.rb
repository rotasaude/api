# Acesso às rotas do balcão (/attendance/*): papel da cidade, limite por
# servidor e tradução de Result para JSON. Usado pelo balcão de validação
# (subprojeto 2) e pelo check-in (subprojeto 3).
module AttendanceAccess
  extend ActiveSupport::Concern

  module RateLimitStore
    def self.increment(...) = Rails.cache.increment(...)
  end

  private

  def require_verifier
    forbid unless CitizenVerificationPolicy.new(Current.user, nil).verify?
  end

  def require_admin
    forbid unless CitizenVerificationPolicy.new(Current.user, nil).manage?
  end

  def forbid
    render json: { error: "forbidden" }, status: :forbidden
  end

  def render_failure(result, status_map)
    payload = { error: result.reason.to_s }.merge(result.details.transform_values { |v| v.respond_to?(:iso8601) ? v.iso8601 : v })
    render json: payload, status: status_map.fetch(result.reason, :unprocessable_entity)
  end
end
