require "rails_helper"

# Módulo 25, Task 12 (contrato §5, §15 K6): o andamento da notificação —
# transições lineares, encerramento com classificação, número oficial e
# descarte da `possible`.
RSpec.describe "Vigilância — andamento da notificação", type: :request do
  let!(:city) { surveillance_city! }
  let(:officer) { surveillance_officer! }
  let(:json_headers) { { "Content-Type" => "application/json" } }

  before { sign_in_as(officer) }

  # Ordenado pelo instante: `.last` sem ordem seria por uuid (flaky).
  def domain_events(name) = DomainEvent.where(name: name).order(:occurred_at)
  def viewed = domain_events("clinical_record.viewed")

  def transition(notification, to:, version: notification.reload.version, **extra)
    post "/surveillance/notifications/#{notification.id}/transition", params: { to: to, version: version }.merge(extra).to_json,
                                                                      headers: json_headers
  end

  def dismiss(notification, version: notification.reload.version, **extra)
    post "/surveillance/notifications/#{notification.id}/dismiss", params: { version: version }.merge(extra).to_json,
                                                                   headers: json_headers
  end

  def capture_log
    log = StringIO.new
    capture = ActiveSupport::Logger.new(log).tap { |l| l.level = Logger::DEBUG }
    Rails.logger.broadcast_to(capture)
    yield
    log.string
  ensure
    Rails.logger.stop_broadcasting_to(capture)
  end

  def at(notification, status, **attrs)
    closed = { classification: "confirmed", closed_at: Time.current }
    extra = { "closed" => closed, "entered" => closed.merge(entered_at: Time.current) }.fetch(status, {})
    notification.update_columns({ status: status }.merge(extra).merge(attrs))
    notification.reload
  end

  let(:notification) { notification!(patient: surveillance_patient!(1)) }

  it "caminho completo notified → investigating → closed → entered: 4 eventos na ordem, autor, versão e fila" do
    transition(notification, to: "investigating", reason: "  Visita   ao domicílio ")
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("status" => "investigating", "version" => 2, "classification" => nil)
    transition(notification, to: "closed", classification: "confirmed")
    expect(json_body).to include("status" => "closed", "classification" => "confirmed", "version" => 3)
    expect(json_body["closed_at"]).to be_present
    expect(json_body["official_number"]).to be_nil

    get "/surveillance/notifications", params: { without_official_number: "true" }
    expect(json_body["notifications"].map { |n| n["id"] }).to eq([ notification.id ])

    transition(notification, to: "entered", official_number: "1234567")
    expect(json_body).to include("status" => "entered", "official_number" => "1234567", "version" => 4)
    expect(json_body["entered_at"]).to be_present

    events = notification.reload.events.to_a
    expect(events.map(&:status)).to eq(%w[notified investigating closed entered])
    expect(events.map(&:by_user_id)).to eq([ notification.events.first.by_user_id, officer.id, officer.id, officer.id ])
    expect(events.map(&:classification)).to eq([ nil, nil, "confirmed", nil ])
    expect(events.second.reason).to eq("Visita ao domicílio")
    expect(json_body["events"].map { |e| e["status"] }).to eq(%w[notified investigating closed entered])

    get "/surveillance/notifications"
    expect(json_body["notifications"].map { |n| n["id"] }).not_to include(notification.id)
    get "/surveillance/notifications", params: { status: "entered" }
    expect(json_body["notifications"].map { |n| n["id"] }).to eq([ notification.id ])
    get "/surveillance/notifications", params: { without_official_number: "true" }
    expect(json_body["notifications"]).to eq([])
  end

  it "devolve a ficha completa e grava uma trilha por pessoa" do
    before = viewed.count
    transition(notification, to: "investigating")
    expect(json_body.keys).to include("form", "events", "patient", "version")
    expect(viewed.count).to eq(before + 1)
    expect(viewed.last.payload).to include("person_ref" => "patient:#{notification.patient_id}", "access" => "surveillance",
                                           "user_id" => officer.id)
  end

  it "possible → notified grava o notificador" do
    possible = notification!(patient: surveillance_patient!(2), origin: "safety_net", status: "possible")
    expect(possible.notifier_user_id).to be_nil
    transition(possible, to: "notified")
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("status" => "notified", "version" => 2)
    expect(possible.reload.notifier_user_id).to eq(officer.id)
    expect(json_body["notifier"]).to be_present
  end

  describe "recusas da transição" do
    it "salto (notified → closed) e retrocesso: 422 invalid_transition, nada gravado" do
      transition(notification, to: "closed", classification: "confirmed")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "invalid_transition")
      transition(notification, to: "possible")
      expect(json_body).to eq("error" => "invalid_transition")
      transition(notification, to: "dismissed")
      expect(json_body).to eq("error" => "invalid_transition")
      transition(notification, to: "nada")
      expect(json_body).to eq("error" => "invalid_transition")
      expect(notification.reload).to have_attributes(status: "notified", version: 1)
      expect(notification.events.count).to eq(1)
    end

    it "entered e dismissed travam: qualquer destino → invalid_transition" do
      entered = at(notification, "entered", official_number: "1")
      %w[notified investigating closed entered].each do |to|
        transition(entered, to: to, classification: "confirmed")
        expect(json_body).to eq("error" => "invalid_transition"), to
      end
      dismissed = at(notification!(patient: surveillance_patient!(3)), "dismissed", dismissed_at: Time.current)
      transition(dismissed, to: "notified")
      expect(json_body).to eq("error" => "invalid_transition")
    end

    it "investigating → closed sem classificação ou com valor fora da lista: 422 classification_required" do
      investigating = at(notification, "investigating")
      [ {}, { classification: "" }, { classification: "maybe" }, { classification: 1 } ].each do |extra|
        transition(investigating, to: "closed", **extra)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_body).to eq("error" => "classification_required")
      end
      expect(investigating.reload).to have_attributes(status: "investigating", version: 1, closed_at: nil)
    end

    it "closed → entered sem número ou com número fora do formato: 422 official_number_required" do
      closed = at(notification, "closed")
      [ {}, { official_number: "12 34" }, { official_number: "" }, { official_number: "a" * 31 }, { official_number: "12;34" },
        { official_number: 1234 } ].each do |extra|
        transition(closed, to: "entered", **extra)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_body).to eq("error" => "official_number_required")
      end
      expect(closed.reload).to have_attributes(status: "closed", official_number: nil, entered_at: nil)
      transition(closed, to: "entered", official_number: "SINAN-2026/0001.A")
      expect(response).to have_http_status(:ok)
    end

    it "classificação fora de closed e número fora de entered: 422 invalid_request com o field" do
      transition(notification, to: "investigating", classification: "confirmed")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "invalid_request", "field" => "classification")
      transition(notification, to: "investigating", official_number: "123")
      expect(json_body).to eq("error" => "invalid_request", "field" => "official_number")
      closed = at(notification, "closed")
      transition(closed, to: "entered", official_number: "123", classification: "discarded")
      expect(json_body).to eq("error" => "invalid_request", "field" => "classification")
      expect(notification.reload.version).to eq(1)
    end

    it "version velha → 409 stale_version; não inteira ou ausente → 422 invalid_request; to ausente → 422 invalid_request" do
      transition(notification, to: "investigating", version: 7)
      expect(response).to have_http_status(:conflict)
      expect(json_body).to eq("error" => "stale_version")
      [ "1", nil, 1.5, [ 1 ] ].each do |version|
        transition(notification, to: "investigating", version: version)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_body).to eq("error" => "invalid_request")
      end
      post "/surveillance/notifications/#{notification.id}/transition", params: { version: 1 }.to_json, headers: json_headers
      expect(json_body).to eq("error" => "invalid_request")
      post "/surveillance/notifications/#{notification.id}/transition", params: { to: %w[investigating], version: 1 }.to_json,
                                                                         headers: json_headers
      expect(json_body).to eq("error" => "invalid_request")
      expect(notification.reload).to have_attributes(status: "notified", version: 1)
    end

    it "stale_version vale também para o descarte, e vem antes do invalid_transition" do
      possible = notification!(patient: surveillance_patient!(4), origin: "safety_net", status: "possible")
      dismiss(possible, version: 3, reason: "não é caso")
      expect(response).to have_http_status(:conflict)
      expect(json_body).to eq("error" => "stale_version")
      transition(notification, to: "closed", version: 9)
      expect(json_body).to eq("error" => "stale_version")
    end

    it "reason: opcional; longo (> 500 depois do squish) é recusado, nunca truncado; não texto também" do
      transition(notification, to: "investigating", reason: "x" * 501)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "invalid_reason", "field" => "reason")
      transition(notification, to: "investigating", reason: [ "x" ])
      expect(json_body).to eq("error" => "invalid_reason", "field" => "reason")
      transition(notification, to: "investigating", reason: "  ")
      expect(response).to have_http_status(:ok)
      expect(notification.reload.events.order(:created_at).last.reason).to be_nil
      transition(notification, to: "closed", classification: "inconclusive", reason: ("a " * 250).strip)
      expect(response).to have_http_status(:ok)
      expect(notification.reload.events.order(:created_at).last.reason.length).to eq(499)
    end
  end

  describe "descarte da possível" do
    let(:possible) { notification!(patient: surveillance_patient!(5), origin: "safety_net", status: "possible") }

    it "em notified → 422 invalid_transition" do
      dismiss(notification, reason: "não é caso")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "invalid_transition")
      expect(notification.reload).to have_attributes(status: "notified", version: 1)
    end

    it "em possible com motivo → dismissed, dismissed_at, evento imutável com autor e motivo" do
      dismiss(possible, reason: "  Caso   de outra doença ")
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("status" => "dismissed", "version" => 2)
      expect(json_body["dismissed_at"]).to be_present
      expect(possible.reload.dismissed_at).to be_present
      last = possible.events.last
      expect(last).to have_attributes(status: "dismissed", by_user_id: officer.id, reason: "Caso de outra doença")
      expect(possible.events.map(&:status)).to eq(%w[possible dismissed])
    end

    it "o descartado some da fila padrão e aparece com status=dismissed" do
      dismiss(possible, reason: "não é caso")
      get "/surveillance/notifications"
      expect(json_body["notifications"].map { |n| n["id"] }).not_to include(possible.id)
      get "/surveillance/notifications", params: { status: "dismissed" }
      expect(json_body["notifications"].map { |n| n["id"] }).to eq([ possible.id ])
      dismiss(possible, reason: "de novo")
      expect(json_body).to eq("error" => "invalid_transition")
    end

    it "motivo obrigatório 3..500: ausente, curto, longo ou não texto → 422 invalid_reason" do
      [ {}, { reason: "" }, { reason: "  ab  " }, { reason: "x" * 501 }, { reason: 123 } ].each do |extra|
        dismiss(possible, **extra)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_body).to eq("error" => "invalid_reason", "field" => "reason")
      end
      expect(possible.reload).to have_attributes(status: "possible", version: 1)
      dismiss(possible, reason: "abc")
      expect(response).to have_http_status(:ok)
    end

    it "version não inteira → 422 invalid_request" do
      dismiss(possible, version: "1", reason: "não é caso")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "invalid_request")
    end
  end

  describe "sigilo do motivo, da classificação e do número" do
    it "só ids nos eventos de domínio; nada disso no log nem em outro evento" do
      marker = "SEGREDO-#{SecureRandom.hex(4)}"
      possible = notification!(patient: surveillance_patient!(6), origin: "safety_net", status: "possible")
      log = capture_log do
        transition(notification, to: "investigating", reason: "#{marker}-a")
        transition(notification, to: "closed", classification: "inconclusive", reason: "#{marker}-b")
        transition(notification, to: "entered", official_number: "NUM#{marker[-4..]}", reason: "#{marker}-c")
        dismiss(possible, reason: "#{marker}-d")
      end
      expect(domain_events("disease_notification.transitioned").map(&:payload)).to all(
        eq("notification_id" => notification.id, "user_id" => officer.id)
      )
      expect(domain_events("disease_notification.transitioned").count).to eq(3)
      expect(domain_events("disease_notification.dismissed").last.payload).to eq("notification_id" => possible.id, "user_id" => officer.id)
      expect(DomainEvent.all.map { |e| e.payload.to_json }.join).not_to include(marker, "inconclusive", "NUM#{marker[-4..]}")
      expect(log).not_to include(marker)
      expect(log).not_to include("inconclusive")
      expect(log).not_to include("NUM#{marker[-4..]}")
      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
      expect(filter.filter("reason" => "x", "classification" => "confirmed", "official_number" => "1", "to" => "closed"))
        .to eq("reason" => "[FILTERED]", "classification" => "[FILTERED]", "official_number" => "[FILTERED]", "to" => "closed")
    end

    it "recusas não ecoam o valor recebido" do
      transition(notification, to: "investigating", reason: "x" * 501)
      expect(response.body).not_to include("xxxx")
    end
  end

  describe "acesso" do
    it "id inexistente ou não uuid → 404, em transição e descarte" do
      [ SecureRandom.uuid, "123", "not-a-uuid" ].each do |id|
        post "/surveillance/notifications/#{id}/transition", params: { to: "investigating", version: 1 }.to_json, headers: json_headers
        expect(response).to have_http_status(:not_found), id
        expect(json_body).to eq("error" => "not_found")
        post "/surveillance/notifications/#{id}/dismiss", params: { reason: "abc", version: 1 }.to_json, headers: json_headers
        expect(response).to have_http_status(:not_found), id
      end
    end

    it "analyst e profissional de saúde: 403 missing_role, nada gravado" do
      [ staff_with("analista-#{SecureRandom.hex(3)}@cidade.gov.br", "analyst"),
        staff_with("medico-#{SecureRandom.hex(3)}@cidade.gov.br", "health_professional") ].each do |user|
        sign_in_as(user)
        transition(notification, to: "investigating")
        expect(response).to have_http_status(:forbidden)
        expect(json_body).to eq("error" => "missing_role")
        dismiss(notification, reason: "abc")
        expect(response).to have_http_status(:forbidden)
      end
      expect(notification.reload).to have_attributes(status: "notified", version: 1)
    end

    it "dados na query são recusados: 422 invalid_request, nada lido da URL" do
      post "/surveillance/notifications/#{notification.id}/transition?to=investigating&version=1", headers: json_headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "invalid_request")
      expect(notification.reload.status).to eq("notified")
    end

    it "vigilância desligada → 403 feature_disabled" do
      Platform::Features.set!(city: city, key: "surveillance", enabled: false, maintainer: ledi_maintainer!)
      transition(notification, to: "investigating")
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "feature_disabled", "feature" => "surveillance")
    end
  end
end
