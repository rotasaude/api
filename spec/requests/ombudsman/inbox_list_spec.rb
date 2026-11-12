require "rails_helper"

# Módulo 33, Task 11 (ADR 0051; contrato §5; §16 Q23, Q34, Q37, Q18;
# preflight F-14): a caixa da equipe e o detalhe. Lista `{ items,
# next_before }`, cursor `before`, filtros repetidos (`state[]`, `color[]`,
# `kind[]`, `channel[]`) e `subject_id` / `health_unit_id` / `q` (só
# protocolo); ordem received_at DESC, id DESC, páginas de 50. Valor fora do
# catálogo e chave fora da lista → 422 com o path (só o nome).
RSpec.describe "Ouvidoria — caixa e detalhe da equipe", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { ombudsman_city! }
  let(:technician) { ombudsman_staff! }
  let(:ouvidor) { ombudsman! }
  let(:now) { Time.utc(2026, 11, 11, 15) }
  let(:today) { now.in_time_zone("America/Sao_Paulo").to_date }

  around { |example| travel_to(Time.utc(2026, 11, 11, 15)) { example.run } }

  def unit!(name = "UBS #{SecureRandom.hex(3)}") = HealthUnit.create!(name: name, kind: "ubs")
  def list(params = {}) = get("/ombudsman/manifestations", params: params)
  def ids = json_body.fetch("items").map { |item| item.fetch("id") }

  # received_at em ordem: cada chamada um segundo antes da anterior.
  def at(offset) = now - offset.seconds

  describe "GET /ombudsman/manifestations" do
    it "item com exatamente as chaves do §5, assunto { id, name, parent } e unidade (Q34)" do
      leaf = subject_leaf!
      unit = unit!("UBS Centro")
      m = raw_manifestation!(subject: leaf, referred_health_unit: unit, state: "in_analysis", urgent: true)
      sign_in_as(technician)
      list
      expect(response).to have_http_status(:ok)
      expect(json_body.keys).to eq(%w[items next_before])
      expect(json_body["next_before"]).to be_nil
      item = json_body["items"].sole
      expect(item.keys).to match_array(%w[id protocol kind identification_mode channel state subject health_unit urgent received_at due_on
                                          color pending_forwardings])
      expect(item).to include("id" => m.id, "protocol" => m.protocol, "state" => "in_analysis", "urgent" => true,
                              "subject" => { "id" => leaf.id, "name" => leaf.name, "parent" => { "id" => leaf.parent.id, "name" => leaf.parent.name } },
                              "health_unit" => { "id" => unit.id, "name" => "UBS Centro" }, "pending_forwardings" => 0,
                              "due_on" => (today + 15).iso8601, "color" => "green")
    end

    it "filtra por estado, tipo e canal (filtros repetidos)" do
      received = raw_manifestation!(received_at: at(1))
      analysis = raw_manifestation!(state: "in_analysis", kind: "praise", received_at: at(2))
      phone = raw_manifestation!(state: "in_analysis", channel: "phone", received_at: at(3))
      sign_in_as(technician)

      list("state[]" => "in_analysis")
      expect(ids).to eq([ analysis.id, phone.id ])
      get "/ombudsman/manifestations?state[]=received&state[]=in_analysis"
      expect(ids).to eq([ received.id, analysis.id, phone.id ])
      get "/ombudsman/manifestations?kind[]=praise"
      expect(ids).to eq([ analysis.id ])
      get "/ombudsman/manifestations?channel[]=phone&channel[]=ouvidorsus"
      expect(ids).to eq([ phone.id ])
      get "/ombudsman/manifestations?state[]=in_analysis&channel[]=web"
      expect(ids).to eq([ analysis.id ])
    end

    it "filtra por cor pelo SQL do prazo: vermelha, amarela, pausada e verde; estado final sem cor" do
      red = raw_manifestation!(state: "in_analysis", cycle_started_on: today - 31, received_at: at(1))
      yellow = raw_manifestation!(state: "in_analysis", cycle_started_on: today - 27, received_at: at(2))
      paused = raw_manifestation!(state: "awaiting_complement", complement_used: true, complement_requested_at: now - 2.days,
                                  cycle_started_on: today - 40, received_at: at(3))
      green = raw_manifestation!(state: "in_analysis", received_at: at(4))
      raw_manifestation!(state: "answered", concluded_at: now, cycle_started_on: today - 60, received_at: at(5))
      sign_in_as(technician)

      { "red" => [ red ], "yellow" => [ yellow ], "paused" => [ paused ], "green" => [ green ] }.each do |color, expected|
        get "/ombudsman/manifestations?color[]=#{color}"
        expect(ids).to eq(expected.map(&:id)), color
        expect(json_body["items"].map { |item| item["color"] }).to all(eq(color))
      end
      get "/ombudsman/manifestations?color[]=red&color[]=yellow"
      expect(ids).to eq([ red.id, yellow.id ])
    end

    it "subject_id casa o assunto e os filhos; health_unit_id casa a unidade referida (ids na URL, Q18)" do
      leaf = subject_leaf!
      sibling = OmbudsmanSubject.where(parent_id: leaf.parent_id).where.not(id: leaf.id).first!
      other = OmbudsmanSubject.where(parent_id: nil).where.not(id: leaf.parent_id).first!
      unit = unit!
      a = raw_manifestation!(subject: leaf, referred_health_unit: unit, received_at: at(1))
      b = raw_manifestation!(subject: sibling, received_at: at(2))
      c = raw_manifestation!(subject: leaf.parent, received_at: at(3))
      raw_manifestation!(subject: other, received_at: at(4))
      raw_manifestation!(received_at: at(5))
      sign_in_as(technician)

      list(subject_id: leaf.parent_id)
      expect(ids).to eq([ a.id, b.id, c.id ])
      list(subject_id: leaf.id)
      expect(ids).to eq([ a.id ])
      list(health_unit_id: unit.id)
      expect(ids).to eq([ a.id ])
      list(subject_id: SecureRandom.uuid)
      expect(ids).to eq([])
    end

    it "q: o protocolo exato ou o prefixo do ano (AAAA-); outra forma → 422 path q" do
      m = raw_manifestation!(received_at: at(1))
      older = raw_manifestation!(received_at: at(2), protocol: "2025-000777")
      sign_in_as(technician)

      list(q: m.protocol)
      expect(ids).to eq([ m.id ])
      list(q: "2025-")
      expect(ids).to eq([ older.id ])
      list(q: "2024-")
      expect(ids).to eq([])
      [ "2025", "2025-00", "%", "2025-000777 ", "Maria", "2025-12345", "2025-0007770000000" ].each do |q|
        list(q: q)
        expect(response).to have_http_status(:unprocessable_content), q
        expect(json_body).to eq("error" => "invalid_request", "path" => "q", "problems" => [ { "error" => "invalid_request", "path" => "q" } ])
      end
    end

    it "pagina de 50 em received_at DESC, id DESC com next_before; o cursor segue a ordem e a última página tem next_before nulo" do
      rows = Array.new(52) { |i| raw_manifestation!(received_at: at(i + 1)) }
      sign_in_as(technician)
      list
      expect(ids).to eq(rows.first(50).map(&:id))
      cursor = json_body["next_before"]
      expect(cursor).to be_a(String)

      list(before: cursor)
      expect(ids).to eq(rows.last(2).map(&:id))
      expect(json_body["next_before"]).to be_nil
    end

    it "empate no received_at: desempata por id DESC, sem perder nem repetir" do
      same = now - 1.hour
      rows = Array.new(51) { raw_manifestation!(received_at: same) }.sort_by(&:id).reverse
      sign_in_as(technician)
      list
      first = ids
      list(before: json_body["next_before"])
      expect(first + ids).to eq(rows.map(&:id))
    end

    it "cursor inválido → 422 invalid_cursor path before" do
      sign_in_as(technician)
      [ "x", "", Base64.urlsafe_encode64("[1,2,3]"), CareRegulation::Cursor.encode([ today, 0, 0, now, SecureRandom.uuid ]) ].each do |cursor|
        list(before: cursor)
        expect(response).to have_http_status(:unprocessable_content)
        expect(json_body).to include("error" => "invalid_cursor", "path" => "before")
      end
    end

    it "valor fora do catálogo ou forma errada → 422 com o path; chave fora da lista (query_only!, F-14) → 422 com o nome" do
      sign_in_as(technician)
      {
        "state[]=closed" => "state", "state=received" => "state", "state[]=" => "state", "color[]=blue" => "color",
        "kind[]=compliment" => "kind", "channel[]=whatsapp" => "channel", "subject_id=1" => "subject_id",
        "health_unit_id[]=#{SecureRandom.uuid}" => "health_unit_id", "q[]=2025-" => "q",
        "cpf=52998224725" => "cpf", "responsible_id=#{SecureRandom.uuid}" => "responsible_id", "state[x]=received" => "state"
      }.each do |query, path|
        get "/ombudsman/manifestations?#{query}"
        expect(response).to have_http_status(:unprocessable_content), query
        expect(json_body).to include("error" => "invalid_request", "path" => path)
        expect(response.body).not_to include("52998224725")
      end
    end

    it "uma consulta por tabela, sem N+1 (assunto com o pai, unidade e encaminhamentos pendentes em lote)" do
      leaf = subject_leaf!
      unit = unit!
      department = department!
      3.times do |i|
        m = raw_manifestation!(subject: leaf, referred_health_unit: unit, state: "forwarded", received_at: at(i + 1))
        OmbudsmanForwarding.create!(ombudsman_manifestation: m, department: department, extract: "Extrato do caso para o setor.",
                                    due_on: today + 10, state: "pending", created_by_user: technician)
      end
      sign_in_as(technician)
      list # aquece sessão, configuração e papéis
      queries = []
      callback = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:sql].match?(/\A(BEGIN|COMMIT|SAVEPOINT|RELEASE|ROLLBACK)/) }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { list }
      expect(json_body["items"].map { |item| item["pending_forwardings"] }).to eq([ 1, 1, 1 ])
      expect(queries.grep(/FROM "ombudsman_subjects"/).size).to be <= 2
      expect(queries.grep(/FROM "health_units"/).size).to eq(1)
      expect(queries.grep(/FROM "ombudsman_forwardings"/).size).to eq(1)
    end

    it "o respondente sem papel de técnico → 403; sem sessão → 401; ouvidoria desligada → 403 feature_disabled" do
      raw_manifestation!
      sign_in_as(responder!(department!))
      list
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "missing_role")

      sign_in_as(ouvidor)
      list
      expect(response).to have_http_status(:ok)

      Platform::Features.set!(city: city, key: "ombudsman", enabled: false, maintainer: ledi_maintainer!)
      list
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "feature_disabled", "feature" => "ombudsman")
    end
  end

  describe "GET /ombudsman/manifestations/:id" do
    def show(m, params = {}) = get("/ombudsman/manifestations/#{m.is_a?(String) ? m : m.id}", params: params)

    it "o detalhe traz body, eventos com actor_name (Q4), encaminhamentos com extrato e resposta, anexos sem nome (Q2)" do
      leaf = subject_leaf!
      unit = unit!("UBS Norte")
      department = department!("Setor de Regulação")
      m = raw_manifestation!(subject: leaf, referred_health_unit: unit, state: "forwarded")
      OmbudsmanEvent.create!(ombudsman_manifestation: m, kind: "received", actor: "citizen", visible_to_citizen: true, created_at: now - 2.hours)
      OmbudsmanEvent.create!(ombudsman_manifestation: m, kind: "classified", actor: "staff", actor_user: technician,
                             data: { "changes" => {} }, created_at: now - 1.hour)
      answered_by = responder!(department)
      OmbudsmanForwarding.create!(ombudsman_manifestation: m, department: department, extract: "Extrato do caso para o setor.", due_on: today + 10,
                                  state: "replied", reply: "O setor já resolveu o agendamento.", replied_by_user: answered_by,
                                  replied_at: now - 30.minutes, created_by_user: technician, created_at: now - 50.minutes)
      pending = OmbudsmanForwarding.create!(ombudsman_manifestation: m, health_unit: unit, extract: "Outro extrato para a unidade.",
                                            due_on: today + 2, state: "pending", created_by_user: technician, created_at: now - 40.minutes)
      attachment = raw_attachment!(manifestation: m, filename: "segredo-do-arquivo.png")

      sign_in_as(technician)
      show(m)
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => m.id, "body" => OmbudsmanHelpers::BODY, "state" => "forwarded", "pending_forwardings" => 1,
                                   "subject" => { "id" => leaf.id, "name" => leaf.name, "parent" => { "id" => leaf.parent.id, "name" => leaf.parent.name } },
                                   "health_unit" => { "id" => unit.id, "name" => "UBS Norte" }, "identity_available" => false)
      expect(json_body).not_to have_key("can_open_identity")
      expect(json_body["events"].map { |e| [ e["kind"], e["actor"], e["actor_name"] ] })
        .to eq([ [ "received", "citizen", nil ], [ "classified", "staff", technician.email_address ] ])
      expect(json_body["forwardings"].map { |f| f["destination"] })
        .to eq([ { "kind" => "department", "id" => department.id, "name" => "Setor de Regulação" },
                 { "kind" => "health_unit", "id" => unit.id, "name" => "UBS Norte" } ])
      expect(json_body["forwardings"].first).to include("extract" => "Extrato do caso para o setor.", "reply" => "O setor já resolveu o agendamento.",
                                                        "state" => "replied", "color" => nil)
      expect(json_body["forwardings"].last).to include("id" => pending.id, "state" => "pending", "color" => "yellow", "due_on" => (today + 2).iso8601)
      expect(json_body["attachments"]).to eq([ { "id" => attachment.id, "uploaded_by" => "citizen" } ])
      expect(response.body).not_to include("segredo-do-arquivo")
    end

    it "reopen_request é o pedido PENDENTE; decidido → nulo" do
      m = raw_manifestation!(state: "answered", concluded_at: now - 1.day)
      decided = OmbudsmanReopenRequest.create!(ombudsman_manifestation: m, cycle: 1, reason: "Quero reabrir o pedido anterior.", state: "rejected",
                                               decision_text: "Recusado pela ouvidoria.", decided_by_user: ouvidor, decided_at: now - 1.hour)
      sign_in_as(ouvidor)
      show(m)
      expect(json_body["reopen_request"]).to be_nil
      expect(json_body["can"]).to include("decide_reopen" => false)

      pending = OmbudsmanReopenRequest.create!(ombudsman_manifestation: m, cycle: 2, reason: "Ainda não resolveram o problema.", state: "pending")
      show(m)
      expect(json_body["reopen_request"]).to include("id" => pending.id, "state" => "pending", "cycle" => 2, "reason" => "Ainda não resolveram o problema.")
      expect(json_body["can"]).to include("decide_reopen" => true)
      expect(decided.reload.state).to eq("rejected")
    end

    it "can: as ações do §2 permitidas ao usuário no estado (técnico × ouvidor)" do
      received = raw_manifestation!(citizen: web_citizen!)
      sign_in_as(technician)
      show(received)
      expect(json_body["can"]).to eq(
        "classify" => true, "forward" => false, "cancel_forwarding" => false, "request_complement" => false, "complement" => false,
        "extend" => false, "interim_response" => true, "final_response" => false, "archive" => false, "reopen" => false,
        "change_resolution" => false, "decide_reopen" => false, "open_identity" => false, "record_identity_consent" => false
      )
      sign_in_as(ouvidor)
      show(received)
      expect(json_body["can"]).to include("classify" => true, "archive" => true, "extend" => false, "open_identity" => true,
                                          "record_identity_consent" => true)

      analysis = raw_manifestation!(state: "in_analysis")
      show(analysis)
      expect(json_body["can"]).to include("forward" => true, "request_complement" => true, "final_response" => true, "extend" => true,
                                          "archive" => true, "reopen" => false)

      used = raw_manifestation!(state: "in_analysis", complement_used: true, extended: true, extension_reason: "Prorrogado por complexidade.")
      show(used)
      expect(json_body["can"]).to include("request_complement" => false, "extend" => false)

      forwarded = raw_manifestation!(state: "forwarded")
      OmbudsmanForwarding.create!(ombudsman_manifestation: forwarded, department: department!, extract: "Extrato do caso para o setor.",
                                  due_on: today + 10, state: "pending", created_by_user: technician)
      show(forwarded)
      expect(json_body["can"]).to include("forward" => true, "cancel_forwarding" => true, "final_response" => false, "archive" => false,
                                          "classify" => false)

      awaiting = raw_manifestation!(state: "awaiting_complement", complement_used: true, complement_requested_at: now - 1.day)
      show(awaiting)
      expect(json_body["can"]).to include("complement" => true, "archive" => true, "interim_response" => true, "request_complement" => false)

      complaint = raw_manifestation!(state: "answered", resolution: "resolved", concluded_at: now)
      praise = raw_manifestation!(state: "answered", kind: "praise", concluded_at: now)
      show(complaint)
      expect(json_body["can"]).to include("reopen" => true, "change_resolution" => true, "interim_response" => false, "classify" => false)
      show(praise)
      expect(json_body["can"]).to include("reopen" => true, "change_resolution" => false)

      anonymous = raw_manifestation!(kind: "report", identification_mode: "anonymous", state: "in_analysis")
      show(anonymous)
      expect(json_body["can"]).to include("request_complement" => false, "interim_response" => false, "open_identity" => false,
                                          "record_identity_consent" => false)

      sign_in_as(technician)
      show(complaint)
      expect(json_body["can"]).to include("reopen" => false, "change_resolution" => false)
    end

    it "load_manifestation: id malformado ou inexistente → 404; chave na query → 422 com o nome (query_only!)" do
      m = raw_manifestation!
      sign_in_as(technician)
      [ "nao-e-uuid", SecureRandom.uuid ].each do |id|
        show(id)
        expect(response).to have_http_status(:not_found)
        expect(json_body).to eq("error" => "not_found")
      end
      show(m, cpf: "52998224725")
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "cpf")
      expect(response.body).not_to include("52998224725")
    end

    it "o respondente sem papel de técnico → 403" do
      m = raw_manifestation!
      sign_in_as(responder!(department!))
      show(m)
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "missing_role")
    end
  end
end
