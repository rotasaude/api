require "rails_helper"
require Rails.root.join("spec/support/city_scoped_authentication_probe_controllers")

# Task 5a fix round 1, achado #2: Authentication's require_authentication
# precisa rodar DENTRO da conexão de cidade que CityResolution's
# around_action :within_city abre — nunca antes. A sessão mora no banco da
# cidade; procurá-la fora dessa conexão (ex.: contra o shard bootstrap, que
# não tem nenhuma tabela) levanta StatementInvalid em vez de devolver 401.
RSpec.describe "Authentication runs inside city resolution", type: :request do
  before(:all) do
    Rails.application.routes.disable_clear_and_finalize = true
    Rails.application.routes.draw do
      post "/_plant_signed_cookie",   to: "signed_cookie_plant#create"
      get  "/_authenticated_probe",   to: "authenticated_probe#show"
    end
  end

  after(:all) do
    Rails.application.routes.disable_clear_and_finalize = false
    Rails.application.reload_routes!
  end

  before do
    City.delete_all
    CityCatalog.reset_cache!
  end

  let(:city_a_url) { city_database_url("rota_saude_test_city_a") }

  it "returns 401, not 500, for a signed session cookie whose session does not exist in the resolved city" do
    create(:city, slug: "cidadeviva", status: "active", database_url: city_a_url)

    bogus_session_id = SecureRandom.uuid
    post "/_plant_signed_cookie", params: { session_id: bogus_session_id }
    raw_cookie = response.headers["Set-Cookie"][/session_id=[^;]+/]
    expect(raw_cookie).to be_present

    # The whole suite runs inside TEST_CITY_A's connection by default (see
    # spec/support/city_test_databases.rb), which would mask this exact
    # regression (its `sessions` table exists, so a bogus id would just miss
    # and return nil regardless of ordering). Force the shard back to
    # `bootstrap` — the empty, no-city-selected database a fresh process
    # actually starts from — so the request reproduces the real bug if the
    # ordering regresses: an unhandled StatementInvalid instead of a 401.
    CityRecord.connected_to(shard: :bootstrap, role: :writing) do
      get "/_authenticated_probe",
          headers: { "HOST" => "cidadeviva.rotasaude.app", "Cookie" => raw_cookie }
    end

    expect(response).to have_http_status(:unauthorized)
  end
end
