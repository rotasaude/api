require "rails_helper"

# Módulo 33, Task 14 (ADR 0051; contrato §2; §16 Q8, Q10, Q26, Q32, Q35, Q36;
# preflight F-18): arquivar, reabrir (de ofício e ao aceitar o pedido do
# cidadão) e decidir o pedido de reabertura.
# - archive/reopen/decide: só o ouvidor; 200 com o detalhe atualizado (Q32).
# - archive: estados received|in_analysis|awaiting_complement (senão 422
#   invalid_transition); duplicate pede outra manifestação (id ou protocolo,
#   Q26); forwarded_elsewhere pede o nome do órgão (1..120); `no_complement`
#   só o job (HTTP → 422 path reason, Q36).
# - reopen: ciclo + 1, prazo novo de hoje, zera extended/complement_used/
#   suspended_days/resolution/archive_reason/duplicate_of_id/external_body_name/
#   concluded_at, tudo junto (os CHECKs com IS NOT DISTINCT FROM).
# - pedido do cidadão (RequestReopen): até 30 dias depois de concluded_at, um
#   por ciclo (Q10). Recusar leva o texto ao cidadão (reopen_decided).
RSpec.describe "Ouvidoria — arquivar, reabrir e pedido de reabertura", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { ombudsman_city! }
  let(:now) { Time.utc(2026, 11, 11, 15) } # 12h em Brasília
  let(:today) { now.in_time_zone("America/Sao_Paulo").to_date }
  let(:citizen) { web_citizen! }
  let(:reason_text) { "A resposta não resolveu o meu problema e a situação continua." }
  let(:decision_text) { "Analisamos o pedido e o caso será retomado pela equipe." }

  before { travel_to(now) }
  after { travel_back }

  def capture_log
    log = StringIO.new
    capture = ActiveSupport::Logger.new(log).tap { |l| l.level = Logger::DEBUG }
    Rails.logger.broadcast_to(capture)
    yield
    log.string
  ensure
    Rails.logger.stop_broadcasting_to(capture)
  end

  def act(m, action, params) = json_post("/ombudsman/manifestations/#{m.id}/#{action}", params)
  def decide(request, params) = json_post("/ombudsman/reopen_requests/#{request.id}/decide", params)
  def open_one!(**attrs) = raw_manifestation!(citizen: citizen, state: "in_analysis", subject: subject_leaf!, **attrs)
  def concluded!(state: "answered", concluded_at: now - 2.days, **attrs)
    raw_manifestation!(citizen: citizen, subject: subject_leaf!, state: state, concluded_at: concluded_at,
                       resolution: (state == "answered" ? "resolved" : nil),
                       archive_reason: (state == "archived" ? "improper" : nil), **attrs)
  end
  def events(m) = OmbudsmanEvent.where(ombudsman_manifestation: m).order(:created_at, :id)
  def notices(m) = OmbudsmanNotice.where(ombudsman_manifestation_id: m.id).pluck(:kind)
  def request_reopen(m, reason: reason_text, at: now) = Ombudsman::RequestReopen.call(manifestation: m, reason: reason, now: at)

  describe "POST .../archive" do
    it "arquiva por motivo simples: archived, concluded_at, evento visível com o motivo, aviso e ombudsman.concluded; 200 com o detalhe" do
      m = open_one!
      sign_in_as(ombudsman!)

      act(m, "archive", expected_state: "in_analysis", reason: "improper")
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => m.id, "state" => "archived", "archive_reason" => "improper", "color" => nil,
                                   "duplicate_of" => nil, "external_body_name" => nil)
      expect(Time.iso8601(json_body["concluded_at"])).to eq(now)
      expect(m.reload).to have_attributes(state: "archived", archive_reason: "improper", concluded_at: now)
      expect(events(m).sole).to have_attributes(kind: "archived", actor: "staff", actor_user_id: ombudsman!.id,
                                                visible_to_citizen: true, data: { "reason" => "improper" })
      expect(notices(m)).to eq([ "archived" ])
      expect(DomainEvent.where(name: "ombudsman.concluded").sole.payload).to eq("manifestation_id" => m.id, "outcome" => "archived")
    end

    it "aceita received, in_analysis e awaiting_complement; forwarded (e answered) → 422 invalid_transition, nada gravado" do
      sign_in_as(ombudsman!)
      %w[received in_analysis awaiting_complement].each do |state|
        m = open_one!(state: state, complement_requested_at: (now if state == "awaiting_complement"))
        act(m, "archive", expected_state: state, reason: "loss_of_object")
        expect(response).to have_http_status(:ok)
        expect(m.reload.state).to eq("archived")
      end
      %w[forwarded answered].each do |state|
        m = open_one!(state: state, concluded_at: (now if state == "answered"))
        act(m, "archive", expected_state: state, reason: "loss_of_object")
        expect(response).to have_http_status(:unprocessable_content)
        expect(json_body).to eq("error" => "invalid_transition")
        expect(m.reload.state).to eq(state)
        expect(events(m)).to be_empty
      end
    end

    it "de awaiting_complement fecha a suspensão no mesmo UPDATE (suspended_days += dias locais, complement_requested_at nulo); reabrir zera de novo" do
      m = open_one!(state: "awaiting_complement", complement_requested_at: now - 3.days, suspended_days: 2, complement_used: true)
      sign_in_as(ombudsman!)

      act(m, "archive", expected_state: "awaiting_complement", reason: "lack_of_clarity")
      expect(response).to have_http_status(:ok)
      expect(m.reload).to have_attributes(state: "archived", suspended_days: 5, complement_requested_at: nil)

      act(m, "reopen", expected_state: "archived")
      expect(response).to have_http_status(:ok)
      expect(m.reload).to have_attributes(state: "in_analysis", suspended_days: 0, complement_requested_at: nil, complement_used: false, cycle: 2)
    end

    it "duplicidade: sem a original → 422; com id ou com protocolo → archived com duplicate_of; a própria ou inexistente → 422" do
      original = open_one!
      m = open_one!
      sign_in_as(ombudsman!)

      act(m, "archive", expected_state: "in_analysis", reason: "duplicate")
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "duplicate_of_id")
      act(m, "archive", expected_state: "in_analysis", reason: "duplicate", duplicate_of_id: m.id)
      expect(json_body).to include("error" => "invalid_request", "path" => "duplicate_of_id")
      act(m, "archive", expected_state: "in_analysis", reason: "duplicate", duplicate_of_id: SecureRandom.uuid)
      expect(json_body).to include("error" => "invalid_request", "path" => "duplicate_of_id")
      act(m, "archive", expected_state: "in_analysis", reason: "duplicate", duplicate_of_protocol: "2026-999999")
      expect(json_body).to include("error" => "invalid_request", "path" => "duplicate_of_protocol")
      act(m, "archive", expected_state: "in_analysis", reason: "duplicate", duplicate_of_id: original.id, duplicate_of_protocol: original.protocol)
      expect(json_body).to include("error" => "invalid_request", "path" => "duplicate_of_id")
      act(m, "archive", expected_state: "in_analysis", reason: "improper", duplicate_of_id: original.id)
      expect(json_body).to include("error" => "invalid_request", "path" => "duplicate_of_id")
      expect(m.reload.state).to eq("in_analysis")
      expect(events(m)).to be_empty

      act(m, "archive", expected_state: "in_analysis", reason: "duplicate", duplicate_of_id: original.id)
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("state" => "archived", "duplicate_of" => { "id" => original.id, "protocol" => original.protocol })
      expect(m.reload.duplicate_of_id).to eq(original.id)

      other = open_one!
      act(other, "archive", expected_state: "in_analysis", reason: "duplicate", duplicate_of_protocol: original.protocol)
      expect(response).to have_http_status(:ok)
      expect(other.reload.duplicate_of_id).to eq(original.id)
    end

    it "outro órgão: sem o nome (ou fora de 1..120, ou com outro motivo) → 422 path external_body_name; com o nome → archived" do
      m = open_one!
      sign_in_as(ombudsman!)

      [ [ "forwarded_elsewhere", nil ], [ "forwarded_elsewhere", "  " ], [ "forwarded_elsewhere", "x" * 121 ], [ "improper", "Outro órgão" ] ]
        .each do |reason, name|
        act(m, "archive", { expected_state: "in_analysis", reason: reason, external_body_name: name }.compact)
        expect(response).to have_http_status(:unprocessable_content)
        expect(json_body).to include("error" => "invalid_request", "path" => "external_body_name")
      end
      expect(m.reload.state).to eq("in_analysis")

      act(m, "archive", expected_state: "in_analysis", reason: "forwarded_elsewhere", external_body_name: "  Secretaria Estadual de Saúde ")
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("external_body_name" => "Secretaria Estadual de Saúde")
    end

    it "motivo fora da lista → 422 path reason; no_complement pelo HTTP → 422 path reason (Q36); nada gravado" do
      m = open_one!
      sign_in_as(ombudsman!)

      [ "talvez", "no_complement", nil ].each do |reason|
        act(m, "archive", { expected_state: "in_analysis", reason: reason }.compact)
        expect(response).to have_http_status(:unprocessable_content)
        expect(json_body).to include("error" => "invalid_request", "path" => "reason")
      end
      expect(m.reload.state).to eq("in_analysis")
      expect(events(m)).to be_empty
    end

    it "o comando aceita no_complement do sistema (o job): evento de sistema, sem usuário" do
      m = open_one!(state: "awaiting_complement", complement_requested_at: now - 10.days)
      result = Ombudsman::Archive.call(manifestation_id: m.id, expected_state: "awaiting_complement", reason: "no_complement",
                                       duplicate_of_id: nil, external_body_name: nil, by: nil, actor: "system", now: now)
      expect(result).to be_ok
      expect(m.reload).to have_attributes(state: "archived", archive_reason: "no_complement")
      expect(events(m).sole).to have_attributes(kind: "archived", actor: "system", actor_user_id: nil, data: { "reason" => "no_complement" })
      expect(notices(m)).to eq([ "archived" ])
    end

    it "expected_state errado → 409 manifestation_changed; sem o campo → 422; técnico → 403; anônima arquiva sem aviso" do
      m = open_one!
      sign_in_as(ombudsman!)
      act(m, "archive", expected_state: "received", reason: "improper")
      expect(response).to have_http_status(:conflict)
      expect(json_body).to eq("error" => "manifestation_changed")
      act(m, "archive", reason: "improper")
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("path" => "expected_state")
      expect(m.reload.state).to eq("in_analysis")

      sign_in_as(ombudsman_staff!)
      act(m, "archive", expected_state: "in_analysis", reason: "improper")
      expect(response).to have_http_status(:forbidden)

      anonymous = raw_manifestation!(kind: "report", identification_mode: "anonymous", state: "in_analysis")
      sign_in_as(ombudsman!)
      act(anonymous, "archive", expected_state: "in_analysis", reason: "improper")
      expect(response).to have_http_status(:ok)
      expect(OmbudsmanNotice.count).to eq(0)
    end
  end

  describe "POST .../reopen (de ofício)" do
    it "answered → in_analysis: ciclo 2, prazo de hoje, zera extended/complement_used/suspended_days/resolution/concluded_at; pode pedir complemento de novo" do
      m = concluded!(extended: true, extension_reason: "Prazo prorrogado", complement_used: true, suspended_days: 5, cycle: 1,
                     cycle_started_on: today - 60)
      sign_in_as(ombudsman!)

      act(m, "reopen", expected_state: "answered", text: "  Nova análise a pedido da coordenação.  ")
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("state" => "in_analysis", "cycle" => 2, "extended" => false, "complement_used" => false,
                                   "resolution" => nil, "concluded_at" => nil, "due_on" => (today + 30).iso8601, "color" => "green")
      expect(json_body.dig("can", "request_complement")).to be(true)
      expect(m.reload).to have_attributes(state: "in_analysis", cycle: 2, cycle_started_on: today, extended: false, extension_reason: nil,
                                          complement_used: false, complement_requested_at: nil, suspended_days: 0, resolution: nil,
                                          archive_reason: nil, duplicate_of_id: nil, external_body_name: nil, concluded_at: nil)
      expect(events(m).sole).to have_attributes(kind: "reopened", actor: "staff", actor_user_id: ombudsman!.id, visible_to_citizen: true,
                                                text: "Nova análise a pedido da coordenação.")
      expect(DomainEvent.where(name: "ombudsman.reopened").sole.payload).to eq("manifestation_id" => m.id)
      expect(notices(m)).to be_empty
    end

    it "o texto do reopened é interno: a linha do tempo do cidadão traz a entrada sem texto" do
      m = concluded!
      sign_in_as(ombudsman!)
      act(m, "reopen", expected_state: "answered", text: "Nota interna sobre a reabertura do caso.")
      expect(events(m).sole.text).to eq("Nota interna sobre a reabertura do caso.")
      entry = Ombudsman::Timeline.citizen(events(m)).sole
      expect(entry[:kind]).to eq("reopened")
      expect(entry).not_to have_key(:text)
    end

    it "com pedido pendente, `by` precisa ser um User (ArgumentError; nada gravado)" do
      m = concluded!
      expect(request_reopen(m)).to be_ok
      expect { Ombudsman::Reopen.call(manifestation_id: m.id, expected_state: "answered", text: nil, by: nil, now: now) }
        .to raise_error(ArgumentError)
      expect(m.reload.state).to eq("answered")
      expect(OmbudsmanReopenRequest.sole.state).to eq("pending")
    end

    it "archived (duplicidade) → in_analysis: archive_reason, duplicate_of_id e external_body_name voltam a nulo juntos; texto é opcional" do
      original = open_one!
      dup = concluded!(state: "archived", archive_reason: "duplicate", duplicate_of_id: original.id)
      elsewhere = concluded!(state: "archived", archive_reason: "forwarded_elsewhere", external_body_name: "Secretaria Estadual")
      sign_in_as(ombudsman!)

      [ dup, elsewhere ].each do |m|
        act(m, "reopen", expected_state: "archived")
        expect(response).to have_http_status(:ok)
        expect(m.reload).to have_attributes(state: "in_analysis", archive_reason: nil, duplicate_of_id: nil, external_body_name: nil, cycle: 2)
        expect(events(m).sole.text).to be_nil
      end
    end

    it "estado aberto → 422 invalid_transition; texto fora de 10..4000 → 422 path text; expected_state errado → 409; técnico → 403" do
      open = open_one!
      done = concluded!
      sign_in_as(ombudsman!)

      act(open, "reopen", expected_state: "in_analysis")
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to eq("error" => "invalid_transition")
      [ "curto", "x" * 4001, 7 ].each do |text|
        act(done, "reopen", expected_state: "answered", text: text)
        expect(response).to have_http_status(:unprocessable_content)
        expect(json_body).to include("error" => "invalid_request", "path" => "text")
      end
      act(done, "reopen", expected_state: "archived")
      expect(response).to have_http_status(:conflict)
      expect(done.reload).to have_attributes(state: "answered", cycle: 1)

      sign_in_as(ombudsman_staff!)
      act(done, "reopen", expected_state: "answered")
      expect(response).to have_http_status(:forbidden)
    end

    it "com pedido do cidadão pendente: a reabertura de ofício o aceita junto (nada fica pendente) e avisa o cidadão" do
      m = concluded!
      expect(request_reopen(m)).to be_ok
      sign_in_as(ombudsman!)

      act(m, "reopen", expected_state: "answered")
      expect(response).to have_http_status(:ok)
      expect(json_body["reopen_request"]).to be_nil
      expect(OmbudsmanReopenRequest.where(ombudsman_manifestation_id: m.id).sole)
        .to have_attributes(state: "accepted", decided_by_user_id: ombudsman!.id, cycle: 1)
      expect(notices(m)).to eq([ "reopen_decided" ])
    end
  end

  describe "Ombudsman::RequestReopen e POST /ombudsman/reopen_requests/:id/decide" do
    it "pedido: grava pending do ciclo, evento visível do cidadão; o detalhe mostra o pedido e `decide_reopen`" do
      m = concluded!
      result = request_reopen(m, reason: "  #{reason_text}  ")
      expect(result).to be_ok
      request = result.payload.fetch(:request)
      expect(request).to have_attributes(state: "pending", cycle: 1, reason: reason_text)
      expect(events(m).sole).to have_attributes(kind: "reopen_requested", actor: "citizen", actor_user_id: nil, visible_to_citizen: true)

      sign_in_as(ombudsman!)
      get "/ombudsman/manifestations/#{m.id}"
      expect(json_body.dig("reopen_request", "id")).to eq(request.id)
      expect(json_body.dig("can", "decide_reopen")).to be(true)
    end

    it "janela de 30 dias: no dia 30 vale, no dia 31 → reopen_window_closed (422); motivo fora de 10..2000 → path reason; manifestação aberta → invalid_transition" do
      on_30 = concluded!(concluded_at: now - 30.days)
      on_31 = concluded!(concluded_at: now - 31.days)
      open = open_one!

      expect(request_reopen(on_30)).to be_ok
      closed = request_reopen(on_31)
      expect(closed.reason).to eq(:reopen_window_closed)
      expect(request_reopen(open).reason).to eq(:invalid_transition)
      [ "curto", "x" * 2001, nil ].each do |reason|
        refusal = request_reopen(concluded!, reason: reason)
        expect([ refusal.reason, refusal.details[:path] ]).to eq([ :invalid_request, "reason" ])
      end
      expect(OmbudsmanReopenRequest.where(ombudsman_manifestation_id: on_31.id)).to be_empty
    end

    it "segundo pedido no mesmo ciclo → recusado: pendente → reopen_pending (409), decidido → reopen_already_requested (422)" do
      m = concluded!
      expect(request_reopen(m)).to be_ok
      expect(request_reopen(m).reason).to eq(:reopen_pending)
      sign_in_as(ombudsman!)
      decide(OmbudsmanReopenRequest.sole, decision: "reject", text: decision_text)
      expect(response).to have_http_status(:ok)
      expect(request_reopen(m).reason).to eq(:reopen_already_requested)
      expect(OmbudsmanReopenRequest.count).to eq(1)
    end

    it "aceitar: reabre (ciclo novo, prazo de hoje), pedido accepted, evento reopened e aviso reopen_decided; 200 com o detalhe" do
      m = concluded!(extended: true, suspended_days: 3)
      request = request_reopen(m).payload.fetch(:request)
      sign_in_as(ombudsman!)

      log = capture_log { decide(request, decision: "accept", text: decision_text) }
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => m.id, "state" => "in_analysis", "cycle" => 2, "reopen_request" => nil,
                                   "due_on" => (today + 30).iso8601)
      expect(request.reload).to have_attributes(state: "accepted", decided_by_user_id: ombudsman!.id, decision_text: decision_text)
      expect(request.decided_at).to eq(now)
      expect(m.reload).to have_attributes(state: "in_analysis", cycle: 2, cycle_started_on: today, extended: false, suspended_days: 0,
                                          concluded_at: nil)
      expect(events(m).map(&:kind)).to contain_exactly("reopen_requested", "reopened")
      expect(events(m).find_by(kind: "reopened")).to have_attributes(actor: "staff", visible_to_citizen: true)
      expect(notices(m)).to eq([ "reopen_decided" ])
      expect(DomainEvent.where(name: "ombudsman.reopened").sole.payload).to eq("manifestation_id" => m.id)
      expect(log).not_to include(decision_text)
    end

    it "aceitar um arquivado limpa archive_reason/duplicate_of_id/external_body_name juntos" do
      original = open_one!
      m = concluded!(state: "archived", archive_reason: "duplicate", duplicate_of_id: original.id)
      request = request_reopen(m).payload.fetch(:request)
      sign_in_as(ombudsman!)

      decide(request, decision: "accept", text: decision_text)
      expect(response).to have_http_status(:ok)
      expect(m.reload).to have_attributes(state: "in_analysis", archive_reason: nil, duplicate_of_id: nil, external_body_name: nil)
    end

    it "recusar: manifestação segue concluída, o texto vai à linha do tempo do cidadão (reopen_rejected) e o aviso reopen_decided sai" do
      m = concluded!
      request = request_reopen(m).payload.fetch(:request)
      sign_in_as(ombudsman!)

      decide(request, decision: "reject", text: "  #{decision_text}  ")
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("state" => "answered", "cycle" => 1, "reopen_request" => nil)
      expect(request.reload).to have_attributes(state: "rejected", decision_text: decision_text, decided_by_user_id: ombudsman!.id)
      expect(events(m).find_by(kind: "reopen_rejected")).to have_attributes(kind: "reopen_rejected", actor: "staff", visible_to_citizen: true, text: decision_text)
      expect(notices(m)).to eq([ "reopen_decided" ])
      expect(DomainEvent.where(name: "ombudsman.reopened")).to be_empty

      timeline = Ombudsman::Timeline.citizen(events(m))
      expect(timeline.find { |item| item[:kind] == "reopen_rejected" }).to include(text: decision_text)
    end

    it "decidir de novo → 409 already_decided; decisão inválida ou texto fora de 10..4000 → 422; id inexistente → 404; técnico → 403" do
      m = concluded!
      request = request_reopen(m).payload.fetch(:request)
      sign_in_as(ombudsman!)

      [ { decision: "talvez", text: decision_text }, { decision: "reject", text: "curto" }, { decision: "accept" },
        { decision: "reject", text: "x" * 4001 } ].each do |params|
        decide(request, params)
        expect(response).to have_http_status(:unprocessable_content)
      end
      expect(json_body).to include("error" => "invalid_request", "path" => "text")
      expect(request.reload.state).to eq("pending")

      decide(request, decision: "reject", text: decision_text)
      expect(response).to have_http_status(:ok)
      decide(request, decision: "accept", text: decision_text)
      expect(response).to have_http_status(:conflict)
      expect(json_body).to eq("error" => "already_decided")
      expect(notices(m)).to eq([ "reopen_decided" ])

      json_post("/ombudsman/reopen_requests/#{SecureRandom.uuid}/decide", decision: "reject", text: decision_text)
      expect(response).to have_http_status(:not_found)
      json_post("/ombudsman/reopen_requests/nao-e-uuid/decide", decision: "reject", text: decision_text)
      expect(response).to have_http_status(:not_found)

      sign_in_as(ombudsman_staff!)
      decide(request, decision: "reject", text: decision_text)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
