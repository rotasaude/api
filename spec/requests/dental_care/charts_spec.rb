require "rails_helper"

# Módulo 28 (ADR 0046; contrato §16 O1, O13, O25, O27; Task 7): leitura
# nominal do odontograma, dos eventos, dos planos e da endodontia. Acesso do
# prontuário, uma trilha por paciente mostrado, nada de dado clínico na URL.
RSpec.describe "Saúde bucal — leitura do paciente", type: :request do
  let!(:city) { dental_city! }
  let(:unit) { create_unit }
  let(:dentist) { dentist!(unit) }
  let(:citizen) { verified_citizen!(1, social_name: "Mariana") }
  let!(:consultation) do
    finalized_dental!(unit: unit, by: dentist, citizen: citizen,
                      dental: { "findings" => [ { "tooth" => 16, "situation" => "caries" }, { "tooth" => 16, "face" => "O", "situation" => "caries" },
                                                { "tooth" => 16, "part" => "root", "situation" => "root_caries" },
                                                { "tooth" => 26, "situation" => "sound" } ],
                                "plan_changes" => { "add" => [ { "sigtap" => "0307010074", "location" => { "kind" => "tooth", "tooth" => 16 } } ] },
                                "endodontics" => [ { "tooth" => 16, "canals" => 3, "status" => "in_progress" } ] })
  end
  let(:patient_id) { consultation.patient_id }

  def body = JSON.parse(response.body)
  def viewed = DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at, :created_at)
  def in_context! = consulting_attendance!(unit, citizen: citizen.reload, doctor: dentist)
  def tooth(number) = body.fetch("teeth").find { |t| t["tooth"] == number.to_s }

  describe "odontograma" do
    it "dentista em contexto: situações, faces, raiz, dentição, planos abertos e uma trilha dental sem dado clínico" do
      in_context!
      viewed.delete_all
      sign_in_as(dentist)
      get "/dental/patients/#{patient_id}/dental_chart"
      expect(response).to have_http_status(:ok)
      expect(body["patient"]).to include("id" => patient_id, "display_name" => "Mariana", "has_cpf" => true)
      expect(body["patient"].keys).to match_array(%w[id display_name has_cpf cns_masked])
      expect(body["dentition"]).to eq("permanent")
      expect(tooth(16)).to include("situation" => "caries", "root" => "root_caries", "faces" => include("O" => "caries", "M" => nil))
      expect(tooth(16)["notes_count"]).to be >= 3
      expect(tooth(16)["last_event_at"]).to be_a(String)
      expect(tooth(26)).to include("situation" => "sound", "root" => nil)
      expect(tooth(11)).to include("situation" => nil, "faces" => include("M" => "restored")) # procedimento do dental_body
      expect(body["teeth"].size).to eq(DentalCare::Chart::TEETH.size)
      expect(body["teeth"].map { |t| t["tooth"] }).to all(be_a(String))
      plan = DentalTreatmentPlan.find_by!(patient_id: patient_id)
      expect(body["open_plans"]).to eq([ { "id" => plan.id, "health_unit" => { "id" => unit.id, "name" => unit.name, "kind" => unit.kind } } ])
      payload = viewed.last.payload
      expect(viewed.count).to eq(1)
      expect(payload).to include("patient_id" => patient_id, "user_id" => dentist.id, "access" => "in_context", "access_scope" => "dental")
      expect(payload.to_s).not_to match(/caries|root_caries|situation|tooth/)
    end

    it "fora de contexto: 403 out_of_context sem trilha; abertura justificada: 200; recepção: 403 missing_role" do
      viewed.delete_all
      sign_in_as(dentist)
      get "/dental/patients/#{patient_id}/dental_chart"
      expect([ response.status, body["error"] ]).to eq([ 403, "out_of_context" ])
      expect(viewed.count).to eq(0)
      now = Time.current
      ClinicalRecordOpening.create!(patient_id: patient_id, user: dentist, reason_code: "case_review", created_at: now, expires_at: now + 30.minutes)
      get "/dental/patients/#{patient_id}/dental_chart"
      expect(response).to have_http_status(:ok)
      expect(viewed.last.payload).to include("access" => "justified", "reason_code" => "case_review", "access_scope" => "dental")
      sign_in_as(reception!)
      get "/dental/patients/#{patient_id}/dental_chart"
      expect([ response.status, body["error"] ]).to eq([ 403, "missing_role" ])
    end

    it "paciente inexistente ou id malformado: 404" do
      in_context!
      sign_in_as(dentist)
      get "/dental/patients/#{SecureRandom.uuid}/dental_chart"
      expect(response).to have_http_status(:not_found)
      get "/dental/patients/xyz/dental_chart"
      expect(response).to have_http_status(:not_found)
    end

    it "interruptor desligado: 403 feature_disabled nas quatro rotas, sem trilha" do
      in_context!
      sign_in_as(dentist)
      Platform::Features.set!(city: city, key: "dental_care", enabled: false, maintainer: ledi_maintainer!)
      viewed.delete_all
      %w[dental_chart dental_chart/events dental_plans endodontic_treatments].each do |path|
        get "/dental/patients/#{patient_id}/#{path}"
        expect([ path, response.status, body ]).to eq([ path, 403, { "error" => "feature_disabled", "feature" => "dental_care" } ])
      end
      expect(viewed.count).to eq(0)
    end

    it "a URL e o log levam só ids, nunca dado clínico" do
      in_context!
      sign_in_as(dentist)
      log = capture_log { get "/dental/patients/#{patient_id}/dental_chart/events?limit=2" }
      expect(response).to have_http_status(:ok)
      expect(log).not_to match(/caries|root_caries|situation/)
      expect(Rails.application.routes.recognize_path("/dental/patients/#{patient_id}/dental_chart/events", method: :get))
        .to include(controller: "dental_care/charts", action: "events")
    end
  end

  describe "eventos" do
    it "páginas por before/limit em ordem do mais novo, sem repetir nem perder, e sem next_before na última" do
      in_context!
      sign_in_as(dentist)
      get "/dental/patients/#{patient_id}/dental_chart/events?limit=2"
      expect(response).to have_http_status(:ok)
      first = body
      expect(first["events"].size).to eq(2)
      expect(first["next_before"]).to be_a(String)
      seen = first["events"].map { |e| e["id"] }
      pages = 1
      cursor = first["next_before"]
      while cursor
        get "/dental/patients/#{patient_id}/dental_chart/events", params: { limit: 2, before: cursor }
        expect(response).to have_http_status(:ok)
        seen += body["events"].map { |e| e["id"] }
        cursor = body["next_before"]
        pages += 1
        break if pages > 20
      end
      all = DentalChartEvent.where(patient_id: patient_id).pluck(:id)
      expect(seen).to match_array(all)
      expect(seen.uniq.size).to eq(all.size)
      expect(pages).to be >= 3
      expect(body["events"].size).to be <= 2
      expect(body["next_before"]).to be_nil
    end

    it "ordem estável com o mesmo recorded_at (desempate por seq) e forma do evento" do
      in_context!
      sign_in_as(dentist)
      get "/dental/patients/#{patient_id}/dental_chart/events"
      expect(response).to have_http_status(:ok)
      events = body["events"]
      expected = DentalChartEvent.where(patient_id: patient_id).order(Arel.sql("recorded_at DESC, seq DESC")).pluck(:id)
      expect(events.map { |e| e["id"] }).to eq(expected)
      event = events.find { |e| e["tooth"] == "16" && e["part"] == "root" }
      expect(event).to include("face" => nil, "situation" => "root_caries", "procedure" => nil, "consultation_id" => consultation.id,
                               "addendum_id" => nil, "by" => { "name" => dentist.professional.professional_name, "cbo" => "223208" })
      expect(event["at"]).to be_a(String)
      proc_event = events.find { |e| e["procedure"] }
      expect(proc_event["procedure"]).to eq("sigtap" => "0307010031", "name" => "RESTAURAÇÃO DE DENTE PERMANENTE ANTERIOR COM RESINA COMPOSTA")
    end

    it "limit fora de 1..100 → 422; cursor adulterado → 422 invalid_cursor; ?tooth= é ignorado" do
      in_context!
      sign_in_as(dentist)
      [ "0", "101", "x" ].each do |limit|
        get "/dental/patients/#{patient_id}/dental_chart/events", params: { limit: limit }
        expect([ response.status, body["error"] ]).to eq([ 422, "invalid_limit" ])
      end
      [ "lixo", Base64.urlsafe_encode64("[1,2]", padding: false), Base64.urlsafe_encode64(%(["2026-01-01T00:00:00.000000Z","x"]), padding: false),
        Base64.urlsafe_encode64(%(["2026-01-01T00:00:00.000000Z",1,2]), padding: false) ].each do |cursor|
        get "/dental/patients/#{patient_id}/dental_chart/events", params: { before: cursor }
        expect([ response.status, body["error"], body["path"] ]).to eq([ 422, "invalid_cursor", "before" ])
      end
      get "/dental/patients/#{patient_id}/dental_chart/events?tooth=99"
      expect(response).to have_http_status(:ok)
      expect(body["events"].size).to eq(DentalChartEvent.where(patient_id: patient_id).count)
    end
  end

  describe "planos" do
    it "lista o plano com itens, filtra por unidade e status e valida os filtros" do
      in_context!
      sign_in_as(dentist)
      get "/dental/patients/#{patient_id}/dental_plans"
      expect(response).to have_http_status(:ok)
      plan = body["plans"].sole
      expect(plan).to include("status" => "open", "opened_in_consultation_id" => consultation.id, "closed_in_consultation_id" => nil,
                              "health_unit" => { "id" => unit.id, "name" => unit.name, "kind" => unit.kind })
      expect(plan["items"].sole).to include("sigtap" => "0307010074", "name" => "TRATAMENTO RESTAURADOR ATRAUMÁTICO (TRA/ART)",
                                            "status" => "planned", "done_in_consultation_id" => nil, "cancel_reason" => nil,
                                            "location" => { "kind" => "tooth", "tooth" => "16", "face" => nil, "sextant" => nil, "arch" => nil })
      other = create_unit("UBS Outra")
      get "/dental/patients/#{patient_id}/dental_plans", params: { health_unit_id: other.id }
      expect(body).to eq("plans" => [])
      get "/dental/patients/#{patient_id}/dental_plans", params: { health_unit_id: unit.id, status: "open" }
      expect(body["plans"].size).to eq(1)
      get "/dental/patients/#{patient_id}/dental_plans", params: { status: "completed" }
      expect(body).to eq("plans" => [])
      get "/dental/patients/#{patient_id}/dental_plans", params: { status: "zzz" }
      expect([ response.status, body["error"], body["path"] ]).to eq([ 422, "invalid_request", "status" ])
      get "/dental/patients/#{patient_id}/dental_plans", params: { health_unit_id: "x" }
      expect([ response.status, body["path"] ]).to eq([ 422, "health_unit_id" ])
      get "/dental/patients/#{patient_id}/dental_plans", params: { limit: 0 }
      expect([ response.status, body["error"] ]).to eq([ 422, "invalid_limit" ])
      expect(viewed.last.payload).to include("access_scope" => "dental")
    end
  end

  describe "endodontia" do
    it "tratamentos com unidade e sessões (consulta, canais, hora, quem fez)" do
      in_context!
      sign_in_as(dentist)
      get "/dental/patients/#{patient_id}/endodontic_treatments"
      expect(response).to have_http_status(:ok)
      treatment = body["treatments"].sole
      expect(treatment).to include("tooth" => "16", "canals" => 3, "status" => "in_progress",
                                   "health_unit" => { "id" => unit.id, "name" => unit.name, "kind" => unit.kind })
      session = treatment["sessions"].sole
      expect(session).to include("consultation_id" => consultation.id, "canals" => 3, "by" => { "name" => dentist.professional.professional_name })
      expect(session["at"]).to be_a(String)
      get "/dental/patients/#{patient_id}/endodontic_treatments", params: { limit: 101 }
      expect([ response.status, body["error"] ]).to eq([ 422, "invalid_limit" ])
      expect(viewed.where("payload ->> 'access_scope' = 'dental'").count).to eq(1)
    end
  end
end
