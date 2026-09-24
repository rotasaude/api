# POST /citizen/verification_codes {citizen_id} — "Validar no posto" (spec
# 2026-09-24 §4). O par precisa ser do celular da sessão.
module CitizenApi
  class VerificationCodesController < BaseController
    rate_limit to: 10, within: 1.hour, only: :create, name: "citizen_verification_code",
               by: -> { current_citizen_session&.id || request.remote_ip }, store: RateLimitStore,
               with: -> { render_error("too_many_requests", :too_many_requests) }

    def create
      citizen = current_citizen_session.citizens.find_by(id: params[:citizen_id])
      return render_error("not_found", :not_found) unless citizen

      result = Citizens::IssueVerificationCode.call(citizen: citizen)
      return render_error(result.reason, :conflict) if result.failure?

      render json: { code: result.payload[:code], expires_at: result.payload[:expires_at].iso8601 }, status: :created
    end
  end
end
