require "rails_helper"

# Módulo 25, Task 11 (contrato §5, §14, §15 K5–K7, K12(c)): a fila da
# vigilância (lista com cursor), o detalhe, a ficha (PATCH) e os contadores.
RSpec.describe "Vigilância — fila, detalhe, ficha e contadores", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { surveillance_city! }
  let(:officer) { surveillance_officer! }
  let(:json_headers) { { "Content-Type" => "application/json" } }

  before { sign_in_as(officer) }

  # Ordenado pelo instante: `.last` sem ordem seria por uuid (flaky).
  def viewed = DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at)

  def patch_form(notification, form:, version: notification.version, **extra)
    patch "/surveillance/notifications/#{notification.id}", params: { form: form, version: version }.merge(extra).to_json,
                                                            headers: json_headers
  end

  def ids = json_body["notifications"].map { |n| n["id"] }

  def settle!(notification, status, **attrs)
    closed = { classification: "confirmed", closed_at: Time.current }
    extra = { "closed" => closed, "entered" => closed.merge(official_number: "SINAN-1", entered_at: Time.current),
              "dismissed" => { dismissed_at: Time.current } }.fetch(status, {})
    notification.update_columns({ status: status }.merge(extra).merge(attrs))
    notification
  end

  it "imediata vencida no topo; lista sem form com uma trilha; detalhe com form e trilha por pessoa; count sem trilha" do
    weekly = notification!(patient: surveillance_patient!(61), disease_code: "dengue")
    late = travel_to(2.days.ago) { notification!(patient: surveillance_patient!(62), disease_code: "sarampo") }
    get "/surveillance/notifications"
    expect(json_body["notifications"].map { |n| n["id"] }).to eq([ late.id, weekly.id ])
    expect(json_body["notifications"].first).to include("overdue" => true).and(satisfy { |n| !n.key?("form") })
    expect(json_body["next_before"]).to be_nil
    expect(viewed.last.payload).to include("access" => "surveillance", "notification_ids" => [ late.id, weekly.id ],
                                           "user_id" => officer.id)
    expect(viewed.last.payload.keys).to contain_exactly("access", "notification_ids", "user_id")
    before_count = DomainEvent.count
    get "/surveillance/notifications/count"
    expect(json_body).to eq("possible" => 0, "notified" => 2, "investigating" => 0, "overdue" => 1, "immediate_open" => 1,
                            "without_official_number" => 0)
    expect(DomainEvent.count).to eq(before_count)
    get "/surveillance/notifications/#{weekly.id}"
    expect(json_body.keys).to include("form", "events", "version")
    expect(viewed.last.payload).to include("person_ref" => "patient:#{weekly.patient_id}", "access" => "surveillance")
    patch_form(weekly, form: { pregnancy: "5" }, version: 1)
    expect(response).to have_http_status(:ok)
    expect(json_body["version"]).to eq(2)
    patch_form(weekly, form: {}, version: 1)
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "stale_version")
  end

  it "a ordem: vencidas, depois imediatas, depois por prazo e id; vencida sem prazo vencido (investigating) não conta" do
    now = Time.current
    plain = notification!(patient: surveillance_patient!(1), disease_code: "dengue", suspected_at: now - 1.day)
    immediate = notification!(patient: surveillance_patient!(2), disease_code: "sarampo", suspected_at: now)
    overdue_weekly = notification!(patient: surveillance_patient!(3), disease_code: "dengue", suspected_at: now - 9.days)
    investigating = settle!(notification!(patient: surveillance_patient!(4), disease_code: "sarampo", suspected_at: now - 5.days), "investigating")
    get "/surveillance/notifications"
    # vencida primeiro; depois imediata (investigando, prazo de há 4 dias, não está vencida); depois a que vence antes.
    expect(ids).to eq([ overdue_weekly.id, investigating.id, immediate.id, plain.id ])
    expect(json_body["notifications"].map { |n| n["overdue"] }).to eq([ true, false, false, false ])
  end

  describe "paginação" do
    it "next_before estável entre duas páginas: sem repetir nem pular, também com prazos iguais" do
      now = Time.current.change(usec: 123_456)
      same = now - 2.hours
      list = [
        notification!(patient: surveillance_patient!(10), disease_code: "sarampo", suspected_at: now - 3.days), # vencida, imediata
        notification!(patient: surveillance_patient!(11), disease_code: "dengue", suspected_at: now - 9.days), # vencida, semanal
        notification!(patient: surveillance_patient!(12), disease_code: "sarampo", suspected_at: same),
        notification!(patient: surveillance_patient!(13), disease_code: "sarampo", suspected_at: same),
        notification!(patient: surveillance_patient!(14), disease_code: "dengue", suspected_at: same),
        notification!(patient: surveillance_patient!(15), disease_code: "dengue", suspected_at: same)
      ]
      get "/surveillance/notifications"
      full = ids
      expect(full.size).to eq(6)
      expect(full.first(2)).to eq([ list[0].id, list[1].id ])
      # empate (imediatas com o mesmo prazo): por id.
      expect(full[2..3]).to eq([ list[2].id, list[3].id ].sort)
      expect(full[4..5]).to eq([ list[4].id, list[5].id ].sort)

      collected = []
      cursor = nil
      pages = 0
      loop do
        get "/surveillance/notifications", params: { limit: 2, before: cursor }.compact
        expect(response).to have_http_status(:ok)
        collected.concat(ids)
        pages += 1
        cursor = json_body["next_before"]
        break unless cursor

        expect(cursor).to match(/\A[A-Za-z0-9_-]+=*\z/)
      end
      expect(pages).to eq(3)
      expect(collected).to eq(full)
      expect(viewed.where("payload->>'notification_ids' IS NOT NULL").count).to eq(4)
    end

    it "página única cheia sem mais linhas não devolve cursor; página vazia não grava trilha" do
      notification!(patient: surveillance_patient!(20))
      notification!(patient: surveillance_patient!(21))
      get "/surveillance/notifications", params: { limit: 2 }
      expect(json_body["next_before"]).to be_nil
      get "/surveillance/notifications", params: { limit: 1 }
      expect(json_body["next_before"]).to be_a(String)
      trail = viewed.count
      get "/surveillance/notifications", params: { status: "closed" }
      expect(json_body).to eq("notifications" => [], "next_before" => nil)
      expect(viewed.count).to eq(trail)
    end

    it "limit: padrão 50, máximo 100; inválido → 422 invalid_limit" do
      [ "0", "101", "abc", "-1", "1.5" ].each do |limit|
        get "/surveillance/notifications", params: { limit: limit }
        expect(response).to have_http_status(:unprocessable_entity), limit
        expect(json_body).to eq("error" => "invalid_limit")
      end
      get "/surveillance/notifications", params: { limit: 100 }
      expect(response).to have_http_status(:ok)
    end

    it "cursor inválido → 422 invalid_cursor" do
      notification!(patient: surveillance_patient!(22))
      forged = Base64.urlsafe_encode64([ "x", true, "nope", "1" ].to_json)
      [ "###", "abc", Base64.urlsafe_encode64("[]"), Base64.urlsafe_encode64("{}"), forged, "a" * 5000 ].each do |cursor|
        get "/surveillance/notifications", params: { before: cursor }
        expect(response).to have_http_status(:unprocessable_entity), cursor.first(20)
        expect(json_body).to eq("error" => "invalid_cursor")
      end
    end
  end

  describe "filtros" do
    let!(:dengue) { notification!(patient: surveillance_patient!(30), disease_code: "dengue") }
    let!(:measles) { notification!(patient: surveillance_patient!(31), disease_code: "sarampo") }
    let!(:possible) { notification!(patient: surveillance_patient!(32), disease_code: "dengue", origin: "safety_net") }
    let!(:investigating) { settle!(notification!(patient: surveillance_patient!(33), disease_code: "dengue"), "investigating") }
    let!(:closed) { settle!(notification!(patient: surveillance_patient!(34), disease_code: "dengue"), "closed") }
    let!(:entered) { settle!(notification!(patient: surveillance_patient!(35), disease_code: "dengue"), "entered") }
    let!(:dismissed) { settle!(notification!(patient: surveillance_patient!(36), disease_code: "dengue", origin: "safety_net"), "dismissed") }

    def listed(**query)
      get "/surveillance/notifications", params: query
      expect(response).to have_http_status(:ok), json_body.inspect
      ids
    end

    it "padrão: tudo menos entered e dismissed" do
      expect(listed).to contain_exactly(dengue.id, measles.id, possible.id, investigating.id, closed.id)
    end

    it "status explícito (inclusive entered e dismissed)" do
      expect(listed(status: "possible")).to eq([ possible.id ])
      expect(listed(status: "entered")).to eq([ entered.id ])
      expect(listed(status: "dismissed")).to eq([ dismissed.id ])
      expect(listed(status: "investigating")).to eq([ investigating.id ])
    end

    it "disease, unit_id e valores vazios (ausentes)" do
      expect(listed(disease: "sarampo")).to eq([ measles.id ])
      expect(listed(disease: "dengue")).to contain_exactly(dengue.id, possible.id, investigating.id, closed.id)
      expect(listed(unit_id: dengue.health_unit_id)).to eq([ dengue.id ])
      expect(listed(status: "", disease: "", unit_id: "", overdue: "", without_official_number: "")).to contain_exactly(
        dengue.id, measles.id, possible.id, investigating.id, closed.id
      )
    end

    it "overdue=true: só vencidas (possible/notified com prazo passado)" do
      dengue.update_columns(due_at: 1.hour.ago)
      investigating.update_columns(due_at: 1.hour.ago)
      closed.update_columns(due_at: 1.hour.ago)
      expect(listed(overdue: "true")).to eq([ dengue.id ])
    end

    it "without_official_number=true = status closed (V12)" do
      expect(listed(without_official_number: "true")).to eq([ closed.id ])
      get "/surveillance/notifications", params: { without_official_number: "true", status: "notified" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "invalid_filter", "field" => "without_official_number")
    end

    it "valor inválido → 422 invalid_filter com o field; chave desconhecida na query → 422 invalid_request" do
      { status: "foo", unit_id: "not-a-uuid", disease: "Dengue!", overdue: "yes", without_official_number: "1" }.each do |field, value|
        get "/surveillance/notifications", params: { field => value }
        expect(response).to have_http_status(:unprocessable_entity), field.to_s
        expect(json_body).to eq("error" => "invalid_filter", "field" => field.to_s)
      end
      get "/surveillance/notifications", params: { status: [ "possible" ] }
      expect(json_body).to eq("error" => "invalid_filter", "field" => "status")
      get "/surveillance/notifications", params: { cpf: "123" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "invalid_request")
    end

    it "disease com a forma de um código (plataforma ou local) é aceito, mesmo sem notificação" do
      expect(listed(disease: "local_algo")).to eq([])
      expect(listed(disease: "doenca_nova")).to eq([])
    end

    it "count: por situação, vencidas, imediatas abertas e sem número" do
      dengue.update_columns(due_at: 1.hour.ago)
      get "/surveillance/notifications/count"
      expect(json_body).to eq("possible" => 1, "notified" => 2, "investigating" => 1, "overdue" => 1, "immediate_open" => 1,
                              "without_official_number" => 1)
    end
  end

  describe "detalhe" do
    it "forma completa com form pré-preenchido e andamento; trilha uma por pessoa" do
      patient = surveillance_patient!(40)
      notification = notification!(patient: patient)
      viewed_before = viewed.count
      get "/surveillance/notifications/#{notification.id}"
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => notification.id, "version" => 1, "form" => notification.form)
      expect(json_body["form"]).to include("race_color" => "9")
      expect(json_body["events"].map { |e| e["status"] }).to eq([ "notified" ])
      expect(viewed.count).to eq(viewed_before + 1)
      expect(viewed.last.payload).to eq("patient_id" => patient.id, "user_id" => officer.id, "access" => "surveillance",
                                        "reason_code" => nil, "person_ref" => "patient:#{patient.id}")
    end

    it "id inexistente, de outra forma ou não uuid → 404, sem trilha" do
      trail = viewed.count
      [ SecureRandom.uuid, "123", "not-a-uuid" ].each do |id|
        get "/surveillance/notifications/#{id}"
        expect(response).to have_http_status(:not_found), id
        expect(json_body).to eq("error" => "not_found")
        patch "/surveillance/notifications/#{id}", params: { form: {}, version: 1 }.to_json, headers: json_headers
        expect(response).to have_http_status(:not_found), id
      end
      expect(viewed.count).to eq(trail)
    end
  end

  describe "PATCH (a ficha inteira)" do
    let(:notification) { notification!(patient: surveillance_patient!(50)) }

    it "grava a ficha normalizada inteira, sobe a versão, publica só o notification_id e grava a trilha da pessoa" do
      before = DomainEvent.where(name: "disease_notification.updated").count
      trail = viewed.count
      patch_form(notification, form: { pregnancy: "6", phone: "(41) 99999-0000", residence_street: "  Rua   X " })
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("version" => 2)
      expect(json_body["form"]).to eq("pregnancy" => "6", "phone" => "41999990000", "residence_street" => "Rua X")
      expect(notification.reload.form).to eq("pregnancy" => "6", "phone" => "41999990000", "residence_street" => "Rua X")
      expect(notification.version).to eq(2)
      events = DomainEvent.where(name: "disease_notification.updated").order(:occurred_at)
      expect(events.count).to eq(before + 1)
      expect(events.last.payload).to eq("notification_id" => notification.id)
      expect(viewed.count).to eq(trail + 1)
      expect(viewed.last.payload).to include("person_ref" => "patient:#{notification.patient_id}")
    end

    it "grava inteiro: o que não veio sai da ficha (inclusive o pré-preenchido)" do
      expect(notification.form).to include("race_color" => "9")
      patch_form(notification, form: { schooling: "6" })
      expect(notification.reload.form).to eq("schooling" => "6")
    end

    it "ficha inválida → 422 invalid_form com path e nada gravado (sem eco do valor)" do
      patch_form(notification, form: { cpf: "123.456.789-09" })
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "invalid_form", "path" => "form.cpf")
      patch_form(notification, form: { residence_street: "x" * 61 })
      expect(json_body).to eq("error" => "invalid_form", "path" => "form.residence_street")
      patch_form(notification, form: "texto")
      expect(json_body).to eq("error" => "invalid_form", "path" => "form")
      expect(notification.reload.version).to eq(1)
      expect(DomainEvent.where(name: "disease_notification.updated").count).to eq(0)
    end

    it "a ficha pré-preenchida, intocada, é aceita de volta" do
      patch_form(notification, form: notification.form)
      expect(response).to have_http_status(:ok)
      expect(json_body["form"]).to eq(notification.form)
    end

    it "version ausente ou não inteira → 422 invalid_request; diferente → 409 stale_version" do
      [ nil, "1", 1.5, true ].each do |version|
        patch "/surveillance/notifications/#{notification.id}", params: { form: {}, version: version }.to_json, headers: json_headers
        expect(response).to have_http_status(:unprocessable_entity), version.inspect
        expect(json_body).to eq("error" => "invalid_request")
      end
      patch_form(notification, form: {}, version: 7)
      expect(response).to have_http_status(:conflict)
      expect(json_body).to eq("error" => "stale_version")
      expect(notification.reload.version).to eq(1)
    end

    it "entered e dismissed estão travadas: 422 invalid_transition" do
      entered = settle!(notification!(patient: surveillance_patient!(51)), "entered")
      dismissed = settle!(notification!(patient: surveillance_patient!(52), origin: "safety_net"), "dismissed")
      [ entered, dismissed ].each do |locked|
        patch_form(locked, form: { pregnancy: "5" })
        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_body).to eq("error" => "invalid_transition")
        expect(locked.reload.version).to eq(1)
      end
    end

    it "closed ainda aceita a ficha (até entrar no Sinan)" do
      closed = settle!(notification!(patient: surveillance_patient!(53)), "closed")
      patch_form(closed, form: { pregnancy: "5" })
      expect(response).to have_http_status(:ok)
    end

    it "query na URL → 422 invalid_request" do
      patch "/surveillance/notifications/#{notification.id}?form=x", params: { form: {}, version: 1 }.to_json, headers: json_headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "invalid_request")
    end

    it "a ficha e o filtro de doença nunca vão ao log do Rails (filter_parameters)" do
      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
      filtered = filter.filter("form" => { "residence_street" => "Rua Segredo" }, "disease" => "sarampo", "status" => "notified")
      expect(filtered).to eq("form" => "[FILTERED]", "disease" => "[FILTERED]", "status" => "notified")
    end
  end

  describe "papéis" do
    let!(:notification) { notification!(patient: surveillance_patient!(60)) }

    it "analyst e profissional de saúde: 403 missing_role em todas as rotas, sem trilha" do
      [ staff_with("analista-#{SecureRandom.hex(3)}@cidade.gov.br", "analyst"),
        staff_with("medico-#{SecureRandom.hex(3)}@cidade.gov.br", "health_professional") ].each do |user|
        sign_in_as(user)
        trail = viewed.count
        get "/surveillance/notifications"
        expect(response).to have_http_status(:forbidden)
        expect(json_body).to eq("error" => "missing_role")
        get "/surveillance/notifications/count"
        expect(response).to have_http_status(:forbidden)
        get "/surveillance/notifications/#{notification.id}"
        expect(response).to have_http_status(:forbidden)
        patch_form(notification, form: {})
        expect(response).to have_http_status(:forbidden)
        expect(viewed.count).to eq(trail)
      end
      expect(notification.reload.version).to eq(1)
    end

    it "vigilância desligada → 403 feature_disabled" do
      Platform::Features.set!(city: city, key: "surveillance", enabled: false, maintainer: ledi_maintainer!)
      get "/surveillance/notifications"
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "feature_disabled", "feature" => "surveillance")
    end
  end
end
