# Request specs against the city of the host (replaces spec/support/admin_auth.rb).
#
# Every request goes through CityResolution, which resolves the city from the
# host label and runs the action on that city's connection. The suite already
# runs every example on TEST_CITY_A's connection (city_test_databases.rb), so by
# default request specs also address TEST_CITY_A's host, with its City row in
# the platform catalog (rolled back with the fixture transaction). Specs that
# test resolution itself pass their own HOST header.
#
# admin_auth.rb was loaded by explicit `require` in two specs, and its global
# `before(type: :request) { host! "localhost" }` then leaked into every request
# spec loaded after it — full-run behaviour differed from isolated runs. This
# file is loaded once by rails_helper, so every run sees the same default.
module CityRequestAuth
  def test_city_host
    "#{TEST_CITY_A.slug}.rotasaude.app"
  end

  # Registers TEST_CITY_A in the platform catalog and points requests at its host.
  def use_test_city_host!
    unless City.exists?(slug: TEST_CITY_A.slug)
      City.create!(slug: TEST_CITY_A.slug, name: TEST_CITY_A.name, status: "active",
                   database_url: TEST_CITY_A.database_url, encryption_key: TEST_CITY_A.encryption_key)
    end
    CityCatalog.reset_cache!
    host! test_city_host
  end

  # Authenticates as `user` by creating a real Session in the current city's
  # database and planting the SIGNED cookie that Authentication resolves
  # (cookies.signed[:session_id]). Does not go through MFA.
  def sign_in_as(user)
    session = user.sessions.create!(user_agent: "rspec", ip_address: "127.0.0.1")
    jar = ActionDispatch::TestRequest.create.cookie_jar
    jar.signed[:session_id] = session.id
    cookies[:session_id] = jar[:session_id]
    session
  end

  # Sessão de operador aberta por grant (Plano 3B): a linha vive no banco da
  # cidade corrente, sem usuário, e o cookie é o mesmo `session_id` da cidade.
  def sign_in_operator_grant(operator)
    session = Session.create!(operator_id: operator.id, user_agent: "rspec", ip_address: "127.0.0.1")
    jar = ActionDispatch::TestRequest.create.cookie_jar
    jar.signed[:session_id] = session.id
    cookies[:session_id] = jar[:session_id]
    session
  end
end

RSpec.configure do |config|
  config.include CityRequestAuth, type: :request
  config.before(type: :request) { use_test_city_host! }
  config.after(type: :request) { CityCatalog.reset_cache! }
end
