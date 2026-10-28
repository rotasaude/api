require "rails_helper"

# Módulo 26a, Task 4 (ADR 0044; contrato §3, §13 G4, G10, G12): o pedido de
# regulação em rascunho na consulta. Só a autora escreve; rascunho e promovido
# aparecem na lista; sem trilha; nada clínico no log.
RSpec.describe "Regulação — pedido na consulta", type: :request do
  let!(:city) { regulation_city! }
  let(:unit) { create_unit("UBS Pedido") }
  let(:doctor) { doctor!(unit) }
  let(:citizen) { regulation_patient!(exam_seq!).last }
  let!(:consultation) { started_consultation!(unit: unit, doctor: doctor, citizen: citizen) }
  let(:path) { "/attendance/consultations/#{consultation.id}/regulation_requests" }
  let(:body) { RegulationHelpers::REGULATION_DEFAULTS.dup }

  def viewed_events = DomainEvent.where(name: "clinical_record.viewed")

  def post_draft(payload = body, to: path) = post(to, params: payload.to_json, headers: { "CONTENT_TYPE" => "application/json" })

  def draft_count(on = consultation) = RegulationRequest.where(consultation_id: on.id, status: "draft").count

  # Promove os rascunhos como a finalização fará (Task 5), sem ela.
  def promote_all!(on = consultation)
    RegulationRequest.where(consultation_id: on.id, status: "draft")
                     .update_all(status: "pending", requested_at: Time.current, due_on: Time.zone.today + 30)
  end

  describe "POST" do
    it "a médica autora cria o rascunho: 201, forma do contrato" do
      sign_in_as(doctor)
      trail = viewed_events.count
      post_draft
      expect(response).to have_http_status(:created)
      expect(json_body).to include(
        "status" => "draft", "type" => "specialty", "requested_at" => nil, "due_on" => nil, "overdue" => false,
        "target" => { "code" => "225120", "name" => "Cardiologia" }, "cid10" => "I10", "ciap2" => nil,
        "justification" => body["justification"], "suggested_color" => "yellow", "color" => nil, "color_reason" => nil,
        "consultation_id" => consultation.id, "authorization" => nil, "appointment_request_id" => nil, "schedule" => nil,
        "outcome" => nil, "misses" => 0, "external" => nil, "state_regulated" => false, "version" => 1, "events" => []
      )
      expect(json_body.fetch("patient").keys).to eq(%w[id display_name has_cpf cns_masked])
      expect(json_body.fetch("patient")).to include("id" => consultation.patient_id, "display_name" => "Maria Aparecida da Silva")
      expect(json_body.fetch("requester")).to eq("name" => Screenings::Json.staff_name(doctor), "cbo" => "225125",
                                                 "unit" => { "id" => unit.id, "name" => unit.name })
      expect(json_body.keys).to eq(%w[id patient type target cid10 ciap2 justification suggested_color color color_reason status
                                      requested_at due_on overdue requester consultation_id authorization appointment_request_id
                                      schedule outcome misses external state_regulated version events])
      expect(viewed_events.count).to eq(trail)

      row = RegulationRequest.find(json_body["id"])
      expect([ row.status, row.requester_user_id, row.requester_cbo, row.requester_unit_id, row.patient_id, row.target_name ])
        .to eq([ "draft", doctor.id, "225125", unit.id, consultation.patient_id, "Cardiologia" ])
    end

    it "state_regulated verdadeiro vale; não booleano → 422 invalid_request em state_regulated" do
      sign_in_as(doctor)
      post_draft(body.merge("state_regulated" => true))
      expect(response).to have_http_status(:created)
      expect(json_body["state_regulated"]).to be(true)
      post_draft(body.merge("state_regulated" => "sim"))
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "state_regulated" } ])
    end

    it "consulta finalizada aceita o rascunho (adendo)" do
      finalized = finalized_consultation!(unit: unit, doctor: doctor, citizen: regulation_patient!(exam_seq!).last)
      sign_in_as(doctor)
      post_draft(body, to: "/attendance/consultations/#{finalized.id}/regulation_requests")
      expect(response).to have_http_status(:created)
    end

    it "consulta descartada → 404 not_found; consulta inexistente ou id inválido também" do
      orphan = started_consultation!(unit: unit, doctor: doctor!(unit), citizen: regulation_patient!(exam_seq!).last)
      discarded = ConsultationDrafts::Discard.call(consultation_id: orphan.id, reason: "Rascunho órfão sem profissional ativo",
                                                   by: regulation_admin!)
      expect(discarded).to be_ok
      sign_in_as(doctor)
      [ orphan.id, SecureRandom.uuid, "nao-e-uuid" ].each do |id|
        post_draft(body, to: "/attendance/consultations/#{id}/regulation_requests")
        expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
      end
    end

    it "outra médica → 403 not_author, nada gravado" do
      sign_in_as(doctor!(unit))
      post_draft
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "not_author" } ])
      expect(draft_count).to eq(0)
    end

    it "quem não é profissional de saúde → 403 missing_role" do
      sign_in_as(care_regulator!)
      post_draft
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    end

    it "enfermeira autora pedindo 225120 (fora da lista) → 403 cbo_not_allowed" do
      nurse = nurse!(unit)
      mine = started_consultation!(unit: unit, doctor: nurse, citizen: regulation_patient!(exam_seq!).last)
      sign_in_as(nurse)
      post_draft(body.merge("ciap2" => "K86"), to: "/attendance/consultations/#{mine.id}/regulation_requests")
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "cbo_not_allowed" } ])
    end

    it "a recusa de CBO sai antes da de diagnóstico (enfermeira, alvo fora da lista, sem diagnóstico)" do
      nurse = nurse!(unit)
      mine = started_consultation!(unit: unit, doctor: nurse, citizen: regulation_patient!(exam_seq!).last)
      sign_in_as(nurse)
      post_draft(body.except("cid10"), to: "/attendance/consultations/#{mine.id}/regulation_requests")
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "cbo_not_allowed" } ])
    end

    context "com a enfermeira autora e um alvo da lista municipal (G10, G12)" do
      let(:nurse) { nurse!(unit) }
      let!(:mine) { started_consultation!(unit: unit, doctor: nurse, citizen: regulation_patient!(exam_seq!).last) }
      let(:nurse_path) { "/attendance/consultations/#{mine.id}/regulation_requests" }
      let(:nurse_body) { body.except("cid10") }

      before do
        expect(CareRegulation::NurseItems.add(target_type: "specialty", target_code: "225120", by: regulation_admin!)).to be_ok
        sign_in_as(nurse)
      end

      it "ciap2 sem cid10 → 201 com ciap2 e cid10 nulo" do
        post_draft(nurse_body.merge("ciap2" => "K86"), to: nurse_path)
        expect(response).to have_http_status(:created)
        expect(json_body).to include("ciap2" => "K86", "cid10" => nil)
        expect(json_body.fetch("requester")).to include("cbo" => "223505")
      end

      it "sem ciap2 → 422 diagnosis_required (path ciap2); com cid10 → 422 cid10_not_allowed_for_cbo (path cid10)" do
        post_draft(nurse_body, to: nurse_path)
        expect([ response.status, json_body ]).to eq([ 422, { "error" => "diagnosis_required", "path" => "ciap2" } ])
        post_draft(nurse_body.merge("cid10" => "I10"), to: nurse_path)
        expect([ response.status, json_body ]).to eq([ 422, { "error" => "cid10_not_allowed_for_cbo", "path" => "cid10" } ])
        expect(draft_count(mine)).to eq(0)
      end
    end

    it "médica só com ciap2 → 422 diagnosis_required (path cid10); com os dois → 201 com os dois" do
      sign_in_as(doctor)
      post_draft(body.except("cid10").merge("ciap2" => "K86"))
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "diagnosis_required", "path" => "cid10" } ])
      post_draft(body.merge("cid10" => "I10", "ciap2" => "K86"))
      expect(response).to have_http_status(:created)
      expect(json_body).to include("cid10" => "I10", "ciap2" => "K86")
    end

    it "cid10 e ciap2 saem normalizados (maiúsculo, sem ponto)" do
      sign_in_as(doctor)
      post_draft(body.merge("cid10" => "i10", "ciap2" => "k86"))
      expect(json_body).to include("cid10" => "I10", "ciap2" => "K86")
    end

    it "ciap2 fora da release → 422 invalid_ciap2 (path ciap2); cid10 Z999 → 422 invalid_cid10 (path cid10)" do
      sign_in_as(doctor)
      post_draft(body.merge("ciap2" => "K99"))
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_ciap2", "path" => "ciap2" } ])
      post_draft(body.merge("cid10" => "Z999"))
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_cid10", "path" => "cid10" } ])
    end

    it "justificativa com 2001 caracteres é recusada, não cortada; 9 também; 2000 vale" do
      sign_in_as(doctor)
      post_draft(body.merge("justification" => "a" * 2001))
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "justification" } ])
      post_draft(body.merge("justification" => "a" * 9))
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "justification" } ])
      post_draft(body.merge("justification" => 12_345_678_901))
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "justification" } ])
      post_draft(body.merge("justification" => "a" * 2000))
      expect(response).to have_http_status(:created)
      expect(json_body["justification"].size).to eq(2000)
      expect(draft_count).to eq(1)
    end

    it "cor sugerida fora de COLORS ou ausente → 422 invalid_request (path suggested_color)" do
      sign_in_as(doctor)
      [ body.merge("suggested_color" => "purple"), body.except("suggested_color") ].each do |payload|
        post_draft(payload)
        expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "suggested_color" } ])
      end
    end

    it "chave desconhecida → 422 invalid_request com o path da chave" do
      sign_in_as(doctor)
      post_draft(body.merge("color" => "red"))
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "color" } ])
    end

    it "procedimento só de APAC → 422 invalid_target (path target_code); o regulável vale" do
      sign_in_as(doctor)
      post_draft(body.merge("type" => "procedure", "target_code" => "0305010107"))
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_target", "path" => "target_code" } ])
      post_draft(body.merge("type" => "procedure", "target_code" => "0209010037"))
      expect(response).to have_http_status(:created)
      expect(json_body).to include("type" => "procedure", "target" => { "code" => "0209010037", "name" => "ESOFAGOGASTRODUODENOSCOPIA" })
    end

    it "tipo ausente ou desconhecido → 422 invalid_target" do
      sign_in_as(doctor)
      [ body.except("type"), body.merge("type" => "exam") ].each do |payload|
        post_draft(payload)
        expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_target", "path" => "target_code" } ])
      end
    end

    it "G4: 10 rascunhos e o 11º → 422 invalid_request (path consultation)" do
      sign_in_as(doctor)
      10.times do
        post_draft
        expect(response).to have_http_status(:created)
      end
      post_draft
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "consultation" } ])
      expect(draft_count).to eq(10)
    end

    it "G4: o limite conta só rascunhos: com 10 pedidos pending (promovidos), mais um rascunho → 201" do
      sign_in_as(doctor)
      10.times { post_draft }
      promote_all!
      expect(draft_count).to eq(0)
      post_draft
      expect(response).to have_http_status(:created)
      expect(RegulationRequest.where(consultation_id: consultation.id).count).to eq(11)
    end

    it "corpo text/plain → 415 json_required" do
      sign_in_as(doctor)
      post path, params: body.to_json, headers: { "CONTENT_TYPE" => "text/plain" }
      expect([ response.status, json_body ]).to eq([ 415, { "error" => "json_required" } ])
      expect(draft_count).to eq(0)
    end

    it "dado do paciente na query não vale (só o corpo)" do
      sign_in_as(doctor)
      post "#{path}?justification=#{'x' * 20}&cid10=I10&type=specialty&target_code=225120", params: {}.to_json,
                                                                                        headers: { "CONTENT_TYPE" => "application/json" }
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_target", "path" => "target_code" } ])
    end

    it "interruptor desligado → 403 feature_disabled" do
      Platform::Features.set!(city: city, key: "care_regulation", enabled: false, maintainer: ledi_maintainer!)
      CityCatalog.reset_cache!
      sign_in_as(doctor)
      post_draft
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "care_regulation" } ])
      get path
      expect(response).to have_http_status(:forbidden)
    end

    it "sem sessão → 401" do
      post_draft
      expect(response).to have_http_status(:unauthorized)
    end

    it "o log da requisição não contém a justificativa, o CID-10 nem o CIAP-2; nenhum clinical_record.viewed" do
      sign_in_as(doctor)
      trail = viewed_events.count
      marker = "SEGREDO#{SecureRandom.hex(4)} paciente com quadro grave"
      log = capture_log do
        post_draft(body.merge("justification" => marker, "cid10" => "I10", "ciap2" => "K86"))
        id = json_body.fetch("id")
        json_patch("#{path}/#{id}", body.merge("justification" => "#{marker} editado", "cid10" => "I10", "ciap2" => "K86"))
        get path
        json_delete("#{path}/#{id}")
        post_draft(body.merge("justification" => marker, "cid10" => "Z999", "ciap2" => "K99"))
      end
      expect(log).to include("regulation_requests") # o log foi capturado
      expect(log).not_to include("SEGREDO")
      expect(log).not_to include("I10")
      expect(log).not_to include("K86")
      expect(log).not_to include("Z999")
      expect(viewed_events.count).to eq(trail)
    end
  end

  describe "PATCH" do
    let(:created) do
      sign_in_as(doctor)
      post_draft
      json_body
    end

    it "substitui o rascunho inteiro (200; chave ausente vira nulo; versão sobe)" do
      id = created.fetch("id")
      json_patch("#{path}/#{id}", { "type" => "specialty", "target_code" => "225250", "cid10" => "I10", "ciap2" => "K86",
                                    "justification" => "Dor torácica atípica em investigação", "suggested_color" => "red" })
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => id, "status" => "draft", "version" => 2, "ciap2" => "K86", "suggested_color" => "red",
                                   "justification" => "Dor torácica atípica em investigação", "state_regulated" => false)
      expect(json_body["target"]["code"]).to eq("225250")

      json_patch("#{path}/#{id}", body.except("ciap2"))
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("ciap2" => nil, "version" => 3, "target" => { "code" => "225120", "name" => "Cardiologia" })
      expect(RegulationRequest.where(consultation_id: consultation.id).count).to eq(1)
    end

    it "valida como o POST (CBO, alvo, diagnóstico, texto) e não grava nada na recusa" do
      id = created.fetch("id")
      {
        body.merge("target_code" => "999999") => [ 422, { "error" => "invalid_target", "path" => "target_code" } ],
        body.merge("cid10" => "Z999") => [ 422, { "error" => "invalid_cid10", "path" => "cid10" } ],
        body.merge("justification" => "curta") => [ 422, { "error" => "invalid_request", "path" => "justification" } ],
        body.merge("foo" => 1) => [ 422, { "error" => "invalid_request", "path" => "foo" } ]
      }.each do |payload, expected|
        json_patch("#{path}/#{id}", payload)
        expect([ response.status, json_body ]).to eq(expected)
      end
      expect(RegulationRequest.find(id)).to have_attributes(version: 1, cid10: "I10")
    end

    it "outra médica → 403 not_author" do
      id = created.fetch("id")
      sign_in_as(doctor!(unit))
      json_patch("#{path}/#{id}", body)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "not_author" } ])
    end

    it "pedido já pending → 409 invalid_transition, intacto" do
      id = created.fetch("id")
      promote_all!
      json_patch("#{path}/#{id}", body.merge("justification" => "Outra justificativa suficiente"))
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition" } ])
      expect(RegulationRequest.find(id)).to have_attributes(status: "pending", version: 1)
    end

    it "id de outra consulta, inexistente ou inválido → 404" do
      other = started_consultation!(unit: unit, doctor: doctor, citizen: regulation_patient!(exam_seq!).last)
      foreign = RegulationRequest.find(created.fetch("id"))
      [ SecureRandom.uuid, "nao-e-uuid" ].each do |rid|
        json_patch("#{path}/#{rid}", body)
        expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
      end
      json_patch("/attendance/consultations/#{other.id}/regulation_requests/#{foreign.id}", body)
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    end

    it "corpo text/plain → 415 json_required" do
      id = created.fetch("id")
      patch "#{path}/#{id}", params: body.to_json, headers: { "CONTENT_TYPE" => "text/plain" }
      expect(response).to have_http_status(:unsupported_media_type)
    end
  end

  describe "DELETE" do
    let(:created) do
      sign_in_as(doctor)
      post_draft
      json_body
    end

    it "apaga o rascunho: 204 sem corpo" do
      id = created.fetch("id")
      json_delete("#{path}/#{id}")
      expect(response).to have_http_status(:no_content)
      expect(response.body).to be_empty
      expect(RegulationRequest.where(id: id)).to be_empty
    end

    it "outra médica → 403 not_author; pedido já pending → 409 invalid_transition" do
      id = created.fetch("id")
      sign_in_as(doctor!(unit))
      json_delete("#{path}/#{id}")
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "not_author" } ])
      sign_in_as(doctor)
      promote_all!
      json_delete("#{path}/#{id}")
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition" } ])
      expect(RegulationRequest.where(id: id)).to exist
    end

    it "id inexistente → 404" do
      created
      json_delete("#{path}/#{SecureRandom.uuid}")
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    end
  end

  describe "GET" do
    it "lista rascunhos e promovidos em created_at, id; sem trilha; sem pedido de outra consulta" do
      sign_in_as(doctor)
      post_draft
      first = json_body.fetch("id")
      post_draft(body.merge("target_code" => "225250", "justification" => "Segundo pedido da mesma consulta"))
      second = json_body.fetch("id")
      other = started_consultation!(unit: unit, doctor: doctor, citizen: regulation_patient!(exam_seq!).last)
      post_draft(body, to: "/attendance/consultations/#{other.id}/regulation_requests")
      RegulationRequest.where(id: first).update_all(status: "pending", requested_at: Time.current, due_on: Time.zone.today + 30)

      trail = viewed_events.count
      get path
      expect(response).to have_http_status(:ok)
      expect(json_body.keys).to eq([ "requests" ])
      expect(json_body["requests"].map { |r| r["id"] }).to eq(RegulationRequest.where(id: [ first, second ]).order(:created_at, :id).pluck(:id))
      expect(json_body["requests"].map { |r| r["status"] }).to match_array(%w[pending draft])
      promoted = json_body["requests"].find { |r| r["id"] == first }
      expect(promoted).to include("requested_at" => a_string_matching(/\A\d{4}-\d\d-\d\dT/), "due_on" => (Time.zone.today + 30).iso8601, "events" => [])
      expect(viewed_events.count).to eq(trail)
    end

    it "consulta sem pedido → lista vazia" do
      sign_in_as(doctor)
      get path
      expect([ response.status, json_body ]).to eq([ 200, { "requests" => [] } ])
    end

    it "outra médica → 403 not_author; consulta descartada ou inexistente → 404" do
      sign_in_as(doctor!(unit))
      get path
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "not_author" } ])
      get "/attendance/consultations/#{SecureRandom.uuid}/regulation_requests"
      expect(response).to have_http_status(:not_found)
    end

    it "pedido enviado devolve o andamento, a autorização e o externo na forma do contrato" do
      sign_in_as(doctor)
      post_draft
      row = RegulationRequest.find(json_body.fetch("id"))
      row.update_columns(status: "external", requested_at: Time.current, due_on: Time.zone.today - 1,
                         external_system: "sisreg", external_number: "SIS-123", state_regulated: true)
      RegulationRequestEvent.create!(regulation_request: row, status: "pending", by_user: doctor)
      RegulationRequestEvent.create!(regulation_request: row, status: "external", by_user: nil, reason: "Regulado pelo estado")
      get path
      item = json_body["requests"].first
      expect(item).to include("status" => "external", "overdue" => true, "external" => { "system" => "sisreg", "number" => "SIS-123" })
      expect(item["events"].map { |e| e["status"] }).to eq(%w[pending external])
      expect(item["events"].first["by"]).to eq("name" => Screenings::Json.staff_name(doctor))
      expect(item["events"].last).not_to have_key("by")
      expect(item["events"].last["reason"]).to eq("Regulado pelo estado")
    end
  end
end
