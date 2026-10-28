require "rails_helper"

# Módulo 26a, Task 7 (ADR 0044; contrato §4, §13 G2, G6): a fila do regulador
# (lista, detalhe e contadores). Só o care_regulator; escopo: a cidade toda.
RSpec.describe "Regulação — fila do regulador", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { regulation_city! }
  let(:regulator) { care_regulator! }
  let(:unit_a) { create_unit("UBS Fila A") }
  let(:unit_b) { create_unit("UBS Fila B") }
  # O dia é fixo (fuso da cidade): a rodada não depende de cruzar a meia-noite.
  let(:today) { Date.new(2026, 10, 28) }

  before { travel_to Time.zone.local(2026, 10, 28, 10, 0) }

  # Ordenado pelo instante: `.last` sem ordem seria por uuid (flaky).
  def viewed = DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at)

  def aged!(days, color, unit: unit_a, **over)
    # travel_to sem bloco: o bloco aninhado devolveria o relógio real.
    travel_to((today - days).in_time_zone.change(hour: 12))
    regulation_request!(unit: unit, suggested_color: color, **over)
  ensure
    travel_to Time.zone.local(2026, 10, 28, 10, 0)
  end

  def ids = json_body["requests"].map { |r| r["id"] }

  describe "regulador" do
    before { sign_in_as(regulator) }

    it "sem vínculo nenhum lista a cidade toda (200), sem events, com uma trilha da requisição" do
      a = aged!(1, "red", unit: unit_a)
      b = aged!(2, "yellow", unit: unit_b)
      get "/regulation/requests"
      expect(response).to have_http_status(:ok)
      expect(ids).to eq([ a.id, b.id ])
      expect(json_body["next_before"]).to be_nil
      expect(json_body["requests"].first.keys).not_to include("events")
      expect(json_body["requests"].first).to include("status" => "pending", "overdue" => false, "version" => 2,
                                                       "target" => { "code" => "225120", "name" => "Cardiologia" })
      trail = viewed.last.payload
      expect(trail).to eq("access" => "regulation", "regulation_request_ids" => [ a.id, b.id ], "user_id" => regulator.id)
      expect(trail.keys).not_to include("patient_id")
    end

    it "lista vazia não grava trilha" do
      expect { get "/regulation/requests" }.not_to(change { viewed.count })
      expect(json_body).to eq("requests" => [], "next_before" => nil)
    end

    it "vencido de cor menos grave vem ANTES do vermelho no prazo (G2)" do
      red_new = aged!(1, "red")
      green_late = aged!(100, "green")
      get "/regulation/requests", params: { status: "pending" }
      expect(ids).to eq([ green_late.id, red_new.id ])
      expect(json_body["requests"].map { |r| r["overdue"] }).to eq([ true, false ])
    end

    it "pagina com limit e next_before; a página 2 segue sem repetir" do
      made = [ aged!(100, "green"), aged!(200, "blue"), aged!(1, "red") ]
      get "/regulation/requests", params: { limit: 2 }
      expect(ids).to eq(made.first(2).map(&:id))
      cursor = json_body["next_before"]
      expect(cursor).to be_a(String)
      get "/regulation/requests", params: { limit: 2, before: cursor }
      expect(ids).to eq([ made.last.id ])
      expect(json_body["next_before"]).to be_nil
    end

    it "filtros: status, type, target_code, color, overdue" do
      late = aged!(100, "green")
      fresh = aged!(1, "red", target_code: "225250")
      get "/regulation/requests", params: { overdue: "true" }
      expect(ids).to eq([ late.id ])
      get "/regulation/requests", params: { overdue: "false", target_code: "225250", type: "specialty", color: "red" }
      expect(ids).to eq([ fresh.id ])
      fresh.update_columns(status: "returned")
      get "/regulation/requests", params: { status: "returned" }
      expect(ids).to eq([ fresh.id ])
    end

    it "a página 2 pedida depois da meia-noite: o overdue do item segue o today da requisição, não o dia do cursor" do
      green_late = aged!(100, "green")
      blue_late = aged!(200, "blue")
      edges = [ aged!(7, "red"), aged!(7, "red") ].sort_by(&:id) # due_on = hoje: no prazo hoje, vencido amanhã
      get "/regulation/requests", params: { limit: 3 }
      expect(ids).to eq([ green_late.id, blue_late.id, edges.first.id ])
      expect(json_body["requests"].map { |r| r["overdue"] }).to eq([ true, true, false ])
      cursor = json_body["next_before"]

      travel_to Time.zone.local(2026, 10, 29, 0, 1)
      get "/regulation/requests", params: { limit: 3, before: cursor }
      expect(response).to have_http_status(:ok)
      expect(ids).to eq([ edges.last.id ]) # o dia do cursor decidiu a posição: nada pulado
      expect(json_body["requests"].first["overdue"]).to be(true) # o item mostra o hoje da requisição
    end

    it "filtro inválido → 422 invalid_request com path" do
      { status: "draft", type: "exam", color: "purple", overdue: "yes" }.each do |field, value|
        get "/regulation/requests", params: { field => value }
        expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => field.to_s } ])
      end
      get "/regulation/requests", params: { limit: "10", sort: "x", other: "y" }
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "sort" } ])
    end

    it "limit 101, 0 ou texto → 422 invalid_limit; 100 vale" do
      [ "101", "0", "abc", "-1" ].each do |limit|
        get "/regulation/requests", params: { limit: limit }
        expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_limit" } ])
      end
      get "/regulation/requests", params: { limit: "100" }
      expect(response).to have_http_status(:ok)
    end

    it "before adulterado ou de 3 elementos (formato antigo) → 422 invalid_cursor" do
      aged!(1, "red")
      get "/regulation/requests", params: { before: "adulterado" }
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_cursor" } ])
      old = Base64.urlsafe_encode64(JSON.generate([ 0, Time.current.utc.iso8601(6), SecureRandom.uuid ]), padding: false)
      get "/regulation/requests", params: { before: old }
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_cursor" } ])
    end

    it "o detalhe traz events (by nulo sem autor) e grava uma trilha por pessoa" do
      request = aged!(3, "yellow")
      get "/regulation/requests/#{request.id}"
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => request.id, "version" => 2)
      expect(json_body["events"].map { |e| e["status"] }).to eq([ "pending" ])
      expect(json_body["events"].first.keys).to eq(%w[status at by reason])
      expect(viewed.last.payload).to eq("patient_id" => request.patient_id, "user_id" => regulator.id, "access" => "regulation",
                                        "reason_code" => nil, "person_ref" => "patient:#{request.patient_id}")
    end

    it "id de rascunho, inexistente ou malformado → 404 e nenhuma trilha" do
      draft = aged!(0, "red", status: "draft")
      before = viewed.count
      [ draft.id, SecureRandom.uuid, "nao-e-uuid" ].each do |id|
        get "/regulation/requests/#{id}"
        expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
      end
      expect(viewed.count).to eq(before)
    end

    it "count devolve os cinco contadores e não grava trilha" do
      aged!(100, "green")
      aged!(1, "red")
      aged!(100, "green", status: "external")
      before = DomainEvent.count
      get "/regulation/requests/count"
      expect(response).to have_http_status(:ok)
      expect(json_body).to eq("pending" => 2, "overdue" => 2, "returned" => 0, "authorized" => 0, "external" => 1)
      expect(DomainEvent.count).to eq(before)
    end

    it "o log da requisição não contém a justificativa, o CID-10 nem o nome" do
      request = aged!(1, "red", justification: "Justificativa-sigilosa-da-fila")
      log = StringIO.new
      previous = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(log)
      begin
        get "/regulation/requests"
        get "/regulation/requests/#{request.id}"
      ensure
        Rails.logger = previous
      end
      expect(log.string).not_to include("Justificativa-sigilosa-da-fila")
    end
  end

  describe "outros papéis e interruptor" do
    it "health_professional → 403 missing_role na lista, no detalhe e no count" do
      request = aged!(1, "red")
      sign_in_as(doctor!(unit_a))
      [ "/regulation/requests", "/regulation/requests/#{request.id}", "/regulation/requests/count" ].each do |path|
        get path
        expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      end
    end

    it "municipal_admin também não lê a fila (G6)" do
      sign_in_as(regulation_admin!)
      get "/regulation/requests"
      expect(response).to have_http_status(:forbidden)
    end

    it "sem sessão → 401" do
      get "/regulation/requests"
      expect(response).to have_http_status(:unauthorized)
    end

    it "interruptor desligado → 403 feature_disabled" do
      Platform::Features.set!(city: city, key: "care_regulation", enabled: false, maintainer: ledi_maintainer!)
      sign_in_as(care_regulator!)
      get "/regulation/requests"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "care_regulation" } ])
    end
  end
end
