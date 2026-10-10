# spec/services/clinical_documents/prescription_content_spec.rb
require "rails_helper"

# Spec §5; ADR 0033 (Invariantes): nenhum controlado no 19c; antimicrobiano só
# papel, 2 vias, 10 dias; texto livre permitido (menos para enfermagem) e
# varrido nas listas; enfermeiro só itens do protocolo vigente, dentro da dose
# máxima, com o CNPJ da cidade.
RSpec.describe ClinicalDocuments::Content::Prescription do
  before { clinical_city!; ciap2_release!; cid10_release!; sigtap_release! }

  let!(:catalog_by_code) { import_test_catalog! }
  let(:catalog) { catalog_by_code.values.index_by(&:id) }
  let(:matcher) { Medications::Substances.matcher }
  let(:unit) { create_unit }
  let(:patient) { finalized_consultation!(unit: unit, doctor: doctor!(unit), citizen: verified_citizen!(1)).patient }
  let(:today) { Time.zone.today }

  def item(code = 268_856, **over)
    { "catalog_item" => { "id" => catalog_item(code).id }, "quantity" => 30, "quantity_unit" => "comprimido",
      "route" => "oral", "dosage_instructions" => "1 comprimido pela manhã", "duration_days" => 30,
      "continuous" => true }.merge(over.transform_keys(&:to_s))
  end

  def call(items, role: :physician, **input)
    described_class.call({ "items" => items }.merge(input.transform_keys(&:to_s)), role: role, patient: patient,
                         catalog: catalog, matcher: matcher, today: today, city_cnpj: input.delete(:cnpj) || "76001234000115")
  end

  it "médico: item do catálogo vira item da receita com o código e a release da emissão" do
    result = call([ item ])
    row = result.payload[:items].sole
    losartana = catalog_item(268_856)
    expect(row).to include(position: 1, medication_catalog_item_id: losartana.id, catmat_code: 268_856,
                           catalog_release_id: losartana.last_release_id, free_text: nil,
                           printed_description: "LOSARTANA POTÁSSICA 50 MG", quantity: BigDecimal("30"),
                           route: "oral", continuous: true, antimicrobial: false)
    expect(result.payload[:content]).to eq(
      "items" => [ { "position" => 1, "catalog_item" => ClinicalDocuments::Json.catalog_ref(losartana).deep_stringify_keys,
                     "printed_description" => "LOSARTANA POTÁSSICA 50 MG", "quantity" => 30, "quantity_unit" => "comprimido",
                     "route" => "oral", "dosage_instructions" => "1 comprimido pela manhã", "duration_days" => 30,
                     "continuous" => true, "antimicrobial" => false } ],
      "catalog_release" => losartana.last_release_id, "antimicrobial" => false, "copies" => 1
    )
    expect(call([ item ], valid_until: (today + 60).iso8601).payload[:content]["valid_until"]).to eq((today + 60).iso8601)
    expect(call([ item ], valid_until: (today - 1).iso8601).details).to eq(field: "valid_until")
  end

  it "item sem forma farmacêutica é aceito e sai com dosage_form null" do
    losartana = catalog_item(268_856)
    losartana.update_columns(dosage_form: nil)
    result = described_class.call({ "items" => [ item ] }, role: :physician, patient: patient,
                                  catalog: { losartana.id => losartana.reload }, matcher: matcher, today: today)
    ref = result.payload[:content]["items"].sole["catalog_item"]
    expect(ref).to include("dosage_form" => nil)
    expect(ref).to have_key("dosage_form")
    expect(result.payload[:items].sole[:printed_description]).to eq(losartana.label)
  end

  it "controlado do catálogo ou em texto livre → controlled_not_allowed com o índice" do
    expect(call([ item, item(267_197) ]).then { |r| [ r.reason, r.details ] }).to eq([ :controlled_not_allowed, { index: 1 } ])
    free = { "free_text" => "Diazepam 10 mg", "quantity" => 10, "quantity_unit" => "comprimido", "route" => "oral",
             "dosage_instructions" => "1 à noite" }
    expect(call([ free ]).reason).to eq(:controlled_not_allowed)
  end

  it "antimicrobiano (catálogo ou texto livre) → 2 vias, validade de 10 dias" do
    content = call([ item(271_089, continuous: false, duration_days: 7) ]).payload[:content]
    expect(content).to include("antimicrobial" => true, "copies" => 2, "valid_until" => (today + 10).iso8601)
    free = { "free_text" => "Azitromicina 500mg", "quantity" => 3, "quantity_unit" => "comprimido", "route" => "oral",
             "dosage_instructions" => "1 ao dia" }
    expect(call([ free ]).payload[:content]).to include("antimicrobial" => true, "copies" => 2)
  end

  it "forma do item: um e só um entre catálogo e texto; escondido; quantidade; via; motivo de outro paciente; limite" do
    expect(call([ item.merge("free_text" => "Losartana") ]).details).to eq(index: 0, field: "catalog_item")
    expect(call([ item(384_258) ]).details).to eq(index: 0, field: "catalog_item")
    expect(call([ item(quantity: 0) ]).details).to eq(index: 0, field: "quantity")
    expect(call([ item(quantity: 1.555) ]).details).to eq(index: 0, field: "quantity")
    expect(call([ item(route: "anal") ]).details).to eq(index: 0, field: "route")
    expect(call([ item(dosage_instructions: "x") ]).details).to eq(index: 0, field: "dosage_instructions")
    expect(call([ item(reason_problem_id: SecureRandom.uuid) ]).details).to eq(index: 0, field: "reason_problem_id")
    expect(call([]).details).to eq(field: "items")
    expect(call(Array.new(21) { item }).details).to eq(field: "items")
  end

  describe "enfermagem" do
    let(:admin) { municipal_admin! }
    let!(:protocol_version) do
      params = { "title" => "Saúde da mulher", "number" => "PE-01", "year" => 2026, "valid_from" => (today - 30).iso8601,
                 "items" => [ { "catalog_item_id" => catalog_item(267_503).id, "max_dose" => { "quantity" => 30, "unit" => "comprimido" } },
                              { "catalog_item_id" => catalog_item(268_162).id } ] }
      NursingProtocols::Save.create(params: params, by: admin, catalog: catalog).payload[:protocol].current_version(on: today)
    end

    def nursing(items, **input) = call(items, role: :nurse, nursing_protocol: { "version_id" => protocol_version.id }, **input)

    it "item do protocolo vigente, dentro da dose, com CNPJ → conteúdo com protocolo e CNPJ" do
      result = nursing([ item(267_503, quantity: 30, continuous: false) ])
      expect(result.payload[:content]).to include(
        "nursing_protocol" => { "id" => protocol_version.nursing_protocol_id, "title" => "Saúde da mulher", "number" => "PE-01",
                                "year" => 2026, "version_id" => protocol_version.id },
        "city_cnpj" => "76001234000115"
      )
      expect(result.payload[:items].sole[:nursing_protocol_version_item_id]).to eq(protocol_version.items.find_by(catalog_item_id: catalog_item(267_503).id).id)
    end

    it "texto livre, sem protocolo, item fora, acima da dose ou unidade diferente, sem CNPJ" do
      free = { "free_text" => "Ácido fólico 5 mg", "quantity" => 30, "quantity_unit" => "comprimido", "route" => "oral",
               "dosage_instructions" => "1 ao dia" }
      expect([ nursing([ free ]).reason, nursing([ free ]).details ]).to eq([ :free_text_not_allowed, { index: 0 } ])
      expect(call([ item(267_503) ], role: :nurse).reason).to eq(:not_in_nursing_protocol)
      expect(nursing([ item(267_503), item(268_856) ]).then { |r| [ r.reason, r.details ] }).to eq([ :not_in_nursing_protocol, { index: 1 } ])
      expect(nursing([ item(267_503, quantity: 31) ]).then { |r| [ r.reason, r.details ] }).to eq([ :above_protocol_max_dose, { index: 0 } ])
      expect(nursing([ item(267_503, quantity: 1, quantity_unit: "caixa") ]).reason).to eq(:above_protocol_max_dose)
      expect(nursing([ item(268_162, quantity: 5, quantity_unit: "bisnaga") ])).to be_ok # sem dose máxima
      expect(described_class.call({ "items" => [ item(267_503) ], "nursing_protocol" => { "version_id" => protocol_version.id } },
                                  role: :nurse, patient: patient, catalog: catalog, matcher: matcher, today: today, city_cnpj: nil).reason)
        .to eq(:city_cnpj_missing)
    end

    it "versão que não é a vigente (substituída ou vencida) → not_in_nursing_protocol" do
      protocol = protocol_version.nursing_protocol
      NursingProtocols::Save.add_version(protocol: protocol, params: { "valid_from" => today.iso8601, "items" => [ { "catalog_item_id" => catalog_item(267_503).id } ] },
                                         by: admin, catalog: catalog)
      expect(nursing([ item(267_503) ]).reason).to eq(:not_in_nursing_protocol)
    end
  end
end
