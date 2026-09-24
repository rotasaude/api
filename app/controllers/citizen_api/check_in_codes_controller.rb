# POST /citizen/triages/:id/check_in_code — "Cheguei na unidade" (spec
# 2026-09-24 §4). Só para triagem de um par do celular da sessão.
module CitizenApi
  class CheckInCodesController < BaseController
    ERROR_STATUS = { triage_too_old: :unprocessable_entity, triage_not_eligible: :unprocessable_entity,
                     already_checked_in: :conflict }.freeze

    rate_limit to: 10, within: 1.hour, only: :create, name: "citizen_check_in_code",
               by: -> { current_citizen_session&.id || request.remote_ip }, store: RateLimitStore,
               with: -> { render_error("too_many_requests", :too_many_requests) }

    def create
      triage = Triage.joins(:conversation)
                     .where(conversations: { channel: "web", citizen_id: current_citizen_session.citizens.select(:id) })
                     .find_by(id: params[:id])
      return render_error("not_found", :not_found) unless triage

      result = Citizens::IssueCheckInCode.call(citizen: triage.conversation.citizen, triage: triage)
      return render_error(result.reason, ERROR_STATUS.fetch(result.reason, :unprocessable_entity)) if result.failure?

      render json: { code: result.payload[:code], expires_at: result.payload[:expires_at].iso8601 }, status: :created
    end
  end
end
