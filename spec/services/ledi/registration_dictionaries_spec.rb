# spec/services/ledi/registration_dictionaries_spec.rb
require "rails_helper"

# Prova técnica do módulo 24a (Task 0): os dicionários das fichas de cadastro
# apontam para campos reais do IDL LEDI 8.7.0, com os domínios oficiais
# (vendor/ledi/8.7.0/docs).
RSpec.describe "Dicionários das fichas de cadastro (LEDI 8.7.0)" do
  let(:yaml) { YAML.load_file(Rails.root.join("config/ledi/registration_dictionaries.yml")) }

  def idl_fields(file, struct)
    text = Ledi::Version.root.join("idl/ras", file).read
    text[/struct\s+#{struct}\s*\{(.*?)\n\}/m, 1].scan(/^\s*\d+:\s*(?:required|optional)\s+[\w.<>]+\s+(\w+)/).flatten
  end

  {
    "identification" => [ "cadastro_individual.thrift", "IdentificacaoUsuarioCidadaoThrift" ],
    "health_conditions" => [ "cadastro_individual.thrift", "CondicoesDeSaudeThrift" ],
    "street_situation" => [ "cadastro_individual.thrift", "EmSituacaoDeRuaThrift" ]
  }.each do |section, (file, struct)|
    it "#{section}: todo campo aponta para um campo de #{struct}, e a chave é o nome em snake_case" do
      fields = idl_fields(file, struct)
      yaml.fetch("sections").fetch(section).each do |key, spec|
        expect(fields).to include(spec.fetch("ledi"))
        expect(key).to eq(spec.fetch("ledi").underscore)
      end
    end
  end

  it "health_conditions e street_situation cobrem a struct inteira" do
    expect(yaml["sections"]["health_conditions"].values.map { |s| s["ledi"] })
      .to match_array(idl_fields("cadastro_individual.thrift", "CondicoesDeSaudeThrift"))
    expect(yaml["sections"]["street_situation"].values.map { |s| s["ledi"] })
      .to match_array(idl_fields("cadastro_individual.thrift", "EmSituacaoDeRuaThrift"))
  end

  it "sociodemographic cobre InformacoesSocioDemograficas e InformacoesSocioEconomicas; living_conditions cobre CondicaoMoradia e os animais" do
    socio = idl_fields("cadastro_individual.thrift", "InformacoesSocioDemograficasThrift") +
            idl_fields("cadastro_individual.thrift", "InformacoesSocioEconomicasThrift")
    living = idl_fields("cadastro_domiciliar.thrift", "CondicaoMoradiaThrift") +
             %w[animaisNoDomicilio stAnimaisNoDomicilio quantosAnimaisNoDomicilio instituicaoPermanencia]
    expect(yaml["sections"]["sociodemographic"].values.map { |s| s["ledi"] }).to match_array(socio)
    expect(yaml["sections"]["living_conditions"].values.map { |s| s["ledi"] }).to match_array(living)
    institution = yaml["sections"]["living_conditions"]["instituicao_permanencia"]["fields"]
    expect(institution.values.map { |s| s["ledi"] })
      .to match_array(idl_fields("cadastro_domiciliar.thrift", "InstituicaoPermanenciaThrift"))
  end

  it "todo campo usa um tipo declarado" do
    specs = yaml["sections"].values.flat_map(&:values)
    specs += specs.filter_map { |s| s["fields"]&.values }.flatten
    expect(specs.map { |s| s["type"] }.uniq - yaml["types"]).to be_empty
  end

  it "todo domínio citado existe, com códigos inteiros, e os valores da prova estão lá" do
    cited = yaml["sections"].values.flat_map(&:values).filter_map { |s| s["domain"] }.uniq
    expect(yaml["domains"].keys).to include(*cited)
    expect(yaml["domains"].values.flat_map(&:keys)).to all(be_a(Integer))
    expect(yaml["domains"]["raca_cor"]).to eq(1 => "Branca", 2 => "Preta", 3 => "Amarela", 4 => "Parda", 5 => "Indígena")
    expect(yaml["domains"]["sexo"].keys).to eq([ 0, 1, 4, 5 ])
    expect(yaml["domains"]["motivo_saida"].keys).to eq([ 135, 136 ])
    expect(yaml["domains"]["justificativa_nao_possui_cpf"].keys.map(&:to_s)).to eq(TerritoryRegistry::Catalog::NO_CPF_REASONS)
    expect(yaml["domains"]["renda_familiar"].keys.map(&:to_s).sort).to eq(TerritoryRegistry::Catalog::INCOME_BANDS.sort)
    expect(yaml["domains"]["tipo_de_imovel"].keys.map(&:to_s)).to eq(TerritoryRegistry::Catalog::PROPERTY_TYPES)
    expect(yaml["domains"]["pais"][31]).to eq("BRASIL")
  end

  it "domínios de campo string do IDL (UF e tipo de logradouro do DNE) com códigos em texto" do
    expect(yaml["string_domains"]["uf"]).to include("17" => "PARANÁ")
    expect(yaml["string_domains"]["tipo_logradouro"]).to include("081" => "RUA", "008" => "AVENIDA")
    expect(yaml["string_domains"].values.flat_map(&:keys)).to all(be_a(String))
  end

  it "tradução de raça/cor e etnia do paciente (códigos do BPA) para a ficha" do
    catalog = TerritoryRegistry::Catalog
    expect(catalog::RACE_TO_LEDI.transform_values { |c| yaml["domains"]["raca_cor"][c] })
      .to eq("01" => "Branca", "02" => "Preta", "03" => "Parda", "04" => "Amarela", "05" => "Indígena")
    expect(yaml["domains"]["etnia"][catalog.ethnicity_to_ledi("0304")]).to eq("PURI")
    expect(yaml["domains"]["etnia"][catalog.ethnicity_to_ledi("0315")]).to eq("WARAO")
    expect(catalog.ethnicity_to_ledi("0001")).to eq(1)
    expect(catalog.ethnicity_to_ledi("0264")).to eq(264)
    expect(catalog.ethnicity_to_ledi("0300")).to be_nil
  end

  it "tabelas de CBO: ACS, agente de endemias, enfermeiro e médicos da ESF nas duas" do
    cbos = YAML.load_file(Rails.root.join("config/ledi/registration_cbos.yml"))
    %w[515105 515140 223505 223565 225142 225125 225130 225170].each do |code|
      expect(cbos["individual"]).to include(code)
      expect(cbos["household"]).to include(code)
    end
    expect(cbos.values.flatten).to all(match(/\A[0-9A-Z]{6}\z/))
  end

  it "registra os tipos de ficha 2 e 3 com as classes geradas" do
    expect(Ledi::FichaTypes.code("cadastro_individual")).to eq(2)
    expect(Ledi::FichaTypes.code("cadastro_domiciliar")).to eq(3)
    expect(Ledi::FichaTypes.klass("cadastro_individual")).to eq(Br::Gov::Saude::Esusab::Ras::Cadastroindividual::CadastroIndividualThrift)
    expect(Ledi::FichaTypes.klass("cadastro_domiciliar")).to eq(Br::Gov::Saude::Esusab::Ras::Cadastrodomiciliar::CadastroDomiciliarThrift)
  end

  it "a documentação baixada bate com o sha256 de SOURCE" do
    recorded = Ledi::Version.root.join("SOURCE").read.scan(%r{^\s+docs/(\S+\.html): (\h{64})$}).to_h
    expect(recorded.keys).to include("dicionario-fci.html", "dicionario-fcd.html", "cbo.html")
    recorded.each do |path, sha|
      expect(Digest::SHA256.file(Ledi::Version.root.join("docs", path)).hexdigest).to eq(sha), path
    end
  end
end
