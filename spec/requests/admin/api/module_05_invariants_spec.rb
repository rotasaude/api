require "rails_helper"

# Critério de fechamento do módulo 05 (Dashboard), como suíte de invariante:
#   - todo painel devolve o envelope { data, as_of }, com as_of = instante da
#     leitura (ADR 0022: agregação ao vivo);
#   - /admin/api é só leitura;
#   - nenhum painel emite dado clínico cru (resposta, texto de mensagem,
#     evidência de consentimento, CPF, telefone);
#   - nenhum painel devolve dado de outra cidade (ADR 0020);
#   - nenhum painel operacional lê a projeção dashboard_metrics (ADR 0022).
# Substitui os testes Minitest de test/controllers/admin/api, que a CI nunca rodava.
RSpec.describe "Admin::Api module 05 invariants", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  ENDPOINTS = %w[
    /admin/api/overview /admin/api/ingestion /admin/api/conversations
    /admin/api/consent /admin/api/triages /admin/api/reports
    /admin/api/classification /admin/api/protocols /admin/api/queues
    /admin/api/events /admin/api/health /admin/api/municipalities
  ].freeze

  SENTINELS = {
    inbound_raw:    "SENTINEL_INBOUND_RAW_42aa3f",
    triage_answer:  "SENTINEL_TRIAGE_ANSWER_b7c91d",
    consent_evid:   "SENTINEL_CONSENT_EVIDENCE_1e88a0",
    cpf:            "52998224725",
    phone:          "+5541987650042"
  }.freeze

  CITY_B_MARKER = "cidadeb-sentinela".freeze

  def viewer
    user = User.create!(email_address: "inv-#{SecureRandom.hex(4)}@x.com", password: "secret123")
    Membership.create!(user: user, role: "viewer", granted_at: 2.days.ago)
    user
  end

  def definition(name)
    {
      "name" => name, "version" => 1, "start_step_id" => "s1",
      "steps" => [ { "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
                     "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 5, "false" => 0 } } ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0, "alta" => 5 },
                     "priority_map" => { "baixa" => 9, "alta" => 1 } }
    }
  end

  # Uma cidade com dado em todo painel, e as sentinelas nos campos proibidos.
  def seed_city!(protocol_name:, tier:, event_name:, answer: nil, evidence: nil, raw: nil, cpf: nil, phone: nil)
    citizen = Citizen.create!(cpf: cpf || "11144477735", phone: phone || "+5541900000077")
    conv = Conversation.create!(phone: citizen.phone, state: "consented", channel: "web", citizen: citizen)
    Consent.create!(conversation: conv, version: 1, policy_text_sha: "sha", channel: "web",
                    given_at: 1.day.ago, evidence: evidence)
    protocol = ProtocolDefinition.create!(name: protocol_name, version: 1, status: "active", definition: definition(protocol_name))
    Triage.create!(conversation: conv, protocol_definition: protocol, protocol_name: protocol_name,
                   status: "completed", tier: tier, priority: 1, completed_at: 1.hour.ago,
                   answers: { "s1" => answer || "true" })
    InboundMessage.create!(message_id: SecureRandom.uuid, from: citizen.phone, kind: "text", raw: raw)
    DomainEvent.create!(name: event_name, payload: { "triage_id" => SecureRandom.uuid }, occurred_at: 1.hour.ago)
  end

  def read_every_panel
    sign_in_as(viewer)
    ENDPOINTS.map do |path|
      get path, params: { period: "7d" }
      expect(response).to have_http_status(:ok), "#{path} respondeu #{response.status}: #{response.body}"
      [ path, response.body ]
    end
  end

  before do
    seed_city!(protocol_name: "resp", tier: "alta", event_name: "triage.completed",
               answer: SENTINELS[:triage_answer], evidence: SENTINELS[:consent_evid], raw: SENTINELS[:inbound_raw],
               cpf: SENTINELS[:cpf], phone: SENTINELS[:phone])
  end

  it "answers every panel with the { data, as_of } envelope, as_of being the read instant" do
    freeze_time do
      read_every_panel.each do |path, body|
        json = JSON.parse(body)
        expect(json).to have_key("data"), "#{path} sem data"
        expect(Time.iso8601(json.fetch("as_of"))).to eq(Time.current.change(usec: 0)), "#{path} com as_of fora do instante da leitura"
      end
    end
  end

  it "exposes no write route under /admin/api" do
    writes = Rails.application.routes.routes.select do |route|
      route.path.spec.to_s.start_with?("/admin/api") && %w[POST PATCH PUT DELETE].include?(route.verb)
    end

    expect(writes.map { |r| "#{r.verb} #{r.path.spec}" }).to be_empty
  end

  it "never emits raw clinical data or the citizen's identity" do
    read_every_panel.each do |path, body|
      SENTINELS.each do |field, sentinel|
        expect(body).not_to include(sentinel), "#{path} vazou #{field}"
      end
    end
  end

  it "never returns another city's data" do
    CityConnection.with(TEST_CITY_B) do
      seed_city!(protocol_name: CITY_B_MARKER, tier: CITY_B_MARKER, event_name: "#{CITY_B_MARKER}.event")
    end

    read_every_panel.each do |path, body|
      expect(body).not_to include(CITY_B_MARKER), "#{path} devolveu dado da cidade B"
    end
  end

  it "keeps the operational panels off the dashboard_metrics projection" do
    readers = Dir[Rails.root.join("app/queries/admin/*.rb")].select { |f| File.read(f).include?("DashboardMetric") }

    expect(readers.map { |f| File.basename(f) }).to eq([ "health_query.rb" ])
  end
end
