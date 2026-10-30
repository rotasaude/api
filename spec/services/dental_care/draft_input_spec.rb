require "rails_helper"

# Módulo 28 (ADR 0046; contrato §2, §6, §16 O2, O5, O6, O25; Desvios 3, 6):
# o bloco `dental` do rascunho → colunas da FAO e itens normalizados. A
# primeira recusa, com o `path` do corpo; códigos inteiros ou string de
# dígitos; o `id` do procedimento nasce no servidor e o do cliente (uuid) fica.
RSpec.describe DentalCare::DraftInput do
  before { Current.city = dental_city! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:dentist) { dentist!(unit) }
  let(:consultation) { dental_consultation!(unit: unit, by: dentist, citizen: verified_citizen!(1)) }

  def call(raw) = described_class.call(raw, consultation: consultation)
  def refusal(raw) = call(raw).then { |r| [ r.reason, r.details[:path] ] }

  it "colunas da FAO com código string ou inteiro; itens normalizados com id gerado" do
    result = call("care_type" => "2", "dental_consultation_type" => 1, "oral_health_surveillance" => [ "3", 99 ],
                  "supplies" => [ 1 ], "dental_outcomes" => [ "16" ], "pregnant" => false, "special_needs" => true,
                  "procedures" => [ { "sigtap" => "0307010031", "location" => { "kind" => "face", "tooth" => "11", "face" => "M" } } ],
                  "findings" => [ { "tooth" => 26, "situation" => "caries", "face" => "O" }, { "arch" => "upper", "situation" => "complete_denture" } ])
    expect(result).to be_ok
    expect(result.payload[:attrs]).to eq("care_type" => 2, "dental_consultation_type" => 1, "oral_health_surveillance" => [ 3, 99 ],
                                         "supplies" => [ 1 ], "dental_outcomes" => [ 16 ], "pregnant" => false, "special_needs" => true)
    procedure = result.payload[:items]["procedures"].sole
    expect(procedure).to include("sigtap" => "0307010031", "quantity" => 1, "plan_item_id" => nil,
                                 "location" => { "kind" => "face", "tooth" => 11, "face" => "M", "sextant" => nil, "arch" => nil })
    expect(procedure["id"]).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
    expect(result.payload[:items]["findings"]).to eq([ { "tooth" => 26, "face" => "O", "part" => "crown", "arch" => nil, "situation" => "caries" },
                                                       { "tooth" => nil, "face" => nil, "part" => nil, "arch" => "upper", "situation" => "complete_denture" } ])
  end

  it "care_type 1 → invalid_care_type; listas e desfechos fora do vocabulário com o índice" do
    expect(refusal("care_type" => 1)).to eq([ :invalid_care_type, "dental.care_type" ])
    expect(refusal("oral_health_surveillance" => [ 7 ])).to eq([ :invalid_request, "dental.oral_health_surveillance[0]" ])
    expect(refusal("dental_outcomes" => [ 13 ])).to eq([ :invalid_request, "dental.dental_outcomes[0]" ])
    expect(refusal("dental_outcomes" => [ 15, "15" ])).to eq([ :invalid_request, "dental.dental_outcomes[1]" ])
    expect(refusal("dental_consultation_type" => 3)).to eq([ :invalid_request, "dental.dental_consultation_type" ])
    expect(refusal("pregnant" => "sim")).to eq([ :invalid_request, "dental.pregnant" ])
    expect(refusal("x")).to eq([ :invalid_request, "dental" ])
  end

  it "procedimento: local fora da lista, proibido na FAO e local inválido" do
    sextant = { "sigtap" => "0307010031", "location" => { "kind" => "sextant", "sextant" => "S1" } }
    expect(refusal("procedures" => [ sextant ])).to eq([ :invalid_location, "dental.procedures[0].location" ])
    forbidden = call("procedures" => [ { "sigtap" => "0301040079", "location" => { "kind" => "mouth" } } ])
    expect([ forbidden.reason, forbidden.details[:path] ]).to eq([ :invalid_procedure, "dental.procedures[0].sigtap" ])
    expect(forbidden.details[:reasons]).to be_present
    no_face = { "sigtap" => "0307010031", "location" => { "kind" => "face", "tooth" => 11 } }
    expect(refusal("procedures" => [ no_face ])).to eq([ :invalid_location, "dental.procedures[0].location" ])
  end

  it "procedimento incompatível na SIGTAP (CBO do vínculo, idade e sexo do paciente) → invalid_procedure com reasons" do
    allow(Terminology::Sigtap).to receive(:compatible?).and_call_original
    allow(Terminology::Sigtap).to receive(:compatible?)
      .with("0307010031", competence: Time.zone.today.strftime("%Y%m"), cbo: "223208", age_months: a_kind_of(Integer), sex: "female")
      .and_return(ok: false, reasons: [ "cbo_incompatible" ], release_version: "x")
    result = call("procedures" => [ { "sigtap" => "0307010031", "location" => { "kind" => "tooth", "tooth" => 11 } } ])
    expect([ result.reason, result.details ]).to eq([ :invalid_procedure, { path: "dental.procedures[0].sigtap", reasons: [ "cbo_incompatible" ] } ])
  end

  it "quantidade: 1 no dente; explícita no sextante até o banco" do
    tooth = { "sigtap" => "0307010031", "location" => { "kind" => "tooth", "tooth" => 11 }, "quantity" => 2 }
    expect(refusal("procedures" => [ tooth ])).to eq([ :invalid_request, "dental.procedures[0].quantity" ])
    sextant = { "sigtap" => "0307030059", "location" => { "kind" => "sextant", "sextant" => "S2" }, "quantity" => 2 }
    expect(call("procedures" => [ sextant ]).payload[:items]["procedures"].sole["quantity"]).to eq(2)
  end

  it "achado: coroa no decíduo e situação de raiz na face recusados" do
    expect(refusal("findings" => [ { "tooth" => 54, "situation" => "crown" } ]))
      .to eq([ :situation_not_allowed_for_tooth, "dental.findings[0].situation" ])
    expect(refusal("findings" => [ { "tooth" => 11, "part" => "root", "face" => "M", "situation" => "root_caries" } ]))
      .to eq([ :invalid_situation, "dental.findings[0].situation" ])
    expect(refusal("findings" => [ { "tooth" => 19, "situation" => "caries" } ])).to eq([ :invalid_request, "dental.findings[0].tooth" ])
  end

  it "especialidades: faixas do periograma, canais da endodontia e registro periodontal" do
    chart = { "teeth" => [ { "tooth" => 16, "mobility" => 1, "furcation" => nil,
                             "sites" => [ { "site" => "MV", "probing_depth_mm" => 21, "recession_mm" => -2, "bleeding" => true } ] } ] }
    expect(refusal("periodontal_chart" => chart)).to eq([ :invalid_request, "dental.periodontal_chart.teeth[0].sites[0].probing_depth_mm" ])
    expect(refusal("endodontics" => [ { "tooth" => 11, "canals" => 6, "status" => "in_progress" } ]))
      .to eq([ :invalid_request, "dental.endodontics[0].canals" ])
    screening = { "sextants" => [ { "sextant" => "S1", "code" => nil, "star" => false }, { "sextant" => "S2", "code" => 3, "star" => true } ] }
    ok = call("periodontal_screening" => screening, "periodontal_chart" => chart.deep_merge("teeth" => [ chart["teeth"][0].merge("sites" => [ chart["teeth"][0]["sites"][0].merge("probing_depth_mm" => 4) ]) ]))
    expect(ok).to be_ok
    expect(ok.payload[:items]["periodontal_screening"]["sextants"].first).to eq("sextant" => "S1", "code" => nil, "star" => false)
  end

  it "plano: motivo curto do cancelamento → invalid_reason; o bloco sai com as três chaves" do
    expect(refusal("plan_changes" => { "cancel" => [ { "item_id" => SecureRandom.uuid, "reason" => "curto" } ] }))
      .to eq([ :invalid_reason, "dental.plan_changes.cancel[0].reason" ])
    add = { "sigtap" => "0307010031", "location" => { "kind" => "tooth", "tooth" => 21 } }
    result = call("plan_changes" => { "add" => [ add ] })
    expect(result.payload[:items]["plan_changes"]).to include("cancel" => [], "cancel_plan" => nil)
    expect(result.payload[:items]["plan_changes"]["add"].sole).to include("sigtap" => "0307010031")
  end

  it "salvar duas vezes mantém o id do procedimento; id do cliente que não é uuid → invalid_request" do
    body = { "procedures" => [ { "sigtap" => "0307010031", "location" => { "kind" => "tooth", "tooth" => 11 } } ] }
    expect(Consultations::SaveDraft.call(consultation: consultation, params: { "dental" => body }, by: dentist)).to be_ok
    id = consultation.reload.draft_items["dental"]["procedures"].sole["id"]
    again = { "procedures" => [ body["procedures"][0].merge("id" => id) ] }
    expect(Consultations::SaveDraft.call(consultation: consultation, params: { "dental" => again }, by: dentist)).to be_ok
    expect(consultation.reload.draft_items["dental"]["procedures"].sole["id"]).to eq(id)
    expect(refusal("procedures" => [ body["procedures"][0].merge("id" => "abc") ])).to eq([ :invalid_request, "dental.procedures[0].id" ])
  end

  it "SaveDraft: o bloco dental na consulta geral → invalid_request path dental; care_type do topo ignorado na dental" do
    general = started_consultation!(unit: unit, doctor: doctor!(unit), citizen: verified_citizen!(2))
    refused = Consultations::SaveDraft.call(consultation: general, params: { "dental" => {} }, by: general.author_user)
    expect([ refused.reason, refused.details ]).to eq([ :invalid_request, { path: "dental" } ])
    expect(Consultations::SaveDraft.call(consultation: consultation, params: { "care_type" => nil, "dental" => { "care_type" => 6 } }, by: dentist)).to be_ok
    expect(consultation.reload.care_type).to eq(6)
    expect(Consultations::SaveDraft.call(consultation: consultation, params: { "care_type" => 5 }, by: dentist)).to be_ok
    expect(consultation.reload.care_type).to eq(6)
  end

  it "dentista registra CID-10 na consulta odontológica; o ASB não (Desvio 9)" do
    cid10_release!
    cid = { "evaluated_problems" => [ { "terminology" => "cid10", "code" => "I10", "action" => "add" } ] }
    expect(Consultations::SaveDraft.call(consultation: consultation, params: cid, by: dentist)).to be_ok
    auxiliary = auxiliary!(unit)
    other = dental_consultation!(unit: unit, by: auxiliary, citizen: verified_citizen!(3))
    expect(Consultations::SaveDraft.call(consultation: other, params: cid, by: auxiliary).reason).to eq(:cid10_not_allowed_for_cbo)
  end
end
