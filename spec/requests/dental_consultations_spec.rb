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
      json_post "/attendance/attendances/#{attendance.id}/consultation", kind: false
      expect([ response.status, body ]).to eq([ 422, { "error" => "invalid_request", "path" => "kind" } ])
      sign_in_as(doctor)
      json_post "/attendance/attendances/#{consulting_attendance!(unit, citizen: verified_citizen!(4), doctor: doctor).id}/consultation",
                kind: nil
      expect([ response.status, body["kind"] ]).to eq([ 201, "general" ])
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

  # Desvio 9 / O19: o dentista registra CID-10 na consulta `dental`; TSB/ASB não.
  describe "CID-10 na consulta odontológica" do
    before { cid10_release! }

    let(:cid10) { { "terminology" => "cid10", "code" => "E119", "action" => "add", "onset_on" => "2026-09-01", "onset_precision" => "month" } }

    def json_patch(path, params) = patch(path, params: params.to_json, headers: { "CONTENT_TYPE" => "application/json" })

    it "options: dentista true (só dental), TSB/ASB false, médico true, interruptor desligado: dentista false" do
      sign_in_as(dentist)
      get "/attendance/consultation_options"
      expect(body["cid10_allowed_for_cbo"]).to be(true)
      sign_in_as(auxiliary!(unit))
      get "/attendance/consultation_options"
      expect(body["cid10_allowed_for_cbo"]).to be(false)
      sign_in_as(doctor!(unit))
      get "/attendance/consultation_options"
      expect(body["cid10_allowed_for_cbo"]).to be(true)
      dental_city!(enabled: false)
      sign_in_as(dentist)
      get "/attendance/consultation_options"
      expect(body["cid10_allowed_for_cbo"]).to be(false)
    end

    it "rascunho do dentista aceita CID-10 e a finalização o mantém" do
      consultation = dental_consultation!(unit: unit, by: dentist, citizen: citizen)
      sign_in_as(dentist)
      json_patch "/attendance/consultations/#{consultation.id}", dental_body(evaluated_problems: [ cid10 ])
      expect(response).to have_http_status(:ok)
      expect(body["evaluated_problems"].sole).to include("terminology" => "cid10", "code" => "E119")
      json_post "/attendance/consultations/#{consultation.id}/finalize", outcome: { outcome: "discharged" }
      expect(response).to have_http_status(:ok)
      expect(PatientProblem.where(code: "E119").pluck(:terminology)).to eq([ "cid10" ])
    end

    it "TSB/ASB na consulta dental não adiciona CID-10 (422 cid10_not_allowed_for_cbo)" do
      asb = auxiliary!(unit)
      consultation = dental_consultation!(unit: unit, by: asb, citizen: citizen)
      sign_in_as(asb)
      json_patch "/attendance/consultations/#{consultation.id}", dental_body(evaluated_problems: [ cid10 ])
      expect([ response.status, body["error"] ]).to eq([ 422, "cid10_not_allowed_for_cbo" ])
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
    # LGPD: com dental_care desligado o vínculo odontológico não põe em contexto.
    dental_city!(enabled: false)
    sign_in_as(dentist)
    get "/attendance/attendances/#{waiting.id}/record"
    expect([ response.status, body["error"] ]).to eq([ 403, "out_of_context" ])
  end

  describe "abertura justificada (contrato §16 O28)" do
    let!(:finalized) { finalized_consultation!(unit: unit, doctor: doctor!(unit), citizen: citizen) }

    def open_as(user)
      stepped_up!(user)
      json_post "/clinical_record/openings", cpf: citizen.cpf, reason_code: "case_review"
    end

    it "dentista abre com dental_care ligado e lê o prontuário com trilha justificada" do
      open_as(dentist)
      expect(response).to have_http_status(:created)
      expect(DomainEvent.where(name: "clinical_record.opened").sole.payload).to include("user_id" => dentist.id)
      get "/clinical_record/patients/#{finalized.patient_id}"
      expect(response).to have_http_status(:ok)
      expect(DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at, :created_at).last.payload)
        .to include("user_id" => dentist.id, "access" => "justified")
    end

    it "TSB/ASB não abre; dentista com dental_care desligado não abre" do
      open_as(auxiliary!(unit))
      expect([ response.status, body["error"] ]).to eq([ 403, "cbo_not_allowed" ])
      dental_city!(enabled: false)
      open_as(dentist)
      expect([ response.status, body["error"] ]).to eq([ 403, "cbo_not_allowed" ])
      expect(ClinicalRecordOpening.count).to eq(0)
    end
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

  describe "documentos, encaminhamento e linha do tempo (F-28.7; api#75)" do
    let(:path) { "/attendance/consultations/#{consultation.id}/documents" }
    let(:sick_note) { { kind: "sick_note", content: { type: "leave", days: 2 } } }

    def regulation_on!
      maintainer = ledi_maintainer!
      Platform::Features.set!(city: Current.city || Platform::City.first, key: "care_regulation", enabled: true, maintainer: maintainer)
      RegulationRiskDeadline.ensure_defaults!
      CityCatalog.reset_cache!
    end

    def save!(consultation, **over)
      saved = Consultations::SaveDraft.call(consultation: consultation, params: dental_body(**over), by: consultation.author_user)
      raise "rascunho recusado: #{saved.reason}" if saved.failure?
    end

    def draft_request!(consultation, code)
      saved = CareRegulation::SaveDraft.call(
        consultation: consultation, by: consultation.author_user,
        attrs: { "type" => "specialty", "target_code" => code, "ciap2" => "D82", "justification" => "Necessita avaliação especializada",
                 "suggested_color" => "yellow" }
      )
      raise "pedido recusado: #{saved.reason} #{saved.details}" if saved.failure?

      saved.payload.fetch(:request)
    end

    def finalize(consultation)
      json_post "/attendance/consultations/#{consultation.id}/finalize", outcome: { outcome: "discharged" }
    end

    context "documentos" do
      let(:consultation) { dental_consultation!(unit: unit, by: dentist, citizen: citizen) }

      before do
        documents_city!
        sign_in_as(dentist)
      end

      it "o dentista emite atestado e receita comum (201)" do
        json_post path, sick_note
        expect(response).to have_http_status(:created)
        import_test_catalog!
        json_post path, kind: "prescription",
                        content: { items: [ { catalog_item: { id: catalog_item(268_856).id }, quantity: 30, quantity_unit: "comprimido",
                                              route: "oral", dosage_instructions: "1 comprimido a cada 8 horas" } ] }
        expect(response).to have_http_status(:created)
      end

      it "a ASB recebe 403 auxiliary_cannot_issue" do
        auxiliary = auxiliary!(unit)
        mine = dental_consultation!(unit: unit, by: auxiliary, citizen: verified_citizen!(5))
        sign_in_as(auxiliary)
        json_post "/attendance/consultations/#{mine.id}/documents", sick_note
        expect([ response.status, body ]).to eq([ 403, { "error" => "auxiliary_cannot_issue" } ])
        expect(ClinicalDocument.count).to eq(0)
      end

      it "registro inicial: 422 baseline_only_findings" do
        first = dental_consultation!(unit: unit, by: dentist, citizen: verified_citizen!(6), baseline: true)
        json_post "/attendance/consultations/#{first.id}/documents", sick_note
        expect([ response.status, body ]).to eq([ 422, { "error" => "baseline_only_findings" } ])
        expect(ClinicalDocument.count).to eq(0)
      end
    end

    context "pedido de regulação" do
      let(:consultation) { dental_consultation!(unit: unit, by: dentist, citizen: citizen) }

      it "registro inicial recusa pedido (422 baseline_only_findings); ASB recebe o cbo_not_allowed de sempre" do
        regulation_on!
        first = dental_consultation!(unit: unit, by: dentist, citizen: verified_citizen!(6), baseline: true)
        sign_in_as(dentist)
        json_post "/attendance/consultations/#{first.id}/regulation_requests",
                  type: "specialty", target_code: "223212", ciap2: "D82", justification: "Necessita avaliação", suggested_color: "yellow"
        expect([ response.status, body ]).to eq([ 422, { "error" => "baseline_only_findings" } ])
        auxiliary = auxiliary!(unit)
        mine = dental_consultation!(unit: unit, by: auxiliary, citizen: verified_citizen!(8))
        sign_in_as(auxiliary)
        json_post "/attendance/consultations/#{mine.id}/regulation_requests",
                  type: "specialty", target_code: "223212", ciap2: "D82", justification: "Necessita avaliação", suggested_color: "yellow"
        expect([ response.status, body["error"] ]).to eq([ 403, "cbo_not_allowed" ])
      end
    end

    context "desfechos 1–9 exigem o pedido (D5)" do
      let(:consultation) { dental_consultation!(unit: unit, by: dentist, citizen: citizen) }

      before { sign_in_as(dentist) }

      it "com care_regulation ligado, o desfecho 3 sem pedido → problems com dental_referral_request_required" do
        regulation_on!
        save!(consultation, dental: { dental_outcomes: [ 3 ] })
        finalize(consultation)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(body["problems"]).to include(a_hash_including("error" => "dental_referral_request_required", "path" => "dental.dental_outcomes[0]"))
        expect(consultation.reload.status).to eq("draft")
      end

      it "pedido em rascunho da especialidade certa (223212) → finaliza e o pedido vira pending" do
        regulation_on!
        save!(consultation, dental: { dental_outcomes: [ 3 ] })
        request = draft_request!(consultation, "223212")
        finalize(consultation)
        expect(response).to have_http_status(:ok)
        expect(request.reload.status).to eq("pending")
      end

      it "pedido de outra especialidade não vale" do
        regulation_on!
        save!(consultation, dental: { dental_outcomes: [ 3 ] })
        draft_request!(consultation, "223268")
        finalize(consultation)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(body["problems"].map { |p| p["error"] }).to include("dental_referral_request_required")
      end

      it "desfecho 10 sem pedido → finaliza" do
        regulation_on!
        save!(consultation, dental: { dental_outcomes: [ 10 ] })
        finalize(consultation)
        expect(response).to have_http_status(:ok)
      end

      it "care_regulation desligado: o desfecho 3 sem pedido finaliza" do
        save!(consultation, dental: { dental_outcomes: [ 3 ] })
        finalize(consultation)
        expect(response).to have_http_status(:ok)
      end
    end
  end

  # O37: com dental_care fora, o rascunho odontológico não se edita nem se finaliza;
  # a consulta geral segue; descartar o rascunho (api#51) continua valendo.
  describe "interruptor desligado (O37)" do
    def json_patch(path, params) = patch(path, params: params.to_json, headers: { "CONTENT_TYPE" => "application/json" })

    it "PATCH e finalize da odontológica → 403 feature_disabled; a geral segue; o descarte funciona" do
      consultation = dental_consultation!(unit: unit, by: dentist, citizen: citizen)
      doctor = doctor!(unit)
      general = Consultation.find(begin
        sign_in_as(doctor)
        json_post "/attendance/attendances/#{consulting_attendance!(unit, citizen: verified_citizen!(2), doctor: doctor).id}/consultation"
        body["id"]
      end)
      dental_city!(enabled: false)
      sign_in_as(dentist)
      forbidden = [ 403, { "error" => "feature_disabled", "feature" => "dental_care" } ]
      json_patch "/attendance/consultations/#{consultation.id}", dental: { "dental_outcomes" => [ 1 ] }
      expect([ response.status, body ]).to eq(forbidden)
      json_post "/attendance/consultations/#{consultation.id}/finalize", outcome: { outcome: "discharged" }
      expect([ response.status, body ]).to eq(forbidden)
      expect(consultation.reload).to be_draft

      sign_in_as(doctor)
      json_patch "/attendance/consultations/#{general.id}", plan: "x"
      expect(response).to have_http_status(:ok)

      ConsultationDrafts::Discard.call(consultation_id: consultation.id, reason: "Rascunho órfão da unidade", by: admin)
      expect(consultation.reload.status).to eq("discarded")
    end
  end
end
