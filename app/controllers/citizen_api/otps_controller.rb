# POST /citizen/otp { phone } — manda o código por SMS (spec §4, §4.2).
# A resposta é a mesma exista cadastro ou não: ela não revela quem usa o serviço.
module CitizenApi
  class OtpsController < BaseController
    allow_anonymous_citizen only: :create

    rate_limit to: 10, within: 1.hour, only: :create, name: "citizen_otp_ip", store: RateLimitStore,
               with: -> { render_error("too_many_requests", :too_many_requests) }

    def create
      phone = CitizenIdentity::Phone.normalize(params[:phone])
      return render_error("invalid_phone", :unprocessable_entity) unless phone

      challenge, code = OtpChallenge.issue!(phone: phone)
      begin
        OtpSender.deliver(phone: phone, code: code)
      rescue OtpSender::Unavailable
        challenge.destroy!
        return render_error("otp_unavailable", :service_unavailable)
      end

      render json: { status: "sent", resend_after: OtpChallenge::RESEND_AFTER.to_i }, status: :accepted
    rescue OtpChallenge::TooSoon
      render_error("too_soon", :too_many_requests)
    rescue OtpChallenge::DailyLimit
      render_error("daily_limit", :too_many_requests)
    end
  end
end
