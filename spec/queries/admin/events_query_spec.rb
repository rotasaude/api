require "rails_helper"

# F-05.12: o painel Eventos é fronteira de LGPD. O stream devolve só
# at/name/actor/ref — nunca o payload livre (ADR 0004/0014) — e lê só a janela
# do período já validado pelo controller.
RSpec.describe Admin::EventsQuery do
  def period = Admin::Api::Period.parse(key: "7d", from: nil, to: nil, tz: ActiveSupport::TimeZone["America/Sao_Paulo"])

  def event!(name, payload, occurred_at: 1.hour.ago)
    DomainEvent.create!(name: name, payload: payload, occurred_at: occurred_at)
  end

  before do
    event!("triage.completed", { "triage_id" => "t-1", "answers" => { "febre" => "sim" },
                                 "cpf" => "52998224725", "phone" => "+5541998765432", "text" => "estou com dor" })
    event!("consent.revoked",  { "conversation_id" => "c-1", "reason" => "não quero mais" })
    event!("protocol.published", { "protocol_definition_id" => "p-1", "actor" => "u-9" })
    event!("triage.completed", { "triage_id" => "t-old" }, occurred_at: 40.days.ago)
  end

  it "streams only at, name, actor and ref, never the free payload" do
    stream = described_class.call(name: nil, period: period)[:stream]

    expect(stream.flat_map(&:keys).uniq).to contain_exactly(:at, :name, :actor, :ref)
    dumped = stream.to_json
    %w[52998224725 +5541998765432 estou febre answers não\ quero].each do |secret|
      expect(dumped).not_to include(secret)
    end
  end

  it "derives ref from an *_id key and actor from the payload, defaulting to sistema" do
    stream = described_class.call(name: nil, period: period)[:stream]

    expect(stream).to include(
      a_hash_including(name: "triage.completed", ref: "triage_id=t-1", actor: "sistema"),
      a_hash_including(name: "protocol.published", ref: "protocol_definition_id=p-1", actor: "u-9")
    )
  end

  it "reads only the period window" do
    out = described_class.call(name: nil, period: period)

    expect(out[:total]).to eq(3)
    expect(out[:stream].map { |e| e[:ref] }).not_to include("triage_id=t-old")
  end

  it "filters by exact name and by prefix" do
    expect(described_class.call(name: "consent.revoked", period: period)[:total]).to eq(1)
    expect(described_class.call(name: "triage.*", period: period)[:byType]).to eq([ { name: "triage.completed", count: 1 } ])
  end
end

RSpec.describe "Admin::Api::Events", type: :request do
  def viewer
    user = User.create!(email_address: "ev-#{SecureRandom.hex(4)}@x.com", password: "secret123")
    Membership.create!(user: user, role: "viewer", granted_at: 2.days.ago)
    user
  end

  it "answers 422, not 500, for an invalid custom window" do
    sign_in_as(viewer)

    get "/admin/api/events", params: { period: "custom", from: "não-é-data", to: "2026-09-01" }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)["error"]).to eq("invalid_scope")
  end

  it "uses the validated period, not raw from/to, when a preset period is given" do
    DomainEvent.create!(name: "triage.completed", payload: { "triage_id" => "t-1" }, occurred_at: 1.hour.ago)
    sign_in_as(viewer)

    get "/admin/api/events", params: { period: "7d", from: "garbage", to: "garbage" }

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig("data", "total")).to eq(1)
  end
end
