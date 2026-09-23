# POST   /citizen/session { phone, code } → 201 + cookie
# GET    /citizen/session                 → 200 | 401
# DELETE /citizen/session                 → 204
module CitizenApi
  class SessionsController < BaseController
    allow_anonymous_citizen only: :create

    rate_limit to: 20, within: 1.hour, only: :create, name: "citizen_session_ip", store: RateLimitStore,
               with: -> { render_error("too_many_requests", :too_many_requests) }

    def create
      phone = CitizenIdentity::Phone.normalize(params[:phone])
      return render_error("invalid_code", :unprocessable_entity) unless phone

      case OtpChallenge.verify(phone: phone, code: params[:code])
      when :ok
        session, token = CitizenSession.start!(phone: phone)
        Current.citizen_session = session
        write_citizen_cookie(token)
        render json: session_json(session), status: :created
      when :expired, :missing then render_error("code_expired", :unprocessable_entity)
      when :exhausted         then render_error("code_exhausted", :unprocessable_entity)
      else                         render_error("invalid_code", :unprocessable_entity)
      end
    end

    def show
      render json: session_json(current_citizen_session)
    end

    def destroy
      current_citizen_session.revoke!
      clear_citizen_cookie
      head :no_content
    end

    private

    def session_json(session)
      { phone_masked: CitizenIdentity::Phone.mask(session.phone) }
    end
  end
end
