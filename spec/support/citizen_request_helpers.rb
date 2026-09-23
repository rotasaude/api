# Planta o cookie assinado `citizen_session` de uma sessão real, como
# CitizenAuthentication lê. Não passa pelo OTP.
module CitizenRequestHelpers
  def sign_in_citizen(phone = "+5541998765432")
    session, token = CitizenSession.start!(phone: phone)
    jar = ActionDispatch::TestRequest.create.cookie_jar
    jar.signed[:citizen_session] = token
    cookies[:citizen_session] = jar[:citizen_session]
    session
  end

  def json_post(path, params = {})
    post path, params: params.to_json, headers: { "CONTENT_TYPE" => "application/json" }
  end
end

RSpec.configure { |c| c.include CitizenRequestHelpers, type: :request }
