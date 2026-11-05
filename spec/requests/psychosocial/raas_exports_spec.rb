require "rails_helper"

# Módulo 31 (contrato §6, §13, P4, P14, P15, P37; plano, Desvios 8, 9 e 10):
# remessa RAAS atrás de `layout_version` (registro de layouts vazio até o gate;
# os exemplos registram um layout de teste), a lista sem dado nominal, o
# download com trilha e a ficha espelho em PDF. Gera e baixa: coordenação
# lotada ou faturista; gerar exige step-up. Relógio fixo no meio de novembro.
RSpec.describe "CAPS — remessa RAAS e ficha espelho", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.zone.local(2026, 11, 18, 15, 0)) { example.run } }

  let!(:city) { psychosocial_city! }
  let(:caps) { caps!(modality: "caps_ad_iii") }
  let(:lead) { caps_staff!(caps, cbo: "223505", lead: true) }
  let(:month) { Date.new(2026, 11, 1) }
  def exported_events = DomainEvent.where(name: "psychosocial.raas_exported")
  def downloaded_events = DomainEvent.where(name: "psychosocial.raas_downloaded")
  def viewed = DomainEvent.where(name: "clinical_record.viewed")
  let(:layout) do
    Psychosocial::RaasFile::Layout.new(
      version: "test-1",
      writer: lambda do |header, records|
        ([ "H|#{header[:cnes]}|#{header[:competence]}|#{header[:month]}" ] +
         records.map { |r| "R|#{r['patient']['cns']}|#{r['actions'].map { |a| a['sigtap_code'] }.join(',')}" }).join("\n")
      end
    )
  end

  def with_layout!
    stub_const("Psychosocial::RaasFile::LAYOUTS", { "test-1" => layout }.freeze)
    allow(Psychosocial::Raas).to receive(:config).and_wrap_original { |original| original.call.merge("layout_version" => "test-1") }
  end

  def export!(m = "2026-11", **body) = json_post("/psychosocial/raas_exports", { health_unit_id: caps.id, month: m }.merge(body))
  def record_of(enrollment, m = month) = PsychosocialMonthlyRecord.find_by!(psychosocial_enrollment_id: enrollment.id, month: m)
  def sheets(m = "2026-11", **query) = get("/psychosocial/months/#{m}/sheets.pdf", params: { health_unit_id: caps.id }.merge(query))
  # Matrícula com paciente de nome único (o paciente de teste nasce sempre com o mesmo nome).
  def named_enrollment!(**attrs)
    enrollment!(caps, **attrs).tap { |e| e.patient.update!(full_name: "Paciente #{SecureRandom.alphanumeric(8)} Teste") }
  end

  def text_of(bytes) = PDF::Reader.new(StringIO.new(bytes)).pages.map(&:text).join(" ").gsub(/\s+/, " ")

  # Um registro com ação RAAS, um sem ação (aviso no_actions) e um só com
  # ação BPA-C; o mês fechado pela via real.
  def closed_month!
    with_action = named_enrollment!(started_on: month)
    complete_month!(with_action, month, by: lead)
    quiet = named_enrollment!(started_on: month)
    record_of(quiet).update!(homeless: true)
    bpa_only = named_enrollment!(started_on: month)
    record_of(bpa_only).update!(homeless: false)
    record_action!(caps, lead, sigtap_code: "0301080305", participants: [ { enrollment_id: bpa_only.id } ])
    expect(Psychosocial::CloseMonth.call(unit: caps, month: month, by: lead)).to be_ok
    [ with_action, quiet, bpa_only ]
  end

  before { stepped_up!(lead) }

  describe "POST /psychosocial/raas_exports" do
    it "sem layout registrado (layout_version null) → 422 raas_layout_unavailable, nada gravado" do
      e, = closed_month!
      expect { export! }.not_to(change { [ PsychosocialRaasExport.count, exported_events.count, BillingPeriod.count ] })
      expect([ response.status, json_body["error"] ]).to eq([ 422, "raas_layout_unavailable" ])
      expect(record_of(e).status).to eq("closed")
    end

    it "com o layout: mês aberto → 409 month_open" do
      with_layout!
      complete_month!(named_enrollment!(started_on: month), month, by: lead)
      expect { export! }.not_to change(PsychosocialRaasExport, :count)
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "month_open" } ])
    end

    it "mês fechado → 201: competência do 22, só os registros com ação RAAS exportados, arquivo cifrado e imutável, evento só com o id" do
      with_layout!
      e, quiet, bpa_only = closed_month!
      clerk = billing_clerk!
      BillingPeriod.create!(health_unit: caps, competence: "202611", status: "closed", version: 1, closed_at: Time.current, closed_by_user: clerk)

      log = capture_log { export! }
      expect(response).to have_http_status(:created)
      export = PsychosocialRaasExport.sole
      expect(json_body).to eq("id" => export.id, "health_unit_id" => caps.id, "month" => "2026-11", "competence" => "202612",
                              "layout_version" => "test-1", "records_count" => 1, "sha256" => export.sha256,
                              "created_at" => Time.current.iso8601, "created_by" => Psychosocial::Json.pro(lead, "223505"))
      expect(export).to have_attributes(competence: "202612", billing_period: BillingPeriod.find_by!(health_unit: caps, competence: "202612"),
                                        records_count: 1, created_by_user_id: lead.id)

      bytes = Base64.strict_decode64(export.file_data)
      expect(bytes).to eq("H|#{caps.cnes}|202612|2026-11\nR|#{e.patient.cns}|0301080208")
      expect(export.sha256).to eq(Digest::SHA256.hexdigest(bytes))
      raw = PsychosocialRaasExport.connection.select_value("SELECT file_data FROM psychosocial_raas_exports WHERE id = '#{export.id}'")
      expect(raw).not_to include(export.file_data)

      expect(record_of(e)).to have_attributes(status: "exported", psychosocial_raas_export_id: export.id)
      expect(record_of(quiet)).to have_attributes(status: "closed", psychosocial_raas_export_id: nil) # P14: sem ação fica fora
      expect(record_of(bpa_only)).to have_attributes(status: "closed", psychosocial_raas_export_id: nil) # BPA vai pelo 22
      expect { record_of(e).update!(homeless: true) }.to raise_error(ActiveRecord::StatementInvalid, /exported record never changes/)
      expect { export.update!(records_count: 2) }.to raise_error(ActiveRecord::StatementInvalid)

      expect(exported_events.sole.payload).to eq("raas_export_id" => export.id)
      [ log, response.body ].each do |text|
        expect(text).not_to include(e.patient.full_name)
        expect(text).not_to include(e.patient.cns)
        expect(text).not_to include("F200")
      end
      expect(viewed.count).to eq(0)
    end

    it "depois da remessa: reabrir → 409 already_exported; segunda remessa → 409 already_exported" do
      with_layout!
      closed_month!
      export!
      expect(response).to have_http_status(:created)

      expect(Psychosocial::ReopenMonth.call(unit: caps, month: month, reason: "Ação lançada com CBO errado", by: lead).reason)
        .to eq(:already_exported)
      expect { export! }.not_to change(PsychosocialRaasExport, :count)
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "already_exported" } ])
    end

    it "fix round 1: mês fechado sem registro com ação RAAS → 422 nothing_to_export, nada gravado; o mês ainda reabre" do
      with_layout!
      caps_cnes_bond!(lead, caps)
      quiet = named_enrollment!(started_on: month)
      record_of(quiet).update!(homeless: true)
      bpa_only = named_enrollment!(started_on: month)
      record_of(bpa_only).update!(homeless: false)
      record_action!(caps, lead, sigtap_code: "0301080305", participants: [ { enrollment_id: bpa_only.id } ])
      expect(Psychosocial::CloseMonth.call(unit: caps, month: month, by: lead)).to be_ok

      expect { export! }.not_to(change { [ PsychosocialRaasExport.count, BillingPeriod.count, exported_events.count ] })
      expect([ response.status, json_body["error"] ]).to eq([ 422, "nothing_to_export" ])
      expect([ record_of(quiet).status, record_of(bpa_only).status ]).to eq(%w[closed closed])
      expect(Psychosocial::ReopenMonth.call(unit: caps, month: month, reason: "Faltou lançar as ações do mês", by: lead)).to be_ok
      expect(record_of(quiet).status).to eq("open")
    end

    it "corrida: o índice único (CAPS, mês), casado pelo nome, vira 409 already_exported" do
      with_layout!
      e, = closed_month!
      # a remessa concorrente já gravou a linha, mas a leitura deste lado ainda não a viu
      period = BillingPeriod.create!(health_unit: caps, competence: "202611")
      PsychosocialRaasExport.create!(health_unit: caps, month: month, competence: "202611", billing_period: period, layout_version: "test-1",
                                     file_data: "x", sha256: "0" * 64, records_count: 1, created_by_user: lead)
      allow(Psychosocial::MonthlyRecords).to receive(:exported?).and_return(false)
      expect { export! }.not_to(change { [ PsychosocialRaasExport.count, exported_events.count ] })
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "already_exported" } ])
      expect(record_of(e).status).to eq("closed")
    end

    it "gerar exige coordenação lotada (ou faturista) e step-up; corpo fora da forma → 422" do
      with_layout!
      closed_month!
      sign_in_as(lead)
      export!
      expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])

      stepped_up!(caps_staff!(caps))
      export!
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "lead_required" } ])
      stepped_up!(screener!(caps, cbo: "225125", email: "medico-#{SecureRandom.hex(3)}@cidade.gov.br"))
      export!
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      stepped_up!(caps_staff!(caps!, cbo: "223505", lead: true))
      export!
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "not_on_caps_team" } ])

      stepped_up!(lead)
      export!("2026-1")
      expect([ response.status, json_body["path"] ]).to eq([ 422, "month" ])
      export!(note: "x")
      expect([ response.status, json_body["path"] ]).to eq([ 422, "note" ])
      json_post "/psychosocial/raas_exports", { health_unit_id: "nao-e-uuid", month: "2026-11" }
      expect([ response.status, json_body["path"] ]).to eq([ 422, "health_unit_id" ])
      expect(PsychosocialRaasExport.count).to eq(0)

      clerk = billing_clerk!
      stepped_up!(clerk)
      export!
      expect(response).to have_http_status(:created)
      expect(PsychosocialRaasExport.sole.created_by_user_id).to eq(clerk.id)
      expect(json_body["created_by"]).to include("user_id" => clerk.id, "cbo_code" => nil)
    end
  end

  describe "GET /psychosocial/raas_exports e /raas_exports/:id/file" do
    it "lista sem nome nem dado clínico e sem trilha; o faturista baixa sem lotação, com evento e trilha por paciente" do
      with_layout!
      e, quiet, = closed_month!
      export!
      export = PsychosocialRaasExport.sole
      clerk = billing_clerk!
      sign_in_as(clerk)

      get "/psychosocial/raas_exports", params: { health_unit_id: caps.id, month: "2026-11" }
      expect(response).to have_http_status(:ok)
      expect(json_body["items"].sole).to include("id" => export.id, "month" => "2026-11", "competence" => export.competence,
                                                 "records_count" => 1, "sha256" => export.sha256)
      expect(response.body).not_to include(e.patient.full_name)
      get "/psychosocial/raas_exports", params: { health_unit_id: caps.id, month: "2026-10" }
      expect(json_body["items"]).to eq([])
      get "/psychosocial/raas_exports", params: { health_unit_id: caps.id, q: "Renato" }
      expect([ response.status, json_body["path"] ]).to eq([ 422, "q" ])
      expect(viewed.count).to eq(0)

      log = capture_log { get "/psychosocial/raas_exports/#{export.id}/file" }
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/octet-stream")
      expect(response.headers["Content-Disposition"]).to include("attachment", "RAAS-#{caps.cnes}-#{export.competence}.txt")
      expect(response.headers["Cache-Control"]).to include("no-store")
      expect(response.body).to eq(Base64.strict_decode64(export.file_data))
      expect(downloaded_events.sole.payload).to eq("raas_export_id" => export.id)
      expect(viewed.map(&:payload)).to eq([ { "patient_id" => e.patient_id, "user_id" => clerk.id, "access" => "psychosocial",
                                              "reason_code" => nil, "resource" => "raas_file" } ])
      expect(viewed.map { |v| v.payload["patient_id"] }).not_to include(quiet.patient_id)
      expect(log).not_to include(e.patient.cns)
    end

    it "fix round 1 (ruling): CAPS desativado depois da remessa — faturista e coordenação ainda listam e baixam" do
      with_layout!
      closed_month!
      export!
      export = PsychosocialRaasExport.sole
      caps.update!(active: false)

      [ billing_clerk!, lead ].each do |user|
        sign_in_as(user)
        get "/psychosocial/raas_exports", params: { health_unit_id: caps.id }
        expect(json_body["items"].map { |item| item["id"] }).to eq([ export.id ])
        get "/psychosocial/raas_exports/#{export.id}/file"
        expect(response).to have_http_status(:ok)
        expect(response.body).to eq(Base64.strict_decode64(export.file_data))
      end
      expect(downloaded_events.count).to eq(2)

      stepped_up!(lead)
      export!("2026-10")
      expect([ response.status, json_body["path"] ]).to eq([ 422, "health_unit_id" ]) # gerar continua só para CAPS ativo
    end

    it "baixar: coordenação de outro CAPS → 404; sem papel → 403; conteúdo adulterado → 409 sem trilha" do
      with_layout!
      closed_month!
      export!
      export = PsychosocialRaasExport.sole

      sign_in_as(caps_staff!(caps!, cbo: "223505", lead: true))
      get "/psychosocial/raas_exports/#{export.id}/file"
      expect(response).to have_http_status(:not_found)
      sign_in_as(screener!(caps, cbo: "225125", email: "medico-#{SecureRandom.hex(3)}@cidade.gov.br"))
      get "/psychosocial/raas_exports/#{export.id}/file"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      get "/psychosocial/raas_exports", params: { health_unit_id: caps.id }
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])

      sign_in_as(lead)
      allow(Digest::SHA256).to receive(:hexdigest).and_return("f" * 64)
      get "/psychosocial/raas_exports/#{export.id}/file"
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "integrity_mismatch" } ])
      expect(downloaded_events.count).to eq(0)
      expect(viewed.count).to eq(0)
    end
  end

  describe "GET /psychosocial/months/:month/sheets.pdf" do
    it "mês aberto: PRÉVIA com dados ao vivo, só registros com ação RAAS, trilha por paciente" do
      e = named_enrollment!(started_on: month)
      complete_month!(e, month, by: lead)
      quiet = named_enrollment!(started_on: month)

      log = capture_log { sheets }
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/pdf")
      expect(response.headers["Content-Disposition"]).to include("RAAS-fichas-#{caps.cnes}-202611.pdf")
      text = text_of(response.body)
      expect(text).to include("PRÉVIA", e.patient.full_name, "F200")
      expect(text).not_to include(quiet.patient.full_name)
      expect(viewed.map(&:payload)).to eq([ { "patient_id" => e.patient_id, "user_id" => lead.id, "access" => "psychosocial",
                                              "reason_code" => nil, "resource" => "raas_sheet" } ])
      expect(log).not_to include(e.patient.full_name)
    end

    it "P43: faturista em mês aberto → 409 month_open, sem trilha; a PRÉVIA ao vivo é só da coordenação lotada" do
      e = named_enrollment!(started_on: month)
      complete_month!(e, month, by: lead)

      sign_in_as(billing_clerk!)
      sheets
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "month_open" } ])
      sheets(enrollment_id: e.id)
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "month_open" } ])
      expect(viewed.count).to eq(0)

      sign_in_as(lead)
      sheets
      expect(response).to have_http_status(:ok)
      expect(text_of(response.body)).to include("PRÉVIA", e.patient.full_name)
      expect(viewed.count).to eq(1)
    end

    it "mês fechado: a foto, sem PRÉVIA; ?enrollment_id= dá uma ficha só; o faturista lê sem lotação" do
      e, quiet, bpa_only = closed_month!
      old_name = e.patient.full_name
      e.patient.update!(full_name: "Nome Trocado Depois Do Fechamento")

      sign_in_as(billing_clerk!)
      sheets
      expect(response).to have_http_status(:ok)
      text = text_of(response.body)
      expect(text).to include(old_name)
      expect(text).not_to include("Nome Trocado", "PRÉVIA")

      expect(viewed.map { |v| v.payload["patient_id"] }).to eq([ e.patient_id ])
      sheets(enrollment_id: e.id)
      expect(response).to have_http_status(:ok)
      expect(viewed.map { |v| v.payload["patient_id"] }).to eq([ e.patient_id, e.patient_id ])
      [ quiet, bpa_only ].each do |without| # sem ação RAAS no mês (P14; BPA vai pelo 22): nenhuma ficha, sem trilha
        sheets(enrollment_id: without.id)
        expect(response).to have_http_status(:ok)
        expect(text_of(response.body)).to include("Nenhum registro")
        expect(text_of(response.body)).not_to include(without.patient.full_name)
      end
      expect(viewed.count).to eq(2)
    end

    # P57 (I1): RAAS e ação de mês anterior ao início (gravadas direto: o PATCH
    # que adianta o início agora é recusado) ficam fora da crítica, do
    # fechamento, das fichas e da remessa.
    it "RAAS órfã anterior ao início da matrícula: fora da crítica, do fechamento, das fichas e da remessa" do
      with_layout!
      october = Date.new(2026, 10, 1)
      e = named_enrollment!(started_on: Date.new(2026, 11, 3))
      orphan = PsychosocialMonthlyRecord.create!(psychosocial_enrollment: e, health_unit: caps, month: october)
      action = PsychosocialAction.create!(health_unit: caps, sigtap_code: "0301080208", instrument: "raas_psi",
                                          performed_at: Time.zone.local(2026, 10, 20, 10), month: october, place: "caps", quantity: 1,
                                          professional_user: lead, cbo_code: "223505", origin: "manual")
      PsychosocialActionParticipant.create!(psychosocial_action: action, position: 1, psychosocial_enrollment: e, patient_id: e.patient_id)

      expect(Psychosocial::MonthProblems.for(health_unit: caps, month: october)[:records]).to eq([])
      expect(Psychosocial::RaasRecords.for(unit: caps, month: october)).to eq([])
      sheets("2026-10")
      expect(text_of(response.body)).not_to include(e.patient.full_name)

      expect(Psychosocial::CloseMonth.call(unit: caps, month: october, by: lead)).to be_ok
      expect(orphan.reload).to have_attributes(status: "open", snapshot: nil)
      expect { export!("2026-10") }.not_to change(PsychosocialRaasExport, :count)
      expect([ response.status, json_body["error"] ]).to eq([ 422, "nothing_to_export" ])
    end

    it "matrícula de outro CAPS ou malformada → 404; sem papel → 403; chave a mais → 422" do
      other = caps!
      foreign = enrollment!(other, reference: caps_staff!(other), started_on: month)
      sheets(enrollment_id: foreign.id)
      expect(response).to have_http_status(:not_found)
      sheets(enrollment_id: "nao-e-uuid")
      expect(response).to have_http_status(:not_found)
      sheets(q: "x")
      expect([ response.status, json_body["path"] ]).to eq([ 422, "q" ])
      sheets("2026-13")
      expect([ response.status, json_body["path"] ]).to eq([ 422, "month" ])

      sign_in_as(caps_staff!(caps))
      sheets
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "lead_required" } ])
      sign_in_as(screener!(caps, cbo: "225125", email: "medico-#{SecureRandom.hex(3)}@cidade.gov.br"))
      sheets
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      expect(viewed.count).to eq(0)
    end
  end
end
