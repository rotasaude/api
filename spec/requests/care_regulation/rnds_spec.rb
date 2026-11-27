require "rails_helper"

# Módulo 26c, Task 14 (contrato §5, Q10, Q11, Q16, Q19, Q25): situação, lista e
# reenvio do envio da regulação à RNDS. Leituras com `enabled?` (a tela abre com
# a credencial recusada); o reenvio com `usable?`, `municipal_admin` e step-up.
# Nenhuma resposta traz paciente, CPF, CNS, CID, alvo nem payload.
RSpec.describe "Regulação — situação, lista e reenvio do envio à RNDS", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { rnds_regulation_city!(mock: false) }
  let(:admin) { regulation_admin! }
  let(:regulator) { care_regulator! }
  let(:now) { Time.zone.local(2026, 11, 20, 15, 0) }

  before { travel_to(now) }

  def sync!(request = regulation_request!, status: "queued", enqueued_at: now - 1.hour, **over)
    row = RegulationRndsSync.find_or_initialize_by(regulation_request: request)
    row.update!({ status: status, enqueued_at: enqueued_at }.merge(over))
    row
  end

  def post_retry(id) = post("/regulation/rnds/syncs/#{id}/retry", params: "{}", headers: { "CONTENT_TYPE" => "application/json" })

  describe "GET /regulation/rnds/status" do
    it "o regulador vê as contagens e a faixa" do
      sync!(status: "queued")
      sync!(status: "sending")
      sync!(status: "blocked", blocked_reasons: [ "missing_diagnosis" ])
      sync!(status: "rejected", last_error_codes: [ "EHR-ERR906" ])
      sync!(status: "idle", last_rnds_id: "doc-1", last_accepted_at: now - 2.days)
      sync!(status: "queued", enqueued_at: now - 3.days)
      # Faixa da carga inicial (Q26): a carência de 72 h conta do enqueued_at.
      sync!(status: "queued", initial_load: true, created_at: now - 40.days, enqueued_at: now - 71.hours)
      sign_in_as(regulator)
      get "/regulation/rnds/status"
      expect([ response.status, json_body ]).to eq(
        [ 200, { "usable" => true, "missing" => [],
                 "counts" => { "queued" => 4, "blocked" => 1, "rejected" => 1, "failed" => 0, "late" => 1, "accepted" => 1 },
                 "late_banner" => true, "initial_load_pending" => 1 } ]
      )
    end

    # Re-revisão N3: só o que ainda espera a vez na faixa da carga inicial (queued/sending).
    it "initial_load_pending conta só as linhas da faixa da carga inicial que esperam envio (queued, sending)" do
      sync!(status: "queued", initial_load: true)
      sync!(status: "idle", initial_load: true)
      sync!(status: "excluded", initial_load: true)
      sign_in_as(admin)
      get "/regulation/rnds/status"
      expect(json_body).to include("initial_load_pending" => 1, "late_banner" => false)
    end

    it "linha em massa que termina blocked/rejected/failed não conta em initial_load_pending" do
      %w[queued sending].each { |status| sync!(status: status, initial_load: true) }
      sync!(status: "blocked", initial_load: true, blocked_reasons: [ "missing_diagnosis" ])
      sync!(status: "rejected", initial_load: true, last_error_codes: [ "EHR-ERR999" ])
      sync!(status: "failed", initial_load: true)
      sync!(status: "queued", initial_load: false)
      sign_in_as(regulator)
      get "/regulation/rnds/status"
      expect(json_body).to include("initial_load_pending" => 2)
    end

    it "interruptor desligado → 403 feature_disabled com feature rnds_regulation" do
      Platform::Features.set!(city: city, key: "rnds_regulation", enabled: false, maintainer: ledi_maintainer!)
      sign_in_as(regulator)
      get "/regulation/rnds/status"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "rnds_regulation" } ])
    end

    it "credencial recusada → a situação responde com usable false e missing (Q10)" do
      rnds_regulation_credential!.update!(last_check_status: "unauthorized")
      sync!(status: "queued")
      sign_in_as(admin)
      get "/regulation/rnds/status"
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("usable" => false, "missing" => [ "credential_unauthorized:rnds_regulation" ])
      expect(json_body["counts"]).to include("queued" => 1)
    end

    it "profissional → 403 missing_role; sem sessão → 401; query com chave estranha → 422" do
      get "/regulation/rnds/status"
      expect(response).to have_http_status(:unauthorized)
      sign_in_as(doctor!(create_unit("UBS RNDS status")))
      get "/regulation/rnds/status"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      sign_in_as(regulator)
      get "/regulation/rnds/status", params: { foo: "1" }
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "foo" } ])
    end
  end

  describe "GET /regulation/rnds/syncs" do
    it "o item traz request_ref com 8 hex maiúsculos do id do pedido (Q11) e a forma completa" do
      request = regulation_request!
      row = sync!(request, status: "rejected", last_error_codes: [ "EHR-ERR906" ], attempts: 2, desired_status: "pending",
                           sent_status: "pending", last_accepted_at: now - 5.days, next_attempt_at: nil)
      sign_in_as(regulator)
      get "/regulation/rnds/syncs"
      expect(response).to have_http_status(:ok)
      expect(json_body).to eq(
        "items" => [ { "id" => row.id, "regulation_request_id" => request.id, "request_ref" => request.id.delete("-")[0, 8].upcase,
                       "status" => "rejected", "sent_status" => "pending", "desired_status" => "pending",
                       "blocked_reasons" => [], "last_error_codes" => [ "EHR-ERR906" ], "attempts" => 2,
                       "enqueued_at" => row.enqueued_at.iso8601, "last_accepted_at" => (now - 5.days).iso8601,
                       "next_attempt_at" => nil, "late" => false,
                       "fix" => { "offer_id" => nil, "provider_id" => nil, "unit_id" => nil, "offer_month" => nil, "settings" => false } } ],
        "next_before" => nil
      )
      expect(json_body["items"][0]["request_ref"]).to match(/\A[0-9A-F]{8}\z/)
    end

    it "filtra por status=blocked e reason=performer_cbo_missing e traz o fix com a oferta" do
      auth = own_authorized_request!
      blocked = sync!(auth[:regulation_request], status: "blocked", blocked_reasons: [ "performer_cbo_missing" ])
      sync!(status: "blocked", blocked_reasons: [ "missing_diagnosis" ])
      sync!(status: "queued")
      sign_in_as(admin)
      get "/regulation/rnds/syncs", params: { status: "blocked", reason: "performer_cbo_missing" }
      expect(json_body["items"].map { |i| i["id"] }).to eq([ blocked.id ])
      expect(json_body["items"][0]["fix"]).to eq(
        "offer_id" => auth[:offer].id, "provider_id" => auth[:offer].care_provider_id, "unit_id" => nil,
        "offer_month" => auth[:offer].month.iso8601, "settings" => false
      )
    end

    it "fix: unidade solicitante sem CNES → unit_id; especialidade sem SIGTAP → settings" do
      request = regulation_request!
      sync!(request, status: "blocked", blocked_reasons: [ "requester_unit_without_cnes", "specialty_without_sigtap" ])
      sign_in_as(regulator)
      get "/regulation/rnds/syncs"
      expect(json_body["items"][0]["fix"]).to include("unit_id" => request.requester_unit_id, "settings" => true, "offer_id" => nil)
    end

    it "fix: executante sem CNES → provider_id e a unidade do prestador próprio" do
      auth = own_authorized_request!
      sync!(auth[:regulation_request], status: "blocked", blocked_reasons: [ "performer_without_cnes" ])
      sign_in_as(admin)
      get "/regulation/rnds/syncs"
      expect(json_body["items"][0]["fix"]).to include("provider_id" => auth[:offer].care_provider_id, "unit_id" => auth[:unit].id,
                                                      "offer_id" => nil)
    end

    # Final wave, item 7: a falta da rede própria aponta a unidade do horário faltado, não a do prestador vigente.
    it "fix: falta na rede própria com a unidade do no_show sem CNES → unit_id dessa unidade, mesmo reautorizado em outra" do
      auth = own_authorized_request!
      appointment = schedule_regulated!(auth[:appointment_request], at: (Time.current + 3.days).change(hour: 9))
      CareRegulation::AppointmentSync.call(appointment_request_id: auth[:appointment_request].id)
      no_show!(appointment)
      CareRegulation::AppointmentSync.call(appointment_request_id: auth[:appointment_request].id)
      other_unit = create_unit("Policlínica #{SecureRandom.hex(3)}", cnes: regulation_cnes)
      request = reauthorize!(auth[:regulation_request].reload, offer: offer!(provider: own_provider!(other_unit)))
      sync = Regulation::RndsSync.recompute!(request, create: true, now: Time.current)
      expect(sync.pending_steps.map { |step| step["status"] }).to eq(%w[absence])
      facts = Regulation::RiraFacts.for(request: request, settings: RegulationRndsSetting.current, credential: nil)
      expect(Regulation::RndsValidation.call(facts: facts, status: sync.pending_steps.first).last).to include("performer_without_cnes")
      sync.update_columns(status: "blocked", blocked_reasons: [ "performer_without_cnes" ])

      sign_in_as(admin)
      get "/regulation/rnds/syncs", params: { status: "blocked" }
      expect(json_body["items"].sole["fix"]).to eq("offer_id" => nil, "provider_id" => nil, "unit_id" => appointment.health_unit_id,
                                                    "offer_month" => nil, "settings" => false)
      expect(appointment.health_unit_id).to eq(auth[:unit].id)
    end

    it "reason=EHR-ERR999 filtra os recusados" do
      hit = sync!(status: "rejected", last_error_codes: [ "EHR-ERR999" ])
      sync!(status: "rejected", last_error_codes: [ "EHR-ERR906" ])
      sync!(status: "blocked", blocked_reasons: [ "missing_diagnosis" ])
      sign_in_as(regulator)
      get "/regulation/rnds/syncs", params: { reason: "EHR-ERR999" }
      expect(json_body["items"].map { |i| i["id"] }).to eq([ hit.id ])
    end

    it "reason por código RNDS casa também a linha queued com recusa de DELETE (sem olhar o status)" do
      hit = sync!(status: "queued", last_error_codes: [ "EHR-ERR999" ])
      sign_in_as(regulator)
      get "/regulation/rnds/syncs", params: { reason: "EHR-ERR999" }
      expect(json_body["items"].map { |i| [ i["id"], i["status"] ] }).to eq([ [ hit.id, "queued" ] ])
    end

    it "reason=skeleton casa qualquer motivo skeleton:<caminho>; caminho arbitrário → 422" do
      hit = sync!(status: "blocked", blocked_reasons: [ "skeleton:Appointment.start[app-2]" ])
      sync!(status: "blocked", blocked_reasons: [ "missing_diagnosis" ])
      sign_in_as(regulator)
      get "/regulation/rnds/syncs", params: { reason: "skeleton" }
      expect(json_body["items"].map { |i| i["id"] }).to eq([ hit.id ])
      expect(json_body["items"][0]["blocked_reasons"]).to eq([ "skeleton:Appointment.start[app-2]" ])
      get "/regulation/rnds/syncs", params: { reason: "skeleton:Appointment.start[app-2]" }
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "reason" } ])
    end

    it "status e reason fora do catálogo → 422 invalid_request com o path" do
      sign_in_as(regulator)
      get "/regulation/rnds/syncs", params: { status: "nope" }
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "status" } ])
      get "/regulation/rnds/syncs", params: { reason: "12345678901" }
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "reason" } ])
    end

    it "cursor de duas páginas, do mais novo ao mais antigo (enqueued_at DESC, id DESC)" do
      rows = Array.new(3) { |i| sync!(enqueued_at: now - (i + 1).hours) }
      sign_in_as(regulator)
      get "/regulation/rnds/syncs", params: { limit: 2 }
      first = json_body
      expect(first["items"].map { |i| i["id"] }).to eq([ rows[0].id, rows[1].id ])
      expect(first["next_before"]).to be_present
      get "/regulation/rnds/syncs", params: { limit: 2, before: first["next_before"] }
      expect(json_body["items"].map { |i| i["id"] }).to eq([ rows[2].id ])
      expect(json_body["next_before"]).to be_nil
    end

    it "cursor inválido → 422 invalid_cursor; limit inválido → 422 invalid_limit" do
      sign_in_as(regulator)
      get "/regulation/rnds/syncs", params: { before: "xx" }
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_cursor" } ])
      get "/regulation/rnds/syncs", params: { limit: 0 }
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_limit" } ])
    end

    it "query com cpf= → 422 invalid_request path cpf" do
      sign_in_as(regulator)
      get "/regulation/rnds/syncs", params: { cpf: "12345678909" }
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "cpf" } ])
    end

    it "late vem do alarme: mudança de ontem sem aceite depois das 23h" do
      late = sync!(status: "queued", enqueued_at: now - 3.days)
      sign_in_as(admin)
      get "/regulation/rnds/syncs"
      expect(json_body["items"].find { |i| i["id"] == late.id }["late"]).to be(true)
    end

    it "nenhum item tem CPF, CNS, CID nem nome (varredura do JSON), nem as janelas internas" do
      citizen = regulation_patient!(exam_seq!).last
      request = regulation_request!(citizen: citizen)
      sync!(request, status: "blocked", blocked_reasons: [ "performer_cbo_missing" ], retry_window_started_at: now - 2.days)
      sign_in_as(regulator)
      get "/regulation/rnds/syncs"
      raw = response.body
      patient = request.patient
      [ patient.cpf, patient.cns, patient.full_name, "I10", "Hipertensão", request.target_code,
        "retry_window_started_at", "unanswered_closed_at", "payload", "justification" ].compact.each do |needle|
        expect(raw).not_to include(needle.to_s)
      end
    end

    it "interruptor desligado → 403 feature_disabled; com a credencial recusada a lista abre" do
      rnds_regulation_credential!.update!(last_check_status: "unauthorized")
      sign_in_as(regulator)
      get "/regulation/rnds/syncs"
      expect(response).to have_http_status(:ok)
      Platform::Features.set!(city: city, key: "rnds_regulation", enabled: false, maintainer: ledi_maintainer!)
      get "/regulation/rnds/syncs"
      expect([ response.status, json_body["error"], json_body["feature"] ]).to eq([ 403, "feature_disabled", "rnds_regulation" ])
    end

    it "profissional → 403 missing_role" do
      sign_in_as(doctor!(create_unit("UBS RNDS lista")))
      get "/regulation/rnds/syncs"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    end
  end

  describe "POST /regulation/rnds/syncs/:id/retry" do
    it "reenvio de rejected com step-up → queued, tentativas zeradas, conteúdo e enqueued_at intactos, evento e janela reaberta" do
      enqueued = now - 4.days
      row = sync!(status: "rejected", enqueued_at: enqueued, attempts: 5, last_error_codes: [ "EHR-ERR906" ], desired_digest: "d" * 64,
                  sent_digest: "s" * 64, desired_status: "booked", sent_status: "pending", next_attempt_at: nil,
                  retry_window_started_at: now - 3.days)
      stepped_up!(admin)
      post_retry(row.id)
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => row.id, "status" => "queued", "attempts" => 0, "late" => true)
      expect(json_body.keys).not_to include("retry_window_started_at", "unanswered_closed_at")
      row.reload
      expect(row).to have_attributes(status: "queued", attempts: 0, next_attempt_at: now, enqueued_at: enqueued, desired_digest: "d" * 64,
                                     sent_digest: "s" * 64, desired_status: "booked", sent_status: "pending", retry_window_started_at: nil)
      event = DomainEvent.where(name: "regulation_rnds.queued").last
      expect(event.payload).to eq("regulation_rnds_sync_id" => row.id, "regulation_request_id" => row.regulation_request_id)
    end

    it "reenvio de failed também volta a queued" do
      row = sync!(status: "failed", attempts: 9)
      stepped_up!(admin)
      post_retry(row.id)
      expect([ response.status, json_body["status"] ]).to eq([ 200, "queued" ])
    end

    it "de idle (e de blocked, queued, sending) → 409 not_retryable, sem mudar a linha" do
      %w[idle blocked queued sending excluded erased].each do |status|
        row = sync!(status: status)
        stepped_up!(admin)
        post_retry(row.id)
        expect([ status, response.status, json_body ]).to eq([ status, 409, { "error" => "not_retryable" } ])
        expect(row.reload.status).to eq(status)
      end
    end

    it "sem step-up → 401 mfa_required" do
      row = sync!(status: "rejected")
      sign_in_as(step_up_enrolled!(admin))
      post_retry(row.id)
      expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
      expect(row.reload.status).to eq("rejected")
    end

    it "regulador → 403, mesmo com step-up" do
      row = sync!(status: "rejected")
      stepped_up!(regulator)
      post_retry(row.id)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      expect(row.reload.status).to eq("rejected")
    end

    it "credencial recusada → 403 feature_disabled (o reenvio exige usable?)" do
      row = sync!(status: "rejected")
      rnds_regulation_credential!.update!(last_check_status: "unauthorized")
      stepped_up!(admin)
      post_retry(row.id)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "rnds_regulation" } ])
      expect(row.reload.status).to eq("rejected")
    end

    it "id desconhecido ou que não é uuid → 404 not_found" do
      stepped_up!(admin)
      post_retry(SecureRandom.uuid)
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
      post_retry("abc")
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    end
  end
end
