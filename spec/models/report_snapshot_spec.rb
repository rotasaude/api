require "rails_helper"

RSpec.describe ReportSnapshot, type: :model do
  describe "#url" do
    around do |ex|
      Current.city = TEST_CITY_A
      ex.run
      Current.reset
    end

    it "aponta pro wpda da cidade corrente, com o token em query param (sem barra dupla)" do
      snap = ReportSnapshot.new(token: "abc123")
      expect(snap.url).to eq("http://#{TEST_CITY_A.slug}.localhost:5175/wpda/?token=abc123")
    end
  end

  # Duas cidades porque isolamento não se prova com uma (spec, Verification).
  let!(:city_a) { create(:city, slug: TEST_CITY_A.slug, database_url: city_database_url("rota_saude_test_city_a")) }
  let!(:city_b) { create(:city, slug: TEST_CITY_B.slug, database_url: city_database_url("rota_saude_test_city_b")) }

  # Snapshot mínimo dentro da cidade corrente. `create_snapshot` do
  # spec/requests/reports_spec.rb NÃO está disponível aqui: é local daquele
  # arquivo. Este helper é o equivalente enxuto.
  def create_snapshot
    pd = ProtocolDefinition.create!(
      name: "triagem-sign", version: 1, status: "active",
      definition: { "name" => "triagem-sign", "version" => 1, "start_step_id" => "s1",
                    "steps" => [ { "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
                                   "branches" => { "true" => nil, "false" => nil } } ] }
    )
    convo = Conversation.create!(phone: "+5541977776666", state: "greeting")
    triage = Triage.create!(conversation: convo, protocol_definition: pd, protocol_name: "triagem-sign",
                            status: "completed", tier: "alta", priority: 1,
                            completed_at: Time.current, outcome: { "trail" => [] })
    token = ReportSnapshot.mint_token
    ReportSnapshot.create!(triage: triage, protocol_definition: pd, outcome: { "tier" => "alta" },
                           payload: { "tier" => "alta" }, token: token,
                           signature: ReportSnapshot.sign(token), expires_at: 30.days.from_now)
  end

  describe "signing" do
    # Digests: comparar assinatura crua imprimiria material no diff de falha.
    def digest(value) = Digest::SHA256.hexdigest(value)

    it "signs with a key derived from the city" do
      token = ReportSnapshot.mint_token
      a = CityConnection.with(city_a) { ReportSnapshot.sign(token) }
      b = CityConnection.with(city_b) { ReportSnapshot.sign(token) }

      expect(digest(a)).not_to eq(digest(b))
    end

    it "verifies a signature minted in the same city" do
      snap = CityConnection.with(city_a) { create_snapshot }
      found = CityConnection.with(city_a) { ReportSnapshot.find_by_signed_token(snap.token) }

      expect(found&.id).to eq(snap.id)
    end

    # Transição (decisão 5 do plano): assinatura gravada com a chave global
    # antes do Plano 8 continua verificando até a rake reescrever.
    it "still verifies a legacy signature during the transition window" do
      snap = CityConnection.with(city_a) { create_snapshot }
      legacy = OpenSSL::HMAC.hexdigest("sha256", Rails.application.credentials.fetch(:report_signing_key), snap.token)
      CityConnection.with(city_a) { snap.update_column(:signature, legacy) }

      found = CityConnection.with(city_a) { ReportSnapshot.find_by_signed_token(snap.token) }
      expect(found&.id).to eq(snap.id)
    end

    it "refuses a signature that is neither the city's nor the legacy one" do
      snap = CityConnection.with(city_a) { create_snapshot }
      CityConnection.with(city_a) { snap.update_column(:signature, "deadbeef") }

      expect(CityConnection.with(city_a) { ReportSnapshot.find_by_signed_token(snap.token) }).to be_nil
    end
  end
end
