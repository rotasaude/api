require "rails_helper"

# Módulo 33, Task 13 (ADR 0051; contrato §2, §9; §16 Q8, Q17, Q25, Q32;
# preflight F-8, F-10): complemento (pedido e registro pela equipe),
# prorrogação, resposta intermediária, conclusiva e mudança de resolutividade.
# - Toda ação responde 200 com o detalhe atualizado (Q32).
# - Textos em TEXT (10..4000), sem as bordas, em code points (Q8, F-8).
# - Complemento uma vez por ciclo, nunca na anônima; na volta,
#   `suspended_days += dias corridos LOCAIS entre o pedido e a resposta` e
#   `complement_requested_at` volta a nulo (Q25).
# - Prorrogação uma vez por ciclo (ouvidor); a justificativa vai ao cidadão
#   como resposta intermediária (aviso `interim_response`).
# - Conclusiva: resolutividade obrigatória em reclamação/solicitação/denúncia
#   e proibida nos outros; com encaminhamento pendente → 422
#   forwarding_pending (F-10); na anônima o texto fica interno.
# - Nenhum texto em log nem em payload de evento.
RSpec.describe "Ouvidoria — complemento, prorrogação e respostas", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { ombudsman_city! }
  let(:technician) { ombudsman_staff! }
  let(:now) { Time.utc(2026, 11, 11, 15) } # 12h em Brasília
  let(:today) { now.in_time_zone("America/Sao_Paulo").to_date }
  let(:citizen) { web_citizen! }
  let(:text) { "Pedimos que informe o dia e o horário do atendimento." }
  let(:answer) { "A coordenação da unidade revisou a escala e o caso foi resolvido." }

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

  def in_analysis!(**attrs) = raw_manifestation!(citizen: citizen, state: "in_analysis", subject: subject_leaf!, **attrs)
  def anonymous!(**attrs) = raw_manifestation!(kind: "report", identification_mode: "anonymous", state: "in_analysis", **attrs)
  def notices(m) = OmbudsmanNotice.where(ombudsman_manifestation_id: m.id).pluck(:kind)
  def events(m) = OmbudsmanEvent.where(ombudsman_manifestation: m).order(:created_at, :id)
  def raw_column(m, column)
    OmbudsmanManifestation.connection.select_value(
      OmbudsmanManifestation.sanitize_sql_array([ "SELECT #{column} FROM ombudsman_manifestations WHERE id = ?", m.id ])
    )
  end

  def instant(value) = value && Time.iso8601(value)

  describe "POST .../request_complement e .../complement" do
    it "pede o complemento: awaiting_complement, prazo `paused`, evento visível com o texto e aviso ao cidadão; segundo pedido no ciclo → 422" do
      m = in_analysis!
      sign_in_as(technician)

      log = capture_log { act(m, "request_complement", expected_state: "in_analysis", text: "  #{text}  ") }
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => m.id, "state" => "awaiting_complement", "color" => "paused", "complement_used" => true,
                                   "due_on" => (today + 30).iso8601, "complement_due_on" => (today + 20).iso8601)
      expect(instant(json_body["complement_requested_at"])).to eq(now)
      expect(json_body.keys).to include("events", "forwardings", "can")
      expect(m.reload).to have_attributes(state: "awaiting_complement", complement_used: true, complement_requested_at: now)
      event = events(m).sole
      expect(event).to have_attributes(kind: "complement_requested", actor: "staff", actor_user_id: technician.id,
                                       visible_to_citizen: true, text: text, data: {})
      expect(notices(m)).to eq([ "complement_requested" ])
      expect(log).not_to include(text)

      # volta pelo registro da equipe e pede de novo no mesmo ciclo
      act(m, "complement", expected_state: "awaiting_complement", text: "O atendimento foi na terça, às 9h.")
      expect(response).to have_http_status(:ok)
      act(m, "request_complement", expected_state: "in_analysis", text: text)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to eq("error" => "complement_already_used")
      expect(m.reload.state).to eq("in_analysis")
      expect(events(m).pluck(:kind)).to contain_exactly("complement_requested", "complement_received") # relógio parado: empate
      expect(notices(m)).to eq([ "complement_requested" ])
    end

    it "na anônima → 422 complement_not_allowed, nada gravado" do
      m = anonymous!
      sign_in_as(technician)

      act(m, "request_complement", expected_state: "in_analysis", text: text)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to eq("error" => "complement_not_allowed")
      expect(m.reload).to have_attributes(state: "in_analysis", complement_used: false, complement_requested_at: nil)
      expect(events(m)).to be_empty
    end

    it "registro pela equipe 6 dias depois: in_analysis, suspended_days 6, due_on +6, complement_requested_at nulo, anexo ligado ao evento; sem aviso" do
      m = in_analysis!
      sign_in_as(technician)
      act(m, "request_complement", expected_state: "in_analysis", text: text)
      expect(response).to have_http_status(:ok)

      travel_to(now + 6.days)
      attachment = Ombudsman::Attachments.upload(data: png_base64, content_type: "image/png", filename: "anexo-1.png", user: technician)
                                         .payload.fetch(:attachment)
      complement = "O atendimento foi na terça-feira, às 9h, na recepção."
      log = capture_log do
        act(m, "complement", expected_state: "awaiting_complement", text: "  #{complement}  ", attachment_ids: [ attachment.id ])
      end
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("state" => "in_analysis", "due_on" => (today + 36).iso8601, "complement_requested_at" => nil,
                                   "complement_due_on" => nil, "complement_used" => true)
      expect(json_body["color"]).not_to eq("paused")
      expect(json_body.fetch("attachments").map { |a| a["id"] }).to eq([ attachment.id ])
      expect(m.reload).to have_attributes(state: "in_analysis", suspended_days: 6, complement_requested_at: nil)

      received = events(m).find_by!(kind: "complement_received")
      expect(received).to have_attributes(actor: "staff", actor_user_id: technician.id, visible_to_citizen: true, text: complement)
      expect(attachment.reload).to have_attributes(ombudsman_manifestation_id: m.id, event_id: received.id)
      expect(ExamFile.find(attachment.exam_file_id).consumed_at).to be_present
      expect(notices(m)).to eq([ "complement_requested" ])
      expect(log).not_to include(complement)
    end

    it "dias corridos LOCAIS (Review Focus 4): pedido às 20h e resposta às 22h do mesmo dia local (dias diferentes em UTC) → 0; pedido às 23h e resposta à 0h10 → 1" do
      sign_in_as(technician)

      same_day = in_analysis!
      travel_to(Time.utc(2026, 11, 11, 23)) # 20h locais
      act(same_day, "request_complement", expected_state: "in_analysis", text: text)
      travel_to(Time.utc(2026, 11, 12, 1)) # 22h locais do dia 11
      act(same_day, "complement", expected_state: "awaiting_complement", text: "Foi na unidade do centro.")
      expect(response).to have_http_status(:ok)
      expect(same_day.reload).to have_attributes(state: "in_analysis", suspended_days: 0)

      next_day = in_analysis!
      travel_to(Time.utc(2026, 11, 13, 2)) # 23h locais do dia 12
      act(next_day, "request_complement", expected_state: "in_analysis", text: text)
      travel_to(Time.utc(2026, 11, 13, 3, 10)) # 0h10 locais do dia 13
      act(next_day, "complement", expected_state: "awaiting_complement", text: "Foi na unidade do centro.")
      expect(response).to have_http_status(:ok)
      expect(next_day.reload).to have_attributes(state: "in_analysis", suspended_days: 1)
    end

    it "resposta no último dia do complemento: volta a in_analysis com os 20 dias suspensos e sai do que o job arquiva (Review Focus 4)" do
      m = in_analysis!
      sign_in_as(technician)
      act(m, "request_complement", expected_state: "in_analysis", text: text)
      expect(json_body["complement_due_on"]).to eq((today + 20).iso8601)

      travel_to(now + 20.days)
      act(m, "complement", expected_state: "awaiting_complement", text: "Seguem os dados pedidos.")
      expect(response).to have_http_status(:ok)
      expect(m.reload).to have_attributes(state: "in_analysis", suspended_days: 20, complement_requested_at: nil)
      expect(json_body).to include("due_on" => (today + 50).iso8601, "complement_due_on" => nil)
      expect(OmbudsmanManifestation.where(state: "awaiting_complement")).not_to exist
    end

    it "recusas do complemento: fora de awaiting_complement, expected_state velho, texto curto, anexo de outro dono; nada gravado" do
      m = in_analysis!
      sign_in_as(technician)

      act(m, "complement", expected_state: "in_analysis", text: "Seguem os dados pedidos.")
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to eq("error" => "invalid_transition")
      act(m, "complement", expected_state: "awaiting_complement", text: "Seguem os dados pedidos.")
      expect(response).to have_http_status(:conflict)
      expect(json_body).to eq("error" => "manifestation_changed")

      act(m, "request_complement", expected_state: "in_analysis", text: text)
      foreign = raw_attachment!(uploaded_by: "staff")
      act(m, "complement", expected_state: "awaiting_complement", text: "Seguem os dados pedidos.", attachment_ids: [ foreign.id ])
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "attachment_ids")
      act(m, "complement", expected_state: "awaiting_complement", text: "  curtinho ")
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "text")

      expect(m.reload).to have_attributes(state: "awaiting_complement", suspended_days: 0, complement_requested_at: now)
      expect(events(m).pluck(:kind)).to eq(%w[complement_requested])
      expect(foreign.reload.ombudsman_manifestation_id).to be_nil
    end
  end

  describe "POST .../extend" do
    it "o ouvidor prorroga: +30 no prazo, motivo cifrado, evento `extended` visível com o texto, aviso interim_response; a segunda → 422" do
      m = in_analysis!
      sign_in_as(ombudsman!)
      reason = "A unidade pediu mais prazo para ouvir a equipe do turno."

      log = capture_log { act(m, "extend", expected_state: "in_analysis", text: "  #{reason}  ") }
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("state" => "in_analysis", "extended" => true, "extension_reason" => reason,
                                   "due_on" => (today + 60).iso8601)
      expect(m.reload).to have_attributes(extended: true, extension_reason: reason)
      expect(raw_column(m, "extension_reason")).not_to include(reason)
      expect(events(m).sole).to have_attributes(kind: "extended", actor: "staff", actor_user_id: ombudsman!.id,
                                                visible_to_citizen: true, text: reason)
      expect(notices(m)).to eq([ "interim_response" ])
      expect(log).not_to include(reason)

      act(m, "extend", expected_state: "in_analysis", text: reason)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to eq("error" => "already_extended")
      expect(events(m).count).to eq(1)
      expect(notices(m)).to eq([ "interim_response" ])
    end

    it "prorroga também em forwarded e awaiting_complement; de received → 422 invalid_transition; o técnico → 403" do
      reason = "A unidade pediu mais prazo para ouvir a equipe do turno."
      waiting = in_analysis!(state: "awaiting_complement", complement_used: true, complement_requested_at: now)
      forwarded = in_analysis!(state: "forwarded")
      received = raw_manifestation!(citizen: citizen)

      sign_in_as(technician)
      act(waiting, "extend", expected_state: "awaiting_complement", text: reason)
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "missing_role")
      expect(waiting.reload.extended).to be(false)

      sign_in_as(ombudsman!)
      act(waiting, "extend", expected_state: "awaiting_complement", text: reason)
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("state" => "awaiting_complement", "extended" => true, "color" => "paused")
      act(forwarded, "extend", expected_state: "forwarded", text: reason)
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("state" => "forwarded", "extended" => true)
      act(received, "extend", expected_state: "received", text: reason)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to eq("error" => "invalid_transition")
      expect(received.reload.extended).to be(false)
    end
  end

  describe "POST .../interim_response" do
    it "texto ao cidadão sem mexer no prazo: evento visível e aviso interim_response; em qualquer estado aberto" do
      m = in_analysis!(state: "forwarded")
      sign_in_as(technician)
      interim = "Seu caso foi encaminhado à unidade e aguardamos o retorno."

      act(m, "interim_response", expected_state: "forwarded", text: interim)
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("state" => "forwarded", "due_on" => (today + 30).iso8601, "extended" => false)
      expect(m.reload).to have_attributes(state: "forwarded", extended: false, suspended_days: 0)
      expect(events(m).sole).to have_attributes(kind: "interim_response", actor: "staff", actor_user_id: technician.id,
                                                visible_to_citizen: true, text: interim)
      expect(notices(m)).to eq([ "interim_response" ])
    end

    it "na anônima → 422 not_allowed_anonymous; em estado final → 422 invalid_transition; nada gravado" do
      anonymous = anonymous!
      answered = in_analysis!(state: "answered", resolution: "resolved", concluded_at: now)
      sign_in_as(technician)

      act(anonymous, "interim_response", expected_state: "in_analysis", text: answer)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to eq("error" => "not_allowed_anonymous")
      act(answered, "interim_response", expected_state: "answered", text: answer)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to eq("error" => "invalid_transition")
      expect(OmbudsmanEvent.where(ombudsman_manifestation_id: [ anonymous.id, answered.id ])).to be_empty
      expect(OmbudsmanNotice.count).to eq(0)
    end
  end

  describe "POST .../final_response" do
    it "conclusiva de reclamação: answered, concluded_at, resolução, evento visível, aviso e ombudsman.concluded só com id e outcome" do
      m = in_analysis!
      sign_in_as(technician)

      log = capture_log { act(m, "final_response", expected_state: "in_analysis", text: "  #{answer}  ", resolution: "resolved") }
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("state" => "answered", "resolution" => "resolved", "color" => nil)
      expect(instant(json_body["concluded_at"])).to eq(now)
      expect(m.reload).to have_attributes(state: "answered", resolution: "resolved", concluded_at: now)
      event = events(m).sole
      expect(event).to have_attributes(kind: "final_response", actor: "staff", actor_user_id: technician.id,
                                       visible_to_citizen: true, text: answer, data: { "resolution" => "resolved" })
      expect(notices(m)).to eq([ "final_response" ])
      expect(DomainEvent.where(name: "ombudsman.concluded").sole.payload).to eq("manifestation_id" => m.id, "outcome" => "answered")
      expect(log).not_to include(answer)
    end

    it "resolutividade: reclamação sem → 422 path resolution; elogio com → 422; valor fora da lista → 422; elogio sem → answered" do
      complaint = in_analysis!
      praise = in_analysis!(kind: "praise")
      sign_in_as(technician)

      [ [ complaint, nil ], [ complaint, "talvez" ], [ praise, "resolved" ] ].each do |m, resolution|
        act(m, "final_response", { expected_state: "in_analysis", text: answer, resolution: resolution }.compact)
        expect(response).to have_http_status(:unprocessable_content)
        expect(json_body).to include("error" => "invalid_request", "path" => "resolution")
      end
      expect(complaint.reload.state).to eq("in_analysis")
      expect(OmbudsmanEvent.where(ombudsman_manifestation_id: [ complaint.id, praise.id ])).to be_empty

      act(praise, "final_response", expected_state: "in_analysis", text: "Agradecemos o elogio à equipe da unidade.")
      expect(response).to have_http_status(:ok)
      expect(praise.reload).to have_attributes(state: "answered", resolution: nil)
      expect(events(praise).sole.data).to eq({})
    end

    it "com encaminhamento pendente (estado forwarded) → 422 forwarding_pending (F-10); de received → 422 invalid_transition; nada gravado" do
      m = in_analysis!(state: "forwarded")
      department = department!("Atenção Especializada")
      OmbudsmanForwarding.create!(ombudsman_manifestation: m, department: department, state: "pending", created_by_user: technician,
                                  extract: "Extrato do caso para a atenção especializada.", due_on: today + 20)
      received = raw_manifestation!(citizen: citizen)
      sign_in_as(technician)

      act(m, "final_response", expected_state: "forwarded", text: answer, resolution: "resolved")
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to eq("error" => "forwarding_pending")
      act(received, "final_response", expected_state: "received", text: answer, resolution: "resolved")
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to eq("error" => "invalid_transition")
      act(m, "final_response", expected_state: "in_analysis", text: answer, resolution: "resolved")
      expect(response).to have_http_status(:conflict)
      expect(json_body).to eq("error" => "manifestation_changed")

      expect(m.reload).to have_attributes(state: "forwarded", concluded_at: nil)
      expect(OmbudsmanEvent.where(ombudsman_manifestation_id: [ m.id, received.id ])).to be_empty
      expect(OmbudsmanNotice.count).to eq(0)
      expect(DomainEvent.where(name: "ombudsman.concluded")).to be_empty
    end

    it "na anônima a conclusiva fica interna: evento visible_to_citizen false, sem aviso; ombudsman.concluded sai" do
      m = anonymous!
      sign_in_as(technician)

      act(m, "final_response", expected_state: "in_analysis", text: answer, resolution: "not_resolved")
      expect(response).to have_http_status(:ok)
      expect(m.reload).to have_attributes(state: "answered", resolution: "not_resolved")
      expect(events(m).sole).to have_attributes(kind: "final_response", visible_to_citizen: false, text: answer)
      expect(OmbudsmanNotice.count).to eq(0)
      expect(DomainEvent.where(name: "ombudsman.concluded").sole.payload).to eq("manifestation_id" => m.id, "outcome" => "answered")
    end
  end

  describe "POST .../change_resolution" do
    it "o ouvidor muda a resolutividade de uma respondida: evento interno resolution_changed com o antes e o depois; o técnico → 403" do
      m = in_analysis!(state: "answered", resolution: "resolved", concluded_at: now)
      justification = "A cidadã voltou a relatar o mesmo problema na unidade."

      sign_in_as(technician)
      act(m, "change_resolution", expected_state: "answered", resolution: "not_resolved", text: justification)
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "missing_role")
      expect(m.reload.resolution).to eq("resolved")

      sign_in_as(ombudsman!)
      log = capture_log { act(m, "change_resolution", expected_state: "answered", resolution: "not_resolved", text: justification) }
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("state" => "answered", "resolution" => "not_resolved")
      expect(m.reload).to have_attributes(state: "answered", resolution: "not_resolved", concluded_at: now)
      expect(events(m).sole).to have_attributes(kind: "resolution_changed", actor: "staff", actor_user_id: ombudsman!.id,
                                                visible_to_citizen: false, text: justification,
                                                data: { "changes" => { "resolution" => %w[resolved not_resolved] } })
      expect(OmbudsmanNotice.count).to eq(0)
      expect(log).not_to include(justification)
    end

    it "recusas: fora de answered, sem justificativa, resolução fora da lista, elogio (sem resolutividade); nada gravado" do
      open = in_analysis!
      praise = in_analysis!(kind: "praise", state: "answered", concluded_at: now)
      answered = in_analysis!(state: "answered", resolution: "resolved", concluded_at: now)
      justification = "A cidadã voltou a relatar o mesmo problema na unidade."
      sign_in_as(ombudsman!)

      act(open, "change_resolution", expected_state: "in_analysis", resolution: "resolved", text: justification)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to eq("error" => "invalid_transition")
      {
        [ answered, { resolution: "not_resolved" } ] => "text",
        [ answered, { resolution: "talvez", text: justification } ] => "resolution",
        [ answered, { text: justification } ] => "resolution",
        [ praise, { resolution: "resolved", text: justification } ] => "resolution"
      }.each do |(m, params), path|
        act(m, "change_resolution", { expected_state: "answered" }.merge(params))
        expect(response).to have_http_status(:unprocessable_content)
        expect(json_body).to include("error" => "invalid_request", "path" => path)
      end
      expect(answered.reload.resolution).to eq("resolved")
      expect(OmbudsmanEvent.where(ombudsman_manifestation_id: [ open.id, praise.id, answered.id ])).to be_empty
    end
  end

  describe "regras comuns" do
    let(:actions) do
      {
        "request_complement" => [ technician, "in_analysis", {} ],
        "complement" => [ technician, "awaiting_complement", {} ],
        "extend" => [ ombudsman!, "in_analysis", {} ],
        "interim_response" => [ technician, "in_analysis", {} ],
        "final_response" => [ technician, "in_analysis", { resolution: "resolved" } ],
        "change_resolution" => [ ombudsman!, "answered", { resolution: "not_resolved" } ]
      }
    end

    it "texto em 10..4000 code points depois do strip (Q8): 9 → 422 path text; 4001 → 422; 10 com bordas → aceito e gravado sem elas" do
      actions.each do |action, (user, state, extra)|
        m = in_analysis!(state: state, complement_requested_at: (now if state == "awaiting_complement"),
                         complement_used: state == "awaiting_complement", resolution: ("resolved" if state == "answered"))
        sign_in_as(user)
        [ "  #{'á' * 9}  ", "x" * 4001, nil, 42 ].each do |value|
          act(m, action, { expected_state: state, text: value }.merge(extra))
          expect(response).to have_http_status(:unprocessable_content), action
          expect(json_body).to include("error" => "invalid_request", "path" => "text"), action
        end
        expect(OmbudsmanEvent.where(ombudsman_manifestation: m)).to be_empty

        act(m, action, { expected_state: state, text: "  #{'á' * 10}  " }.merge(extra))
        expect(response).to have_http_status(:ok), action
        expect(OmbudsmanEvent.where(ombudsman_manifestation: m).sole.text).to eq("á" * 10)
      end
    end

    it "chave desconhecida no corpo ou na query → 422 com o nome; expected_state ausente → 422 path; id malformado → 404; o respondente → 403" do
      m = in_analysis!
      responder = responder!(department!("Setor Respondente"))
      sign_in_as(ombudsman!)

      actions.each do |action, (_, _, extra)|
        act(m, action, expected_state: "in_analysis", text: answer, outro: "x")
        expect(response).to have_http_status(:unprocessable_content), action
        expect(json_body).to include("error" => "invalid_request", "path" => "outro"), action
        post "/ombudsman/manifestations/#{m.id}/#{action}?text=x", params: { expected_state: "in_analysis" }.to_json,
                                                                    headers: { "CONTENT_TYPE" => "application/json" }
        expect(response).to have_http_status(:unprocessable_content), action
        expect(json_body).to include("path" => "text"), action
        act(m, action, { text: answer }.merge(extra))
        expect(response).to have_http_status(:unprocessable_content), action
        expect(json_body).to include("error" => "invalid_request", "path" => "expected_state"), action
        json_post("/ombudsman/manifestations/x/#{action}", { expected_state: "in_analysis", text: answer }.merge(extra))
        expect(response).to have_http_status(:not_found), action
        json_post("/ombudsman/manifestations/#{SecureRandom.uuid}/#{action}", { expected_state: "in_analysis", text: answer }.merge(extra))
        expect(response).to have_http_status(:not_found), action
      end

      sign_in_as(responder)
      actions.each_key do |action|
        act(m, action, expected_state: "in_analysis", text: answer)
        expect(response).to have_http_status(:forbidden), action
      end
      expect(OmbudsmanEvent.where(ombudsman_manifestation: m)).to be_empty
    end
  end
end
