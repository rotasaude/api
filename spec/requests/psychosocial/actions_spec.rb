require "rails_helper"

# Módulo 31 (contrato §4, P3, P12, P13, P23, P25; Desvios 3, 4 e 5; Review
# Focus 1 e 2): ações do CAPS — individuais, coletivas e no território — com a
# crítica SIGTAP na hora (422 action_rejected com problems[] { error, path,
# participant_index? }), imutáveis, canceladas com motivo; a lista sem notas
# nem trilha, o detalhe com notas e a trilha por paciente. Relógio fixo (meio
# de novembro, ou o `now:` do exemplo): nada depende da virada do mês.
RSpec.describe "CAPS — ações", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(example.metadata[:now] || Time.zone.local(2026, 11, 18, 15, 0)) { example.run } }

  let!(:city) { psychosocial_city! }
  let(:caps) { caps! }
  let(:staff) { caps_staff!(caps, cbo: "251510") }
  # Matrículas do mês anterior (com a RAAS só de outubro): uma RAAS indevida
  # do mês da ação aparece na contagem.
  let(:a) { enrollment!(caps, reference: staff, started_on: Date.current.prev_month.beginning_of_month) }
  let(:b) { enrollment!(caps, reference: staff, started_on: Date.current.prev_month.beginning_of_month) }
  let(:recorded) { DomainEvent.where(name: "psychosocial.action_recorded") }
  let(:viewed) { DomainEvent.where(name: "clinical_record.viewed") }

  def action(**over)
    { health_unit_id: caps.id, sigtap_code: "0301080216", performed_at: 1.hour.ago.iso8601, place: "caps", quantity: 1,
      notes: "Grupo de convivência; boa participação", participants: [ { enrollment_id: a.id }, { enrollment_id: b.id } ] }.merge(over)
  end

  def errors = json_body["problems"].map { |p| p["error"] }
  def counts = [ PsychosocialAction.count, PsychosocialActionParticipant.count, PsychosocialMonthlyRecord.count, recorded.count ]

  before { sign_in_as(staff) }

  describe "POST /psychosocial/actions" do
    it "coletiva: uma ação, um participante por matrícula na ordem (position 1..n), a RAAS do mês, o evento só com o id" do
      a && b
      expect { json_post "/psychosocial/actions", action }.to change(PsychosocialAction, :count).by(1)
        .and change(PsychosocialActionParticipant, :count).by(2)
      expect(response).to have_http_status(:created)
      expect(json_body).to include("instrument" => "raas_psi", "participants_count" => 2, "place" => "caps", "quantity" => 1,
                                   "cancelled" => false, "notes" => "Grupo de convivência; boa participação")
      expect(json_body["sigtap"]).to include("code" => "0301080216", "instrument" => "raas_psi")
      expect(json_body["professional"]).to eq(Psychosocial::Json.pro(staff, "251510"))
      saved = PsychosocialAction.find(json_body["id"])
      expect(saved).to have_attributes(cbo_code: "251510", professional_user_id: staff.id, origin: "manual",
                                       month: Date.current.beginning_of_month)
      expect(saved.psychosocial_action_participants.map { |p| [ p.position, p.psychosocial_enrollment_id, p.patient_id ] })
        .to eq([ [ 1, a.id, a.patient_id ], [ 2, b.id, b.patient_id ] ])
      [ a, b ].each do |enrollment|
        expect(PsychosocialMonthlyRecord.where(psychosocial_enrollment_id: enrollment.id, month: Date.current.beginning_of_month)).to exist
      end
      expect(recorded.last.payload).to eq("action_id" => saved.id)
      expect(viewed.count).to eq(0)
    end

    it "Review Focus 1: participante de outro CAPS (ou encerrado) recusa tudo, com o índice; nada gravado" do
      a && b
      foreign = enrollment!(caps!(modality: "caps_ad"))
      expect do
        json_post "/psychosocial/actions", action(participants: [ { enrollment_id: a.id }, { enrollment_id: b.id }, { enrollment_id: foreign.id } ])
      end.not_to(change { counts })
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "action_rejected",
                              "problems" => [ { "error" => "enrollment_required", "path" => "participants[2]", "participant_index" => 2 } ])

      b.update_columns(closed_on: Date.current, destination: "01", closed_by_user_id: staff.id)
      expect { json_post "/psychosocial/actions", action }.not_to(change { counts })
      expect(json_body["problems"]).to eq([ { "error" => "enrollment_required", "path" => "participants[1]", "participant_index" => 1 } ])
    end

    it "crítica completa de uma vez: quantidade, data futura, autorização e familiar fora do atendimento familiar" do
      json_post "/psychosocial/actions", action(sigtap_code: "0301080291", quantity: 1, performed_at: 1.hour.from_now.iso8601,
                                                participants: [ { enrollment_id: a.id }, { family_name: "Mãe do usuário" } ])
      expect(json_body["problems"]).to eq([
        { "error" => "performed_in_future", "path" => "performed_at" },
        { "error" => "authorization_required", "path" => "authorization_number" },
        { "error" => "family_only_for_family_care", "path" => "participants[1].family_name", "participant_index" => 1 }
      ])
      json_post "/psychosocial/actions", action(sigtap_code: "0301080208", quantity: 32)
      expect(json_body["problems"]).to eq([ { "error" => "quantity_exceeded", "path" => "quantity" } ])
      expect(PsychosocialAction.count).to eq(0)
    end

    it "CBO do vínculo fora da lista do código → cbo_incompatible em sigtap_code" do
      a && b
      sign_in_as(caps_staff!(caps, cbo: "515105"))
      json_post "/psychosocial/actions", action
      expect(json_body["problems"]).to eq([ { "error" => "cbo_incompatible", "path" => "sigtap_code" } ])
    end

    it "código fora da SIGTAP → instrument_mismatch; com autorização de 13 dígitos o 0301080291 passa" do
      json_post "/psychosocial/actions", action(sigtap_code: "0399999999")
      expect(json_body["problems"]).to eq([ { "error" => "instrument_mismatch", "path" => "sigtap_code" } ])
      json_post "/psychosocial/actions", action(sigtap_code: "0301080291", authorization_number: "1234567890123",
                                                participants: [ { enrollment_id: a.id } ])
      expect(response).to have_http_status(:created)
      expect(PsychosocialAction.find(json_body["id"]).authorization_number).to eq("1234567890123")
    end

    it "atendimento familiar aceita familiar sem cadastro" do
      json_post "/psychosocial/actions", action(sigtap_code: "0301080224", participants: [ { enrollment_id: a.id }, { family_name: "Mãe do usuário" } ])
      expect(response).to have_http_status(:created)
      family = PsychosocialAction.find(json_body["id"]).psychosocial_action_participants.last
      expect([ family.position, family.family_name, family.patient_id ]).to eq([ 2, "Mãe do usuário", nil ])
    end

    it "Review Focus 2: 23:30 locais de 30/11 são de novembro (fechado → recusado; reaberto → RAAS de novembro, SIGTAP 202611)",
       now: Time.zone.local(2026, 12, 1, 10, 0) do
      enrolled = enrollment!(caps, reference: staff, started_on: Date.new(2026, 11, 1))
      late = Time.zone.local(2026, 11, 30, 23, 30)
      expect(late.utc.to_date).to eq(Date.new(2026, 12, 1))
      closure = PsychosocialMonthClosure.create!(health_unit: caps, month: Date.new(2026, 11, 1), closed_by_user: staff, closed_at: Time.current)
      json_post "/psychosocial/actions", action(performed_at: late.iso8601, participants: [ { enrollment_id: enrolled.id } ])
      expect(json_body).to eq("error" => "action_rejected", "problems" => [ { "error" => "month_closed", "path" => "performed_at" } ])

      closure.update!(reopened_at: Time.current, reopened_by_user: staff, reopen_reason: "Correção de ação lançada")
      allow(Terminology::Sigtap).to receive(:release_for).and_call_original
      json_post "/psychosocial/actions", action(performed_at: late.iso8601, participants: [ { enrollment_id: enrolled.id } ])
      expect(response).to have_http_status(:created)
      expect(PsychosocialAction.find(json_body["id"]).month).to eq(Date.new(2026, 11, 1))
      expect(PsychosocialMonthlyRecord.where(psychosocial_enrollment_id: enrolled.id).pluck(:month)).to eq([ Date.new(2026, 11, 1) ])
      expect(Terminology::Sigtap).to have_received(:release_for).with("202611").at_least(:once)
      expect(Terminology::Sigtap).not_to have_received(:release_for).with("202612")
    end

    it "ação antes do início da matrícula → enrollment_required no participante, nenhuma RAAS nova" do
      a && b
      november = enrollment!(caps, reference: staff, started_on: Date.new(2026, 11, 1))
      expect do
        json_post "/psychosocial/actions", action(performed_at: Time.zone.local(2026, 10, 20, 10).iso8601,
                                                  participants: [ { enrollment_id: november.id } ])
      end.not_to(change { counts })
      expect(json_body).to eq("error" => "action_rejected",
                              "problems" => [ { "error" => "enrollment_required", "path" => "participants[0]", "participant_index" => 0 } ])

      mid = enrollment!(caps, reference: staff, started_on: Date.new(2026, 11, 10))
      json_post "/psychosocial/actions", action(performed_at: Time.zone.local(2026, 11, 5, 10).iso8601, participants: [ { enrollment_id: mid.id } ])
      expect(json_body["problems"]).to eq([ { "error" => "enrollment_required", "path" => "participants[0]", "participant_index" => 0 } ])
      json_post "/psychosocial/actions", action(performed_at: Time.zone.local(2026, 11, 10, 8).iso8601, participants: [ { enrollment_id: mid.id } ])
      expect(response).to have_http_status(:created)
    end

    it "ids em maiúsculas valem como os mesmos uuids (busca e deduplicação)" do
      group = PsychosocialGroup.create!(health_unit: caps, name: "Grupo", kind: "group", weekday: 3, starts_at: "10:00", ends_at: "11:00",
                                        responsible_user: staff, capacity: 10, sigtap_code: "0301080216", updated_by_user: staff)
      json_post "/psychosocial/actions", action(participants: [ { enrollment_id: a.id.upcase }, { enrollment_id: a.id } ])
      expect(json_body["problems"]).to eq([ { "error" => "invalid_request", "path" => "participants[1]" } ])
      json_post "/psychosocial/actions", action(sigtap_code: "0301080232", group_id: group.id.upcase,
                                                participants: [ { patient_id: caps_patient!.id.upcase } ])
      expect(response).to have_http_status(:created)
      json_post "/psychosocial/actions", action(group_id: group.id.upcase, participants: [ { enrollment_id: a.id.upcase } ])
      expect(response).to have_http_status(:created)
      saved = PsychosocialAction.find(json_body["id"])
      expect([ saved.psychosocial_group_id, saved.psychosocial_action_participants.sole.psychosocial_enrollment_id ]).to eq([ group.id, a.id ])
    end

    it "corrida com o fechamento: o trigger recusa e a resposta é month_closed, nunca 500" do
      allow(Psychosocial::MonthlyRecords).to receive(:closed?).and_return(false)
      PsychosocialMonthClosure.create!(health_unit: caps, month: Date.current.beginning_of_month, closed_by_user: staff, closed_at: Time.current)
      a && b
      expect { json_post "/psychosocial/actions", action }.not_to(change { counts })
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "action_rejected",
                                                            "problems" => [ { "error" => "month_closed", "path" => "performed_at" } ] } ])
    end

    it "BPA-C aceita zero participantes; RAAS sem matrícula não; BPA-I com dois pacientes não" do
      json_post "/psychosocial/actions", action(sigtap_code: "0301080259", participants: [], place: "territory")
      expect([ response.status, json_body["instrument"], json_body["participants_count"] ]).to eq([ 201, "bpa_c", 0 ])
      json_post "/psychosocial/actions", action(participants: [ { patient_id: caps_patient!.id } ])
      expect(json_body["problems"]).to eq([ { "error" => "enrollment_required", "path" => "participants" } ])
      json_post "/psychosocial/actions", action(sigtap_code: "0301080232", participants: [ { patient_id: caps_patient!.id }, { patient_id: caps_patient!.id } ])
      expect(json_body["problems"]).to eq([ { "error" => "bpa_i_single_patient", "path" => "participants" } ])
      json_post "/psychosocial/actions", action(sigtap_code: "0301080232", participants: [ { patient_id: caps_patient!.id } ])
      expect(json_body["instrument"]).to eq("bpa_i")
    end

    it "recusas de campo (invalid_request / too_long) com o path, todas de uma vez, antes da crítica" do
      json_post "/psychosocial/actions", action(place: "rua", quantity: 0, notes: "n" * 4001, authorization_number: "12",
                                                performed_at: "ontem", participants: [ { family_name: "f" * 121 }, { family_name: "ab" },
                                                                                       { enrollment_id: "x" }, { patient_id: a.patient_id, family_name: "Mãe" } ],
                                                cid: "F20")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["problems"]).to contain_exactly(
        { "error" => "invalid_request", "path" => "cid" }, { "error" => "invalid_request", "path" => "performed_at" },
        { "error" => "invalid_request", "path" => "place" }, { "error" => "invalid_request", "path" => "quantity" },
        { "error" => "too_long", "path" => "notes" }, { "error" => "invalid_request", "path" => "authorization_number" },
        { "error" => "too_long", "path" => "participants[0].family_name" },
        { "error" => "invalid_request", "path" => "participants[1].family_name" },
        { "error" => "invalid_request", "path" => "participants[2].enrollment_id" },
        { "error" => "invalid_request", "path" => "participants[3]" }
      )
      expect(response.body).not_to include("n" * 50)
      expect(PsychosocialAction.count).to eq(0)
    end

    it "mesmo paciente duas vezes ou grupo de outro CAPS → invalid_request" do
      json_post "/psychosocial/actions", action(participants: [ { enrollment_id: a.id }, { patient_id: a.patient_id } ])
      expect(json_body["problems"]).to eq([ { "error" => "invalid_request", "path" => "participants[1]" } ])
      other = caps!(modality: "caps_ad")
      group = PsychosocialGroup.create!(health_unit: other, name: "Grupo", kind: "group", weekday: 3, starts_at: "10:00", ends_at: "11:00",
                                        responsible_user: staff, capacity: 10, sigtap_code: "0301080216", updated_by_user: staff)
      json_post "/psychosocial/actions", action(group_id: group.id)
      expect(json_body["problems"]).to eq([ { "error" => "invalid_request", "path" => "group_id" } ])
    end

    it "grava o grupo do mesmo CAPS" do
      group = PsychosocialGroup.create!(health_unit: caps, name: "Grupo", kind: "group", weekday: 3, starts_at: "10:00", ends_at: "11:00",
                                        responsible_user: staff, capacity: 10, sigtap_code: "0301080216", updated_by_user: staff)
      json_post "/psychosocial/actions", action(group_id: group.id)
      expect([ response.status, json_body["group_id"] ]).to eq([ 201, group.id ])
    end

    it "fora do CAPS de lotação → 403 not_on_caps_team; sem o papel → 403 missing_role" do
      json_post "/psychosocial/actions", action(health_unit_id: caps!(modality: "caps_ad").id)
      expect([ response.status, json_body["error"] ]).to eq([ 403, "not_on_caps_team" ])
      sign_in_as(ubs_doctor!(caps))
      json_post "/psychosocial/actions", action
      expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
    end
  end

  describe "leitura" do
    it "lista sem notas e sem trilha; detalhe com notas, participantes e a trilha por paciente; outro CAPS → 404" do
      json_post "/psychosocial/actions", action
      id = json_body["id"]
      expect { get "/psychosocial/actions", params: { enrollment_id: a.id } }.not_to(change { viewed.count })
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("boa participação")
      item = json_body["items"].sole
      expect(item.keys).to contain_exactly("id", "sigtap", "instrument", "performed_at", "place", "quantity", "professional", "group_id",
                                           "participants_count", "cancelled")
      expect(item).to include("id" => id, "participants_count" => 2, "cancelled" => false)
      expect(json_body).to have_key("next_before")

      expect { get "/psychosocial/actions/#{id}" }.to change { viewed.count }.by(2)
      expect(viewed.last.payload).to include("access" => "psychosocial", "resource" => "action")
      expect(json_body).to include("notes" => "Grupo de convivência; boa participação")
      expect(json_body["participants"].map { |p| [ p["enrollment_id"], p.dig("patient", "patient_id") ] })
        .to eq([ [ a.id, a.patient_id ], [ b.id, b.patient_id ] ])

      sign_in_as(caps_staff!(caps!(modality: "caps_ad")))
      get "/psychosocial/actions/#{id}"
      expect(response).to have_http_status(:not_found)
      get "/psychosocial/actions", params: { enrollment_id: a.id }
      expect(response).to have_http_status(:not_found)
    end

    it "familiar sai só com o nome, sem trilha" do
      json_post "/psychosocial/actions", action(sigtap_code: "0301080224", participants: [ { enrollment_id: a.id }, { family_name: "Mãe do usuário" } ])
      expect { get "/psychosocial/actions/#{json_body['id']}" }.to change { viewed.count }.by(1)
      expect(json_body["participants"].last).to eq("family_name" => "Mãe do usuário")
    end

    it "lista exige enrollment_id e recusa outra chave na query" do
      get "/psychosocial/actions"
      expect([ response.status, json_body["path"] ]).to eq([ 422, "enrollment_id" ])
      get "/psychosocial/actions", params: { enrollment_id: a.id, notes: "x" }
      expect([ response.status, json_body["path"] ]).to eq([ 422, "notes" ])
    end
  end

  describe "POST /psychosocial/actions/:id/cancel" do
    let(:recorded_action) { record_action!(caps, staff, sigtap_code: "0301080216", participants: [ { enrollment_id: a.id } ]) }

    it "cancela com motivo (10..2000), uma vez; o evento só com o id" do
      id = recorded_action.id
      json_post "/psychosocial/actions/#{id}/cancel", reason: "curto"
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "reason" ])
      json_post "/psychosocial/actions/#{id}/cancel", reason: "m" * 2001
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "too_long", "reason" ])

      json_post "/psychosocial/actions/#{id}/cancel", reason: "Lançada no grupo errado"
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => id, "cancelled" => true)
      expect(recorded_action.reload).to have_attributes(cancelled?: true, cancel_reason: "Lançada no grupo errado", cancelled_by_user_id: staff.id)
      expect(DomainEvent.where(name: "psychosocial.action_cancelled").last.payload).to eq("action_id" => id)

      json_post "/psychosocial/actions/#{id}/cancel", reason: "Lançada no grupo errado"
      expect([ response.status, json_body["error"] ]).to eq([ 409, "already_cancelled" ])
    end

    it "mês fechado: só a coordenação (403 lead_required); mês exportado → 409 already_exported" do
      id = recorded_action.id
      month = recorded_action.month
      PsychosocialMonthClosure.create!(health_unit: caps, month: month, closed_by_user: staff, closed_at: Time.current)
      json_post "/psychosocial/actions/#{id}/cancel", reason: "Lançada no grupo errado"
      expect([ response.status, json_body["error"] ]).to eq([ 403, "lead_required" ])

      lead = caps_staff!(caps, cbo: "223505", lead: true)
      PsychosocialRaasExport.create!(health_unit: caps, month: month, competence: month.strftime("%Y%m"), layout_version: "test",
                                     file_data: "x", sha256: "0" * 64, records_count: 0, created_by_user: lead,
                                     billing_period: BillingPeriod.create!(health_unit_id: caps.id, competence: month.strftime("%Y%m")))
      sign_in_as(lead)
      json_post "/psychosocial/actions/#{id}/cancel", reason: "Lançada no grupo errado"
      expect([ response.status, json_body["error"] ]).to eq([ 409, "already_exported" ])
      expect(recorded_action.reload).not_to be_cancelled
    end

    it "mês fechado e não exportado: a coordenação cancela" do
      id = recorded_action.id
      PsychosocialMonthClosure.create!(health_unit: caps, month: recorded_action.month, closed_by_user: staff, closed_at: Time.current)
      sign_in_as(caps_staff!(caps, cbo: "223505", lead: true))
      json_post "/psychosocial/actions/#{id}/cancel", reason: "Lançada no grupo errado"
      expect(response).to have_http_status(:ok)
      expect(PsychosocialAction.find(id)).to be_cancelled
    end

    it "ação de outro CAPS → 404; chave desconhecida → 422" do
      id = recorded_action.id
      json_post "/psychosocial/actions/#{id}/cancel", reason: "Lançada no grupo errado", extra: 1
      expect([ response.status, json_body["path"] ]).to eq([ 422, "extra" ])
      sign_in_as(caps_staff!(caps!(modality: "caps_ad")))
      json_post "/psychosocial/actions/#{id}/cancel", reason: "Lançada no grupo errado"
      expect(response).to have_http_status(:not_found)
    end
  end
end
