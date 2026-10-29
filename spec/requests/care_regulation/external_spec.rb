require "rails_helper"

# Módulo 26a, Task 11 (ADR 0044; contrato §7, §8, §13 G1, G7, G12 #7; overlay):
# prestador externo e convivência com o sistema do estado. Marcar como
# regulado pelo estado (external), agendar/remarcar (schedule) e o desfecho
# (outcome); só o care_regulator, corpo JSON, 200 com o <regulation_request>
# completo.
RSpec.describe "Regulação — prestador externo e estado", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.local(2026, 10, 28, 10, 0) }

  before { travel_to now }

  let!(:city) { regulation_city! }
  let(:regulator) { care_regulator! }
  let(:offer) { offer!(provider: external_provider!) }
  let(:place) { "Hospital Regional — ambulatório 3" }
  # G15.2: o desfecho só vale a partir do dia do agendamento; o horário padrão é
  # do próprio dia do `now`, para os specs de desfecho não viajarem no tempo.
  let(:at) { now.change(hour: 14).iso8601 }

  before do
    tick_regulation_events!
    sign_in_as(regulator)
  end

  def viewed = DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at)
  def published(name) = DomainEvent.where(name: "regulation_request.#{name}")
  def mark!(request, number: "123456789", system: "sisreg") = json_post("/regulation/requests/#{request.id}/external", system: system, number: number, version: request.version)
  def schedule!(request, **over)
    json_post "/regulation/requests/#{request.id}/schedule", { at: at, place: place, version: request.reload.version }.merge(over.transform_keys(&:to_sym))
  end
  def outcome!(request, result) = json_post("/regulation/requests/#{request.id}/outcome", result: result, version: request.reload.version)

  def external_request! = regulation_request!.tap { |r| mark!(r) }.reload

  describe "POST /regulation/requests/:id/external" do
    it "marca pending como SISREG: external, state_regulated, sai da fila de pending e não consome cota" do
      request = regulation_request!
      mark!(request)
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => request.id, "status" => "external", "state_regulated" => true, "version" => request.version + 1,
                                   "external" => { "system" => "sisreg", "number" => "123456789" })
      expect(json_body["events"].map { |e| e["status"] }).to eq(%w[pending external])
      expect(json_body.keys).to include("events", "authorization", "schedule", "outcome")
      expect(viewed.last.payload).to include("access" => "regulation", "patient_id" => request.patient_id, "user_id" => regulator.id)
      expect(published("external").sole.payload).to eq("regulation_request_id" => request.id, "user_id" => regulator.id)

      get "/regulation/requests", params: { status: "pending" }
      expect(json_body["requests"].map { |r| r["id"] }).not_to include(request.id)
      get "/regulation/requests/count"
      expect(json_body).to include("pending" => 0, "external" => 1)
      expect(RegulationAuthorization.count).to eq(0)
    end

    it "número inválido ou sistema desconhecido → 422 invalid_request com path; nada muda" do
      request = regulation_request!
      mark!(request, number: "12 34")
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "number" } ])
      mark!(request, number: "1" * 31)
      expect(json_body).to eq("error" => "invalid_request", "path" => "number")
      mark!(request, system: "esus")
      expect(json_body).to eq("error" => "invalid_request", "path" => "system")
      json_post "/regulation/requests/#{request.id}/external", system: "sisreg", number: "1", version: "1"
      expect(json_body).to eq("error" => "invalid_request", "path" => "version")
      expect(request.reload).to have_attributes(status: "pending", state_regulated: false, external_number: nil)
    end

    it "chave desconhecida no corpo → 422 invalid_request com path" do
      request = regulation_request!
      json_post "/regulation/requests/#{request.id}/external", system: "sisreg", number: "1", version: request.version, cpf: "x"
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "cpf" } ])
    end

    it "número na query → 422 invalid_request com path, nada lido da URL" do
      request = regulation_request!
      post "/regulation/requests/#{request.id}/external?number=123",
           params: { system: "sisreg", number: "9", version: request.version }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "number" } ])
      expect(request.reload.status).to eq("pending")
    end

    it "authorized → 409 invalid_transition; versão velha → 409 stale_version" do
      request = reauthorize!(regulation_request!, offer: offer)
      mark!(request)
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition" } ])
      pending = regulation_request!
      json_post "/regulation/requests/#{pending.id}/external", system: "sisreg", number: "1", version: pending.version + 5
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "stale_version" } ])
    end

    it "returned → external (G12 #7)" do
      request = regulation_request!
      expect(CareRegulation::Decide.call(request: request, decision: "return", reason: "Falta o laudo do exame", version: request.version,
                                         by: regulator)).to be_ok
      mark!(request.reload)
      expect(json_body).to include("status" => "external", "state_regulated" => true)
      expect(json_body["events"].map { |e| e["status"] }).to eq(%w[pending returned external])
    end

    it "external → external corrige o número e deixa rastro: andamento external e evento só com ids (sem número nem sistema)" do
      request = external_request!
      other = care_regulator!
      sign_in_as(other)
      expect { mark!(request, number: "987654321", system: "care") }
        .to change { request.events.count }.by(1).and change { published("external").count }.by(1)
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("status" => "external", "external" => { "system" => "care", "number" => "987654321" },
                                   "version" => request.version + 1)
      expect(json_body["events"].map { |e| e["status"] }).to eq(%w[pending external external])
      last = request.events.reorder(:created_at, :id).last
      expect(last).to have_attributes(status: "external", by_user_id: other.id, reason: nil)
      payload = published("external").order(:occurred_at).last.payload
      expect(payload).to eq("regulation_request_id" => request.id, "user_id" => other.id)
      expect(payload.to_s + last.reason.to_s).not_to include("987654321", "care")
    end

    it "só o care_regulator: profissional e administrador → 403; id desconhecido ou de rascunho → 404" do
      request = regulation_request!
      [ doctor!(create_unit("UBS Externo")), regulation_admin! ].each do |user|
        sign_in_as(user)
        mark!(request)
        expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      end
      expect(request.reload.status).to eq("pending")
      sign_in_as(regulator)
      draft = regulation_request!(status: "draft")
      [ SecureRandom.uuid, "abc", draft.id ].each do |id|
        json_post "/regulation/requests/#{id}/external", system: "sisreg", number: "1", version: 1
        expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
      end
    end

    it "interruptor desligado → 403 feature_disabled" do
      request = regulation_request!
      Platform::Features.set!(city: city, key: "care_regulation", enabled: false, maintainer: ledi_maintainer!)
      mark!(request)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "care_regulation" } ])
    end

    it "o número não vai ao log nem ao evento" do
      request = regulation_request!
      log = StringIO.new
      capture = ActiveSupport::Logger.new(log).tap { |l| l.level = Logger::DEBUG }
      Rails.logger.broadcast_to(capture)
      mark!(request, number: "SIGILOSO-777")
      Rails.logger.stop_broadcasting_to(capture)
      expect(response).to have_http_status(:ok)
      expect(log.string).not_to include("SIGILOSO-777")
      expect(DomainEvent.all.map { |e| e.payload.to_s }.join).not_to include("SIGILOSO-777")
    end
  end

  describe "POST /regulation/requests/:id/schedule" do
    it "agenda um external: scheduled, state_regulated mantido, schedule com data, local e observação" do
      request = external_request!
      schedule!(request, notes: "Levar exames anteriores")
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("status" => "scheduled", "state_regulated" => true, "version" => request.version + 1,
                                   "external" => { "system" => "sisreg", "number" => "123456789" })
      expect(json_body["schedule"]).to eq("at" => Time.iso8601(at).iso8601, "place" => place, "notes" => "Levar exames anteriores")
      expect(json_body["events"].map { |e| e["status"] }).to eq(%w[pending external scheduled])
      expect(published("scheduled").sole.payload).to eq("regulation_request_id" => request.id, "user_id" => regulator.id)
      expect(viewed.last.payload).to include("access" => "regulation", "patient_id" => request.patient_id)
    end

    it "remarca o que já está scheduled pelo estado (overlay G1): 200, nova data, state_regulated mantido" do
      request = external_request!
      schedule!(request)
      later = (now + 20.days).change(hour: 9).iso8601
      schedule!(request, at: later, place: "Clínica nova")
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("status" => "scheduled", "state_regulated" => true)
      expect(json_body["schedule"]).to include("at" => Time.iso8601(later).iso8601, "place" => "Clínica nova", "notes" => nil)
      expect(request.reload.events.map(&:status)).to eq(%w[pending external scheduled scheduled])
    end

    it "validações: at (sem fuso, fora de -30/+365 dias, lixo), place (vazio, 201) e notes (501) → 422 com path; nada muda" do
      request = external_request!
      {
        "at" => [ "2026-11-05T14:00:00", "2026-11-05", "amanhã", nil, 123, (now - 31.days).iso8601, (now + 366.days).iso8601 ],
        "place" => [ "", "   ", nil, "x" * 201, 5 ],
        "notes" => [ "n" * 501, 5 ]
      }.each do |field, values|
        values.each do |value|
          schedule!(request, field => value)
          expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => field } ])
        end
      end
      expect(request.reload.status).to eq("external")
    end

    it "limites aceitos: 30 dias atrás, 365 à frente, place com 200 e notes com 500" do
      request = external_request!
      schedule!(request, at: (now - 29.days).iso8601, place: "p" * 200, notes: "n" * 500)
      expect(response).to have_http_status(:ok)
      schedule!(request, at: (now + 364.days).iso8601)
      expect(response).to have_http_status(:ok)
    end

    it "pending → 409 invalid_transition" do
      pending = regulation_request!
      schedule!(pending)
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition" } ])
    end

    it "autorizado em oferta contratada: agenda (200) e remarcar (200) mantém a mesma autorização e o mesmo mês" do
      request = reauthorize!(regulation_request!, offer: offer)
      authorization = request.authorizations.sole
      schedule!(request)
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("status" => "scheduled", "state_regulated" => false)
      first = json_body["authorization"]
      schedule!(request, at: (now + 15.days).change(hour: 8).iso8601)
      expect(response).to have_http_status(:ok)
      expect(json_body["authorization"]).to eq(first)
      expect(json_body.dig("authorization", "month")).to eq("2026-10")
      expect(request.reload.authorizations.sole).to eq(authorization)
      expect(authorization.reload.released_at).to be_nil
    end

    it "falta em oferta contratada e depois external: scheduled e completed vêm com authorization nula; a vaga continua consumida" do
      request = reauthorize!(regulation_request!, offer: offer)
      schedule!(request)
      outcome!(request, "missed")
      expect(json_body).to include("status" => "pending", "misses" => 1)
      stale = request.reload.authorizations.sole
      mark!(request)
      expect(json_body).to include("status" => "external", "state_regulated" => true, "authorization" => nil)
      schedule!(request)
      expect(json_body).to include("status" => "scheduled", "state_regulated" => true, "authorization" => nil)
      outcome!(request, "completed")
      expect(json_body).to include("status" => "completed", "state_regulated" => true, "authorization" => nil)
      expect(stale.reload.released_at).to be_nil
      expect(CareRegulation::Quota.used([ offer.id ]).fetch(offer.id)).to eq(1)
    end

    it "autorizado em oferta própria → 409 invalid_transition; scheduled próprio também" do
      setup = own_authorized_request!
      request = setup.fetch(:regulation_request)
      schedule!(request)
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition" } ])

      schedule_regulated!(setup.fetch(:appointment_request), at: 3.days.from_now.change(hour: 9))
      CareRegulation::AppointmentSync.call(appointment_request_id: request.reload.appointment_request_id)
      expect(request.reload.status).to eq("scheduled")
      schedule!(request)
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition" } ])
      outcome!(request, "completed")
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition" } ])
      outcome!(request, "missed")
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition" } ])
      expect(request.reload).to have_attributes(status: "scheduled", misses: 0)
    end

    it "versão velha → 409 stale_version; só o regulador → 403" do
      request = external_request!
      json_post "/regulation/requests/#{request.id}/schedule", at: at, place: place, version: request.version - 1
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "stale_version" } ])
      sign_in_as(doctor!(create_unit("UBS Agenda")))
      schedule!(request)
      expect(response).to have_http_status(:forbidden)
    end

    it "o local e a observação não vão ao log nem ao evento" do
      request = external_request!
      log = StringIO.new
      capture = ActiveSupport::Logger.new(log).tap { |l| l.level = Logger::DEBUG }
      Rails.logger.broadcast_to(capture)
      schedule!(request, place: "Local-Sigiloso-9", notes: "Nota-Sigilosa-9")
      Rails.logger.stop_broadcasting_to(capture)
      expect(response).to have_http_status(:ok)
      expect(log.string).not_to include("Local-Sigiloso-9")
      expect(log.string).not_to include("Nota-Sigilosa-9")
      expect(DomainEvent.all.map { |e| e.payload.to_s }.join).not_to include("Local-Sigiloso-9")
    end
  end

  describe "POST /regulation/requests/:id/outcome" do
    it "scheduled + completed → completed (outcome completed, evento só com ids)" do
      request = external_request!
      schedule!(request)
      outcome!(request, "completed")
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("status" => "completed", "outcome" => "completed", "misses" => 0, "state_regulated" => true)
      expect(json_body["events"].map { |e| e["status"] }).to eq(%w[pending external scheduled completed])
      expect(published("completed").sole.payload).to eq("regulation_request_id" => request.id, "user_id" => regulator.id)
    end

    it "missed no regulado pelo estado → volta a external com misses 1; segunda falta → closed (outcome missed)" do
      request = external_request!
      schedule!(request)
      outcome!(request, "missed")
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("status" => "external", "misses" => 1, "state_regulated" => true, "schedule" => nil, "outcome" => nil,
                                   "external" => { "system" => "sisreg", "number" => "123456789" })
      expect(json_body["events"].map { |e| e["status"] }).to eq(%w[pending external scheduled missed external])
      expect(published("missed").count).to eq(1)

      schedule!(request)
      outcome!(request, "missed")
      expect(json_body).to include("status" => "closed", "misses" => 2, "outcome" => "missed")
      expect(published("missed").count).to eq(2)
      expect(published("closed").count).to eq(1)
    end

    it "missed em oferta contratada → pending com misses 1, sem liberar a cota; completed mantém a autorização" do
      request = reauthorize!(regulation_request!, offer: offer)
      schedule!(request)
      outcome!(request, "missed")
      expect(json_body).to include("status" => "pending", "misses" => 1, "state_regulated" => false, "authorization" => nil)
      expect(CareRegulation::Quota.used([ offer.id ]).fetch(offer.id)).to eq(1)

      again = reauthorize!(request.reload, offer: offer)
      schedule!(again)
      outcome!(again, "completed")
      expect(json_body).to include("status" => "completed", "outcome" => "completed")
      expect(json_body.dig("authorization", "offer_id")).to eq(offer.id)
    end

    it "fora de scheduled → 409 invalid_transition; result inválido → 422 com path" do
      request = external_request!
      outcome!(request, "completed")
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition" } ])
      schedule!(request)
      outcome!(request, "cancelled")
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "result" } ])
      json_post "/regulation/requests/#{request.id}/outcome", result: "completed", version: nil
      expect(json_body).to eq("error" => "invalid_request", "path" => "version")
      json_post "/regulation/requests/#{request.id}/outcome", result: "completed", version: request.version - 1
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "stale_version" } ])
      expect(request.reload.status).to eq("scheduled")
    end

    it "antes do dia do agendamento → 422 outcome_before_schedule; nada muda; no dia, 200" do
      request = external_request!
      schedule!(request, at: (now + 2.days).change(hour: 14).iso8601)
      version = request.reload.version
      %w[completed missed].each do |result|
        json_post "/regulation/requests/#{request.id}/outcome", result: result, version: version
        expect([ response.status, json_body ]).to eq([ 422, { "error" => "outcome_before_schedule" } ])
      end
      expect(request.reload).to have_attributes(status: "scheduled", version: version, misses: 0)
      expect(published("completed").count + published("missed").count).to eq(0)

      travel_to (now + 2.days).change(hour: 8)
      outcome!(request, "completed")
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("status" => "completed")
    end

    it "só o regulador → 403" do
      request = external_request!
      schedule!(request)
      sign_in_as(regulation_admin!)
      outcome!(request, "completed")
      expect(response).to have_http_status(:forbidden)
    end
  end
end
