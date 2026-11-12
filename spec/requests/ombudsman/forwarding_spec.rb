require "rails_helper"

# Módulo 33, Task 12 (ADR 0051; contrato §2, §6; §16 Q8, Q9, Q23, Q32, Q33,
# Q34, Q48; preflight F-11, F-20): classificar, encaminhar por extrato,
# cancelar o encaminhamento e o ponto de resposta.
# - As ações da equipe (`classify`, `forward`, `/forwardings/:id/cancel`)
#   respondem 200 com o detalhe atualizado (Q32).
# - As do respondente (`/inbox/:id/reply|decline|extend`) respondem 200 com o
#   item atualizado do inbox, nunca o detalhe (Q48).
# - `cancel` e as do respondente levam o `expected_state` do ENCAMINHAMENTO
#   (Q33): diferente do atual → 409 forwarding_changed; igual mas fora de
#   pending → 422 invalid_transition.
# - O inbox nunca traz protocolo, identidade, texto original, assunto nem
#   anexos; o respondente sem ombudsman_staff não lê nada do §5 (403).
RSpec.describe "Ouvidoria — classificar, encaminhar e o ponto de resposta", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { ombudsman_city! }
  let(:technician) { ombudsman_staff! }
  let(:now) { Time.utc(2026, 11, 11, 15) }
  let(:today) { now.in_time_zone("America/Sao_Paulo").to_date }
  let(:extract) { "Cidadã relata espera de três horas na recepção da unidade." }
  let(:reply_text) { "A escala da recepção foi revista e o caso será acompanhado." }
  let(:department) { department!("Atenção Primária") }
  let(:unit) { HealthUnit.create!(name: "UBS Encaminhada", kind: "ubs") }
  let!(:dept_responder) { responder!(department) }
  let!(:unit_responder) { responder!(unit) }

  around { |example| travel_to(Time.utc(2026, 11, 11, 15)) { example.run } }

  def act(m, action, params) = json_post("/ombudsman/manifestations/#{m.id}/#{action}", params)
  def classify(m, params) = act(m, "classify", params)
  def forward(m, params) = act(m, "forward", params)
  def cancel(f, params) = json_post("/ombudsman/forwardings/#{f.id}/cancel", params)
  def respond_to_forwarding(f, action, params) = json_post("/ombudsman/inbox/#{f.id}/#{action}", params)

  def in_analysis! = raw_manifestation!(state: "in_analysis", subject: subject_leaf!)

  # Encaminhamento gravado direto (o caminho real é o forward, exercitado abaixo).
  def raw_forwarding!(m, destination, state: "pending", created_at: now, **attrs)
    key = destination.is_a?(Department) ? :department : :health_unit
    reply = %w[replied declined].include?(state) ? reply_text : nil
    OmbudsmanForwarding.create!({ ombudsman_manifestation: m, key => destination, extract: extract, state: state, reply: reply,
                                  due_on: today + 20, created_by_user: technician, created_at: created_at }.merge(attrs))
  end

  def forwarded!(*destinations)
    m = raw_manifestation!(state: "forwarded", subject: subject_leaf!)
    [ m, *destinations.map { |d| raw_forwarding!(m, d) } ]
  end

  describe "POST /ombudsman/manifestations/:id/classify" do
    it "classifica e reclassifica: received → in_analysis, um evento `classified` por ação com o antes e o depois; 200 com o detalhe" do
      leaf = subject_leaf!
      other = OmbudsmanSubject.where(active: true).where.not(parent_id: nil).where.not(id: leaf.id).order(:position, :id).first!
      ubs = HealthUnit.create!(name: "UBS Classificada", kind: "ubs")
      doctor = staff_with("medico-ouv-#{SecureRandom.hex(3)}@cidade.gov.br", "health_professional")
      link_professional!(doctor, ubs)
      m = raw_manifestation!
      sign_in_as(technician)

      classify(m, expected_state: "received", subject_id: leaf.id, kind: "request", health_unit_id: ubs.id,
                  professional_id: doctor.professional.id, urgent: true)
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => m.id, "state" => "in_analysis", "kind" => "request", "urgent" => true)
      expect(json_body.keys).to include("can", "events", "forwardings", "body")
      expect(json_body.dig("subject", "id")).to eq(leaf.id)
      expect(json_body.dig("health_unit", "id")).to eq(ubs.id)
      expect(json_body.dig("referred_professional", "id")).to eq(doctor.professional.id)

      classify(m, expected_state: "in_analysis", subject_id: other.id)
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("state" => "in_analysis", "kind" => "request")
      expect(json_body.dig("subject", "id")).to eq(other.id)
      classify(m, expected_state: "in_analysis", subject_id: other.id, kind: "request") # nada muda: nada gravado
      expect(response).to have_http_status(:ok)

      # o relógio está parado (os dois no mesmo instante): a 1ª é a que sai de assunto nulo
      events = OmbudsmanEvent.where(ombudsman_manifestation: m, kind: "classified").to_a
        .sort_by { |e| e.data.dig("changes", "subject_id", 0).nil? ? 0 : 1 }
      expect(events.size).to eq(2)
      expect(events.first).to have_attributes(actor: "staff", actor_user_id: technician.id, visible_to_citizen: false, text: nil)
      expect(events.first.data).to eq("changes" => { "subject_id" => [ nil, leaf.id ], "kind" => %w[complaint request],
                                                     "health_unit_id" => [ nil, ubs.id ],
                                                     "professional_id" => [ nil, doctor.professional.id ], "urgent" => [ false, true ] })
      expect(events.last.data).to eq("changes" => { "subject_id" => [ leaf.id, other.id ] })
      expect(m.reload).to have_attributes(state: "in_analysis", subject_id: other.id, kind: "request", urgent: true)
    end

    it "assunto com filho → 422 subject_not_leaf; inativo ou desconhecido → 422 path subject_id; nada gravado" do
      parent = OmbudsmanSubject.ensure_defaults! && OmbudsmanSubject.where(parent_id: nil).joins(:children).first!
      inactive = subject_leaf!.tap { |s| s.update!(active: false) }
      m = raw_manifestation!
      sign_in_as(technician)

      classify(m, expected_state: "received", subject_id: parent.id)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "subject_not_leaf", "path" => "subject_id")
      [ inactive.id, SecureRandom.uuid, "x", nil ].each do |value|
        classify(m, expected_state: "received", subject_id: value)
        expect(response).to have_http_status(:unprocessable_content)
        expect(json_body).to include("error" => "invalid_request", "path" => "subject_id")
      end
      expect(m.reload.state).to eq("received")
      expect(OmbudsmanEvent.where(ombudsman_manifestation: m)).to be_empty
    end

    it "a anônima continua `report`: outro tipo → 422 path kind; unidade, profissional e urgent inválidos → 422 com o path" do
      anonymous = raw_manifestation!(kind: "report", identification_mode: "anonymous")
      sign_in_as(technician)

      classify(anonymous, expected_state: "received", subject_id: subject_leaf!.id, kind: "complaint")
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "kind")
      {
        { kind: "outro" } => "kind", { health_unit_id: SecureRandom.uuid } => "health_unit_id",
        { professional_id: SecureRandom.uuid } => "professional_id", { urgent: "true" } => "urgent", { urgent: nil } => "urgent"
      }.each do |extra, path|
        classify(anonymous, { expected_state: "received", subject_id: subject_leaf!.id }.merge(extra))
        expect(json_body).to include("error" => "invalid_request", "path" => path), path
      end
      classify(anonymous, expected_state: "received", subject_id: subject_leaf!.id, kind: "report")
      expect(response).to have_http_status(:ok)
      expect(anonymous.reload).to have_attributes(state: "in_analysis", kind: "report")
    end

    it "expected_state: ausente → 422 path; outro → 409 manifestation_changed; fora da tabela → 422 invalid_transition; chave desconhecida → 422" do
      m = raw_manifestation!
      forwarded, = forwarded!(department)
      sign_in_as(technician)

      classify(m, subject_id: subject_leaf!.id)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "expected_state")
      classify(m, expected_state: "in_analysis", subject_id: subject_leaf!.id)
      expect(response).to have_http_status(:conflict)
      expect(json_body).to eq("error" => "manifestation_changed")
      classify(forwarded, expected_state: "forwarded", subject_id: subject_leaf!.id)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_transition")
      classify(m, expected_state: "received", subject_id: subject_leaf!.id, body: "outro texto da manifestação")
      expect(json_body).to include("error" => "invalid_request", "path" => "body")
      post "/ombudsman/manifestations/#{m.id}/classify?subject_id=#{subject_leaf!.id}", params: { expected_state: "received" }.to_json,
                                                                                         headers: { "CONTENT_TYPE" => "application/json" }
      expect(json_body).to include("path" => "subject_id")
      expect(m.reload.state).to eq("received")
      expect(OmbudsmanEvent.where(ombudsman_manifestation: [ m, forwarded ])).to be_empty

      classify(OmbudsmanManifestation.new(id: SecureRandom.uuid), expected_state: "received", subject_id: subject_leaf!.id)
      expect(response).to have_http_status(:not_found)
    end

    # Só o valor que MUDA é conferido: o assunto que ficou inativo depois da
    # classificação não impede mudar só o `urgent`; `health_unit_id: null`
    # limpa a unidade, com o antes e o depois no evento.
    it "mantendo um assunto que ficou inativo, mudar só o urgent é aceito; health_unit_id null limpa com changes [id, nil]" do
      leaf = subject_leaf!
      ubs = HealthUnit.create!(name: "UBS Limpa", kind: "ubs")
      m = raw_manifestation!(state: "in_analysis", subject: leaf, referred_health_unit: ubs)
      leaf.update!(active: false)
      sign_in_as(technician)

      classify(m, expected_state: "in_analysis", subject_id: leaf.id, urgent: true)
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("urgent" => true)
      expect(json_body.dig("subject", "id")).to eq(leaf.id)

      classify(m, expected_state: "in_analysis", subject_id: leaf.id, health_unit_id: nil)
      expect(response).to have_http_status(:ok)
      expect(json_body["health_unit"]).to be_nil

      expect(OmbudsmanEvent.where(ombudsman_manifestation: m, kind: "classified").map(&:data))
        .to contain_exactly({ "changes" => { "urgent" => [ false, true ] } }, { "changes" => { "health_unit_id" => [ ubs.id, nil ] } })
      expect(m.reload).to have_attributes(subject_id: leaf.id, referred_health_unit_id: nil, urgent: true)
    end
  end

  describe "POST /ombudsman/manifestations/:id/forward" do
    it "setor sem respondente ativo → 422 destination_without_responder, nada gravado" do
      empty = department!("Setor Vazio")
      revoked = department!("Setor Revogado")
      responder!(revoked).memberships.each(&:revoke!)
      m = in_analysis!
      sign_in_as(technician)

      [ empty, revoked ].each do |destination|
        forward(m, expected_state: "in_analysis", department_id: destination.id, extract: extract)
        expect(response).to have_http_status(:unprocessable_content)
        expect(json_body).to include("error" => "destination_without_responder")
      end
      expect(m.reload.state).to eq("in_analysis")
      expect(OmbudsmanForwarding.where(ombudsman_manifestation: m)).to be_empty
      expect(OmbudsmanEvent.where(ombudsman_manifestation: m)).to be_empty
      expect(DomainEvent.where(name: "ombudsman.forwarded")).to be_empty
    end

    it "setor com respondente → forwarded, encaminhamento pending com due_on = hoje + forwarding_days, evento e ombudsman.forwarded só com ids; extrato fora do log" do
      m = in_analysis!
      sign_in_as(technician)

      log = capture_log { forward(m, expected_state: "in_analysis", department_id: department.id, extract: "  #{extract}  ") }
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => m.id, "state" => "forwarded", "pending_forwardings" => 1)
      shown = json_body.fetch("forwardings").sole
      expect(shown).to include("destination" => { "kind" => "department", "id" => department.id, "name" => "Atenção Primária" },
                               "extract" => extract, "state" => "pending", "due_on" => (today + 20).iso8601)

      forwarding = OmbudsmanForwarding.find_by!(ombudsman_manifestation: m)
      expect(forwarding).to have_attributes(state: "pending", department_id: department.id, health_unit_id: nil, extract: extract,
                                            due_on: today + 20, created_by_user_id: technician.id, extended: false)
      event = OmbudsmanEvent.find_by!(ombudsman_manifestation: m, kind: "forwarded")
      expect(event).to have_attributes(actor: "staff", actor_user_id: technician.id, visible_to_citizen: false, text: nil)
      expect(event.data).to eq("forwarding_id" => forwarding.id)
      expect(DomainEvent.where(name: "ombudsman.forwarded").sole.payload).to eq("manifestation_id" => m.id, "forwarding_id" => forwarding.id)
      expect(log).not_to include(extract)
    end

    it "dois encaminhamentos paralelos: o segundo sai de `forwarded`, a uma unidade" do
      m = in_analysis!
      sign_in_as(technician)

      forward(m, expected_state: "in_analysis", department_id: department.id, extract: extract)
      forward(m, expected_state: "forwarded", health_unit_id: unit.id, extract: extract)
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("state" => "forwarded", "pending_forwardings" => 2)
      # o relógio está parado: os dois nascem no mesmo instante (a ordem do empate é o id)
      expect(json_body.fetch("forwardings").map { |f| f.dig("destination", "kind") }).to contain_exactly("department", "health_unit")
      expect(OmbudsmanForwarding.where(ombudsman_manifestation: m, state: "pending").count).to eq(2)
      expect(OmbudsmanEvent.where(ombudsman_manifestation: m, kind: "forwarded").count).to eq(2)
    end

    it "recusas: extrato fora de 20..4000, destino ausente, os dois, inativo ou desconhecido; estado fora da tabela" do
      m = in_analysis!
      inactive = department!("Setor Inativo").tap { |d| d.update!(active: false) }
      responder!(inactive)
      sign_in_as(technician)

      {
        { department_id: department.id, extract: "curto demais" } => "extract",
        { department_id: department.id, extract: "x" * 4001 } => "extract",
        { department_id: department.id } => "extract",
        { extract: extract } => "department_id",
        { department_id: department.id, health_unit_id: unit.id, extract: extract } => "health_unit_id",
        { department_id: inactive.id, extract: extract } => "department_id",
        { department_id: SecureRandom.uuid, extract: extract } => "department_id",
        { health_unit_id: "x", extract: extract } => "health_unit_id"
      }.each do |params, path|
        forward(m, { expected_state: "in_analysis" }.merge(params))
        expect(response).to have_http_status(:unprocessable_content)
        expect(json_body).to include("error" => "invalid_request", "path" => path), path
      end
      received = raw_manifestation!
      forward(received, expected_state: "received", department_id: department.id, extract: extract)
      expect(json_body).to include("error" => "invalid_transition")
      expect(OmbudsmanForwarding.where(ombudsman_manifestation: [ m, received ])).to be_empty
    end
  end

  describe "POST /ombudsman/forwardings/:id/cancel" do
    it "cancela o único pending: volta a in_analysis, evento forwarding_cancelled com o motivo cifrado; 200 com o detalhe" do
      m, forwarding = forwarded!(department)
      sign_in_as(technician)

      cancel(forwarding, expected_state: "pending", reason: "  Encaminhado ao setor errado.  ")
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => m.id, "state" => "in_analysis", "pending_forwardings" => 0)
      expect(json_body.fetch("forwardings").sole).to include("state" => "cancelled")
      expect(forwarding.reload.state).to eq("cancelled")
      event = OmbudsmanEvent.find_by!(ombudsman_manifestation: m, kind: "forwarding_cancelled")
      expect(event).to have_attributes(actor: "staff", actor_user_id: technician.id, visible_to_citizen: false,
                                       text: "Encaminhado ao setor errado.")
      expect(event.data).to eq("forwarding_id" => forwarding.id)
    end

    it "com outro pending a manifestação continua forwarded; sem motivo também vale" do
      m, first, second = forwarded!(department, unit)
      sign_in_as(technician)

      cancel(first, expected_state: "pending")
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("state" => "forwarded", "pending_forwardings" => 1)
      expect(second.reload.state).to eq("pending")
      expect(OmbudsmanEvent.find_by!(ombudsman_manifestation: m, kind: "forwarding_cancelled").text).to be_nil
    end

    it "expected_state do encaminhamento: outro → 409 forwarding_changed; igual fora de pending → 422 invalid_transition; ausente → 422; nada gravado" do
      m, forwarding = forwarded!(department)
      replied = raw_forwarding!(m, unit, state: "replied", replied_by_user: unit_responder, replied_at: now)
      sign_in_as(technician)

      cancel(forwarding, expected_state: "replied")
      expect(response).to have_http_status(:conflict)
      expect(json_body).to eq("error" => "forwarding_changed")
      cancel(replied, expected_state: "replied")
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_transition")
      [ {}, { expected_state: "outro" }, { expected_state: "received" } ].each do |params|
        cancel(forwarding, params)
        expect(json_body).to include("error" => "invalid_request", "path" => "expected_state")
      end
      cancel(forwarding, expected_state: "pending", reason: "curto")
      expect(json_body).to include("error" => "invalid_request", "path" => "reason")
      cancel(forwarding, expected_state: "pending", extract: extract)
      expect(json_body).to include("error" => "invalid_request", "path" => "extract")
      expect(forwarding.reload.state).to eq("pending")
      expect(OmbudsmanEvent.where(ombudsman_manifestation: m)).to be_empty

      json_post("/ombudsman/forwardings/#{SecureRandom.uuid}/cancel", expected_state: "pending")
      expect(response).to have_http_status(:not_found)
      json_post("/ombudsman/forwardings/x/cancel", expected_state: "pending")
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "papéis" do
    it "o respondente sem ombudsman_staff não lê nada do §5 (403); o técnico sem ser respondente não tem inbox (403)" do
      m, forwarding = forwarded!(department)
      sign_in_as(dept_responder)

      get "/ombudsman/manifestations"
      expect(response).to have_http_status(:forbidden)
      get "/ombudsman/manifestations/#{m.id}"
      expect(response).to have_http_status(:forbidden)
      forward(m, expected_state: "forwarded", department_id: department.id, extract: extract)
      expect(response).to have_http_status(:forbidden)
      classify(m, expected_state: "forwarded", subject_id: subject_leaf!.id)
      expect(response).to have_http_status(:forbidden)
      cancel(forwarding, expected_state: "pending")
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "missing_role")
      expect(forwarding.reload.state).to eq("pending")

      sign_in_as(technician)
      get "/ombudsman/inbox"
      expect(response).to have_http_status(:forbidden)
      respond_to_forwarding(forwarding, "reply", expected_state: "pending", body: reply_text)
      expect(response).to have_http_status(:forbidden)
      expect(forwarding.reload.state).to eq("pending")
    end
  end

  describe "GET /ombudsman/inbox" do
    it "só os encaminhamentos dos destinos do respondente, com exatamente as chaves do §6 — nada da manifestação" do
      citizen = web_citizen!.tap { |c| c.update!(full_name: "Maria Identificada Rocha") }
      m = raw_manifestation!(citizen: citizen, state: "forwarded", subject: subject_leaf!, referred_health_unit: unit)
      raw_attachment!(manifestation: m)
      mine = raw_forwarding!(m, department)
      raw_forwarding!(m, unit)
      sign_in_as(dept_responder)

      get "/ombudsman/inbox"
      expect(response).to have_http_status(:ok)
      expect(json_body.keys).to eq(%w[items next_before])
      item = json_body.fetch("items").sole
      expect(item.keys).to match_array(%w[id destination extract due_on color state created_at extended])
      expect(item).to include("id" => mine.id, "extract" => extract, "state" => "pending", "extended" => false, "due_on" => (today + 20).iso8601,
                              "color" => "green", "destination" => { "kind" => "department", "id" => department.id, "name" => "Atenção Primária" })
      [ m.protocol, m.id, OmbudsmanHelpers::BODY, m.subject.name, citizen.full_name, citizen.cpf, citizen.cpf_masked, "UBS Encaminhada" ]
        .each { |secret| expect(response.body).not_to include(secret) }
    end

    it "filtro state[] (scalar ou fora do catálogo → 422), páginas de 50 por created_at DESC com cursor, cursor ruim → 422" do
      m = raw_manifestation!(state: "forwarded")
      rows = Array.new(52) { |i| raw_forwarding!(m, department, created_at: now - i.seconds) }
      replied = raw_forwarding!(m, department, state: "replied", replied_by_user: dept_responder, replied_at: now, created_at: now - 1.hour)
      sign_in_as(dept_responder)

      get "/ombudsman/inbox?state[]=pending"
      expect(json_body["items"].map { |i| i["id"] }).to eq(rows.first(50).map(&:id))
      get "/ombudsman/inbox", params: { "state" => [ "pending" ], "before" => json_body.fetch("next_before") }
      expect(json_body["items"].map { |i| i["id"] }).to eq(rows.last(2).map(&:id))
      expect(json_body["next_before"]).to be_nil

      get "/ombudsman/inbox?state[]=replied"
      item = json_body["items"].sole
      expect(item).to include("id" => replied.id, "state" => "replied", "reply" => reply_text, "color" => nil)
      expect(item.keys).to match_array(%w[id destination extract due_on color state created_at extended reply])

      [ "state=pending", "state[]=outro", "state[]=", "cpf=1" ].each do |query|
        get "/ombudsman/inbox?#{query}"
        expect(response).to have_http_status(:unprocessable_content)
        expect(json_body).to include("error" => "invalid_request", "path" => query.split(/[\[=]/).first), query
      end
      get "/ombudsman/inbox?before=lixo"
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_cursor", "path" => "before")
    end
  end

  describe "POST /ombudsman/inbox/:id/reply | decline | extend" do
    it "a resposta do primeiro deixa forwarded; a do segundo leva a in_analysis; 200 com o item do inbox (Q48), evento e ombudsman.forwarding_replied" do
      m, by_dept, by_unit = forwarded!(department, unit)
      sign_in_as(dept_responder)

      log = capture_log { respond_to_forwarding(by_dept, "reply", expected_state: "pending", body: "  #{reply_text}  ") }
      expect(response).to have_http_status(:ok)
      expect(json_body.keys).to match_array(%w[id destination extract due_on color state created_at extended reply])
      expect(json_body).to include("id" => by_dept.id, "state" => "replied", "reply" => reply_text, "color" => nil)
      expect(log).not_to include(reply_text)
      expect(m.reload.state).to eq("forwarded")
      expect(by_dept.reload).to have_attributes(state: "replied", reply: reply_text, replied_by_user_id: dept_responder.id, replied_at: now)
      event = OmbudsmanEvent.find_by!(ombudsman_manifestation: m, kind: "forwarding_replied")
      expect(event).to have_attributes(actor: "staff", actor_user_id: dept_responder.id, visible_to_citizen: false)
      expect(event.data).to eq("forwarding_id" => by_dept.id)
      expect(DomainEvent.where(name: "ombudsman.forwarding_replied").sole.payload)
        .to eq("manifestation_id" => m.id, "forwarding_id" => by_dept.id)

      sign_in_as(unit_responder)
      respond_to_forwarding(by_unit, "reply", expected_state: "pending", body: reply_text)
      expect(response).to have_http_status(:ok)
      expect(m.reload.state).to eq("in_analysis")
      expect(DomainEvent.where(name: "ombudsman.forwarding_replied").count).to eq(2)
    end

    # A linha de respondente desativada (o papel continua): o destino sai do
    # alcance — o inbox fica vazio e a ação no encaminhamento é 404.
    it "linha de respondente desativada: o inbox fica vazio e a resposta → 404, nada gravado" do
      m, f = forwarded!(department)
      sign_in_as(dept_responder)
      get "/ombudsman/inbox"
      expect(json_body["items"].map { |i| i["id"] }).to eq([ f.id ]) # controle: antes de desativar

      OmbudsmanResponder.find_by!(user: dept_responder, department: department).update!(active: false)
      get "/ombudsman/inbox"
      expect(response).to have_http_status(:ok)
      expect(json_body["items"]).to eq([])
      respond_to_forwarding(f, "reply", expected_state: "pending", body: reply_text)
      expect(response).to have_http_status(:not_found)
      expect(f.reload).to have_attributes(state: "pending", reply: nil)
      expect(m.reload.state).to eq("forwarded")
      expect(DomainEvent.where(name: "ombudsman.forwarding_replied")).to be_empty
    end

    it "o respondente de outra unidade → 404, nada gravado" do
      _m, by_dept = forwarded!(department)
      sign_in_as(unit_responder)

      { "reply" => { body: reply_text }, "decline" => { reason: reply_text }, "extend" => { reason: reply_text } }.each do |action, params|
        respond_to_forwarding(by_dept, action, { expected_state: "pending" }.merge(params))
        expect(response).to have_http_status(:not_found), action
      end
      respond_to_forwarding(OmbudsmanForwarding.new(id: SecureRandom.uuid), "reply", expected_state: "pending", body: reply_text)
      expect(response).to have_http_status(:not_found)
      expect(by_dept.reload).to have_attributes(state: "pending", extended: false)
    end

    it "a recusa grava o motivo em `reply` com state declined (Q9) e devolve a manifestação a in_analysis; sem forwarding_replied" do
      m, by_dept = forwarded!(department)
      sign_in_as(dept_responder)

      respond_to_forwarding(by_dept, "decline", expected_state: "pending", reason: "  Não é assunto deste setor.  ")
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("state" => "declined", "reply" => "Não é assunto deste setor.")
      expect(by_dept.reload).to have_attributes(state: "declined", reply: "Não é assunto deste setor.", replied_by_user_id: dept_responder.id)
      expect(m.reload.state).to eq("in_analysis")
      expect(OmbudsmanEvent.find_by!(ombudsman_manifestation: m, kind: "forwarding_declined"))
        .to have_attributes(actor: "staff", actor_user_id: dept_responder.id, visible_to_citizen: false)
      expect(DomainEvent.where(name: "ombudsman.forwarding_replied")).to be_empty
    end

    it "prorroga uma vez (+ forwarding_extension_days, motivo cifrado); a segunda → 422 already_extended; a manifestação não muda" do
      m, by_dept = forwarded!(department)
      sign_in_as(dept_responder)

      respond_to_forwarding(by_dept, "extend", expected_state: "pending", reason: "Aguardando a escala do mês seguinte.")
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("state" => "pending", "due_on" => (today + 40).iso8601, "extended" => true)
      expect(by_dept.reload).to have_attributes(extended: true, due_on: today + 40, extension_reason: "Aguardando a escala do mês seguinte.")
      expect(OmbudsmanEvent.where(ombudsman_manifestation: m, kind: "forwarding_extended").sole)
        .to have_attributes(actor: "staff", actor_user_id: dept_responder.id, visible_to_citizen: false)

      respond_to_forwarding(by_dept, "extend", expected_state: "pending", reason: "Outra prorrogação pedida pelo setor.")
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "already_extended")
      expect(by_dept.reload.due_on).to eq(today + 40)
      expect(OmbudsmanEvent.where(ombudsman_manifestation: m, kind: "forwarding_extended").count).to eq(1)
      expect(m.reload.state).to eq("forwarded")
    end

    it "expected_state: outro → 409 forwarding_changed; igual fora de pending → 422 invalid_transition; textos fora de 10..4000 → 422; chave desconhecida → 422" do
      m, by_dept = forwarded!(department)
      replied = raw_forwarding!(m, department, state: "replied", replied_by_user: dept_responder, replied_at: now)
      sign_in_as(dept_responder)

      respond_to_forwarding(by_dept, "reply", expected_state: "replied", body: reply_text)
      expect(response).to have_http_status(:conflict)
      expect(json_body).to eq("error" => "forwarding_changed")
      %w[reply decline extend].each do |action|
        respond_to_forwarding(replied, action, { expected_state: "replied" }.merge(action == "reply" ? { body: reply_text } : { reason: reply_text }))
        expect(response).to have_http_status(:unprocessable_content)
        expect(json_body).to include("error" => "invalid_transition"), action
      end
      {
        [ "reply", { body: "curto" } ] => "body", [ "reply", {} ] => "body", [ "reply", { body: "x" * 4001 } ] => "body",
        [ "decline", { reason: "curto" } ] => "reason", [ "extend", { reason: 12_345_678_901 } ] => "reason",
        [ "reply", { body: reply_text, reason: reply_text } ] => "reason", [ "reply", { body: reply_text } ] => "expected_state"
      }.each do |(action, params), path|
        params = { expected_state: "pending" }.merge(params) unless path == "expected_state"
        respond_to_forwarding(by_dept, action, params)
        expect(response).to have_http_status(:unprocessable_content)
        expect(json_body).to include("error" => "invalid_request", "path" => path), "#{action} #{path}"
      end
      expect(by_dept.reload).to have_attributes(state: "pending", extended: false, reply: nil)
      expect(OmbudsmanEvent.where(ombudsman_manifestation: m)).to be_empty
    end
  end
end
