require "rails_helper"

# Rascunho de consulta órfão (card rotasaude/api#51; módulo 19a, ADR 0031):
# o admin municipal designa outro profissional da unidade (papel, vínculo
# ativo, CBO permitido pelo 19a). Troca autora, vínculo, CBO e quem chamou o
# atendimento; texto e itens ficam; trilha e evento só com ids. As regras de
# CID-10 seguem pelo CBO novo na finalização.
RSpec.describe ConsultationDrafts::Reassign do
  before { Current.city = clinical_city!; ciap2_release!; cid10_release!; sigtap_release! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:admin) { staff_with("admin-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin") }
  let(:reason) { "Autora afastada; paciente segue com o colega" }
  let(:citizen) { verified_citizen!(1) }
  let(:body) { draft_body(subjective: "MARCADOR-S") }
  let(:consultation) do
    started_consultation!(unit: unit, doctor: doctor, citizen: citizen).tap do |c|
      saved = Consultations::SaveDraft.call(consultation: c, params: body, by: doctor)
      raise "rascunho recusado: #{saved.reason} #{saved.details}" if saved.failure?

      end_links!(doctor)
    end
  end

  def end_links!(user) = ProfessionalLink.joins(:professional).where(professionals: { user_id: user.id })
                                         .find_each { |link| link.update!(ended_at: Time.current, ended_by_user: admin) }

  def reassign(to:, id: consultation.id, why: reason, by: admin) =
    described_class.call(consultation_id: id, user_id: to.is_a?(User) ? to.id : to, reason: why, by: by)

  it "motivo inválido → invalid_reason; interruptor desligado → feature_disabled" do
    colleague = doctor!(unit)
    expect(reassign(to: colleague, why: "curto").reason).to eq(:invalid_reason)
    expect(reassign(to: colleague, why: 42).reason).to eq(:invalid_reason)
    Platform::Features.set!(city: Current.city, key: "clinical_record", enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    expect(reassign(to: colleague).reason).to eq(:feature_disabled)
  end

  it "inexistente → not_found; finalizada ou descartada → not_draft; a mesma autora → same_author" do
    colleague = doctor!(unit)
    expect(reassign(to: colleague, id: SecureRandom.uuid).reason).to eq(:not_found)
    expect(reassign(to: colleague, id: "lixo").reason).to eq(:not_found)
    finalized = finalized_consultation!(unit: unit, doctor: colleague, citizen: verified_citizen!(2, full_name: "Rita Souza"))
    expect(reassign(to: doctor, id: finalized.id).reason).to eq(:not_draft)
    expect(reassign(to: doctor).reason).to eq(:same_author)
    ConsultationDrafts::Discard.call(consultation_id: consultation.id, reason: reason, by: admin)
    expect(reassign(to: colleague).reason).to eq(:not_draft)
  end

  it "quem não pode registrar consulta na unidade → invalid_professional" do
    consultation
    other_unit = create_unit("UBS Norte")
    elsewhere = doctor!(other_unit)
    ended = doctor!(unit).tap { |user| end_links!(user) }
    dentist = doctor!(unit, cbo: "223208")
    technician = doctor!(unit, cbo: "322205")
    no_role = staff_with("sem-papel-#{SecureRandom.hex(3)}@cidade.gov.br", "citizen_verifier").tap { |user| link_professional!(user, unit) }
    no_link = staff_with("sem-vinculo-#{SecureRandom.hex(3)}@cidade.gov.br", "health_professional")
    deactivated = doctor!(unit).tap { |user| user.update!(deactivated_at: Time.current) }
    [ elsewhere, ended, dentist, technician, no_role, no_link, deactivated, SecureRandom.uuid, "lixo", nil ].each do |user|
      expect(reassign(to: user).reason).to eq(:invalid_professional), user.inspect
    end
    expect(consultation.reload.author_user_id).to eq(doctor.id)
    expect(ConsultationDraftAction.count).to eq(0)
  end

  it "troca autora, vínculo, CBO e quem chamou; preserva texto e itens; trilha e evento só com ids" do
    items = consultation.draft_items
    nurse = doctor!(unit, cbo: "223505")
    nurse_link = ProfessionalLink.joins(:professional).find_by!(professionals: { user_id: nurse.id })
    result = reassign(to: nurse)
    expect(result).to be_ok

    fresh = Consultation.find(consultation.id)
    expect(fresh).to have_attributes(status: "draft", author_user_id: nurse.id, professional_link_id: nurse_link.id,
                                     cbo_code: "223505", subjective: "MARCADOR-S", draft_items: items)
    expect(fresh.attendance.reload).to have_attributes(status: "in_care", called_by_user_id: nurse.id)

    action = ConsultationDraftAction.sole
    expect(action).to have_attributes(action: "reassigned", consultation_id: fresh.id, attendance_id: fresh.attendance_id,
                                      previous_author_user_id: doctor.id, new_author_user_id: nurse.id,
                                      by_user_id: admin.id, reason: reason)
    expect(DomainEvent.where(name: "consultation.draft_reassigned").sole.payload)
      .to eq("consultation_id" => fresh.id, "attendance_id" => fresh.attendance_id, "previous_author_user_id" => doctor.id,
             "new_author_user_id" => nurse.id, "by_user_id" => admin.id)
    expect(DomainEvent.pluck(:payload).to_json).not_to include("MARCADOR", "afastada")
  end

  it "o novo autor salva e finaliza; a autora antiga recebe not_author" do
    colleague = doctor!(unit)
    expect(reassign(to: colleague)).to be_ok
    draft = consultation.reload
    expect(Consultations::SaveDraft.call(consultation: draft, params: body, by: doctor).reason).to eq(:not_author)
    expect(Consultations::Finalize.call(consultation: draft, outcome_params: { "outcome" => "discharged" }, by: doctor).reason)
      .to eq(:not_author)
    expect(Consultations::SaveDraft.call(consultation: draft, params: draft_body(plan: "Plano do colega"), by: colleague)).to be_ok
    finalized = Consultations::Finalize.call(consultation: draft.reload, outcome_params: { "outcome" => "discharged" }, by: colleague)
    expect(finalized).to be_ok
    expect(draft.reload).to have_attributes(status: "finalized", author_user_id: colleague.id, plan: "Plano do colega")
    expect(draft.attendance.reload).to have_attributes(status: "closed", closed_by_user_id: colleague.id)
  end

  describe "regras de CID-10 pelo CBO novo" do
    let(:nurse) { doctor!(unit, cbo: "223505") }

    it "CID-10 adicionado pelo médico, designado à enfermeira → cid10_not_allowed_for_cbo" do
      body.merge!("evaluated_problems" => [ { "terminology" => "cid10", "code" => "E119", "action" => "add" },
                                            { "terminology" => "ciap2", "code" => "T90", "action" => "add" } ])
      expect(reassign(to: nurse)).to be_ok
      result = Consultations::Finalize.call(consultation: consultation.reload, outcome_params: { "outcome" => "discharged" }, by: nurse)
      expect([ result.reason, result.details ]).to eq([ :cid10_not_allowed_for_cbo, { index: 0 } ])
      expect(consultation.reload.status).to eq("draft")
    end

    it "pedido de exame com justificativa CID-10 do médico, designado à enfermeira → cid10_not_allowed_for_cbo" do
      body.merge!("exam_requests" => [ { "sigtap_code" => "0202010503", "cid10_justification" => "E119" } ])
      expect(consultation.draft_items["exam_requests"].sole).to include("cid10_justification" => "E119")
      expect(reassign(to: nurse)).to be_ok
      result = Consultations::Finalize.call(consultation: consultation.reload, outcome_params: { "outcome" => "discharged" }, by: nurse)
      expect([ result.reason, result.details ]).to eq([ :cid10_not_allowed_for_cbo, { index: 0 } ])
      expect(consultation.reload.status).to eq("draft")
      expect(ConsultationExamRequest.where(consultation_id: consultation.id)).to be_empty
    end

    context "com problema CID-10 já na lista do paciente" do
      # Uma consulta anterior do médico deixa E119 (CID-10) na lista.
      let!(:prior) do
        finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen,
                                evaluated_problems: [ { "terminology" => "cid10", "code" => "E119", "action" => "add" } ])
      end
      let(:consultation) do
        started_consultation!(unit: unit, doctor: doctor, citizen: citizen.reload).tap do |c|
          saved = Consultations::SaveDraft.call(consultation: c, params: body, by: doctor)
          raise "rascunho recusado: #{saved.reason} #{saved.details}" if saved.failure?

          end_links!(doctor)
        end
      end
      let(:cid10) { { "problem_id" => PatientProblem.find_by!(code: "E119").id, "action" => "evaluate" } }

      it "avaliado sem CIAP-2 → ciap2_required_for_cbo" do
        body.merge!("evaluated_problems" => [ cid10 ])
        expect(reassign(to: nurse)).to be_ok
        result = Consultations::Finalize.call(consultation: consultation.reload, outcome_params: { "outcome" => "discharged" }, by: nurse)
        expect(result.reason).to eq(:ciap2_required_for_cbo)
      end

      it "com CIAP-2 junto finaliza, e a ficha omite o CID-10" do
        city = ledi_ready!(Current.city, pec_url: "https://pec.a.test", record_mode: "record", ibge_code: "4106902")
        Current.city = city
        body.merge!("evaluated_problems" => [ cid10, { "terminology" => "ciap2", "code" => "T90", "action" => "add" } ])
        exportable_unit!(unit, nurse)
        expect(reassign(to: nurse)).to be_ok
        result = Consultations::Finalize.call(consultation: consultation.reload, outcome_params: { "outcome" => "discharged" }, by: nurse)
        expect(result).to be_ok
        expect(consultation.reload.problem_items.map(&:code)).to contain_exactly("E119", "T90")
        ficha, reasons = Ledi::ConsultationFicha.build(consultation)
        expect(reasons).to eq([])
        sent = ficha.to_thrift(uuid: "x").atendimentosIndividuais.sole
        expect(ficha.to_thrift(uuid: "x").headerTransport.lotacaoFormPrincipal.cboCodigo_2002).to eq("223505")
        expect(sent.problemasCondicoes.map { |p| [ p.ciap, p.cid10 ] }).to eq([ [ "T90", nil ] ])
      end
    end
  end
end
