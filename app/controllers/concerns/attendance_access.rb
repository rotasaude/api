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

  def require_professional
    # ADR 0021: a recusa diz o que falta. O vínculo é conferido no comando.
    forbid("missing_role") unless CitizenVerificationPolicy.new(Current.user, nil).care?
  end

  def require_attendance_staff
    policy = CitizenVerificationPolicy.new(Current.user, nil)
    forbid unless policy.verify? || policy.care?
  end

  def forbid(reason = "forbidden")
    render json: { error: reason }, status: :forbidden
  end

  def render_failure(result, status_map)
    render json: AttendanceAccess.failure_payload(result), status: status_map.fetch(result.reason, :unprocessable_entity)
  end

  # `{ error, ...details }` (datas em ISO 8601) — também o formato de recusa do
  # 19 nas rotas do CAPS (ClinicalDocumentResponses).
  def self.failure_payload(result)
    { error: result.reason.to_s }.merge(result.details.transform_values { |v| v.respond_to?(:iso8601) ? v.iso8601 : v })
  end
end
