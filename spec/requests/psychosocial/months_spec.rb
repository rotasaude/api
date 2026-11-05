require "rails_helper"

# Módulo 31 (contrato §6, P6, P13, P14, P24, P25, P36, P37; plano, Desvios 6 e
# 7; Review Focus 3): RAAS do mês — situação de rua por registro (só `open`),
# pendências lidas e nunca gravadas (problems bloqueiam, warnings não),
# fechamento com step-up da coordenação (foto cifrada, evento só com
# health_unit_id e month, ações travadas) e reabertura com motivo antes da
# remessa. Relógio fixo (meio de novembro, ou o `now:` do exemplo).
RSpec.describe "CAPS — RAAS do mês", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(example.metadata[:now] || Time.zone.local(2026, 11, 18, 15, 0)) { example.run } }

  let!(:city) { psychosocial_city! }
  let(:caps) { caps!(modality: "caps_ad_iii") }
  let(:lead) { caps_staff!(caps, cbo: "223505", lead: true) }
  let(:month) { Date.new(2026, 11, 1) }
  let(:closed_events) { DomainEvent.where(name: "psychosocial.month_closed") }
  let(:reopened_events) { DomainEvent.where(name: "psychosocial.month_reopened") }
  let(:reason) { "Ação lançada com CBO errado" }

  def show(m = "2026-11", unit: caps) = get("/psychosocial/months/#{m}", params: { health_unit_id: unit.id })
  def close!(m = "2026-11", **body) = json_post("/psychosocial/months/#{m}/close", { health_unit_id: caps.id }.merge(body))
  def reopen!(m = "2026-11", **body) = json_post("/psychosocial/months/#{m}/reopen", { health_unit_id: caps.id, reason: reason }.merge(body))
  def record_of(enrollment, m = month) = PsychosocialMonthlyRecord.find_by!(psychosocial_enrollment_id: enrollment.id, month: m)
  def errors = json_body["problems"].map { |p| p["error"] }

  before { stepped_up!(lead) }

  describe "GET /psychosocial/months/:month" do
    it "pendências lidas, nunca gravadas: problems por registro com ação RAAS; sem ação, tudo é aviso (P57)" do
      e = enrollment!(caps, patient: caps_patient!(cns: false), started_on: month)
      caps_cnes_bond!(lead, caps)
      record_action!(caps, lead, participants: [ { enrollment_id: e.id } ])
      quiet = enrollment!(caps, patient: caps_patient!(cns: false), started_on: month)
      expect { show }.not_to(change { [ PsychosocialMonthlyRecord.where(status: "open").count, DomainEvent.count ] })
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("month" => "2026-11", "health_unit_id" => caps.id, "status" => "open", "closure" => nil)
      item, idle = json_body["records"]
      expect(item).to include("id" => record_of(e).id, "enrollment_id" => e.id, "status" => "open", "homeless" => nil,
                              "patient" => Psychosocial::Json.patient_ref(e.patient), "actions_count" => 1)
      expect(item["problems"]).to eq(%w[patient_cns_missing homeless_missing])
      expect(item["warnings"]).to eq([])
      expect(idle).to include("id" => record_of(quiet).id, "actions_count" => 0, "problems" => [],
                              "warnings" => %w[patient_cns_missing homeless_missing no_actions])
      expect(json_body["counts"]).to eq("records" => 2, "open" => 2, "closed" => 0, "exported" => 0, "with_problems" => 1,
                                        "with_warnings" => 1, "actions" => 1)
      expect(response.body).not_to include("F200")
      expect(DomainEvent.where(name: "clinical_record.viewed").count).to eq(0)
    end

    it "a equipe (não só a coordenação) lê; mês malformado → 422 month; CAPS não lotado → 403" do
      staff = caps_staff!(caps)
      sign_in_as(staff)
      show
      expect(response).to have_http_status(:ok)
      show("2026-13")
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "month" ])
      show(unit: caps!)
      expect([ response.status, json_body["error"] ]).to eq([ 403, "not_on_caps_team" ])
      get "/psychosocial/months/2026-11", params: { health_unit_id: caps.id, q: "Renato" }
      expect([ response.status, json_body["path"] ]).to eq([ 422, "q" ])
    end
  end

  describe "PATCH /psychosocial/monthly_records/:id" do
    it "grava a situação de rua do registro aberto; fechado → 409 record_not_open; fora da forma → 422" do
      e = enrollment!(caps, started_on: month)
      json_patch "/psychosocial/monthly_records/#{record_of(e).id}", homeless: true
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => record_of(e).id, "status" => "open", "homeless" => true, "month" => "2026-11")
      expect(record_of(e).homeless).to be(true)

      json_patch "/psychosocial/monthly_records/#{record_of(e).id}", homeless: "sim"
      expect([ response.status, json_body["path"] ]).to eq([ 422, "homeless" ])
      json_patch "/psychosocial/monthly_records/#{record_of(e).id}", homeless: false, notes: "x"
      expect([ response.status, json_body["path"] ]).to eq([ 422, "notes" ])

      record_of(e).update!(status: "closed", snapshot: {}, closed_at: Time.current)
      json_patch "/psychosocial/monthly_records/#{record_of(e).id}", homeless: false
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "record_not_open" } ])
      expect(record_of(e).homeless).to be(true)
    end

    it "registro de outro CAPS → 404" do
      other = caps!
      e = enrollment!(other, reference: caps_staff!(other), started_on: month)
      json_patch "/psychosocial/monthly_records/#{record_of(e).id}", homeless: true
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /psychosocial/months/:month/close e /reopen" do
    it "com pendência recusa: 422 month_has_problems, um item por (registro, pendência), nada gravado" do
      e = enrollment!(caps, patient: caps_patient!(cns: false), started_on: month)
      caps_cnes_bond!(lead, caps)
      record_action!(caps, lead, participants: [ { enrollment_id: e.id } ]) # com ação RAAS: vai à remessa, então bloqueia (P57)
      expect { close! }.not_to(change { [ PsychosocialMonthClosure.count, closed_events.count ] })
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["error"]).to eq("month_has_problems")
      expect(json_body["problems"]).to eq([ { "error" => "patient_cns_missing", "path" => "records.#{record_of(e).id}" },
                                            { "error" => "homeless_missing", "path" => "records.#{record_of(e).id}" } ])
      expect(record_of(e).status).to eq("open")
      expect(e.reload).to be_open
    end

    it "fecha sem pendência: foto cifrada, evento só com unidade e mês, ações travadas; o aviso no_actions não bloqueia" do
      e = enrollment!(caps, started_on: month)
      complete_month!(e, month)
      quiet = enrollment!(caps, started_on: month)
      record_of(quiet).update!(homeless: true)

      log = capture_log { close! }
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("status" => "closed")
      expect(json_body["closure"]).to include("closed_at" => Time.current.iso8601, "closed_by" => Psychosocial::Json.pro(lead, "223505"))
      expect(PsychosocialMonthClosure.active.sole).to have_attributes(health_unit_id: caps.id, month: month, closed_by_user_id: lead.id)

      record = record_of(e)
      expect(record).to have_attributes(status: "closed", closed_at: Time.current)
      expect(record.snapshot).to include("origin" => "01", "cid_main" => "F200", "homeless" => false, "destination" => "00")
      expect(record.snapshot["patient"]).to include("name" => e.patient.full_name, "cns" => e.patient.cns,
                                                    "race_color" => "03", "phone" => be_present)
      expect(record_of(quiet)).to have_attributes(status: "closed") # o aviso não bloqueia; a foto vale também para ele
      raw = PsychosocialMonthlyRecord.connection.select_value("SELECT snapshot FROM psychosocial_monthly_records WHERE id = '#{record.id}'")
      expect(raw).not_to include(e.patient.full_name)

      expect(closed_events.sole.payload).to eq("health_unit_id" => caps.id, "month" => "2026-11")
      [ log, closed_events.sole.payload.to_json ].each do |text|
        expect(text).not_to include(e.patient.full_name)
        expect(text).not_to include(e.patient.cns)
      end

      expect { record_action!(caps, lead, participants: [ { enrollment_id: e.id } ]) }.to raise_error(/month_closed/)
      close!
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "already_closed" } ])
    end

    it "reabre com motivo (10..500) antes da remessa: registros voltam a open sem foto; o motivo nunca no evento" do
      e = enrollment!(caps, started_on: month)
      complete_month!(e, month)
      close!

      reopen!(reason: "curto")
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "reason" ])
      reopen!(reason: "x" * 501)
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "too_long", "reason" ])

      reopen!
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("status" => "open", "closure" => nil)
      expect(record_of(e)).to have_attributes(status: "open", snapshot: nil, closed_at: nil)
      closure = PsychosocialMonthClosure.sole
      expect(closure).to have_attributes(reopened_by_user_id: lead.id, reopen_reason: reason, reopened_at: Time.current)
      expect(reopened_events.sole.payload).to eq("health_unit_id" => caps.id, "month" => "2026-11")

      reopen!
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "month_open" } ])
      close!
      expect(response).to have_http_status(:ok)
      expect(PsychosocialMonthClosure.active.count).to eq(1)
    end

    it "mês exportado não reabre: 409 already_exported" do
      e = enrollment!(caps, started_on: month)
      complete_month!(e, month)
      close!
      period = BillingPeriod.create!(health_unit: caps, competence: "202611")
      export = PsychosocialRaasExport.create!(health_unit: caps, month: month, competence: "202611", billing_period: period,
                                              layout_version: "test", file_data: "x", sha256: "0" * 64, records_count: 1,
                                              created_by_user: lead)
      record_of(e).update!(status: "exported", psychosocial_raas_export: export)

      expect { reopen! }.not_to(change { [ PsychosocialMonthClosure.active.count, reopened_events.count ] })
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "already_exported" } ])
      show
      expect(json_body["status"]).to eq("exported")
    end

    it "fechar e reabrir exigem a coordenação e o step-up" do
      staff = caps_staff!(caps)
      stepped_up!(staff)
      close!
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "lead_required" } ])
      reopen!
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "lead_required" } ])

      sign_in_as(lead)
      close!
      expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
      reopen!
      expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
      expect(PsychosocialMonthClosure.count).to eq(0)
    end

    it "mês futuro ou malformado → 422 month; chave desconhecida → 422 com o path" do
      close!("2026-12")
      expect([ response.status, json_body["path"] ]).to eq([ 422, "month" ])
      close!("2026-1")
      expect([ response.status, json_body["path"] ]).to eq([ 422, "month" ])
      close!(note: "x")
      expect([ response.status, json_body["path"] ]).to eq([ 422, "note" ])
      expect(PsychosocialMonthClosure.count).to eq(0)
    end

    it "P37: a RAAS de mês depois do encerramento fica fora das pendências e do fechamento, e nunca se apaga" do
      e = enrollment!(caps, started_on: Date.new(2026, 10, 1))
      after = Psychosocial::MonthlyRecords.ensure!(e, month) # a continuidade de novembro já tinha rodado
      result = Psychosocial::CloseEnrollment.call(enrollment: e, destination: "01", closed_on: "2026-10-20", by: lead)
      expect(result).to be_ok

      show
      expect(json_body["records"]).to eq([])
      expect(json_body["counts"]["records"]).to eq(0)
      close!
      expect(response).to have_http_status(:ok)
      expect(after.reload).to have_attributes(status: "open", snapshot: nil) # nem travada pelo fechamento
      reopen!
      expect(after.reload.status).to eq("open")

      # o mês do encerramento continua na crítica: outubro sem ação e sem situação de rua (avisos, P57)
      show("2026-10")
      expect(json_body["records"].sole).to include("id" => record_of(e, Date.new(2026, 10, 1)).id, "problems" => [],
                                                   "warnings" => %w[homeless_missing no_actions])
      expect { after.delete }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
    end

    it "Review Focus 3: no leito na virada do mês, novembro não fecha; a saída grava cada noite no seu mês e então fecha",
       now: Time.zone.local(2026, 12, 2, 9, 0) do
      e = enrollment!(caps, started_on: Date.new(2026, 11, 3))
      complete_month!(e, month)
      caps_cnes_bond!(lead, caps)
      stay = PsychosocialNightStay.create!(psychosocial_bed: bed!(caps), health_unit: caps, psychosocial_enrollment: e, patient_id: e.patient_id,
                                           started_at: Time.zone.local(2026, 11, 29, 19), expected_end_at: Time.zone.local(2026, 12, 3, 8),
                                           started_by_user: lead)

      close!
      expect([ response.status, json_body["error"] ]).to eq([ 422, "month_has_problems" ])
      expect(json_body["problems"]).to eq([ { "error" => "night_stay_open", "path" => "records.#{record_of(e).id}" } ])
      show
      expect(json_body["records"].sole["problems"]).to eq(%w[night_stay_open])

      json_post "/psychosocial/night_stays/#{stay.id}/close", ended_at: Time.zone.local(2026, 12, 2, 8).iso8601,
                                                             reason: "Alta do acolhimento noturno combinada"
      expect(response).to have_http_status(:ok)
      nights = PsychosocialAction.where(psychosocial_night_stay_id: stay.id).order(:performed_at)
      expect(nights.map { |a| [ a.performed_at.in_time_zone.to_date, a.month ] })
        .to eq([ [ Date.new(2026, 11, 29), month ], [ Date.new(2026, 11, 30), month ], [ Date.new(2026, 12, 1), Date.new(2026, 12, 1) ] ])

      close!
      expect(response).to have_http_status(:ok)
      expect(record_of(e).status).to eq("closed")
      expect(record_of(e, Date.new(2026, 12, 1)).status).to eq("open")
    end

    it "permanência que só começa no mês seguinte não bloqueia o anterior", now: Time.zone.local(2026, 12, 2, 9, 0) do
      e = enrollment!(caps, started_on: Date.new(2026, 11, 3))
      complete_month!(e, month)
      Psychosocial::MonthlyRecords.ensure!(e, Date.new(2026, 12, 1))
      PsychosocialNightStay.create!(psychosocial_bed: bed!(caps), health_unit: caps, psychosocial_enrollment: e, patient_id: e.patient_id,
                                    started_at: Time.zone.local(2026, 12, 1, 19), expected_end_at: Time.zone.local(2026, 12, 3, 8),
                                    started_by_user: lead)
      close!
      expect(response).to have_http_status(:ok)
    end
  end
end
