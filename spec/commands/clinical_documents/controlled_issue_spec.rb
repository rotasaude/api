require "rails_helper"

# Spec §5–§6; ADR 0034 (Invariantes; Desvios 9–11): a RCE/RET digital tira um
# número do estoque do modo corrente na transação da emissão e nasce com o
# pedido de assinatura; sem número, certificado ou assinatura, papel com o
# motivo; a falha devolve o número (Review Focus 3); nada de número no evento.
# Papel nunca prepara assinatura (nem pedido, nem SignJob, nem canônico).
RSpec.describe "Emissão de receita controlada" do
  before do
    controlled_city!(mock: true)
    ciap2_release!; cid10_release!; sigtap_release!; city_profile!
    import_test_catalog!
  end

  let(:unit) { create_unit }
  let(:doctor) { signer_doctor!(unit).tap { |user| prescriber_contact!(user) } }
  let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)) }
  let(:fluoxetina) { controlled_item!(code: 9_900_001, ingredient: "FLUOXETINA", list: "C1") }

  def rce_content
    { "items" => [ { "catalog_item" => { "id" => fluoxetina.id }, "quantity" => 30, "quantity_unit" => "cápsula", "route" => "oral",
                     "dosage_instructions" => "1 cápsula pela manhã", "duration_days" => 30, "continuous" => true } ],
      "patient_identification" => patient_identification }
  end

  def ret_content
    { "items" => [ { "catalog_item" => { "id" => catalog_item(271_089).id }, "quantity" => 21, "quantity_unit" => "cápsula",
                     "route" => "oral", "dosage_instructions" => "1 cápsula de 8 em 8 horas", "duration_days" => 7 } ] }
  end

  def issue!(content = rce_content, kind: "prescription", by: doctor)
    ClinicalDocuments::Issue.call(kind: kind, content: content, by: by, consultation: consultation)
  end

  it "RCE digital: número do estoque, pedido de assinatura, eventos só com ids" do
    linked_certificate!(doctor)
    sncr_stock!(doctor, kind: "rce", count: 2)
    result = issue!
    document = result.payload[:document]
    expect(result.payload[:paper_reason]).to be_nil
    expect(document.issue_mode).to eq("digital")
    expect(document.paper_reason).to be_nil
    expect(document.content_data["sncr"]).to eq("kind" => "rce", "number" => "2610.1-41.0000001", "simulated" => true)
    expect(document.content_data["category"]).to eq("special_control")
    expect(SncrNumber.find_by(document_id: document.id)).to have_attributes(status: "used", number: "2610.1-41.0000001")
    expect(document.signature_request).to be_present
    issued = DomainEvent.where(name: "clinical_document.issued").order(:created_at).last.payload
    expect(issued).to include("document_id" => document.id, "category" => "special_control", "issue_mode" => "digital")
    used = DomainEvent.where(name: "sncr.number_used").order(:created_at).last.payload
    expect(used).to eq("document_id" => document.id, "kind" => "rce")
    expect(DomainEvent.where(name: %w[clinical_document.issued sncr.number_used]).pluck(:payload).to_json).not_to include("2610.1-41")
  end

  # Fix round 1 da Task 11 (coordenador, §12): só texto livre antimicrobiano
  # não vira RET; papel do 19c sem tirar número, motivo free_text_items (§12, docs 89f6748).
  it "só texto livre antimicrobiano: papel free_text_items, nenhum número tirado, sem pedido de assinatura" do
    linked_certificate!(doctor)
    sncr_stock!(doctor, kind: "ret", count: 1)
    free = { "items" => [ { "free_text" => "Azitromicina 500mg", "quantity" => 3, "quantity_unit" => "comprimido", "route" => "oral",
                            "dosage_instructions" => "1 ao dia", "duration_days" => 3 } ] }
    result = issue!(free).payload
    document = result[:document]
    expect([ document.issue_mode, result[:paper_reason], document.paper_reason ]).to eq([ "paper", "free_text_items", "free_text_items" ])
    expect(document.content_data).to include("category" => "antimicrobial", "sncr" => nil, "copies" => 2,
                                             "patient_identification" => nil, "prescriber_contact" => nil)
    both = issue!(free.merge("items" => free["items"] + [ free["items"].first.merge("free_text" => "Dipirona 500mg gotas") ])).payload
    expect([ both[:document].issue_mode, both[:paper_reason], both[:document].paper_reason ]).to eq([ "paper", "free_text_items", "free_text_items" ])
    expect(both[:document].content_data).to include("category" => "antimicrobial", "sncr" => nil, "patient_identification" => nil,
                                                    "prescriber_contact" => nil)
    expect(document.signature_request).to be_nil
    expect(SncrNumber.where(user_id: doctor.id).pluck(:status)).to eq([ "free" ])
    mixed = issue!(free.merge("items" => ret_content["items"] + free["items"]))
    expect([ mixed.reason, mixed.details ]).to eq([ :mixed_categories, { index: 1 } ])
  end

  it "duas emissões com 1 número: a segunda sai em papel com no_sncr_number (Review Focus 3)" do
    linked_certificate!(doctor)
    sncr_stock!(doctor, kind: "rce", count: 1)
    first = issue!.payload
    second = issue!.payload
    expect([ first[:document].issue_mode, first[:paper_reason] ]).to eq([ "digital", nil ])
    expect([ second[:document].issue_mode, second[:paper_reason] ]).to eq([ "paper", "no_sncr_number" ])
    expect(second[:document].paper_reason).to eq("no_sncr_number")
    expect(second[:document].content_data["sncr"]).to be_nil
    expect(second[:document].signature_request).to be_nil
    expect(SncrNumber.where(document_id: [ first[:document].id, second[:document].id ]).count).to eq(1)
  end

  it "falha depois de tirar o número: rollback, número livre, nenhum documento (Review Focus 3)" do
    linked_certificate!(doctor)
    sncr_stock!(doctor, kind: "rce", count: 1)
    consultation # a finalização também abre pedido de assinatura: a consulta nasce antes do stub
    allow(Signatures::OpenRequest).to receive(:call).and_raise(ActiveRecord::StatementInvalid, "falha simulada")
    expect { issue! }.to raise_error(ActiveRecord::StatementInvalid)
    expect(SncrNumber.where(user_id: doctor.id).pluck(:status)).to eq([ "free" ])
    expect(ClinicalDocument.where(consultation_id: consultation.id).count).to eq(0)
  end

  it "sem certificado: papel no_certificate e o número fica livre; sem assinatura: signature_unavailable" do
    sncr_stock!(doctor, kind: "rce", count: 1)
    result = issue!.payload
    expect([ result[:document].issue_mode, result[:paper_reason] ]).to eq([ "paper", "no_certificate" ])
    expect(SncrNumber.where(user_id: doctor.id).pluck(:status)).to eq([ "free" ])
    Platform::Features.set!(city: Current.city, key: "digital_signature", enabled: false, maintainer: ledi_maintainer!)
    expect(issue!.payload[:paper_reason]).to eq("signature_unavailable")
  end

  it "número simulado não serve com o sncr_mock desligado (Review Focus 4)" do
    linked_certificate!(doctor)
    sncr_stock!(doctor, kind: "rce", count: 1, simulated: true)
    Platform::Features.set!(city: Current.city, key: "sncr_mock", enabled: false, maintainer: ledi_maintainer!)
    result = issue!.payload
    expect([ result[:document].issue_mode, result[:paper_reason] ]).to eq([ "paper", "no_sncr_number" ])
  end

  it "modo real (sncr_mock desligado): número real sai com simulated false" do
    linked_certificate!(doctor)
    sncr_stock!(doctor, kind: "rce", count: 1, simulated: false)
    Platform::Features.set!(city: Current.city, key: "sncr_mock", enabled: false, maintainer: ledi_maintainer!)
    document = issue!.payload[:document]
    expect([ document.issue_mode, document.paper_reason ]).to eq([ "digital", nil ])
    expect(document.content_data["sncr"]).to eq("kind" => "rce", "number" => "2610.1-41.0000001", "simulated" => false)
    expect(SncrNumber.find_by(document_id: document.id)).to have_attributes(status: "used", simulated: false)
  end

  it "número real não serve com o sncr_mock ligado: papel no_sncr_number e o número fica livre" do
    linked_certificate!(doctor)
    sncr_stock!(doctor, kind: "rce", count: 1, simulated: false)
    result = issue!.payload
    expect([ result[:document].issue_mode, result[:paper_reason] ]).to eq([ "paper", "no_sncr_number" ])
    expect(SncrNumber.where(user_id: doctor.id).pluck(:status, :simulated)).to eq([ [ "free", false ] ])
  end

  it "RET digital: número ret; sem contato → 422 e o número volta" do
    linked_certificate!(doctor)
    sncr_stock!(doctor, kind: "ret", count: 1)
    result = issue!(ret_content).payload
    expect(result[:document].content_data).to include("category" => "antimicrobial", "copies" => 2,
                                                      "sncr" => include("kind" => "ret", "number" => "2610.2-41.0000001"))
    sncr_stock!(doctor, kind: "ret", count: 1)
    doctor.professional.update!(prescriber_address: nil)
    expect(issue!(ret_content).reason).to eq(:prescriber_address_missing)
    expect(SncrNumber.where(user_id: doctor.id, kind: "ret", status: "free").count).to eq(1)
  end

  it "RET sem contato que sairia em papel (sem número) é emitida: o contato só é exigido no digital (§12)" do
    linked_certificate!(doctor)
    doctor.professional.update!(prescriber_address: nil)
    result = issue!(ret_content).payload
    expect([ result[:document].issue_mode, result[:paper_reason] ]).to eq([ "paper", "no_sncr_number" ])
    expect(result[:document].content_data).to include("prescriber_contact" => nil, "sncr" => nil)
  end

  it "interruptor desligado: antimicrobiano em papel (feature_disabled), controlado recusado" do
    linked_certificate!(doctor)
    Platform::Features.set!(city: Current.city, key: "controlled_prescriptions", enabled: false, maintainer: ledi_maintainer!)
    result = issue!(ret_content).payload
    expect([ result[:document].issue_mode, result[:paper_reason] ]).to eq([ "paper", "feature_disabled" ])
    expect(issue!.reason).to eq(:controlled_not_allowed)
  end

  it "papel nunca prepara assinatura: RCE e RET em papel sem pedido, sem SignJob e sem canônico" do
    linked_certificate!(doctor)
    consultation # a finalização da consulta (assinável) enfileira o SignJob dela antes do bloco
    allow(ClinicalDocuments::Canonical).to receive(:content).and_call_original
    rce = ret = nil
    expect do
      rce = issue!.payload[:document]
      ret = issue!(ret_content).payload[:document]
    end.not_to have_enqueued_job(Signatures::SignJob)
    expect([ rce, ret ].map { |document| [ document.issue_mode, document.paper_reason ] })
      .to eq([ [ "paper", "no_sncr_number" ], [ "paper", "no_sncr_number" ] ])
    expect(SignatureRequest.where(document_id: [ rce.id, ret.id ])).to be_empty
    expect(ClinicalDocuments::Canonical).not_to have_received(:content)
  end

  it "registro da Notificação ainda não liberado: recusado sem 500 (a Task 13 libera)" do
    expect(issue!({}, kind: "controlled_notification_record").reason).to eq(:cbo_not_allowed)
    Platform::Features.set!(city: Current.city, key: "controlled_prescriptions", enabled: false, maintainer: ledi_maintainer!)
    off = issue!({}, kind: "controlled_notification_record")
    expect([ off.reason, off.details ]).to eq([ :feature_disabled, { feature: "controlled_prescriptions" } ])
  end

  it "a decisão do modo (Desvio 10)" do
    ctx = ->(signing: true, controlled: true) { ClinicalDocuments::Issue::Context.new(signing: signing, controlled: controlled, simulated: true, platform: nil, contact: nil) }
    decide = ->(category, role: :physician, certificate: true, **opts) do
      ClinicalDocuments::Issue.decide(kind: "prescription", category: category, role: role, ctx: ctx.(**opts), certificate: certificate)
    end
    expect(decide.("antimicrobial", controlled: false)).to eq([ :paper, :feature_disabled ])
    expect(decide.("antimicrobial", controlled: false, role: :nurse, signing: false)).to eq([ :paper, :feature_disabled ])
    expect(decide.("antimicrobial", role: :nurse)).to eq([ :paper, :nurse_antimicrobial ])
    expect(decide.("antimicrobial", role: :nurse, signing: false)).to eq([ :paper, :nurse_antimicrobial ])
    expect(decide.("special_control", signing: false)).to eq([ :paper, :signature_unavailable ])
    expect(decide.("special_control", signing: false, certificate: false)).to eq([ :paper, :signature_unavailable ])
    expect(decide.("special_control", certificate: false)).to eq([ :paper, :no_certificate ])
    expect(decide.("common")).to eq([ :digital, nil ])
    free = ->(**opts) do
      ClinicalDocuments::Issue.decide(kind: "prescription", category: "antimicrobial", role: opts.fetch(:role, :physician),
                                      ctx: ctx.(**opts.except(:role)), certificate: true, paper_only: true)
    end
    expect(free.()).to eq([ :paper, :free_text_items ])
    expect(free.(signing: false)).to eq([ :paper, :free_text_items ])
    expect(free.(role: :nurse)).to eq([ :paper, :nurse_antimicrobial ])
    expect(free.(controlled: false)).to eq([ :paper, :feature_disabled ])
    expect(ClinicalDocuments::Issue.decide(kind: "controlled_notification_record", category: nil, role: :physician, ctx: ctx.(), certificate: true))
      .to eq([ :paper, nil ])
    expect(ctx.().inspect).not_to include("contact")
    secret = ClinicalDocuments::Issue::Context.new(signing: true, controlled: true, simulated: false, platform: nil,
                                                   contact: { "address" => ControlledPrescriptionHelpers::ADDRESS, "phone" => "41999990000" })
    [ secret.inspect, secret.to_s, secret.pretty_inspect ].each { |text| expect(text).not_to include("Araucárias", "41999990000") }
  end
end
