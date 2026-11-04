require "rails_helper"

# Módulo 31 (ADR 0049; contrato §10, P18, P45, P46): a linha do tempo restrita
# do CAPS (GET /psychosocial/enrollments/:id/timeline, só a equipe lotada no
# CAPS da matrícula, trilha `timeline`) e o que o resto do sistema vê: na linha
# do tempo geral do profissional, só o marcador "Acompanhamento no CAPS" (sem
# nome, CID, substância, ação, linha do BPA nem documento do CAPS); no
# histórico do cidadão e no PEC externo, nada. Relógio fixo no meio de novembro.
RSpec.describe "CAPS — linha do tempo restrita e o marcador do vínculo", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.zone.local(2026, 11, 18, 15, 0)) { example.run } }

  before do
    Platform::Features.set!(city: city, key: "patient_timeline", enabled: true, maintainer: ledi_maintainer!)
    Platform::Features.set!(city: city, key: "clinical_documents", enabled: true, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
  end

  let!(:city) { psychosocial_city!(billing: true) }
  let(:caps) { caps!(name: "CAPS AD III Centro Vida", modality: "caps_ad_iii") }
  let(:staff) { caps_staff!(caps, cbo: "225133") }
  let(:enrollment) do
    enrollment!(caps, reference: staff, started_on: Date.new(2026, 11, 3), cid: "F102").tap { |e| e.update!(substances: [ "02" ]) }
  end
  let(:patient) { enrollment.patient }
  let(:citizen) { Citizen.find_by!(patient_id: patient.id) }
  let(:ubs) { create_unit("UBS Boa Vista") }
  let(:doctor) { ubs_doctor!(ubs) }
  let(:hidden) { [ "Centro Vida", "AD III", "caps_ad_iii", "F102", "Crack", "crack", "Isolamento" ] }
  def body = JSON.parse(response.body)
  def timeline_of(target, **params) = get("/psychosocial/enrollments/#{target.id}/timeline", params: params)
  def viewed = DomainEvent.where(name: "clinical_record.viewed")

  # O CAPS inteiro do paciente: ação RAAS com evolução, acolhimento inicial
  # (BPA-I, com a linha do 22), PTS e atestado da ação.
  def caps_history!
    action = record_action!(caps, staff, performed_at: Time.zone.local(2026, 11, 10, 10), notes: "Relata uso diário de crack",
                                         participants: [ { enrollment_id: enrollment.id } ])
    reception = record_action!(caps, staff, sigtap_code: "0301080232", performed_at: Time.zone.local(2026, 11, 3, 9),
                                            participants: [ { patient_id: patient.id } ])
    line = Billing::FromPsychosocial.call(reception)
    raise "linha BPA-I não gerada" unless line&.patient_id == patient.id

    plan = PsychosocialCarePlan.create!(psychosocial_enrollment: enrollment, version: 1, needs: "Isolamento social e uso de crack",
                                        goals: [ "Reduzir o uso" ], intensity: "intensive", review_on: Date.current + 90, created_by_user: staff,
                                        created_at: Time.zone.local(2026, 11, 4, 9))
    document = caps_document!(action, kind: "sick_note", issued_at: Time.zone.local(2026, 11, 10, 11))
    { action: action, reception: reception, line: line, plan: plan, document: document }
  end

  describe "GET /psychosocial/enrollments/:id/timeline" do
    it "a equipe lotada lê ação, PTS, documento e o marcador, com trilha timeline; nada de evolução nem CID" do
      history = caps_history!
      sign_in_as(staff)
      expect { timeline_of(enrollment) }.to change { viewed.count }.by(1)
      expect(response).to have_http_status(:ok)
      expect(body.keys).to contain_exactly("items", "next_before")
      kinds = body["items"].map { |entry| [ entry["kind"], entry.dig("detail_ref", "type") ] }
      expect(kinds).to eq([ [ "psychosocial", "clinical_document" ], [ "psychosocial", "psychosocial_action" ],
                            [ "psychosocial", "psychosocial_care_plan" ], [ "psychosocial", "psychosocial_action" ],
                            [ "psychosocial_link", nil ] ])
      expect(body["items"].map { |entry| entry["id"] }).to include("psychosocial:#{history[:action].id}", "psychosocial:#{history[:plan].id}",
                                                                 "psychosocial:#{history[:reception].id}", "psychosocial_link:#{enrollment.id}")
      expect(body["items"].first.keys).to eq(%w[id kind occurred_at unit professional title summary status detail_ref])
      expect(body["next_before"]).to be_nil
      expect(response.body).not_to include("crack", "F102", "Isolamento")
      expect(viewed.order(:occurred_at, :created_at).last.payload)
        .to eq("patient_id" => patient.id, "user_id" => staff.id, "access" => "psychosocial", "reason_code" => nil, "resource" => "timeline")
    end

    it "o cursor pagina; cursor inválido e chave fora da lista na query → 422" do
      caps_history!
      sign_in_as(staff)
      ids = []
      timeline_of(enrollment, limit: 2)
      ids.concat(body["items"].map { |entry| entry["id"] })
      while body["next_before"]
        timeline_of(enrollment, limit: 2, before: body["next_before"])
        expect(response).to have_http_status(:ok)
        ids.concat(body["items"].map { |entry| entry["id"] })
      end
      timeline_of(enrollment)
      expect(ids).to eq(body["items"].map { |entry| entry["id"] })
      expect(ids.size).to eq(5)

      timeline_of(enrollment, before: "lixo")
      expect([ response.status, body["error"], body["path"] ]).to eq([ 422, "invalid_cursor", "before" ])
      timeline_of(enrollment, cid: "F102")
      expect([ response.status, body["error"], body["path"] ]).to eq([ 422, "invalid_request", "cid" ])
    end

    it "outro CAPS → 404; sem o papel do CAPS → 403; interruptor desligado → 403; nada de trilha" do
      other_staff = caps_staff!(caps!)
      sign_in_as(other_staff)
      expect { timeline_of(enrollment) }.not_to(change { viewed.count })
      expect([ response.status, body["error"] ]).to eq([ 404, "not_found" ])
      timeline_of(Struct.new(:id).new("nao-e-uuid"))
      expect(response).to have_http_status(:not_found)

      sign_in_as(doctor)
      timeline_of(enrollment)
      expect([ response.status, body["error"] ]).to eq([ 403, "missing_role" ])

      Platform::Features.set!(city: city, key: "psychosocial_care", enabled: false, maintainer: ledi_maintainer!)
      sign_in_as(staff)
      timeline_of(enrollment)
      expect([ response.status, body["error"] ]).to eq([ 403, "feature_disabled" ])
    end
  end

  describe "linha do tempo geral (UBS)" do
    it "o médico da UBS em contexto vê só o marcador 'Acompanhamento no CAPS', sem nome; nem ação, nem BPA-I, nem documento do CAPS" do
      history = caps_history!
      attendance = in_context!(doctor, ubs, patient)
      sign_in_as(doctor)
      get "/attendance/timeline", params: { attendance_id: attendance.id }
      expect(response).to have_http_status(:ok)
      kinds = body["entries"].map { |entry| entry["kind"] }
      expect(kinds).to include("psychosocial_link", "attendance")
      expect(kinds).not_to include("psychosocial", "clinical_document")
      ids = body["entries"].map { |entry| entry["id"] }
      expect(ids).not_to include("procedure:#{history[:line].id}", "clinical_document:#{history[:document].id}")
      link = body["entries"].find { |entry| entry["kind"] == "psychosocial_link" }
      expect(link).to eq("id" => "psychosocial_link:#{enrollment.id}", "kind" => "psychosocial_link",
                         "occurred_at" => Date.new(2026, 11, 3).in_time_zone.iso8601, "unit" => nil, "professional" => nil,
                         "title" => "Acompanhamento no CAPS", "summary" => "Desde 03/11/2026", "status" => "open", "detail_ref" => nil)
      expect(response.body).not_to include(caps.name)
      hidden.each { |text| expect(response.body).not_to include(text) }

      # Filtros: o marcador sozinho; a fonte do CAPS nunca é aceita aqui.
      get "/attendance/timeline", params: { attendance_id: attendance.id, kinds: %w[psychosocial_link] }
      expect(body["entries"].map { |entry| entry["kind"] }).to eq(%w[psychosocial_link])
      get "/attendance/timeline", params: { attendance_id: attendance.id, kinds: %w[psychosocial] }
      expect([ response.status, body["error"] ]).to eq([ 422, "invalid_kinds" ])
      get "/attendance/timeline", params: { attendance_id: attendance.id, kinds: %w[procedure] }
      expect(body["entries"].map { |entry| entry["id"] }).not_to include("procedure:#{history[:line].id}")
    end

    it "o cursor da linha do tempo geral passa pelo marcador" do
      attendance = in_context!(doctor, ubs, patient)
      sign_in_as(doctor)
      get "/attendance/timeline", params: { attendance_id: attendance.id, kinds: %w[psychosocial_link attendance], limit: 1 }
      seen = body["entries"].map { |entry| entry["kind"] }
      while body["next_before"]
        get "/attendance/timeline", params: { attendance_id: attendance.id, kinds: %w[psychosocial_link attendance], limit: 1,
                                              before: body["next_before"] }
        expect(response).to have_http_status(:ok)
        seen.concat(body["entries"].map { |entry| entry["kind"] })
      end
      expect(seen).to include("psychosocial_link", "attendance")
    end
  end

  describe "cidadão (wpda)" do
    it "o histórico nunca traz o CAPS: o marcador e a fonte são recusados no filtro e ficam fora da lista" do
      caps_history!
      sign_in_citizen(citizen.phone)
      get "/citizen/history", params: { citizen_id: citizen.id }
      expect(response).to have_http_status(:ok)
      expect(body["entries"].map { |entry| entry["kind"] }.grep(/\Apsychosocial/)).to eq([])
      expect(body["entries"].map { |entry| entry["kind"] }).not_to include("procedure", "clinical_document")
      expect(response.body).not_to include(caps.name)
      hidden.each { |text| expect(response.body).not_to include(text) }
      %w[psychosocial_link psychosocial].each do |kind|
        get "/citizen/history", params: { citizen_id: citizen.id, kinds: [ kind ] }
        expect([ response.status, body["error"] ]).to eq([ 422, "invalid_kinds" ])
      end
    end
  end
end
