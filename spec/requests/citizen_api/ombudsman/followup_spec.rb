require "rails_helper"

# Módulo 33, Task 15 (ADR 0051; contrato §3, §10; §16 Q8, Q19, Q40, Q42, Q43,
# Q45): o cidadão responde o complemento, pede a reabertura e responde a
# pesquisa de satisfação pelo wpda. A posse é da sessão (404 nas de outro
# cidadão); os `can_*` do detalhe acompanham cada passo.
RSpec.describe "Ouvidoria — complemento, reabertura e satisfação pelo canal do cidadão", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { ombudsman_city! }
  let!(:citizen) { web_citizen!(cpf: "52998224725", phone: "+5541998765432") }
  let(:base) { "/citizen/ombudsman/manifestations" }
  let(:text) { "Foi na terça-feira passada, por volta das nove horas." }

  before do
    travel_to Time.zone.local(2026, 11, 11, 10, 0)
    sign_in_citizen("+5541998765432")
  end
  after { travel_back }

  def upload(filename: "anexo-1.png")
    json_post "/citizen/ombudsman/attachments", filename: filename, content_type: "image/png", data: png_base64
    json_body.fetch("id")
  end

  def detail(manifestation)
    get "#{base}/#{manifestation.id}"
    json_body
  end

  def waiting!(**over)
    manifestation!(citizen: citizen, state: "awaiting_complement", complement_requested_at: 3.days.ago, complement_used: true, **over)
  end

  def answered!(concluded_at: 2.days.ago, **over)
    manifestation!(citizen: citizen, state: "answered", resolution: "resolved", concluded_at: concluded_at, **over)
  end

  describe "POST …/complement" do
    it "responde com anexo: volta a in_analysis, soma os dias suspensos e fecha o can_complement" do
      manifestation = waiting!
      attachment_id = upload
      json_post "#{base}/#{manifestation.id}/complement", body: "  #{text}  ", attachment_ids: [ attachment_id ]

      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => manifestation.id, "state" => "in_analysis", "can_complement" => false)
      expect(manifestation.reload).to have_attributes(state: "in_analysis", suspended_days: 3, complement_requested_at: nil)
      event = manifestation.events.find_by!(kind: "complement_received")
      expect(event).to have_attributes(actor: "citizen", text: text, visible_to_citizen: true)
      expect(OmbudsmanAttachment.find(attachment_id)).to have_attributes(ombudsman_manifestation_id: manifestation.id, event_id: event.id)
      expect(detail(manifestation)).to include("state" => "in_analysis", "can_complement" => false)
      expect(json_body["attachments"]).to eq([ { "id" => attachment_id } ])
    end

    it "fora de awaiting_complement → 409 manifestation_changed, nada gravado; forwarded nunca aparece" do
      manifestation = manifestation!(citizen: citizen, state: "forwarded")
      json_post "#{base}/#{manifestation.id}/complement", body: text
      expect(response).to have_http_status(:conflict)
      expect(json_body).to eq("error" => "manifestation_changed")
      expect(manifestation.reload.state).to eq("forwarded")
      expect(manifestation.events.count).to eq(0)
      expect(detail(manifestation)["state"]).to eq("in_analysis")
    end

    it "texto curto ou fora do tipo → 422 path body; 4 anexos → 422 too_many_attachments; chave a mais → 422 com o path" do
      manifestation = waiting!
      json_post "#{base}/#{manifestation.id}/complement", body: "curto"
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "body")
      json_post "#{base}/#{manifestation.id}/complement", body: 123
      expect(json_body).to include("path" => "body")
      json_post "#{base}/#{manifestation.id}/complement", body: text, attachment_ids: 4.times.map { upload }
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to eq("error" => "too_many_attachments")
      json_post "#{base}/#{manifestation.id}/complement", body: text, expected_state: "awaiting_complement"
      expect(json_body).to include("error" => "invalid_request", "path" => "expected_state")
      expect(manifestation.reload.state).to eq("awaiting_complement")
    end

    it "anexo de outra sessão → 422 path attachment_ids e nada muda" do
      manifestation = waiting!
      web_citizen!(phone: "+5541911112222")
      sign_in_citizen("+5541911112222")
      foreign_attachment = upload
      sign_in_citizen("+5541998765432")
      json_post "#{base}/#{manifestation.id}/complement", body: text, attachment_ids: [ foreign_attachment ]
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "attachment_ids")
      expect(manifestation.reload.state).to eq("awaiting_complement")
      expect(manifestation.events.count).to eq(0)
    end
  end

  describe "POST …/reopen_request" do
    it "pede a reabertura: 201, evento do cidadão e can_request_reopen fecha" do
      manifestation = answered!
      expect(detail(manifestation)["can_request_reopen"]).to be(true)
      json_post "#{base}/#{manifestation.id}/reopen_request", reason: "  A resposta não resolveu o meu problema.  "

      expect(response).to have_http_status(:created)
      expect(json_body).to include("can_request_reopen" => false, "state" => "answered")
      expect(OmbudsmanReopenRequest.where(ombudsman_manifestation_id: manifestation.id).sole)
        .to have_attributes(state: "pending", cycle: 1, reason: "A resposta não resolveu o meu problema.")
      expect(manifestation.events.find_by!(kind: "reopen_requested")).to have_attributes(actor: "citizen", text: nil)
      json_post "#{base}/#{manifestation.id}/reopen_request", reason: "A resposta não resolveu o meu problema."
      expect(response).to have_http_status(:conflict)
      expect(json_body).to eq("error" => "reopen_pending")
    end

    it "motivo curto → 422 path reason; fora da janela → 422 reopen_window_closed; não final → 422 invalid_transition" do
      json_post "#{base}/#{answered!.id}/reopen_request", reason: "curto"
      expect(json_body).to include("error" => "invalid_request", "path" => "reason")
      json_post "#{base}/#{answered!(concluded_at: 31.days.ago).id}/reopen_request", reason: "A resposta não resolveu o meu problema."
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to eq("error" => "reopen_window_closed")
      json_post "#{base}/#{waiting!.id}/reopen_request", reason: "A resposta não resolveu o meu problema."
      expect(json_body).to eq("error" => "invalid_transition")
    end
  end

  describe "POST …/satisfaction" do
    it "responde uma vez (201); a segunda → 409 already_answered; can_answer_satisfaction fecha" do
      manifestation = answered!
      expect(detail(manifestation)["can_answer_satisfaction"]).to be(true)
      json_post "#{base}/#{manifestation.id}/satisfaction", met: "partly", clear: true, score: 4

      expect(response).to have_http_status(:created)
      expect(json_body).to include("can_answer_satisfaction" => false)
      expect(OmbudsmanSatisfactionResponse.where(ombudsman_manifestation_id: manifestation.id).sole)
        .to have_attributes(met: "partly", clear: true, score: 4)
      json_post "#{base}/#{manifestation.id}/satisfaction", met: "yes", clear: false, score: 1
      expect(response).to have_http_status(:conflict)
      expect(json_body).to eq("error" => "already_answered")
      expect(OmbudsmanSatisfactionResponse.count).to eq(1)
    end

    it "no dia 30 vale; no dia 31 → 422 satisfaction_window_closed" do
      json_post "#{base}/#{answered!(concluded_at: 30.days.ago).id}/satisfaction", met: "yes", clear: true, score: 5
      expect(response).to have_http_status(:created)
      json_post "#{base}/#{answered!(concluded_at: 31.days.ago).id}/satisfaction", met: "yes", clear: true, score: 5
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to eq("error" => "satisfaction_window_closed")
    end

    it "preservada com citizen_id também responde; fora de answered → 422 invalid_transition" do
      json_post "#{base}/#{answered!(identification_mode: 'preserved').id}/satisfaction", met: "no", clear: false, score: 1
      expect(response).to have_http_status(:created)
      archived = manifestation!(citizen: citizen, state: "archived", archive_reason: "improper", concluded_at: 1.day.ago)
      json_post "#{base}/#{archived.id}/satisfaction", met: "no", clear: false, score: 1
      expect(json_body).to eq("error" => "invalid_transition")
    end

    it "forma inválida → 422 com o path; texto livre (chave a mais) → 422; nada gravado" do
      id = answered!.id
      {
        { met: "maybe", clear: true, score: 3 } => "met", { met: "yes", clear: "sim", score: 3 } => "clear",
        { met: "yes", clear: true, score: 0 } => "score", { met: "yes", clear: true, score: 6 } => "score",
        { met: "yes", clear: true, score: "3" } => "score", { met: "yes", clear: true, score: 3.5 } => "score",
        { clear: true, score: 3 } => "met", { met: "yes", clear: true, score: 3, comment: "ótimo" } => "comment"
      }.each do |params, path|
        json_post "#{base}/#{id}/satisfaction", params
        expect(response).to have_http_status(:unprocessable_content)
        expect(json_body).to include("error" => "invalid_request", "path" => path)
      end
      expect(OmbudsmanSatisfactionResponse.count).to eq(0)
    end

    # A corrida perdida: a conferência sob a trava não viu a resposta da outra
    # sessão (`exists?` falso), e o INSERT bate no índice único — o
    # RecordNotUnique vira o mesmo 409, sem segunda linha.
    it "o índice único é a última palavra: corrida perdida → 409 already_answered" do
      manifestation = answered!
      OmbudsmanSatisfactionResponse.create!(ombudsman_manifestation: manifestation, met: "yes", clear: true, score: 5)
      allow(OmbudsmanSatisfactionResponse).to receive(:exists?).and_return(false)
      json_post "#{base}/#{manifestation.id}/satisfaction", met: "no", clear: false, score: 1
      expect(response).to have_http_status(:conflict)
      expect(json_body).to eq("error" => "already_answered")
      expect(OmbudsmanSatisfactionResponse).to have_received(:exists?)
      expect(OmbudsmanSatisfactionResponse.where(ombudsman_manifestation_id: manifestation.id).count).to eq(1)
    end

    it "depois da exclusão LGPD (citizen_id nulo) a resposta fica e a manifestação some da sessão: 404" do
      manifestation = answered!
      json_post "#{base}/#{manifestation.id}/satisfaction", met: "yes", clear: true, score: 5
      manifestation.update_columns(citizen_id: nil)
      json_post "#{base}/#{manifestation.id}/satisfaction", met: "yes", clear: true, score: 5
      expect(response).to have_http_status(:not_found)
      expect(OmbudsmanSatisfactionResponse.count).to eq(1)
    end
  end

  describe "posse, sessão e limites" do
    it "manifestação de outro cidadão, anônima, inexistente ou id inválido → 404 nas três rotas" do
      other = web_citizen!(phone: "+5541911112222")
      foreign = manifestation!(citizen: other, state: "awaiting_complement", complement_requested_at: 1.day.ago)
      anonymous = manifestation!(citizen: nil, kind: "report", identification_mode: "anonymous", state: "answered", concluded_at: 1.day.ago)
      [ foreign.id, anonymous.id, SecureRandom.uuid, "x" ].each do |id|
        json_post "#{base}/#{id}/complement", body: text
        expect(response).to have_http_status(:not_found)
        json_post "#{base}/#{id}/reopen_request", reason: text
        expect(response).to have_http_status(:not_found)
        json_post "#{base}/#{id}/satisfaction", met: "yes", clear: true, score: 5
        expect(response).to have_http_status(:not_found)
        expect(json_body).to eq("error" => "not_found")
      end
      expect(foreign.reload.state).to eq("awaiting_complement")
    end

    it "query na URL → 422; sem sessão → 401; sem o interruptor → 403" do
      manifestation = answered!
      post "#{base}/#{manifestation.id}/satisfaction?score=1", params: { met: "yes", clear: true, score: 5 }.to_json,
                                                              headers: { "CONTENT_TYPE" => "application/json" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("path" => "score")

      Platform::Features.set!(city: city, key: Ombudsman::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
      CityCatalog.reset_cache!
      json_post "#{base}/#{manifestation.id}/satisfaction", met: "yes", clear: true, score: 5
      expect(response).to have_http_status(:forbidden)
    end

    it "o 31º envio do dia → 429 too_many_requests; o limite é da sessão" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      manifestation = answered!
      30.times do
        json_post "#{base}/#{manifestation.id}/reopen_request", reason: "curto"
        expect(response).to have_http_status(:unprocessable_content)
      end
      json_post "#{base}/#{manifestation.id}/reopen_request", reason: "curto"
      expect(response).to have_http_status(:too_many_requests)
      expect(json_body).to eq("error" => "too_many_requests")
    end

    it "a resposta nunca leva o texto de volta em log" do
      manifestation = waiting!
      log = StringIO.new
      capture = ActiveSupport::Logger.new(log).tap { |l| l.level = Logger::DEBUG }
      Rails.logger.broadcast_to(capture)
      json_post "#{base}/#{manifestation.id}/complement", body: text
      Rails.logger.stop_broadcasting_to(capture)
      expect(log.string).not_to include(text)
    end
  end
end
