require "rails_helper"

# Módulo 32a (ADR 0050; contrato §8 e §14 Q7, Q8, Q15; plano, Valor fixado
# 6; preflight C-15, C-16, C-17): locais de chamada e TVs da sala de espera.
# Escrita só do municipal_admin com step-up; a lista de locais (com
# `location_required`) lê quem chama na unidade. Código de pareamento de 6
# dígitos (10 min, uso único) e token longo, os dois guardados só como
# SHA-256; o token sai só na resposta do pareamento e vale até a revogação.
# Interruptor desligado → 403 feature_disabled em tudo.
RSpec.describe "Locais de chamada e TVs da sala de espera", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { urgency_city!(waiting_room: true) }
  let(:upa) { upa! }
  let(:admin) { urgency_admin! }
  after { Current.reset }

  def displays(unit = upa) = get("/waiting_room/displays", params: { health_unit_id: unit.id })
  def create_display(**body) = json_post("/waiting_room/displays", { health_unit_id: upa.id, name: "TV da recepção", **body })
  def pairing_code(display) = json_post("/waiting_room/displays/#{display_id(display)}/pairing_code", {})
  def revoke(display) = json_post("/waiting_room/displays/#{display_id(display)}/revoke", {})
  def pair(code) = json_post("/waiting_room/pair", { code: code })
  def board(token) = get("/waiting_room/board", headers: { "X-Display-Token" => token })
  def locations(unit = upa) = get("/attendance/call_locations", params: { health_unit_id: unit.id })
  def display_id(display) = display.is_a?(Hash) ? display["id"] : display.id

  def anonymous!
    reset!
    host! test_city_host
  end

  def refusal(error, path) = { "error" => error, "path" => path, "problems" => [ { "path" => path, "error" => error } ] }

  describe "TVs" do
    it "só o municipal_admin com step-up escreve; a lista vem em { items } com paired e last_seen_at" do
      sign_in_as(upa_reception!)
      create_display
      expect(response).to have_http_status(:forbidden)
      displays
      expect(response).to have_http_status(:forbidden)
      sign_in_as(admin)
      create_display
      expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
      displays
      expect(json_body).to eq("items" => [])

      stepped_up!(admin)
      create_display(show_wait_times: false)
      expect(response).to have_http_status(:created)
      created = json_body
      expect(created.keys).to contain_exactly("id", "health_unit_id", "name", "active", "show_wait_times", "paired", "paired_at",
                                              "last_seen_at", "revoked", "revoked_at")
      expect(created).to include("health_unit_id" => upa.id, "name" => "TV da recepção", "active" => true, "show_wait_times" => false,
                                 "paired" => false, "paired_at" => nil, "revoked" => false)
      json_patch "/waiting_room/displays/#{created['id']}", name: "TV do corredor", show_wait_times: true
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("name" => "TV do corredor", "show_wait_times" => true)
      displays
      expect(json_body["items"].map { |d| d["id"] }).to eq([ created["id"] ])
      expect(WaitingRoomDisplay.find(created["id"]).as_json.keys).not_to include("token_digest", "pairing_code_digest")
    end

    it "recusas de campo: nome fora de 1..60, chave desconhecida, unidade inexistente ou CAPS; health_unit_id obrigatório na lista" do
      stepped_up!(admin)
      create_display(name: " ")
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "name") ])
      create_display(name: "x" * 61)
      expect(json_body["path"]).to eq("name")
      create_display(token_digest: "a" * 64)
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "token_digest") ])
      create_display(show_wait_times: "sim")
      expect(json_body["path"]).to eq("show_wait_times")
      json_post "/waiting_room/displays", { health_unit_id: SecureRandom.uuid, name: "TV" }
      expect(json_body["path"]).to eq("health_unit_id")
      caps = HealthUnit.create!(name: "CAPS TV", kind: "caps", caps_modality: "caps_ii")
      json_post "/waiting_room/displays", { health_unit_id: caps.id, name: "TV" }
      expect([ response.status, json_body["error"] ]).to eq([ 422, "caps_unit_not_allowed" ])
      get "/waiting_room/displays"
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "health_unit_id") ])
      expect(WaitingRoomDisplay.count).to eq(0)
    end

    it "pareia sem sessão; o código vale uma vez e expira em 10 min; o token só na resposta do pair, nunca no banco nem no log" do
      stepped_up!(admin)
      create_display
      display = json_body
      pairing_code(display)
      expect(response).to have_http_status(:created)
      expect(json_body.keys).to contain_exactly("code", "expires_at")
      code = json_body["code"]
      expect(code).to match(/\A\d{6}\z/)
      expect(Time.iso8601(json_body["expires_at"])).to be_within(5.seconds).of(10.minutes.from_now)
      expect(WaitingRoomDisplay.pluck(:pairing_code_digest)).to eq([ WaitingRoomDisplay.digest(code) ])

      anonymous!
      token = nil
      log = capture_log do
        expect { pair(code) }.to change { DomainEvent.where(name: "waiting_room.display_paired").count }.by(1)
        expect(response).to have_http_status(:created)
        expect(json_body.keys).to eq([ "display_token" ])
        token = json_body["display_token"]
        board(token)
        expect(response).to have_http_status(:ok)
      end
      expect(token.length).to eq(64)
      expect(log).not_to include(token)
      expect(DomainEvent.where(name: "waiting_room.display_paired").last.payload).to eq("display_id" => display["id"])
      row = WaitingRoomDisplay.find(display["id"])
      expect(row.token_digest).to eq(WaitingRoomDisplay.digest(token))
      expect(WaitingRoomDisplay.pluck(:token_digest)).not_to include(token)
      expect(row.attributes.values.map(&:to_s).join).not_to include(token)
      expect([ row.pairing_code_digest, row.pairing_expires_at, row.revoked_at ]).to eq([ nil, nil, nil ])
      expect(row.paired_at).to be_present

      pair(code)
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_pairing_code" } ])
      pair("12345")
      expect(json_body["error"]).to eq("invalid_pairing_code")

      stepped_up!(admin)
      displays
      expect(response.body).not_to include(token)
      expect(json_body["items"].first).to include("paired" => true, "revoked" => false)
      expect(json_body["items"].first["last_seen_at"]).to be_present
      pairing_code(display)
      late = json_body["code"]
      travel 11.minutes do
        anonymous!
        pair(late)
        expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_pairing_code" } ])
        board(token)
        expect(response).to have_http_status(:ok)
      end
    end

    it "parear de novo uma TV com token vivo revoga o antigo antes (display_revoked e depois display_paired)" do
      display, old_token = paired_display!(upa)
      code = WaitingRoom::IssuePairingCode.call(display: display, by: admin).payload.fetch(:code)
      anonymous!
      allow(DomainEvents).to receive(:publish).and_call_original
      pair(code)
      new_token = json_body["display_token"]
      expect(DomainEvents).to have_received(:publish).with("waiting_room.display_revoked", display_id: display.id).ordered
      expect(DomainEvents).to have_received(:publish).with("waiting_room.display_paired", display_id: display.id).ordered
      board(old_token)
      expect([ response.status, json_body ]).to eq([ 401, { "error" => "display_revoked" } ])
      board(new_token)
      expect(response).to have_http_status(:ok)
      row = WaitingRoomDisplay.find(display.id)
      expect(row.revoked_token_digest).to eq(WaitingRoomDisplay.digest(old_token))
      expect(row.as_json.keys).not_to include("revoked_token_digest")
      expect(row.inspect).not_to include(row.revoked_token_digest)
    end

    it "revogar e parear de novo: o token mais antigo responde display_revoked e o novo funciona, sem novo display_revoked" do
      display, oldest = paired_display!(upa)
      WaitingRoom::Revoke.call(display: display, by: admin)
      code = WaitingRoom::IssuePairingCode.call(display: display, by: admin).payload.fetch(:code)
      anonymous!
      expect { pair(code) }.not_to change { DomainEvent.where(name: "waiting_room.display_revoked").count }
      newest = json_body["display_token"]
      board(oldest)
      expect([ response.status, json_body ]).to eq([ 401, { "error" => "display_revoked" } ])
      board(newest)
      expect(response).to have_http_status(:ok)
      expect(display.reload).to have_attributes(paired?: true, revoked?: false)
    end

    # Só o último digest anterior fica (revoked_token_digest): um token mais
    # antigo que ele já não casa com nada e responde invalid_token.
    it "dois re-pareamentos seguidos: o penúltimo responde display_revoked, o mais antigo invalid_token" do
      display, first = paired_display!(upa)
      tokens = 2.times.map do
        code = WaitingRoom::IssuePairingCode.call(display: display, by: admin).payload.fetch(:code)
        WaitingRoom::Pair.call(code: code).payload.fetch(:display_token)
      end
      second, third = tokens
      anonymous!
      board(first)
      expect([ response.status, json_body ]).to eq([ 401, { "error" => "invalid_token" } ])
      board(second)
      expect([ response.status, json_body ]).to eq([ 401, { "error" => "display_revoked" } ])
      board(third)
      expect(response).to have_http_status(:ok)
    end

    it "revoga pela rota e por active: false; a TV revogada responde 401 display_revoked" do
      display, token = paired_display!(upa)
      sign_in_as(admin)
      revoke(display)
      expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
      stepped_up!(admin)
      expect { revoke(display) }.to change { DomainEvent.where(name: "waiting_room.display_revoked").count }.by(1)
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => display.id, "paired" => false, "revoked" => true)
      expect(DomainEvent.where(name: "waiting_room.display_revoked").last.payload).to eq("display_id" => display.id)
      board(token)
      expect([ response.status, json_body ]).to eq([ 401, { "error" => "display_revoked" } ])

      other, other_token = paired_display!(upa)
      stepped_up!(admin)
      expect { json_patch "/waiting_room/displays/#{other.id}", active: false }
        .to change { DomainEvent.where(name: "waiting_room.display_revoked").count }.by(1)
      expect(json_body).to include("active" => false, "revoked" => true, "paired" => false)
      board(other_token)
      expect(json_body["error"]).to eq("display_revoked")
      pairing_code(other)
      expect([ response.status, json_body["error"] ]).to eq([ 422, "display_inactive" ])
      json_post "/waiting_room/displays/#{SecureRandom.uuid}/revoke", {}
      expect(response).to have_http_status(:not_found)
    end

    it "código vivo nunca casa duas TVs: o sorteio repete no RecordNotUnique; o expirado com o mesmo digest é zerado" do
      first, second = 2.times.map do |i|
        WaitingRoom::SaveDisplay.call(attrs: { "health_unit_id" => upa.id, "name" => "TV #{i}" }, by: admin).payload.fetch(:display)
      end
      issue = ->(display) { WaitingRoom::IssuePairingCode.call(display: display, by: admin).payload.fetch(:code) }
      allow(SecureRandom).to receive(:random_number).and_call_original
      allow(SecureRandom).to receive(:random_number).with(10**6).and_return(123_456, 123_456, 654_321)
      expect(issue.call(first)).to eq("123456")
      expect(issue.call(second)).to eq("654321")
      travel 11.minutes do
        allow(SecureRandom).to receive(:random_number).with(10**6).and_return(123_456)
        expect(issue.call(second)).to eq("123456")
        expect(first.reload.pairing_code_digest).to be_nil
        expect(WaitingRoom::Pair.call(code: "123456").payload.fetch(:display).id).to eq(second.id)
      end
    end

    it "11ª tentativa de pareamento no minuto pelo mesmo IP → 429" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      10.times { pair("000000") }
      expect(json_body["error"]).to eq("invalid_pairing_code")
      pair("000000")
      expect([ response.status, json_body ]).to eq([ 429, { "error" => "too_many_requests" } ])
    end

    it "o pareamento é JSON" do
      post "/waiting_room/pair", params: { code: "123456" }
      expect([ response.status, json_body ]).to eq([ 415, { "error" => "json_required" } ])
    end
  end

  describe "locais de chamada" do
    it "lista com location_required para quem chama na unidade; escrita só do admin com step-up" do
      call_location!(upa, name: "Consultório 1")
      sign_in_as(upa_reception!)
      locations
      expect(response).to have_http_status(:ok)
      expect(json_body["location_required"]).to be(false)
      expect(json_body["items"].first.keys).to contain_exactly("id", "health_unit_id", "name", "active")
      expect(json_body["items"].map { |l| l["name"] }).to eq([ "Consultório 1" ])
      paired_display_row!(upa)
      sign_in_as(upa_doctor!(upa))
      locations
      expect(json_body["location_required"]).to be(true)
      sign_in_as(upa_doctor!(create_unit("UBS Outra")))
      locations
      expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_link" ])
      json_post "/attendance/call_locations", { health_unit_id: upa.id, name: "Consultório 2" }
      expect(response).to have_http_status(:forbidden)

      sign_in_as(admin)
      json_post "/attendance/call_locations", { health_unit_id: upa.id, name: "Consultório 2" }
      expect(json_body).to eq("error" => "mfa_required")
      stepped_up!(admin)
      json_post "/attendance/call_locations", { health_unit_id: upa.id, name: "Consultório 2" }
      expect(response).to have_http_status(:created)
      created = json_body
      expect(created).to include("health_unit_id" => upa.id, "name" => "Consultório 2", "active" => true)
      json_patch "/attendance/call_locations/#{created['id']}", active: false
      expect(json_body).to include("active" => false)
      locations
      expect(json_body["items"].map { |l| [ l["name"], l["active"] ] }).to eq([ [ "Consultório 1", true ], [ "Consultório 2", false ] ])
    end

    it "nome fora de 1..40, nome repetido (sem caixa) → 409, unidade CAPS, health_unit_id obrigatório" do
      stepped_up!(admin)
      json_post "/attendance/call_locations", { health_unit_id: upa.id, name: "x" * 41 }
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "name") ])
      json_post "/attendance/call_locations", { health_unit_id: upa.id, name: "Sala A" }
      json_post "/attendance/call_locations", { health_unit_id: upa.id, name: "sala a" }
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "call_location_name_taken" } ])
      other = json_post("/attendance/call_locations", { health_unit_id: upa.id, name: "Sala B" }) && json_body
      json_patch "/attendance/call_locations/#{other['id']}", name: "SALA A"
      expect(response).to have_http_status(:conflict)
      json_patch "/attendance/call_locations/#{other['id']}", health_unit_id: create_unit("UBS X").id
      expect(json_body["path"]).to eq("health_unit_id")
      caps = HealthUnit.create!(name: "CAPS Local", kind: "caps", caps_modality: "caps_ii")
      json_post "/attendance/call_locations", { health_unit_id: caps.id, name: "Sala" }
      expect(json_body["error"]).to eq("caps_unit_not_allowed")
      get "/attendance/call_locations"
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "health_unit_id") ])
      json_patch "/attendance/call_locations/#{SecureRandom.uuid}", name: "Y"
      expect(response).to have_http_status(:not_found)
    end
  end

  it "interruptor desligado → 403 feature_disabled no admin, nos locais, no pair e no board" do
    display, token = paired_display!(upa)
    Platform::Features.set!(city: city, key: WaitingRoom::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    disabled = { "error" => "feature_disabled", "feature" => "waiting_room_display" }
    stepped_up!(admin)
    displays
    expect([ response.status, json_body ]).to eq([ 403, disabled ])
    pairing_code(display)
    expect([ response.status, json_body ]).to eq([ 403, disabled ])
    locations
    expect([ response.status, json_body ]).to eq([ 403, disabled ])
    anonymous!
    pair("123456")
    expect([ response.status, json_body ]).to eq([ 403, disabled ])
    board(token)
    expect([ response.status, json_body ]).to eq([ 403, disabled ])
  end
end
