require "rails_helper"

RSpec.describe CityReports::Resign do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { create(:city, database_url: city_database_url("rota_saude_test_city_a")) }

  def legacy_signature(token)
    OpenSSL::HMAC.hexdigest("sha256", CityEncryption.legacy_report_signing_key, token)
  end

  # Snapshot com assinatura LEGADA, como as linhas gravadas antes deste plano.
  def snapshot_with_legacy_signature
    CityConnection.with(city) do
      pd = ProtocolDefinition.create!(
        name: "triagem-resign", version: 1, status: "active",
        definition: { "name" => "triagem-resign", "version" => 1, "start_step_id" => "s1",
                      "steps" => [ { "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
                                     "branches" => { "true" => nil, "false" => nil } } ] }
      )
      convo = Conversation.create!(phone: "+5541988887777", state: "greeting")
      triage = Triage.create!(conversation: convo, protocol_definition: pd, protocol_name: "triagem-resign",
                              status: "completed", tier: "alta", priority: 1,
                              completed_at: Time.current, outcome: { "trail" => [] })
      token = ReportSnapshot.mint_token
      ReportSnapshot.create!(triage: triage, protocol_definition: pd, outcome: { "tier" => "alta" },
                             payload: { "tier" => "alta" }, token: token,
                             signature: legacy_signature(token), expires_at: 30.days.from_now)
    end
  end

  it "rewrites a legacy signature with the city's own key" do
    snapshot = snapshot_with_legacy_signature

    result = CityConnection.with(city) { described_class.call }

    expect(result.ok?).to be(true)
    expect(result.payload[:count]).to eq(1)
    reloaded = CityConnection.with(city) { ReportSnapshot.find(snapshot.id) }
    expect(Digest::SHA256.hexdigest(reloaded.signature))
      .not_to eq(Digest::SHA256.hexdigest(legacy_signature(snapshot.token)))
  end

  it "leaves the token verifiable afterwards" do
    snapshot = snapshot_with_legacy_signature
    CityConnection.with(city) { described_class.call }

    found = CityConnection.with(city) { ReportSnapshot.find_by_signed_token(snapshot.token) }
    expect(found&.id).to eq(snapshot.id)
  end

  it "does not bump updated_at" do
    snapshot = snapshot_with_legacy_signature
    before = snapshot.updated_at

    travel(1.hour) { CityConnection.with(city) { described_class.call } }

    reloaded = CityConnection.with(city) { ReportSnapshot.find(snapshot.id) }
    expect(reloaded.updated_at).to eq(before)
  end

  it "counts only what it changed, so a second run is a no-op" do
    snapshot_with_legacy_signature
    CityConnection.with(city) { described_class.call }

    second = CityConnection.with(city) { described_class.call }
    expect(second.payload[:count]).to eq(0)
  end
end
