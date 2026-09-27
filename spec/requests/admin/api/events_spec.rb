require "rails_helper"

# F-07.13 — painel de eventos do dashboard da cidade: GET /admin/api/events
# (Admin::EventsQuery). Busca por nome (exato ou prefixo "x.*") e por janela;
# o stream expõe só referências (at/name/actor/ref), nunca o payload livre
# (ADR-0004/0014).
RSpec.describe "Admin::Api::Events", type: :request do
  def viewer
    user = User.create!(email_address: "ev-#{SecureRandom.hex(4)}@x.com", password: "secret123")
    Membership.create!(user: user, role: "viewer", granted_at: 2.days.ago)
    user
  end

  def event(name, at: 1.hour.ago, **payload)
    DomainEvent.create!(name: name, occurred_at: at, payload: payload)
  end

  def fetch(params = {})
    get "/admin/api/events", params: { period: "7d" }.merge(params)
    expect(response).to have_http_status(:ok)
    JSON.parse(response.body).fetch("data")
  end

  before { sign_in_as(viewer) }

  it "filtra por nome exato" do
    event("triage.completed", triage_id: "t1")
    event("triage.urgent", triage_id: "t2")

    data = fetch(name: "triage.completed")

    expect(data["total"]).to eq(1)
    expect(data["stream"].map { |e| e["name"] }).to eq(["triage.completed"])
  end

  it "filtra por prefixo x.* sem casar outro domínio que comece igual" do
    event("triage.completed")
    event("triage.urgent")
    event("triagex.other")
    event("consent.granted")

    data = fetch(name: "triage.*")

    expect(data["byType"].map { |t| t["name"] }).to contain_exactly("triage.completed", "triage.urgent")
  end

  it "trata % e _ do prefixo como texto, não como curinga" do
    event("triage.completed")

    expect(fetch(name: "tri_ge.*")["total"]).to eq(0)
    expect(fetch(name: "%.*")["total"]).to eq(0)
  end

  it "respeita a janela: custom from/to e o período padrão" do
    inside = event("triage.completed", at: Time.zone.parse("2026-09-10T12:00:00-03:00"))
    event("triage.completed", at: Time.zone.parse("2026-08-01T12:00:00-03:00"))

    data = fetch(period: "custom", from: "2026-09-09", to: "2026-09-11")

    expect(data["total"]).to eq(1)
    expect(data["stream"].first["ref"]).to be_nil
    expect(data["stream"].first["at"]).to eq(inside.occurred_at.iso8601)
    expect(fetch["total"]).to eq(0)
  end

  it "recusa data inválida com 422" do
    get "/admin/api/events", params: { period: "custom", from: "ontem", to: "hoje" }
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "ordena o stream do mais novo para o mais antigo e corta em 50" do
    55.times { |i| event("triage.completed", at: (i + 1).minutes.ago) }

    data = fetch

    expect(data["total"]).to eq(55)
    expect(data["stream"].size).to eq(50)
    ats = data["stream"].map { |e| Time.iso8601(e["at"]) }
    expect(ats).to eq(ats.sort.reverse)
  end

  it "expõe só referências no stream, nunca o payload livre" do
    event("user.invited", email: "pessoa@cidade.gov.br", role: "viewer", invitation_id: "inv-1", actor: "user-9")

    data = fetch
    row = data["stream"].first

    expect(row.keys).to contain_exactly("at", "name", "actor", "ref")
    expect(row["ref"]).to eq("invitation_id=inv-1")
    expect(row["actor"]).to eq("user-9")
    expect(response.body).not_to include("pessoa@cidade.gov.br")
  end

  it "usa 'sistema' quando o evento não tem ator" do
    event("triage.completed", triage_id: "t1")
    expect(fetch["stream"].first["actor"]).to eq("sistema")
  end

  it "ancora o replay no evento mais antigo da cidade" do
    oldest = event("triage.completed", at: 200.days.ago)
    event("triage.completed")

    expect(fetch["replayAnchor"]).to eq("seq" => "evt_id=#{oldest.id}", "at" => oldest.occurred_at.iso8601)
    expect(fetch["retentionMonths"]).to eq(12)
  end
end
