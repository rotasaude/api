require "rails_helper"

# Contrato §3 (ADR 0035): a linha do tempo do profissional com as regras de
# leitura do 19a sobre a pessoa, trilha `timeline`, filtros e cursor.
RSpec.describe "Linha do tempo do profissional", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:unit) { create_unit("UBS Centro") }
  let(:doctor) { doctor!(unit) }
  let(:citizen) { verified_citizen!(101, social_name: "Bia") }
  def body = JSON.parse(response.body)
  def status_and_error = [ response.status, body["error"] ]

  context "modo record" do
    before { timeline_city!; ciap2_release!; cid10_release!; sigtap_release! }

    it "em contexto pelo atendimento: entradas, pessoa, trilha timeline" do
      consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
      attendance = consulting_attendance!(unit, citizen: citizen.reload, doctor: doctor)
      sign_in_as(doctor)
      get "/attendance/timeline", params: { attendance_id: attendance.id }
      expect(response).to have_http_status(:ok)
      expect(body["person"]).to eq("display_name" => "Bia", "partial" => false, "patient_id" => consultation.patient_id)
      expect(body["entries"].map { |e| e["kind"] }).to include("consultation", "attendance", "triage")
      expect(body["entries"].first.keys).to eq(%w[id kind occurred_at unit professional title summary status detail_ref])
      expect(response.body).not_to include("Refere sede", "Metformina")
      expect(DomainEvent.where(name: "clinical_record.viewed").last.payload)
        .to eq("patient_id" => consultation.patient_id, "user_id" => doctor.id, "access" => "timeline", "reason_code" => nil,
               "person_ref" => "patient:#{consultation.patient_id}")
    end

    it "fora de contexto: 403; com abertura válida (opening_id ou patient_id), justificada com o motivo na trilha" do
      consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
      other = doctor!(unit, cbo: "225142")
      sign_in_as(other)
      get "/attendance/timeline", params: { patient_id: consultation.patient_id }
      expect(status_and_error).to eq([ 403, "out_of_context" ])
      now = Time.current
      opening = ClinicalRecordOpening.create!(patient: consultation.patient, user: other, reason_code: "case_review",
                                              created_at: now, expires_at: now + 30.minutes)
      get "/attendance/timeline", params: { opening_id: opening.id }
      expect(response).to have_http_status(:ok)
      expect(DomainEvent.where(name: "clinical_record.viewed").last.payload["reason_code"]).to eq("case_review")
      get "/attendance/timeline", params: { patient_id: consultation.patient_id }
      expect(response).to have_http_status(:ok)
      sign_in_as(doctor!(unit, cbo: "223505"))
      get "/attendance/timeline", params: { opening_id: opening.id }
      expect(status_and_error).to eq([ 403, "opening_required" ])
      travel_to(31.minutes.from_now) do
        sign_in_as(other)
        get "/attendance/timeline", params: { opening_id: opening.id }
        expect(status_and_error).to eq([ 403, "opening_required" ])
      end
    end

    it "atendimento de par declarado: 409; sem alvo ou alvo inexistente: 404; recepção: 403 missing_role" do
      declared = consulting_attendance!(unit, citizen: screening_citizen!(102), doctor: doctor)
      sign_in_as(doctor)
      get "/attendance/timeline", params: { attendance_id: declared.id }
      expect(status_and_error).to eq([ 409, "citizen_not_verified" ])
      get "/attendance/timeline"
      expect(status_and_error).to eq([ 404, "not_found" ])
      get "/attendance/timeline", params: { patient_id: SecureRandom.uuid }
      expect(status_and_error).to eq([ 404, "not_found" ])
      get "/attendance/timeline", params: { attendance_id: "nao-e-uuid" }
      expect(status_and_error).to eq([ 404, "not_found" ])
      sign_in_as(reception!)
      get "/attendance/timeline", params: { attendance_id: declared.id }
      expect(status_and_error).to eq([ 403, "missing_role" ])
    end

    it "filtros, limite e cursor; erros de período, kinds e cursor" do
      attendance = consulting_attendance!(unit, citizen: citizen, doctor: doctor)
      sign_in_as(doctor)
      get "/attendance/timeline", params: { attendance_id: attendance.id, kinds: %w[attendance], limit: 1 }
      expect(body["entries"].map { |e| e["kind"] }).to eq(%w[attendance])
      expect(body["next_before"]).to be_nil
      get "/attendance/timeline", params: { attendance_id: attendance.id, limit: 1 }
      expect(body["next_before"]).to be_present
      get "/attendance/timeline", params: { attendance_id: attendance.id, limit: 1, before: body["next_before"] }
      expect(response).to have_http_status(:ok)
      get "/attendance/timeline", params: { attendance_id: attendance.id, from: Time.zone.tomorrow.iso8601 }
      expect(body["entries"]).to eq([])
      [ [ { from: "ontem" }, "invalid_period" ], [ { from: Time.zone.today.iso8601, to: Time.zone.yesterday.iso8601 }, "invalid_period" ],
        [ { kinds: %w[vaccine] }, "invalid_kinds" ], [ { kinds: "attendance" }, "invalid_kinds" ], [ { before: "lixo" }, "invalid_cursor" ] ]
        .each do |extra, error|
          get "/attendance/timeline", params: { attendance_id: attendance.id }.merge(extra)
          expect(status_and_error).to eq([ 422, error ]), extra.inspect
        end
    end

    it "kinds repetidos não duplicam entradas; abertura de par excluído: 404 sem trilha" do
      attendance = consulting_attendance!(unit, citizen: citizen, doctor: doctor)
      sign_in_as(doctor)
      get "/attendance/timeline", params: { attendance_id: attendance.id, kinds: %w[attendance attendance] }
      expect(body["entries"].map { |e| e["kind"] }).to eq(%w[attendance])
      get "/attendance/timeline", params: { attendance_id: attendance.id, kinds: [ "" ] }
      expect(status_and_error).to eq([ 422, "invalid_kinds" ])

      other = doctor!(unit, cbo: "225142")
      now = Time.current
      opening = ClinicalRecordOpening.create!(patient: nil, citizen: citizen, user: other, reason_code: "case_review",
                                              created_at: now, expires_at: now + 30.minutes)
      citizen.update_columns(cpf: "erased:#{SecureRandom.hex(4)}", erased_at: Time.current)
      sign_in_as(other)
      expect { get "/attendance/timeline", params: { opening_id: opening.id } }
        .not_to change { DomainEvent.where(name: "clinical_record.viewed").count }
      expect(status_and_error).to eq([ 404, "not_found" ])
    end
  end

  context "modo integrado" do
    before { timeline_city!(record_mode: "integrated", clinical_record: false) }

    it "pessoa sem paciente, histórico parcial; interruptor desligado: 403 feature_disabled" do
      attendance = consulting_attendance!(unit, citizen: citizen, doctor: doctor)
      sign_in_as(doctor)
      get "/attendance/timeline", params: { attendance_id: attendance.id }
      expect(body["person"]).to eq("display_name" => "Bia", "partial" => true, "patient_id" => nil)
      expect(DomainEvent.where(name: "clinical_record.viewed").last.payload["person_ref"]).to eq("citizen:#{citizen.id}")
      Platform::Features.set!(city: Current.city, key: "patient_timeline", enabled: false, maintainer: ledi_maintainer!)
      get "/attendance/timeline", params: { attendance_id: attendance.id }
      expect([ response.status, body["error"], body["feature"] ]).to eq([ 403, "feature_disabled", "patient_timeline" ])
    end
  end
end
