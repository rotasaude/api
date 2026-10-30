require "rails_helper"

# Módulo 28 (ADR 0046; contrato §4, O4, O20, O25): iniciar a consulta
# odontológica em /attendance, as opções com `kinds`, `dental_role` e o
# vocabulário `dental` (sempre presente, código string), a leitura do
# prontuário de quem espera na unidade e o rascunho órfão odontológico.
RSpec.describe "Consulta odontológica", type: :request do
  before { dental_city! }

  let(:unit) { create_unit }
  let(:dentist) { dentist!(unit) }
  let(:citizen) { verified_citizen!(1) }
  let(:attendance) { consulting_attendance!(unit, citizen: citizen, doctor: dentist) }
  let(:admin) { staff_with("admin-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin") }

  def body = JSON.parse(response.body)

  describe "POST /attendance/attendances/:id/consultation" do
    it "kind dental → 201 com kind e baseline; baseline do dentista → 201 baseline true" do
      sign_in_as(dentist)
      json_post "/attendance/attendances/#{attendance.id}/consultation", kind: "dental"
      expect(response).to have_http_status(:created)
      expect(body).to include("kind" => "dental", "baseline" => false, "care_type" => "5", "cbo_code" => "223208")
      other = consulting_attendance!(unit, citizen: verified_citizen!(2), doctor: dentist)
      json_post "/attendance/attendances/#{other.id}/consultation", kind: "dental", baseline: true
      expect(response).to have_http_status(:created)
      expect(body).to include("kind" => "dental", "baseline" => true, "care_type" => nil)
    end

    it "sem kind → general (contrato antigo); kind inválido → 422 invalid_request path kind" do
      doctor = doctor!(unit)
      general = consulting_attendance!(unit, citizen: verified_citizen!(2), doctor: doctor)
      sign_in_as(doctor)
      json_post "/attendance/attendances/#{general.id}/consultation"
      expect([ response.status, body["kind"], body["baseline"] ]).to eq([ 201, "general", false ])
      sign_in_as(dentist)
      json_post "/attendance/attendances/#{attendance.id}/consultation", kind: "xyz"
      expect([ response.status, body ]).to eq([ 422, { "error" => "invalid_request", "path" => "kind" } ])
      json_post "/attendance/attendances/#{attendance.id}/consultation", kind: { "a" => 1 }
      expect([ response.status, body ]).to eq([ 422, { "error" => "invalid_request", "path" => "kind" } ])
    end

    it "recusas: 403 cbo_not_allowed, 422 baseline_requires_dentist, 403 feature_disabled dental_care" do
      sign_in_as(dentist)
      json_post "/attendance/attendances/#{attendance.id}/consultation"
      expect([ response.status, body ]).to eq([ 403, { "error" => "cbo_not_allowed" } ])
      auxiliary = auxiliary!(unit)
      by_auxiliary = consulting_attendance!(unit, citizen: verified_citizen!(3), doctor: auxiliary)
      sign_in_as(auxiliary)
      json_post "/attendance/attendances/#{by_auxiliary.id}/consultation", kind: "dental", baseline: true
      expect([ response.status, body ]).to eq([ 422, { "error" => "baseline_requires_dentist" } ])
      dental_city!(enabled: false)
      sign_in_as(dentist)
      json_post "/attendance/attendances/#{attendance.id}/consultation", kind: "dental"
      expect([ response.status, body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "dental_care" } ])
      expect(Consultation.count).to eq(0)
    end
  end

  describe "GET /attendance/consultation_options" do
    def codes(list) = list.map { |item| item["code"] }

    it "dentista: kinds dental, dental_role dentist e o vocabulário com código string e rótulo" do
      sign_in_as(dentist)
      get "/attendance/consultation_options"
      expect(response).to have_http_status(:ok)
      expect(body).to include("kinds" => [ "dental" ], "dental_role" => "dentist")
      dental = body["dental"]
      expect(dental.keys).to match_array(%w[care_types consultation_types surveillance supplies outcomes situations])
      expect(codes(dental["care_types"])).to eq(%w[2 4 5 6])
      expect(codes(dental["consultation_types"])).to eq(%w[1 2 4])
      expect(codes(dental["surveillance"])).to eq(%w[1 2 3 4 5 6 99])
      expect(codes(dental["supplies"])).to eq(%w[1 2 3])
      expect(codes(dental["outcomes"])).to eq(%w[1 2 3 4 5 6 7 8 9 10 11 12 14 15 16 17 18])
      expect(dental["outcomes"]).to include("code" => "15", "label" => "Tratamento concluído")
      expect(dental["situations"].keys).to match_array(%w[crown root arch face])
      expect(codes(dental["situations"]["root"])).to eq(%w[none root_caries endodontics implant post furcation_lesion])
      expect(codes(dental["situations"]["arch"])).to eq(%w[complete_denture])
      expect(codes(dental["situations"]["face"]))
        .to match_array(%w[caries restored restored_with_caries fracture active_white_spot sealant_indicated sound_sealed])
      expect(codes(dental["situations"]["crown"]).size).to eq(21)
      all = dental.except("situations").values.flatten + dental["situations"].values.flatten
      expect(all).to all(match("code" => a_kind_of(String), "label" => a_kind_of(String)))
      expect(all.map { |item| item["label"] }).to all(be_present)
    end

    it "TSB/ASB: dental_role auxiliary; médico: kinds general, dental_role nulo, vocabulário presente" do
      sign_in_as(auxiliary!(unit))
      get "/attendance/consultation_options"
      expect(body).to include("kinds" => [ "dental" ], "dental_role" => "auxiliary")
      sign_in_as(doctor!(unit))
      get "/attendance/consultation_options"
      expect(body).to include("kinds" => [ "general" ], "dental_role" => nil)
      expect(body["dental"].keys).to include("care_types", "situations")
      expect(body["care_types"].map { |t| t["code"] }).to eq(%w[1 2 5 6])
    end

    it "dentista que também é médico: os dois tipos; interruptor desligado: sem dental e sem papel, vocabulário fica" do
      both = dentist
      link_professional!(both, create_unit("UBS Norte"), cbo: "225125")
      sign_in_as(both)
      get "/attendance/consultation_options"
      expect(body).to include("kinds" => %w[general dental], "dental_role" => "dentist")
      dental_city!(enabled: false)
      get "/attendance/consultation_options"
      expect(body).to include("kinds" => [ "general" ], "dental_role" => nil)
      expect(body["dental"]["situations"].keys).to match_array(%w[crown root arch face])
    end

    it "admin municipal sem vínculo: kinds vazio, dental_role nulo, vocabulário presente" do
      sign_in_as(admin)
      get "/attendance/consultation_options"
      expect(body).to include("kinds" => [], "dental_role" => nil)
      expect(body["dental"]).to be_present
    end
  end

  it "dentista lê o prontuário de quem espera na unidade (in_context); fora da unidade não" do
    finalized = finalized_consultation!(unit: unit, doctor: doctor!(unit), citizen: citizen)
    waiting = walk_in_attendance!(unit, citizen: citizen.reload)
    sign_in_as(dentist)
    get "/attendance/attendances/#{waiting.id}/record"
    expect(response).to have_http_status(:ok)
    expect(body["access"]).to eq("in_context")
    expect(body["consultations"].map { |c| c["id"] }).to include(finalized.id)
    sign_in_as(dentist!(create_unit("UBS Outra")))
    get "/attendance/attendances/#{waiting.id}/record"
    expect([ response.status, body["error"] ]).to eq([ 403, "out_of_context" ])
  end

  describe "rascunho órfão odontológico" do
    let(:base) { "/clinical_record/consultation_drafts" }
    let(:reason) { "Profissional desligada da unidade" }

    def candidates(consultation)
      sign_in_as(admin)
      get "#{base}/#{consultation.id}/candidates"
      expect(response).to have_http_status(:ok)
      body["candidates"].map { |row| row["user_id"] }
    end

    def reassign(consultation, user)
      ConsultationDrafts::Reassign.call(consultation_id: consultation.id, user_id: user.id, reason: reason, by: admin)
    end

    it "registro inicial: só dentistas; ASB e médico recusados" do
      draft = dental_consultation!(unit: unit, by: dentist, citizen: citizen, baseline: true)
      colleague = dentist!(unit, cbo: "223212")
      auxiliary = auxiliary!(unit)
      doctor = doctor!(unit)
      expect(candidates(draft)).to eq([ colleague.id ])
      expect(reassign(draft, auxiliary).reason).to eq(:invalid_professional)
      expect(reassign(draft, doctor).reason).to eq(:invalid_professional)
      expect(reassign(draft, colleague)).to be_ok
      expect(draft.reload).to have_attributes(author_user_id: colleague.id, cbo_code: "223212")
    end

    it "consulta odontológica: dentista e ASB, nunca o médico; a consulta geral nunca oferece o dentista" do
      draft = dental_consultation!(unit: unit, by: dentist, citizen: citizen)
      colleague = dentist!(unit, cbo: "223212")
      auxiliary = auxiliary!(unit)
      doctor = doctor!(unit)
      expect(candidates(draft)).to contain_exactly(colleague.id, auxiliary.id)
      expect(reassign(draft, doctor).reason).to eq(:invalid_professional)
      expect(reassign(draft, auxiliary)).to be_ok
      expect(draft.reload.cbo_code).to eq("322430")
      general = started_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(2))
      expect(candidates(general)).not_to include(colleague.id, auxiliary.id, dentist.id)
      expect(reassign(general, colleague).reason).to eq(:invalid_professional)
    end
  end
end
