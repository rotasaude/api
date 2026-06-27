# Autentica request specs criando uma Session real e injetando o cookie ASSINADO
# que o concern Authentication resolve (cookies.signed[:session_id]). Não passa
# pelo fluxo de MFA — endpoints Admin::Api exigem apenas require_authentication
# e (no caso de cities) require_operator!.
module AdminAuth
  def sign_in_as(user)
    session = user.sessions.create!(user_agent: "rspec", ip_address: "127.0.0.1")
    jar = ActionDispatch::TestRequest.create.cookie_jar
    jar.signed[:session_id] = session.id
    cookies[:session_id] = jar[:session_id]
    session
  end

  def operator!(email: "op@local")
    user = User.create!(email_address: email, password: "secret123")
    Membership.create!(user: user, role: "platform_operator", municipality_id: nil, granted_at: Time.current)
    user
  end
end

RSpec.configure do |config|
  config.include AdminAuth, type: :request
  # HostAuthorization (ADR de hosts) bloqueia o host default www.example.com dos
  # request specs com 403 "Blocked hosts". localhost (PUBLIC_HOST) está na allowlist.
  config.before(type: :request) { host! "localhost" }
end
