# spec/services/clinical_documents/controlled_content_spec.rb
require "rails_helper"

# Spec §5; ADR 0034 (Invariantes; Valores fixados 3–4): categoria calculada
# pelos itens; misturar → mixed_categories (com o índice do primeiro item que
# não serve à categoria dominante; esquema apertado de 2026-10-10: RCE só C1/C5
# do catálogo, RET só antimicrobiano do catálogo); listas A/B →
# requires_notification; C2/C3/C4 → not_supported; RCE só médico/dentista,
# ≤ 3 C1, ≤ 60 dias (180 anticonvulsivante), duração obrigatória,
# identificação do paciente e contato do prescritor; antimicrobiano 10 dias;
# desligado, o 19c. Review Focus 5.
RSpec.describe ClinicalDocuments::Content::Prescription do
  before { documents_city!; ciap2_release!; cid10_release!; sigtap_release! }

  let(:catalog_items) do
    import_test_catalog!
    { fluoxetina: controlled_item!(code: 9_900_001, ingredient: "FLUOXETINA", list: "C1"),
      carbamazepina: controlled_item!(code: 9_900_002, ingredient: "CARBAMAZEPINA", list: "C1", anticonvulsant: true),
      diazepam: controlled_item!(code: 9_900_003, ingredient: "DIAZEPAM", list: "B1"),
      talidomida: controlled_item!(code: 9_900_004, ingredient: "TALIDOMIDA", list: "C3"),
      zidovudina: controlled_item!(code: 9_900_005, ingredient: "ZIDOVUDINA", list: "C4"),
      sertralina: controlled_item!(code: 9_900_006, ingredient: "SERTRALINA", list: "C1"),
      amitriptilina: controlled_item!(code: 9_900_007, ingredient: "AMITRIPTILINA", list: "C1"),
      c1_antimicrobiano: controlled_item!(code: 9_900_008, ingredient: "SUBSTANCIA TESTE", list: "C1", antimicrobial: true),
      nandrolona: controlled_item!(code: 9_900_009, ingredient: "NANDROLONA", list: "C5"),
      amoxicilina: catalog_item(271_089), losartana: catalog_item(268_856), paracetamol: catalog_item(267_778) }
  end
  let(:unit) { create_unit }
  let(:patient) { finalized_consultation!(unit: unit, doctor: doctor!(unit), citizen: verified_citizen!(1)).patient }
  let(:contact) { { "address" => ControlledPrescriptionHelpers::ADDRESS, "phone" => "41999990000" } }
  let(:today) { Date.new(2026, 10, 10) }

  def item(name, duration: 30, **over)
    { "catalog_item" => { "id" => catalog_items.fetch(name).id }, "quantity" => 30, "quantity_unit" => "comprimido", "route" => "oral",
      "dosage_instructions" => "1 comprimido ao dia", "duration_days" => duration }.merge(over.stringify_keys)
  end

  def free(text, duration: 7)
    { "free_text" => text, "quantity" => 30, "quantity_unit" => "comprimido", "route" => "oral",
      "dosage_instructions" => "1 ao dia", "duration_days" => duration }
  end

  def call(items, role: :physician, controlled: true, identification: patient_identification, prescriber_contact: contact)
    input = { "items" => items, "patient_identification" => identification }.compact
    described_class.call(input, role: role, patient: patient, catalog: catalog_items.values.index_by(&:id),
                                matcher: Medications::Substances.matcher, today: today, controlled: controlled,
                                prescriber_contact: prescriber_contact)
  end

  def failure(result) = [ result.reason, result.details ]

  it "RCE: categoria, identificação normalizada, contato, 30 dias, 2 vias, sncr ainda nulo" do
    # CPF, no_cpf e passaporte mandados na entrada são ignorados: vale o CPF do cadastro (Review Focus 5).
    result = call([ item(:fluoxetina) ], identification: patient_identification("cpf" => ControlledPrescriptionHelpers::PATIENT_CPF,
                                                                                "no_cpf" => true, "passport" => "AB123456"))
    expect(result).to be_ok
    expect(patient.cpf).to match(/\A\d{11}\z/)
    expect(patient.cpf).not_to eq(ControlledPrescriptionHelpers::PATIENT_CPF)
    expect(result.payload[:category]).to eq("special_control")
    expect(result.payload[:content]).to include("category" => "special_control", "sncr" => nil, "copies" => 2,
                                                "valid_until" => "2026-11-09", "prescriber_contact" => contact,
                                                "patient_identification" => { "cpf" => patient.cpf,
                                                                              "address" => ControlledPrescriptionHelpers::ADDRESS })
    expect(result.payload[:items].sole).to include(antimicrobial: false)
  end

  it "listas A/B e C2/C3/C4 (com o índice); controlado em texto livre recusado antes" do
    expect(failure(call([ item(:losartana), item(:diazepam) ]))).to eq([ :requires_notification, { index: 1 } ])
    expect(failure(call([ item(:talidomida) ]))).to eq([ :not_supported, { index: 0 } ])
    expect(failure(call([ item(:fluoxetina), item(:zidovudina) ]))).to eq([ :not_supported, { index: 1 } ])
    expect(failure(call([ free("fluoxetina 20 mg", duration: 30) ]))).to eq([ :controlled_not_allowed, { index: 0 } ])
    expect(failure(call([ item(:fluoxetina), free("diazepam 10 mg") ]))).to eq([ :controlled_not_allowed, { index: 1 } ])
  end

  describe "categoria dominante e mixed_categories com o índice (esquema apertado, 2026-10-10)" do
    {
      "C1 + comum" => [ %i[fluoxetina losartana], 1 ],
      "comum + C1 (índice 0)" => [ %i[losartana fluoxetina], 0 ],
      "C1 + antimicrobiano" => [ %i[fluoxetina amoxicilina], 1 ],
      "antimicrobiano + C1 (a RCE domina)" => [ %i[amoxicilina fluoxetina], 0 ],
      "C1 que também é antimicrobiano" => [ %i[c1_antimicrobiano], 0 ],
      "amoxicilina + paracetamol (vira duas receitas)" => [ %i[amoxicilina paracetamol], 1 ],
      "paracetamol + amoxicilina" => [ %i[paracetamol amoxicilina], 0 ]
    }.each do |label, (names, index)|
      it label do
        expect(failure(call(names.map { |name| item(name) }))).to eq([ :mixed_categories, { index: index } ])
      end
    end

    it "texto livre não entra em RCE nem em RET (P1 revogado)" do
      expect(failure(call([ item(:fluoxetina), free("chá de camomila", duration: 30) ]))).to eq([ :mixed_categories, { index: 1 } ])
      expect(failure(call([ item(:amoxicilina, duration: 7), free("Azitromicina 500mg") ]))).to eq([ :mixed_categories, { index: 1 } ])
      expect(failure(call([ free("Azitromicina 500mg") ], identification: nil))).to eq([ :mixed_categories, { index: 0 } ])
    end

    it "comum com texto livre comum continua uma receita só" do
      result = call([ item(:losartana, duration: nil), free("chá de camomila", duration: nil) ], identification: nil)
      expect(result).to be_ok
      expect(result.payload[:category]).to eq("common")
    end

    it "C1 + C5 é uma RCE só" do
      expect(call([ item(:fluoxetina), item(:nandrolona) ]).payload[:category]).to eq("special_control")
    end
  end

  it "limites: 3 C1 + 1 C5 de 60 dias passa; 4 C1 não; 61 dias não; anticonvulsivante até 180; duração obrigatória (Review Focus 5)" do
    expect(call([ item(:fluoxetina, duration: 60), item(:sertralina, duration: 60), item(:amitriptilina, duration: 60),
                  item(:nandrolona, duration: 60) ])).to be_ok
    expect(call([ item(:fluoxetina), item(:sertralina), item(:amitriptilina), item(:carbamazepina) ]).reason).to eq(:too_many_c1_substances)
    expect(failure(call([ item(:fluoxetina, duration: 61) ]))).to eq([ :duration_exceeded, { index: 0 } ])
    expect(call([ item(:carbamazepina, duration: 180) ])).to be_ok
    expect(failure(call([ item(:fluoxetina), item(:carbamazepina, duration: 181) ]))).to eq([ :duration_exceeded, { index: 1 } ])
    expect(failure(call([ item(:fluoxetina, duration: nil) ]))).to eq([ :invalid_item, { index: 0, field: "duration_days" } ])
    expect(call([ item(:carbamazepina) ]).payload[:items].sole).to include(antimicrobial: false)
  end

  it "quem prescreve: médico e dentista; enfermeiro não" do
    expect(call([ item(:fluoxetina) ], role: :dentist)).to be_ok
    expect(call([ item(:fluoxetina) ], role: :nurse).reason).to eq(:cbo_not_allowed)
    expect(call([ item(:fluoxetina) ], role: :other).reason).to eq(:cbo_not_allowed)
  end

  it "identificação e contato: obrigatórios na RCE, com o campo exato e sem o valor (Review Focus 5)" do
    expect(failure(call([ item(:fluoxetina) ], identification: nil))).to eq([ :patient_identification_required, { field: "patient_identification" } ])
    expect(failure(call([ item(:fluoxetina) ], identification: "Rua X"))).to eq([ :invalid_content, { field: "patient_identification" } ])
    expect(call([ item(:fluoxetina) ], identification: patient_identification("address" => nil)).details).to eq(field: "patient_identification.address")
    masked = call([ item(:fluoxetina) ], identification: patient_identification("address" => ControlledPrescriptionHelpers::ADDRESS.merge("zip" => "80010-000")))
    expect(failure(masked)).to eq([ :invalid_content, { field: "patient_identification.address.zip" } ])
    expect(masked.message.to_s).not_to include("80010")
    allow(patient).to receive(:cpf).and_return(nil) # cadastro sem CPF: a RCE não sai (o 19d não tem "não possui")
    expect(failure(call([ item(:fluoxetina) ]))).to eq([ :patient_identification_required, { field: "patient_identification.cpf" } ])
    allow(patient).to receive(:cpf).and_return("11111111111")
    expect(call([ item(:fluoxetina) ]).details).to eq(field: "patient_identification.cpf")
    allow(patient).to receive(:cpf).and_call_original
    expect(call([ item(:fluoxetina) ], prescriber_contact: nil).reason).to eq(:prescriber_address_missing)
  end

  it "antimicrobiano: 10 dias, 2 vias, identificação opcional (inteira quando vem); contato só de quem não é enfermeiro" do
    result = call([ item(:amoxicilina, duration: 7) ], identification: nil)
    expect(result.payload[:content]).to include("category" => "antimicrobial", "valid_until" => "2026-10-20", "copies" => 2, "sncr" => nil,
                                                "patient_identification" => nil, "prescriber_contact" => contact, "antimicrobial" => true)
    identified = call([ item(:amoxicilina, duration: 7) ]).payload[:content]["patient_identification"]
    expect(identified).to eq("cpf" => patient.cpf, "address" => ControlledPrescriptionHelpers::ADDRESS)
    bad = call([ item(:amoxicilina, duration: 7) ], identification: patient_identification("address" => { "street" => "Rua" }))
    expect(failure(bad)).to eq([ :invalid_content, { field: "patient_identification.address.number" } ])
    # RET sem contato só é recusada quando sairia digital (contrato §12): a emissão decide, aqui passa.
    expect(call([ item(:amoxicilina, duration: 7) ], prescriber_contact: nil).payload[:content]["prescriber_contact"]).to be_nil
    # O enfermeiro passa ainda pela trava do protocolo do 19c; a regra do contato é da categoria:
    nurse = ClinicalDocuments::Content::Controlled.check("antimicrobial", [], role: :nurse, identification: nil, prescriber_contact: contact,
                                                                              patient: patient)
    expect(nurse.payload[:prescriber_contact]).to be_nil
  end

  it "comum: sem identificação nem contato (mesmo mandados), validade do 19c" do
    content = call([ item(:losartana, duration: nil, continuous: true) ]).payload[:content]
    expect(content).to include("category" => "common", "copies" => 1, "sncr" => nil, "patient_identification" => nil, "prescriber_contact" => nil)
    expect(content).not_to have_key("valid_until")
  end

  it "interruptor desligado: o 19c (controlado recusado, antimicrobiano + comum em papel, texto livre antimicrobiano), identificação ignorada" do
    expect(failure(call([ item(:fluoxetina) ], controlled: false))).to eq([ :controlled_not_allowed, { index: 0 } ])
    expect(failure(call([ item(:losartana), item(:talidomida) ], controlled: false))).to eq([ :controlled_not_allowed, { index: 1 } ])
    content = call([ item(:amoxicilina) ], controlled: false, prescriber_contact: nil).payload[:content]
    expect(content).to include("category" => "antimicrobial", "copies" => 2, "patient_identification" => nil, "prescriber_contact" => nil)
    mixed = call([ item(:amoxicilina), item(:paracetamol), free("Azitromicina 500mg") ], controlled: false)
    expect(mixed).to be_ok
    expect(mixed.payload[:content]).to include("category" => "antimicrobial", "copies" => 2, "valid_until" => "2026-10-20",
                                               "patient_identification" => nil, "prescriber_contact" => nil)
  end

  describe ClinicalDocuments::Content::Controlled do
    it "valores fixados (ADR 0034)" do
      expect(described_class::SPECIAL).to eq(%w[C1 C5])
      expect(described_class::NOTIFICATION).to eq(%w[A1 A2 A3 B1 B2])
      expect(described_class::UNSUPPORTED).to eq(%w[C2 C3 C4])
      expect([ described_class::MAX_C1, described_class::SPECIAL_DAYS, described_class::ANTICONVULSANT_DAYS ]).to eq([ 3, 60, 180 ])
      expect(described_class::VALIDITY).to eq("special_control" => 30, "antimicrobial" => 10)
      expect(described_class::PRESCRIBERS).to eq(%i[physician dentist])
    end

    it "lista de controle desconhecida (fora de C1/C5/A/B) falha fechada: not_supported" do
      odd = { catalog: Object.new, free_text: nil, controlled: true, controlled_list: "D1", antimicrobial: false }
      expect(failure(described_class.classify([ odd ]))).to eq([ :not_supported, { index: 0 } ])
    end
  end
end
