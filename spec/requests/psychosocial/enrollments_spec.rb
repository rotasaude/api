require "rails_helper"

# Módulo 31 (contrato §4, P5, P12, P13): matrícula no CAPS — criação com a
# RAAS do mês do início, lista sem dado clínico e sem trilha (sem `q`, P5),
# detalhe com trilha, edição (origem e início travados depois da primeira RAAS
# exportada) e encerramento (destino na RAAS do mês do encerramento).
RSpec.describe "CAPS — matrícula", type: :request do
  let!(:city) { psychosocial_city! }
  let(:caps) { caps! }
  let(:staff) { caps_staff!(caps) }
  let(:patient) { caps_patient! }
  let(:viewed) { DomainEvent.where(name: "clinical_record.viewed") }

  def body(**over)
    { health_unit_id: caps.id, patient_id: patient.id, started_on: Date.current.iso8601, origin: "02", cid_main: "F20.0",
      cid_secondary: [ "F10.2" ], substances: [ "01" ], esf_covered: false, reference_user_id: staff.id }.merge(over)
  end

  def enroll!(**over)
    json_post "/psychosocial/enrollments", body(**over)
    raise "matrícula recusada: #{response.body}" unless response.status == 201

    json_body["id"]
  end

  before { sign_in_as(staff) }

  describe "POST /psychosocial/enrollments" do
    it "matricula, cria a RAAS do mês e recusa a segunda aberta no mesmo CAPS" do
      expect { json_post "/psychosocial/enrollments", body }.to change(PsychosocialMonthlyRecord, :count).by(1)
      expect(response).to have_http_status(:created)
      expect(json_body).to include("status" => "open", "cid_main" => "F200", "cid_secondary" => [ "F102" ], "substances" => [ "01" ],
                                   "origin" => "02", "esf_covered" => false, "esf_cnes" => nil)
      expect(json_body["reference"]).to eq(Psychosocial::Json.pro(staff, "251510"))
      enrollment = PsychosocialEnrollment.find(json_body["id"])
      expect(PsychosocialMonthlyRecord.find_by!(psychosocial_enrollment_id: enrollment.id))
        .to have_attributes(month: Date.current.beginning_of_month, status: "open", health_unit_id: caps.id)
      expect(DomainEvent.where(name: "psychosocial.enrolled").last.payload).to eq("enrollment_id" => enrollment.id)

      json_post "/psychosocial/enrollments", body
      expect([ response.status, json_body["error"] ]).to eq([ 409, "enrollment_open" ])
    end

    it "recusas todas de uma vez; ESF exige o CNES da USF" do
      json_post "/psychosocial/enrollments", body(origin: "77", cid_main: "XYZ", substances: [ "99", "01" ], esf_covered: true)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["problems"].map { |p| p["path"] }).to contain_exactly("origin", "cid_main", "substances", "esf_cnes")
      expect(json_body["problems"].find { |p| p["path"] == "esf_cnes" }["error"]).to eq("esf_cnes_required")
      expect(response.body).not_to include("XYZ")
      expect(PsychosocialEnrollment.count).to eq(0)
    end

    it "início futuro, técnico de referência fora do CAPS, mais de 4 CIDs secundários e chave desconhecida" do
      outsider = caps_staff!(caps!(modality: "caps_ad"))
      json_post "/psychosocial/enrollments", body(started_on: Date.tomorrow.iso8601, reference_user_id: outsider.id,
                                                  cid_secondary: %w[F10.2 F10.2 F10.2 F10.2 F10.2], esf_covered: false,
                                                  esf_cnes: "1234567", extra: 1)
      expect(json_body["problems"].map { |p| p["path"] })
        .to contain_exactly("started_on", "reference_user_id", "cid_secondary", "esf_cnes", "extra")
    end

    it "ESF coberta grava o CNES da USF" do
      enroll!(esf_covered: true, esf_cnes: "1234567")
      expect(json_body).to include("esf_covered" => true, "esf_cnes" => "1234567")
      json_post "/psychosocial/enrollments", body(patient_id: caps_patient!.id, esf_covered: true, esf_cnes: "12345")
      expect(json_body["problems"]).to eq([ { "error" => "invalid_request", "path" => "esf_cnes" } ])
    end

    it "início em mês fechado → 422 month_closed started_on, nada gravado (ruling)" do
      start = Date.current.beginning_of_month.prev_month
      PsychosocialMonthClosure.create!(health_unit: caps, month: start, closed_at: Time.current, closed_by_user: staff)
      request_body = body(started_on: (start + 3).iso8601) # o paciente nasce antes da contagem
      expect { json_post "/psychosocial/enrollments", request_body }
        .not_to change { [ PsychosocialEnrollment.count, PsychosocialMonthlyRecord.count, DomainEvent.count ] }
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "month_closed", "started_on" ])
    end

    it "corrida na matrícula aberta (índice único) → 409 enrollment_open, nada gravado" do
      enroll!
      allow(PsychosocialEnrollment).to receive(:open_enrollments).and_return(PsychosocialEnrollment.none)
      expect { json_post "/psychosocial/enrollments", body }
        .not_to change { [ PsychosocialEnrollment.count, PsychosocialMonthlyRecord.count, DomainEvent.count ] }
      expect([ response.status, json_body["error"] ]).to eq([ 409, "enrollment_open" ])
    end

    it "fora do CAPS de lotação → 403 not_on_caps_team" do
      json_post "/psychosocial/enrollments", body(health_unit_id: caps!(modality: "caps_ad").id)
      expect([ response.status, json_body["error"] ]).to eq([ 403, "not_on_caps_team" ])
    end
  end

  describe "leitura" do
    it "lista sem CID e sem trilha; detalhe com CID e com trilha; outro CAPS → 403 e 404" do
      id = enroll!
      expect { get "/psychosocial/enrollments", params: { health_unit_id: caps.id } }.not_to(change { viewed.count })
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("F200")
      item = json_body["items"].sole
      expect(item.keys).to contain_exactly("id", "patient", "started_on", "reference", "next_visit_at", "status", "care_plan_review_on")
      expect(item["patient"]).to eq(Psychosocial::Json.patient_ref(patient))
      expect(json_body["next_before"]).to be_nil

      expect { get "/psychosocial/enrollments/#{id}" }.to change { viewed.count }.by(1)
      expect(json_body).to include("cid_main" => "F200", "substances" => [ "01" ], "origin" => "02")
      expect(viewed.last.payload).to include("patient_id" => patient.id, "user_id" => staff.id, "access" => "psychosocial",
                                             "resource" => "enrollment")

      sign_in_as(caps_staff!(caps!(modality: "caps_ad")))
      get "/psychosocial/enrollments", params: { health_unit_id: caps.id }
      expect(json_body["error"]).to eq("not_on_caps_team")
      get "/psychosocial/enrollments/#{id}"
      expect(response).to have_http_status(:not_found)
    end

    it "filtra pela situação e recusa `q` (P5) sem o nome no log" do
      open_id = enroll!
      closed_id = enroll!(patient_id: caps_patient!.id)
      json_post "/psychosocial/enrollments/#{closed_id}/close", destination: "01", closed_on: Date.current.iso8601

      get "/psychosocial/enrollments", params: { health_unit_id: caps.id, status: "open" }
      expect(json_body["items"].map { |i| i["id"] }).to eq([ open_id ])
      get "/psychosocial/enrollments", params: { health_unit_id: caps.id, status: "closed" }
      expect(json_body["items"].map { |i| [ i["id"], i["status"] ] }).to eq([ [ closed_id, "closed" ] ])
      get "/psychosocial/enrollments", params: { health_unit_id: caps.id, status: "x" }
      expect(json_body["path"]).to eq("status")

      log = capture_log { get "/psychosocial/enrollments", params: { health_unit_id: caps.id, q: "Renato" } }
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "q" ])
      expect(log).not_to include("Renato")
    end

    it "papel fora do CAPS → 403 missing_role" do
      id = enroll!
      sign_in_as(ubs_doctor!(create_unit))
      get "/psychosocial/enrollments/#{id}"
      expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
    end
  end

  describe "PATCH /psychosocial/enrollments/:id" do
    it "a resposta traz o detalhe clínico e grava a trilha; corpo vazio → 422" do
      id = enroll!
      expect { json_patch "/psychosocial/enrollments/#{id}", cid_main: "F31.2" }.to change { viewed.count }.by(1)
      expect(viewed.last.payload).to include("patient_id" => patient.id, "access" => "psychosocial", "resource" => "enrollment")

      expect { json_patch "/psychosocial/enrollments/#{id}", {} }.not_to(change { viewed.count })
      expect([ response.status, json_body["error"] ]).to eq([ 422, "invalid_request" ])
    end

    it "início movido para mês fechado, ou com o mês de início atual fechado → 422 month_closed (ruling)" do
      month = Date.current.beginning_of_month
      id = enroll!(started_on: month.iso8601)
      previous = month.prev_month
      PsychosocialMonthClosure.create!(health_unit: caps, month: previous, closed_at: Time.current, closed_by_user: staff)
      json_patch "/psychosocial/enrollments/#{id}", started_on: (previous + 5).iso8601
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "month_closed", "started_on" ])

      older = previous.prev_month
      other = enroll!(patient_id: caps_patient!.id, started_on: (older + 10).iso8601)
      PsychosocialMonthClosure.create!(health_unit: caps, month: older, closed_at: Time.current, closed_by_user: staff)
      json_patch "/psychosocial/enrollments/#{other}", started_on: month.iso8601
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "month_closed", "started_on" ])
      expect(PsychosocialEnrollment.find(other).started_on).to eq(older + 10)
    end

    it "edita CIDs, substâncias, ESF, técnico e próxima visita" do
      id = enroll!
      other = caps_staff!(caps, cbo: "223505")
      visit = 2.days.from_now.change(sec: 0)
      json_patch "/psychosocial/enrollments/#{id}", cid_main: "F31.2", cid_secondary: [], substances: [ "99" ], esf_covered: true,
                                                    esf_cnes: "7654321", reference_user_id: other.id, next_visit_at: visit.iso8601
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("cid_main" => "F312", "cid_secondary" => [], "substances" => [ "99" ], "esf_cnes" => "7654321")
      expect(Time.iso8601(json_body["next_visit_at"])).to eq(visit)
      expect(json_body["reference"]).to eq(Psychosocial::Json.pro(other, "223505"))

      json_patch "/psychosocial/enrollments/#{id}", esf_covered: false
      expect(json_body).to include("esf_covered" => false, "esf_cnes" => nil)
      json_patch "/psychosocial/enrollments/#{id}", esf_covered: true
      expect([ json_body["error"], json_body["path"] ]).to eq([ "esf_cnes_required", "esf_cnes" ])
    end

    it "origem e início só antes da primeira RAAS exportada (origin_locked)" do
      id = enroll!(started_on: Date.current.beginning_of_month.iso8601)
      json_patch "/psychosocial/enrollments/#{id}", origin: "03"
      expect(json_body["origin"]).to eq("03")

      PsychosocialMonthlyRecord.find_by!(psychosocial_enrollment_id: id).update!(status: "exported", snapshot: { "origin" => "03" })
      json_patch "/psychosocial/enrollments/#{id}", origin: "04", started_on: Date.current.beginning_of_month.prev_day.iso8601
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["problems"]).to contain_exactly({ "error" => "origin_locked", "path" => "origin" },
                                                       { "error" => "origin_locked", "path" => "started_on" })
      json_patch "/psychosocial/enrollments/#{id}", origin: "03", cid_main: "F20.1"
      expect([ response.status, json_body["cid_main"] ]).to eq([ 200, "F201" ])
    end

    it "matrícula encerrada não se edita (409 already_closed)" do
      id = enroll!
      json_post "/psychosocial/enrollments/#{id}/close", destination: "01", closed_on: Date.current.iso8601
      json_patch "/psychosocial/enrollments/#{id}", cid_main: "F31.2"
      expect([ response.status, json_body["error"] ]).to eq([ 409, "already_closed" ])
    end
  end

  describe "POST /psychosocial/enrollments/:id/close" do
    it "a resposta traz o detalhe clínico e grava a trilha; a recusa não grava" do
      id = enroll!
      expect { json_post "/psychosocial/enrollments/#{id}/close", destination: "00", closed_on: Date.current.iso8601 }
        .not_to(change { viewed.count })
      expect { json_post "/psychosocial/enrollments/#{id}/close", destination: "01", closed_on: Date.current.iso8601 }
        .to change { viewed.count }.by(1)
      expect(viewed.last.payload).to include("patient_id" => patient.id, "access" => "psychosocial", "resource" => "enrollment")
    end

    it "encerrar: 00 recusado, data futura recusada; o destino vai à RAAS do mês do encerramento" do
      id = enroll!
      json_post "/psychosocial/enrollments/#{id}/close", destination: "00", closed_on: Date.current.iso8601
      expect(json_body["error"]).to eq("destination_is_permanence")
      json_post "/psychosocial/enrollments/#{id}/close", destination: "01", closed_on: Date.tomorrow.iso8601
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "closed_on_in_future", "closed_on" ])

      json_post "/psychosocial/enrollments/#{id}/close", destination: "01", closed_on: Date.current.iso8601
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("status" => "closed", "destination" => "01", "closed_on" => Date.current.iso8601)
      record = PsychosocialMonthlyRecord.find_by!(psychosocial_enrollment_id: id, month: Date.current.beginning_of_month)
      expect([ record.destination, record.concluded_on ]).to eq([ "01", Date.current ])
      expect(DomainEvent.where(name: "psychosocial.enrollment_closed").last.payload).to eq("enrollment_id" => id)

      json_post "/psychosocial/enrollments/#{id}/close", destination: "01", closed_on: Date.current.iso8601
      expect([ response.status, json_body["error"] ]).to eq([ 409, "already_closed" ])
    end

    it "encerrar em mês anterior cria a RAAS daquele mês; mês fechado recusa" do
      start = Date.current.beginning_of_month.prev_month
      id = enroll!(started_on: start.iso8601)
      PsychosocialMonthClosure.create!(health_unit: caps, month: start, closed_at: Time.current, closed_by_user: staff)
      json_post "/psychosocial/enrollments/#{id}/close", destination: "04", closed_on: (start + 10).iso8601
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "month_closed", "closed_on" ])

      json_post "/psychosocial/enrollments/#{id}/close", destination: "04", closed_on: Date.current.beginning_of_month.iso8601
      record = PsychosocialMonthlyRecord.find_by!(psychosocial_enrollment_id: id, month: Date.current.beginning_of_month)
      expect([ record.destination, record.concluded_on ]).to eq([ "04", Date.current.beginning_of_month ])
    end

    it "com permanência noturna aberta → 409 night_stay_open, nada encerrado; depois da saída, o encerramento passa (ruling)" do
      night_caps = caps!(modality: "caps_ad_iii")
      tech = caps_staff!(night_caps, cbo: "322205")
      enrollment = enrollment!(night_caps, reference: tech, started_on: Date.current.prev_month.beginning_of_month)
      stay = PsychosocialNightStay.create!(psychosocial_bed: bed!(night_caps), health_unit: night_caps, psychosocial_enrollment: enrollment,
                                           patient_id: enrollment.patient_id, started_at: Date.yesterday.in_time_zone.change(hour: 19),
                                           expected_end_at: Date.tomorrow.in_time_zone.change(hour: 8), started_by_user: tech)
      sign_in_as(tech)
      expect do
        json_post "/psychosocial/enrollments/#{enrollment.id}/close", destination: "01", closed_on: Date.current.iso8601
      end.not_to(change { [ enrollment.reload.closed_on, DomainEvent.where(name: "psychosocial.enrollment_closed").count ] })
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "night_stay_open" } ])

      json_post "/psychosocial/night_stays/#{stay.id}/close", ended_at: Time.current.iso8601, reason: "Alta do acolhimento noturno"
      expect(response).to have_http_status(:ok)
      json_post "/psychosocial/enrollments/#{enrollment.id}/close", destination: "01", closed_on: Date.current.iso8601
      expect(response).to have_http_status(:ok)
      expect(enrollment.reload.closed_on).to eq(Date.current)
    end

    it "encerramento antes do início é recusado" do
      id = enroll!
      json_post "/psychosocial/enrollments/#{id}/close", destination: "01", closed_on: Date.yesterday.iso8601
      expect([ json_body["error"], json_body["path"] ]).to eq([ "invalid_request", "closed_on" ])
    end
  end

  describe "Psychosocial::MonthlyRecords.ensure!" do
    it "cria uma vez por mês e, com o mês fechado, devolve o existente sem criar" do
      enrollment = PsychosocialEnrollment.find(enroll!)
      month = Date.current.beginning_of_month
      expect { Psychosocial::MonthlyRecords.ensure!(enrollment, month + 5) }.not_to change(PsychosocialMonthlyRecord, :count)
      next_month = month.next_month
      PsychosocialMonthClosure.create!(health_unit: caps, month: next_month, closed_at: Time.current, closed_by_user: staff)
      expect(Psychosocial::MonthlyRecords.ensure!(enrollment, next_month)).to be_nil
      expect(Psychosocial::MonthlyRecords.ensure!(enrollment, month).month).to eq(month)
    end
  end
end
