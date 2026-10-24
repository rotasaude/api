require "rails_helper"

# D-U1 (contrato §12): validação dos campos do BPA-I no cadastro do
# paciente — códigos do layout sem 99, etnia só e sempre com indígena,
# larguras do layout recusadas (nunca cortadas), só as chaves presentes.
RSpec.describe Patients::Demographics do
  before { clinical_city! }

  let(:patient) { exam_patient!(exam_seq!).first }

  it "aceita os campos válidos, normaliza CEP e espaços, e só mexe nas chaves presentes" do
    parsed = described_class.parse("race_color" => "03", "address_zip" => "80010-000", "address_street" => "  Rua XV   de Novembro ",
                                   "address_number" => "SN")
    expect(parsed.payload[:values]).to eq("race_color" => "03", "address_zip" => "80010000", "address_street" => "Rua XV de Novembro",
                                          "address_number" => "SN")
    described_class.save!(patient, parsed.payload[:values])
    described_class.save!(patient, described_class.parse("address_district" => "Centro").payload[:values])
    expect(patient.reload).to have_attributes(race_color: "03", address_zip: "80010000", address_district: "Centro")
    expect(described_class.flags(patient)).to eq(race_color_set: true, address_set: true, address_from_household: false)
    described_class.save!(patient, described_class.parse("address_district" => "").payload[:values])
    expect(described_class.flags(patient.reload)).to eq(race_color_set: true, address_set: false, address_from_household: false)
  end

  it "recusa com o campo: 99, CEP, larguras, tipo; etnia × raça" do
    {
      { "race_color" => "99" } => [ :invalid_race_color, "race_color" ], { "address_zip" => "8001000" } => [ :invalid_zip, "address_zip" ],
      { "address_street" => "R" * 31 } => [ :too_long, "address_street" ], { "address_number" => "123456" } => [ :too_long, "address_number" ],
      { "address_complement" => "C" * 11 } => [ :too_long, "address_complement" ], { "ethnicity" => "12" } => [ :invalid_ethnicity, "ethnicity" ],
      { "address_district" => "B" * 31 } => [ :too_long, "address_district" ], { "race_color" => 3 } => [ :invalid_demographics, "race_color" ]
    }.each do |params, (reason, field)|
      result = described_class.parse(params)
      expect([ result.reason, result.details[:field] ]).to eq([ reason, field ]), params.keys.inspect
    end
    expect(described_class.save!(patient, "race_color" => "05").reason).to eq(:ethnicity_required)
    expect(described_class.save!(patient, "race_color" => "03", "ethnicity" => "0001").reason).to eq(:invalid_ethnicity)
    expect(described_class.save!(patient, "race_color" => "05", "ethnicity" => "0001")).to be_ok
    expect(patient.reload.race_color).to eq("05")
  end

  it "larguras do layout no limite passam inteiras (nunca cortadas)" do
    values = described_class.parse("address_street" => "R" * 30, "address_number" => "12345", "address_complement" => "C" * 10,
                                   "address_district" => "B" * 30).payload[:values]
    expect(values.values.map(&:length)).to eq([ 30, 5, 10, 30 ])
  end

  # §13 E4: número presente e vazio vira SN (sem número); os demais apagam.
  it "número vazio ou nulo vira SN; os outros campos vazios apagam" do
    expect(described_class.parse("address_number" => "").payload[:values]).to eq("address_number" => "SN")
    expect(described_class.parse("address_number" => nil).payload[:values]).to eq("address_number" => "SN")
    expect(described_class.parse("address_street" => nil, "race_color" => "  ").payload[:values])
      .to eq("address_street" => nil, "race_color" => nil)
  end

  # §13 E12: a combinação raça × etnia sai de save! para check, usada antes de validar o par.
  it "check confere a combinação final sem gravar" do
    expect(described_class.check("race_color" => "05").reason).to eq(:ethnicity_required)
    expect(described_class.check("race_color" => "05").details).to eq(field: "ethnicity")
    expect(described_class.check("ethnicity" => "0001").reason).to eq(:invalid_ethnicity)
    expect(described_class.check("race_color" => "05", "ethnicity" => "0001")).to be_ok
    expect(described_class.check({})).to be_ok
  end

  # Mutação: tirar a linha do ADR 0039 de filter_parameters põe raça/endereço no "Parameters:" do log.
  it "o log de parâmetros esconde os sete campos, só nas chaves exatas" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    expect(filter.filter(Patient::DEMOGRAPHICS.index_with { "x" })).to eq(Patient::DEMOGRAPHICS.index_with { "[FILTERED]" })
    expect(filter.filter("race_colors_count" => "1")).to eq("race_colors_count" => "1")
  end

  it "flags sem paciente: nada preenchido" do
    expect(described_class.flags(nil)).to eq(race_color_set: false, address_set: false, address_from_household: false)
  end
end
