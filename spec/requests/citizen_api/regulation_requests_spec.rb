require "rails_helper"

# Módulo 26a (ADR 0044; contrato §9, §13 G3/G9): "Meus encaminhamentos" do
# cidadão. Forma fixa { id label status scheduled_at place updated_at }: nunca
# cor, posição, CID, justificativa, prazo, motivo nem autorização (decisão 9).
RSpec.describe "Cidadão — situação do pedido de regulação", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:keys) { %w[id label status scheduled_at place updated_at] }
  let(:now) { Time.zone.parse("2026-10-28 10:00:00") }

  before do
    travel_to(now)
    regulation_city!
  end

  let(:pair) { regulation_patient!(exam_seq!) }
  let(:patient) { pair.first }
  let(:citizen) { pair.last }
  let(:regulator) { regulation_regulator! }
  let(:justification) { "Hipertensão resistente a três fármacos" }

  def mine(**over) = regulation_request!(citizen: citizen, **over)

  def authorize!(request)
    reauthorize!(request, offer: offer!(provider: external_provider!, target_code: request.target_code))
  end

  def decide!(request, decision, reason = "Motivo registrado pela regulação")
    result = CareRegulation::Decide.call(request: request.reload, decision: decision, reason: reason, version: request.version, by: regulator)
    raise "recusada: #{result.reason}" if result.failure?

    request.reload
  end

  def row(id) = json_body["requests"].find { |r| r["id"] == id }

  it "lista cada situação com a forma fixa; rascunho fora; autorizado e pendente saem waiting; cancelado e encerrado saem closed" do
    pending_r = mine
    authorized = authorize!(mine(target_code: "225103"))
    scheduled = authorize!(mine(target_code: "225105"))
    when_at = Time.zone.parse("2026-11-10 09:30:00")
    scheduled_result = CareRegulation::ScheduleExternal.call(request: scheduled, at: when_at.iso8601, place: "Clínica de Olhos Araucária, sala 3",
                                                             notes: "Levar exames anteriores", version: scheduled.version, by: regulator)
    raise "agendamento recusado: #{scheduled_result.reason}" if scheduled_result.failure?

    returned = decide!(mine(target_code: "225109"), "return")
    denied = decide!(mine(target_code: "225110"), "deny")
    cancelled = decide!(mine(target_code: "225112"), "cancel")
    closed = mine(target_code: "225115")
    closed.update_columns(status: "closed") # encerrada pela 2ª falta (comando do 17): só a situação interessa aqui
    external = mine(status: "external", target_code: "225124")
    draft = mine(status: "draft", target_code: "225127")

    sign_in_citizen(citizen.phone)
    get "/citizen/regulation_requests", params: { citizen_id: citizen.id }

    expect(response).to have_http_status(:ok)
    expect(json_body.keys).to eq([ "requests" ])
    expect(json_body["requests"].map { |r| r["id"] }).not_to include(draft.id)
    expect(json_body["requests"]).to all(satisfy { |r| r.keys.sort == keys.sort })
    expect({ pending_r => "waiting", authorized => "authorized", external => "waiting", scheduled => "scheduled", returned => "returned",
             denied => "denied", cancelled => "closed", closed => "closed" }.transform_keys(&:id))
      .to eq(json_body["requests"].to_h { |r| [ r["id"], r["status"] ] })
    expect(row(scheduled.id)).to include("scheduled_at" => when_at.iso8601, "place" => "Clínica de Olhos Araucária, sala 3")
    # A observação do agendamento (schedule_notes) é do regulador: nem no local, nem em parte alguma do corpo.
    expect(scheduled.reload.schedule_notes).to eq("Levar exames anteriores")
    expect(row(scheduled.id)["place"]).not_to include("Levar exames")
    expect(response.body).not_to include("Levar exames")
    expect(row(pending_r.id)).to include("scheduled_at" => nil, "place" => nil)
    expect(row(authorized.id)).to include("scheduled_at" => nil, "place" => nil)
  end

  it "completed sai completed, sem data nem local; a frase: 'Consulta em <especialidade>' e o nome do procedimento" do
    consult = mine
    proc_r = mine(type: "procedure", target_code: "0209010037")
    done = authorize!(mine(target_code: "225103"))
    done.update_columns(status: "completed")

    sign_in_citizen(citizen.phone)
    get "/citizen/regulation_requests", params: { citizen_id: citizen.id }

    expect(row(consult.id)["label"]).to eq("Consulta em #{consult.target_name}")
    expect(consult.target_name).to eq("Cardiologia")
    expect(row(proc_r.id)["label"]).to eq("ESOFAGOGASTRODUODENOSCOPIA")
    expect(row(done.id)).to include("status" => "completed", "scheduled_at" => nil, "place" => nil)
  end

  it "ordena por updated_at decrescente e depois id" do
    older = mine
    travel(2.hours)
    newer = mine(target_code: "225103")
    sign_in_citizen(citizen.phone)
    get "/citizen/regulation_requests", params: { citizen_id: citizen.id }
    expect(json_body["requests"].map { |r| r["id"] }).to eq([ newer.id, older.id ])
    expect(json_body["requests"].first["updated_at"]).to eq(newer.updated_at.iso8601)
  end

  it "só o paciente da pessoa: pedido de outra pessoa não aparece" do
    mine
    other = regulation_request!(citizen: regulation_patient!(exam_seq!).last, target_code: "225103")
    sign_in_citizen(citizen.phone)
    get "/citizen/regulation_requests", params: { citizen_id: citizen.id }
    expect(json_body["requests"].map { |r| r["id"] }).not_to include(other.id)
    expect(json_body["requests"].size).to eq(1)
  end

  it "nunca expõe cor, posição, CID, CIAP, justificativa, prazo, motivo nem autorização (decisão 9)" do
    request = authorize!(mine(suggested_color: "red", ciap2: "K86"))
    forbidden = { "color" => "red", "suggested_color" => "red", "effective_color" => "red", "position" => 1, "queue_position" => 1,
                  "cid10" => "I10", "ciap2" => "K86", "justification" => justification, "color_reason" => "Risco de vida imediato descrito",
                  "due_on" => request.due_on.iso8601, "overdue" => false, "reason" => "x", "skip_reason" => "y", "misses" => 0,
                  "authorization" => {}, "provider" => "Prestador", "target_code" => "225120", "patient" => {}, "external_number" => "1" }
    request.update_columns(color: "red", color_reason: "Risco de vida imediato descrito", schedule_notes: "Levar exames anteriores", external_system: "sisreg", external_number: "123456")

    sign_in_citizen(citizen.phone)
    get "/citizen/regulation_requests", params: { citizen_id: citizen.id }

    item = json_body["requests"].first
    expect(item.keys).to match_array(keys)
    expect(item.keys & forbidden.keys).to be_empty
    expect(response.body).not_to include("I10", "K86", justification, "Risco de vida", "Levar exames", "123456", "225120", "red", "yellow",
                                         request.due_on.iso8601, "Prestador")
    # G16: `authorized` é situação do contrato §9; fora esse valor, nada de autorização no corpo.
    expect(item["status"]).to eq("authorized")
    expect(response.body.sub('"status":"authorized"', '"status":"_"'))
      .not_to match(/color|position|cid10|ciap|justif|due_on|overdue|reason|authoriz|provider|target_code|patient|cpf|cns/i)
  end

  it "trilha citizen com o paciente; sem paciente, nenhuma" do
    mine
    before = DomainEvent.where(name: "clinical_record.viewed").count
    sign_in_citizen(citizen.phone)
    get "/citizen/regulation_requests", params: { citizen_id: citizen.id }
    views = DomainEvent.where(name: "clinical_record.viewed")
    expect(views.count).to eq(before + 1)
    expect(views.order(:occurred_at, :created_at).last.payload).to include("access" => "citizen", "patient_id" => patient.id, "user_id" => nil)
    expect(views.order(:occurred_at, :created_at).last.payload.to_s).not_to include("regulation_request_ids")
  end

  it "par validado sem paciente: lista vazia e nenhuma trilha" do
    lone = verified_citizen!(exam_seq!, age: 40)
    before = DomainEvent.where(name: "clinical_record.viewed").count
    sign_in_citizen(lone.phone)
    get "/citizen/regulation_requests", params: { citizen_id: lone.id }
    expect(json_body).to eq("requests" => [])
    expect(DomainEvent.where(name: "clinical_record.viewed").count).to eq(before)
  end

  it "citizen_id de outro celular: 404; par declarado: 403 not_verified; interruptor desligado: 403 feature_disabled" do
    declared = profiled_citizen!(age: 30, phone: "+5541990000124")
    sign_in_citizen(declared.phone)
    get "/citizen/regulation_requests", params: { citizen_id: declared.id }
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "not_verified")

    get "/citizen/regulation_requests", params: { citizen_id: citizen.id }
    expect(response).to have_http_status(:not_found)
    expect(json_body).to eq("error" => "not_found")

    get "/citizen/regulation_requests"
    expect(response).to have_http_status(:not_found)

    Platform::Features.set!(city: Current.city, key: "care_regulation", enabled: false, maintainer: ledi_maintainer!)
    get "/citizen/regulation_requests", params: { citizen_id: declared.id }
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "care_regulation")
  end

  it "sem prontuário utilizável: 403 feature_disabled" do
    Platform::Features.set!(city: Current.city, key: "clinical_record", enabled: false, maintainer: ledi_maintainer!)
    sign_in_citizen(citizen.phone)
    get "/citizen/regulation_requests", params: { citizen_id: citizen.id }
    expect(response).to have_http_status(:forbidden)
    expect(json_body["error"]).to eq("feature_disabled")
  end

  it "sem sessão: 401" do
    get "/citizen/regulation_requests", params: { citizen_id: citizen.id }
    expect(response).to have_http_status(:unauthorized)
  end

  # G9: a sessão lista care_regulation pelo mecanismo genérico (Platform::Features.summary).
  it "GET /citizen/session lista care_regulation só quando utilizável" do
    sign_in_citizen(citizen.phone)
    get "/citizen/session"
    expect(json_body["features"]).to include("care_regulation")

    Platform::Features.set!(city: Current.city, key: "care_regulation", enabled: false, maintainer: ledi_maintainer!)
    get "/citizen/session"
    expect(json_body["features"]).not_to include("care_regulation")

    Platform::Features.set!(city: Current.city, key: "care_regulation", enabled: true, maintainer: ledi_maintainer!)
    Platform::Features.set!(city: Current.city, key: "clinical_record", enabled: false, maintainer: ledi_maintainer!)
    get "/citizen/session"
    expect(json_body["features"]).not_to include("care_regulation")
  end

  it "o pedido de agendamento da rede própria sai com kind regulated em /citizen/appointments" do
    own = own_authorized_request!(citizen: citizen)
    sign_in_citizen(citizen.phone)
    get "/citizen/appointments", params: { citizen_id: citizen.id }
    expect(response).to have_http_status(:ok)
    item = json_body["appointments"].find { |a| a["request"]["kind"] == "regulated" }
    expect(item["request"]).to include("kind" => "regulated", "status" => "open")
    # G15.1: o prazo da cor não chega ao cidadão (chave ausente, não nula).
    expect(item["request"]).not_to have_key("due_on")
    expect(own[:appointment_request].due_on).to be_present
    expect(response.body).not_to include(own[:appointment_request].due_on.iso8601)

    get "/citizen/regulation_requests", params: { citizen_id: citizen.id }
    expect(row(own[:regulation_request].id)["status"]).to eq("authorized") # G16
  end
end
