require "rails_helper"

# Módulo 24a (ADR 0042; contrato §15.4): a ficha de Cadastro Domiciliar e
# Territorial montada de valores (pura). tipoEndereco 3; endereço com o
# município e a UF (DNE) do perfil da cidade; famílias só no tipo 1, com o CPF
# OU o CNS do responsável; domicílio inativo = famílias em stMudanca (o IDL
# não tem stAtivo, §15.5).
RSpec.describe Ledi::Fichas::HouseholdRegistration do
  let(:header) { Ledi::Fichas::RegistrationHeader.new(cnes: "1234567", ine: "0000000001", professional_cns: "700000000000005", cbo: "515105",
                                                       saved_at: Time.zone.parse("2026-10-23 10:00"), ibge_code: "4106902") }
  let(:family) do
    { "cpf" => "52998224725", "cns" => nil, "birth_date" => "1953-08-20", "members_count" => 3, "income_band" => "2",
      "living_since" => "2019-03", "moved_out" => false }
  end
  let(:values) do
    { "property_type" => "1", "refused" => false, "status" => "active", "micro_area_code" => "01", "uf" => "PR",
      "contact_phone" => "4133334444",
      "address" => { "zip" => "80010000", "street_type" => "081", "street" => "das Flores", "number" => "120", "no_number" => false,
                     "complement" => "casa 2", "district" => "Centro", "reference" => "perto da escola" },
      "living_conditions" => { "localizacao" => 83, "situacao_moradia_posse_terra" => 75, "nu_moradores" => 3, "nu_comodos" => 4,
                               "st_animais_no_domicilio" => true, "animais_no_domicilio" => [ 128, 129 ], "quantos_animais_no_domicilio" => 2 },
      "families" => [ family ] }
  end

  # Ruby 3: thrift("chave" => …) chega como palavras-chave (chave String é
  # aceita em **); o resto vira o Hash de sobrescrita.
  def ficha(over = {}, originating: nil, **rest) =
    described_class.new(header: header, values: values.merge(over.merge(rest.transform_keys(&:to_s))), originating_uuid: originating, source_id: "h1")

  def thrift(over = {}, originating: nil, **rest) = ficha(over, originating: originating, **rest).to_thrift(uuid: "1234567-h1")

  it "interface de ficha; tipoEndereco 3, tpCdsOrigem 3, tipo de imóvel; originadora como no individual" do
    expect(Ledi::Ficha.assert!(ficha)).to be_a(described_class)
    expect([ ficha.type, ficha.competence, ficha.source ]).to eq([ "cadastro_domiciliar", "202610", { type: "HouseholdVersion", id: "h1" } ])
    t = thrift
    expect([ t.tipoEndereco, t.tpCdsOrigem, t.tipoDeImovel, t.statusTermoRecusa ]).to eq([ 3, 3, 1, false ])
    expect([ t.uuid, t.uuidFichaOriginadora, t.fichaAtualizada ]).to eq([ "1234567-h1", "1234567-h1", false ])
    expect([ thrift(originating: "1234567-h0").uuidFichaOriginadora, thrift(originating: "1234567-h0").fichaAtualizada ]).to eq([ "1234567-h0", true ])
    expect(t.headerTransport.cboCodigo_2002).to eq("515105")
  end

  it "endereço: codigoIbgeMunicipio do perfil, numeroDneUf PR → 17, tipo de logradouro DNE, telefoneContato, microárea" do
    a = thrift.enderecoLocalPermanencia
    expect([ a.codigoIbgeMunicipio, a.numeroDneUf, a.tipoLogradouroNumeroDne, a.cep, a.nomeLogradouro, a.numero, a.stSemNumero ])
      .to eq([ "4106902", "17", "081", "80010000", "das Flores", "120", false ])
    expect([ a.complemento, a.bairro, a.pontoReferencia, a.telefoneContato, a.telefoneResidencia, a.microArea, a.stForaArea ])
      .to eq([ "casa 2", "Centro", "perto da escola", "4133334444", nil, "01", false ])
    no_number = thrift("address" => values["address"].merge("number" => nil, "no_number" => true)).enderecoLocalPermanencia
    expect([ no_number.numero, no_number.stSemNumero ]).to eq([ nil, true ])
  end

  it "condições de moradia e animais pelo nome do IDL (contagens em texto, como no IDL)" do
    t = thrift
    expect([ t.condicaoMoradia.localizacao, t.condicaoMoradia.situacaoMoradiaPosseTerra, t.condicaoMoradia.nuMoradores, t.condicaoMoradia.nuComodos ])
      .to eq([ 83, 75, "3", "4" ])
    expect([ t.stAnimaisNoDomicilio, t.animaisNoDomicilio, t.quantosAnimaisNoDomicilio ]).to eq([ true, [ 128, 129 ], "2" ])
    expect(t.instituicaoPermanencia).to be_nil
  end

  it "familias com cpfResponsavel e sem numeroCnsResponsavel (e o contrário sem CPF); resideDesde = dia 1 em epoch ms" do
    row = thrift.familias.sole
    expect([ row.cpfResponsavel, row.numeroCnsResponsavel, row.numeroMembrosFamilia, row.rendaFamiliar, row.stMudanca ])
      .to eq([ "52998224725", nil, 3, 2, false ])
    expect(row.resideDesde).to eq(Time.zone.parse("2019-03-01").to_i * 1000)
    expect(row.dataNascimentoResponsavel).to eq(Time.zone.parse("1953-08-20").to_i * 1000)
    row = thrift("families" => [ family.merge("cpf" => nil, "cns" => "700000000000005") ]).familias.sole
    expect([ row.cpfResponsavel, row.numeroCnsResponsavel ]).to eq([ nil, "700000000000005" ])
    row = thrift("families" => [ family.merge("cns" => "700000000000005") ]).familias.sole
    expect([ row.cpfResponsavel, row.numeroCnsResponsavel ]).to eq([ "52998224725", nil ])
  end

  it "famílias só no tipo 1; família que saiu e domicílio inativo vão com stMudanca" do
    expect(thrift("property_type" => "2", "living_conditions" => nil).familias).to be_nil
    expect(thrift("families" => []).familias).to be_nil
    moved = thrift("families" => [ family, family.merge("cpf" => "11144477735", "moved_out" => true) ]).familias
    expect(moved.map(&:stMudanca)).to eq([ false, true ])
    inactive = thrift("status" => "inactive", "families" => [ family, family.merge("cpf" => "11144477735") ]).familias
    expect(inactive.map(&:stMudanca)).to eq([ true, true ])
  end

  it "instituição de permanência (07–11) com o nome do responsável técnico no conjunto oficial" do
    t = thrift("property_type" => "7", "families" => [],
               "living_conditions" => { "localizacao" => 83, "instituicao_permanencia" => {
                 "nome_instituicao_permanencia" => "Abrigo Esperança", "nome_responsavel_tecnico" => "Conceição Peña-Ribeiro",
                 "st_outros_profissionais_vinculados" => true, "telefone_responsavel_tecnico" => "4133335555" } })
    inst = t.instituicaoPermanencia
    expect([ inst.nomeInstituicaoPermanencia, inst.nomeResponsavelTecnico, inst.stOutrosProfissionaisVinculados, inst.telefoneResponsavelTecnico ])
      .to eq([ "Abrigo Esperança", "CONCEICÃO PENA RIBEIRO", true, "4133335555" ])
    expect(TerritoryRegistry::Dictionary.valid_name?(inst.nomeResponsavelTecnico, strict: true)).to be(true)
    expect([ t.tipoDeImovel, t.condicaoMoradia.localizacao ]).to eq([ 7, 83 ])
  end

  it "recusa: statusTermoRecusa, sem condição de moradia, animais nem famílias" do
    t = thrift("refused" => true)
    expect([ t.statusTermoRecusa, t.condicaoMoradia, t.familias, t.animaisNoDomicilio, t.stAnimaisNoDomicilio ]).to eq([ true, nil, nil, nil, nil ])
    expect(t.enderecoLocalPermanencia.cep).to eq("80010000")
  end

  it "inspect sem endereço, telefone nem CPF" do
    built = ficha
    [ built.inspect, built.to_s, built.pretty_inspect, built.as_json.to_s ].each do |text|
      expect(text).not_to include("Flores", "4133334444", "52998224725")
    end
  end

  it "UF_TO_DNE: sigla do perfil → código texto do DNE (string_domains.uf)" do
    expect(TerritoryRegistry::Catalog::UF_TO_DNE.fetch("PR")).to eq("17")
    expect(TerritoryRegistry::Catalog::UF_TO_DNE.fetch("SP")).to eq("26")
    expect(TerritoryRegistry::Catalog::UF_TO_DNE.size).to eq(27)
    expect(TerritoryRegistry::Catalog::UF_TO_DNE.values).to match_array(TerritoryRegistry::Dictionary.string_domain("uf").keys)
  end
end
