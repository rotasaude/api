require "rails_helper"

# Módulo 24a (ADR 0042; contrato §15): os dicionários das fichas de cadastro
# (config/ledi/registration_dictionaries.yml, Task 0) validam o corpo — só as
# chaves da seção, tipo, domínio e limites — e recusam com o caminho do campo,
# nunca com o valor.
RSpec.describe TerritoryRegistry::Dictionary do
  def parse(section, raw, prefix: section) = described_class.parse(section, raw, prefix: prefix)
  def path(...) = parse(...).details[:path]

  describe "leitura do YAML" do
    it "section expõe tipo, domínio, limites e required como chaves reais" do
      expect(described_class.section("identification")["nacionalidade_cidadao"])
        .to include("type" => "code", "domain" => "nacionalidade", "required" => true)
      expect(described_class.section("identification")["portaria_naturalizacao"]).to include("max" => 16)
      expect(described_class.section("identification")["email_cidadao"]).to include("min" => 6, "max" => 100)
      expect(described_class.section("health_conditions")["doenca_cardiaca"]).to include("max_items" => 3)
      expect(described_class.section("living_conditions")["instituicao_permanencia"]["fields"])
        .to include("nome_responsavel_tecnico" => include("type" => "name", "required" => true))
      expect { described_class.section("nope") }.to raise_error(KeyError)
    end

    it "domain devolve códigos inteiros; string_domain, códigos texto com zeros à esquerda" do
      expect(described_class.domain("nacionalidade")).to eq(1 => "Brasileira", 2 => "Naturalizado", 3 => "Estrangeiro")
      expect(described_class.string_domain("uf")["17"]).to eq("PARANÁ")
      expect(described_class.string_domain("tipo_logradouro")["081"]).to eq("RUA")
      expect(described_class.string_domain("tipo_logradouro")).not_to have_key(81)
    end
  end

  describe ".parse" do
    it "devolve values com as chaves do YAML, sem as vazias" do
      result = parse("identification", { "nacionalidade_cidadao" => 1, "telefone_celular" => "41999990000",
                                         "email_cidadao" => nil, "desconhece_nome_pai" => true })
      expect(result).to be_ok
      expect(result.payload[:values]).to eq("nacionalidade_cidadao" => 1, "telefone_celular" => "41999990000", "desconhece_nome_pai" => true)
      expect(parse("identification", nil).payload[:values]).to be_nil
    end

    it "chave desconhecida → invalid_registration (seções do indivíduo) / invalid_household (moradia) com o caminho" do
      expect(parse("sociodemographic", { "cpf" => "1" }).to_h).to include(reason: :invalid_registration, details: { path: "sociodemographic.cpf" })
      expect(parse("living_conditions", { "piscina" => true }).to_h).to include(reason: :invalid_household, details: { path: "living_conditions.piscina" })
      expect(path("identification", "x")).to eq("identification")
    end

    it "bool só true/false" do
      expect(path("health_conditions", { "status_eh_fumante" => "true" })).to eq("health_conditions.status_eh_fumante")
      expect(parse("health_conditions", { "status_eh_fumante" => false }).payload[:values]).to eq("status_eh_fumante" => false)
    end

    it "code: inteiro do domínio" do
      expect(path("identification", { "nacionalidade_cidadao" => 4 })).to eq("identification.nacionalidade_cidadao")
      expect(path("identification", { "nacionalidade_cidadao" => "1" })).to eq("identification.nacionalidade_cidadao")
      expect(path("living_conditions", { "localizacao" => 1 })).to eq("living_conditions.localizacao")
    end

    it "codes: lista do domínio, sem repetição, até max_items" do
      expect(parse("health_conditions", { "doenca_cardiaca" => [ 24, 25 ] }).payload[:values]).to eq("doenca_cardiaca" => [ 24, 25 ])
      expect(path("health_conditions", { "doenca_cardiaca" => [ 24, 24 ] })).to eq("health_conditions.doenca_cardiaca")
      expect(path("health_conditions", { "doenca_cardiaca" => [ 30 ] })).to eq("health_conditions.doenca_cardiaca")
      expect(path("health_conditions", { "doenca_cardiaca" => 24 })).to eq("health_conditions.doenca_cardiaca")
      expect(path("sociodemographic", { "deficiencias_cidadao" => [ 12, 13, 14, 15, 232, 16, 12 ] })).to eq("sociodemographic.deficiencias_cidadao")
      expect(parse("health_conditions", { "doenca_cardiaca" => [] }).payload[:values]).to eq({})
    end

    it "text: até max (padrão 100) — mais longo é too_long; abaixo de min é recusado" do
      long = parse("health_conditions", { "descricao_outra_condicao1" => "x" * 101 })
      expect(long.to_h).to include(reason: :too_long, details: { path: "health_conditions.descricao_outra_condicao1" })
      expect(parse("health_conditions", { "descricao_outra_condicao1" => "x" * 100 })).to be_ok
      expect(parse("identification", { "portaria_naturalizacao" => "x" * 17 }).reason).to eq(:too_long)
      expect(path("identification", { "email_cidadao" => "a@b.c" })).to eq("identification.email_cidadao")
      expect(path("identification", { "dnv" => 12_345_678_901 })).to eq("identification.dnv")
    end

    it "name: regra Validar nome, até max" do
      expect(parse("identification", { "nome_pai_cidadao" => "José da Silva" }).payload[:values]).to eq("nome_pai_cidadao" => "José da Silva")
      expect(path("identification", { "nome_pai_cidadao" => "José" })).to eq("identification.nome_pai_cidadao")
      expect(parse("identification", { "nome_pai_cidadao" => "José #{'a' * 70}" }).reason).to eq(:too_long)
    end

    it "digits: só dígitos, entre min e max" do
      expect(path("identification", { "telefone_celular" => "4199999000" })).to be_nil
      expect(path("identification", { "telefone_celular" => "419999900" })).to eq("identification.telefone_celular")
      expect(path("identification", { "telefone_celular" => "(41)999990000" })).to eq("identification.telefone_celular")
      expect(path("identification", { "codigo_ibge_municipio_nascimento" => 4_106_902 })).to eq("identification.codigo_ibge_municipio_nascimento")
    end

    it "date ISO e date_month AAAA-MM, devolvidos como texto canônico" do
      expect(parse("identification", { "dt_entrada_brasil" => "2020-02-29" }).payload[:values]).to eq("dt_entrada_brasil" => "2020-02-29")
      expect(path("identification", { "dt_entrada_brasil" => "2021-02-29" })).to eq("identification.dt_entrada_brasil")
      expect(path("identification", { "dt_entrada_brasil" => "29/02/2020" })).to eq("identification.dt_entrada_brasil")
      fields = { "living_since" => { "type" => "date_month" } }
      expect(described_class.parse(fields, { "living_since" => "2020-03" }, prefix: "family").payload[:values]).to eq("living_since" => "2020-03")
      expect(described_class.parse(fields, { "living_since" => "2020-13" }, prefix: "family").details[:path]).to eq("family.living_since")
    end

    it "count: inteiro maior que zero" do
      expect(parse("living_conditions", { "nu_moradores" => 2 }).payload[:values]).to eq("nu_moradores" => 2)
      expect(path("living_conditions", { "nu_comodos" => 0 })).to eq("living_conditions.nu_comodos")
      expect(path("living_conditions", { "nu_moradores" => "2" })).to eq("living_conditions.nu_moradores")
    end

    it "object: valida os campos de dentro com o caminho completo; required dentro do objeto vale sempre" do
      ok = parse("living_conditions", { "instituicao_permanencia" => { "nome_responsavel_tecnico" => "Ana Maria Souza", "st_outros_profissionais_vinculados" => true } })
      expect(ok.payload[:values]).to eq("instituicao_permanencia" => { "nome_responsavel_tecnico" => "Ana Maria Souza", "st_outros_profissionais_vinculados" => true })
      expect(path("living_conditions", { "instituicao_permanencia" => { "cargo_instituicao" => "Diretora" } }))
        .to eq("living_conditions.instituicao_permanencia.nome_responsavel_tecnico")
      expect(path("living_conditions", { "instituicao_permanencia" => { "nome_responsavel_tecnico" => "Ana Maria Souza", "cpf" => "1" } }))
        .to eq("living_conditions.instituicao_permanencia.cpf")
      expect(path("living_conditions", { "instituicao_permanencia" => { "nome_responsavel_tecnico" => "Ana Maria Souza", "telefone_responsavel_tecnico" => "123" } }))
        .to eq("living_conditions.instituicao_permanencia.telefone_responsavel_tecnico")
      expect(path("living_conditions", { "instituicao_permanencia" => "Abrigo" })).to eq("living_conditions.instituicao_permanencia")
    end

    it "aceita chaves símbolo (corpo JSON já convertido)" do
      expect(parse("living_conditions", { localizacao: 83 }).payload[:values]).to eq("localizacao" => 83)
    end
  end

  describe ".valid_name? (Validar nome, LEDI 8.7.0)" do
    it "aceita nomes com acento, cedilha e apóstrofo, em qualquer caixa" do
      [ "Maria da Paz", "JOÃO D'ÁVILA", "João D’Ávila", "Gonçalves Dias", "Ana Li", "Kauã Wyllian" ].each do |name|
        expect(described_class.valid_name?(name)).to be(true), name
      end
    end

    it "recusa cada regra oficial" do
      {
        "Jo" => "menos de três caracteres", "Joaquim" => "um termo só", "Maria  Paz" => "espaço duplicado",
        " Maria Paz" => "espaço nas pontas", "Maria Paz 2" => "dígito", "Ana-Maria Souza" => "hífen", "Maria P. Souza" => "ponto",
        "A A da Silva" => "dois primeiros termos de uma letra", "Li Wu" => "dois termos de duas letras",
        "Maria #{'a' * 70}" => "mais de 70", nil => "nulo", 123 => "não texto"
      }.each do |name, rule|
        expect(described_class.valid_name?(name)).to be(false), rule
      end
    end

    it "strict: o conjunto oficial da ficha — maiúsculas, sem cedilha, apóstrofo reto; as outras regras iguais" do
      expect(described_class.valid_name?("MARIA GONCALVES D'ÁVILA SOUZA", strict: true)).to be(true)
      { "GONÇALVES DIAS" => "cedilha", "Maria da Paz" => "minúscula", "JOÃO D’ÁVILA" => "apóstrofo tipográfico",
        "JOAQUIM" => "um termo só", "A A DA SILVA" => "dois primeiros termos de uma letra" }.each do |name, rule|
        expect(described_class.valid_name?(name, strict: true)).to be(false), rule
      end
    end
  end
end

RSpec.describe TerritoryRegistry::Address do
  let(:neighborhood) { Neighborhood.create!(name: "Jardim das Flores", source: "manual") }
  let(:raw) do
    { "zip" => "81000000", "street_type" => "081", "street" => "Rua das Acácias", "number" => "120", "no_number" => false,
      "complement" => "casa 2", "neighborhood_id" => neighborhood.id, "reference" => "perto da escola" }
  end

  def path(over) = described_class.parse(raw.merge(over)).details[:path]

  it "aceita o endereço do contrato e devolve as chaves do R3" do
    result = described_class.parse(raw.symbolize_keys)
    expect(result).to be_ok
    expect(result.payload[:values]).to eq(raw.merge("district" => nil))
  end

  it "limites do menor entre LEDI e BPA → invalid_household com o caminho, nunca cortado" do
    expect(described_class.parse(raw.merge("street" => "R" * 31)).to_h).to include(reason: :invalid_household, details: { path: "address.street" })
    expect(path("number" => "1234A6")).to eq("address.number")
    expect(path("number" => "12-A")).to eq("address.number")
    expect(path("complement" => "C" * 11)).to eq("address.complement")
    expect(path("reference" => "R" * 41)).to eq("address.reference")
    expect(path("zip" => "8100000")).to eq("address.zip")
    expect(path("street_type" => "999")).to eq("address.street_type")
    expect(path("street_type" => 81)).to eq("address.street_type")
    expect(path("street" => "")).to eq("address.street")
    expect(path("piscina" => true)).to eq("address.piscina")
    expect(described_class.parse("Rua X").details[:path]).to eq("address")
  end

  it "número vazio exige no_number true, e vice-versa" do
    expect(path("number" => "")).to eq("address.number")
    expect(path("number" => "120", "no_number" => true)).to eq("address.number")
    expect(path("no_number" => "sim")).to eq("address.no_number")
    expect(described_class.parse(raw.merge("number" => "", "no_number" => true)).payload[:values]).to include("number" => nil, "no_number" => true)
  end

  it "bairro do cadastro de bairros ativo e com nome que cabe no BPA; sem bairro, district obrigatório" do
    expect(path("neighborhood_id" => SecureRandom.uuid)).to eq("address.neighborhood_id")
    expect(path("neighborhood_id" => "abc")).to eq("address.neighborhood_id")
    neighborhood.update!(active: false)
    expect(path({})).to eq("address.neighborhood_id")
    long = Neighborhood.create!(name: "Bairro #{'L' * 30}", source: "manual")
    expect(path("neighborhood_id" => long.id)).to eq("address.neighborhood_id")
    expect(path("neighborhood_id" => nil)).to eq("address.district")
    expect(path("neighborhood_id" => nil, "district" => "D" * 31)).to eq("address.district")
    expect(described_class.parse(raw.merge("neighborhood_id" => nil, "district" => "Vila Nova"))).to be_ok
  end

  it "to_patient: chaves de endereço do paciente, bairro pelo nome, SN sem número" do
    values = described_class.parse(raw).payload[:values]
    expect(described_class.to_patient(values, neighborhood: neighborhood))
      .to eq("address_zip" => "81000000", "address_street" => "Rua das Acácias", "address_number" => "120",
             "address_complement" => "casa 2", "address_district" => "Jardim das Flores")
    no_number = described_class.parse(raw.merge("number" => "", "no_number" => true, "neighborhood_id" => nil, "district" => "Vila Nova")).payload[:values]
    expect(described_class.to_patient(no_number, neighborhood: nil)).to include("address_number" => "SN", "address_district" => "Vila Nova")
    expect(described_class.to_patient(values, neighborhood: neighborhood).keys).to all(be_in(Patient::DEMOGRAPHICS))
  end
end

RSpec.describe TerritoryRegistry::Identity do
  let(:patient) do
    Patient.new(full_name: "Joana Ribeiro Lima", social_name: nil, birth_date: Date.new(1990, 2, 3), sex: "female",
                mother_name: "Rita Ribeiro Lima", race_color: "03", ethnicity: nil, cpf: "52998224725", cns: nil, no_cpf_reason: nil)
  end

  it "snapshot: só a identidade do paciente, com nascimento ISO" do
    expect(described_class.snapshot(patient)).to eq(
      "full_name" => "Joana Ribeiro Lima", "social_name" => nil, "birth_date" => "1990-02-03", "sex" => "female",
      "mother_name" => "Rita Ribeiro Lima", "race_color" => "03", "ethnicity" => nil, "cpf" => "52998224725", "cns" => nil, "no_cpf_reason" => nil
    )
  end

  it "changed_fields: só os nomes dos campos que mudaram" do
    old = described_class.snapshot(patient)
    expect(described_class.changed_fields(old, old)).to eq([])
    expect(described_class.changed_fields(old, old.merge("full_name" => "Joana Lima", "sex" => "male"))).to eq(%w[full_name sex])
    expect(described_class.changed_fields(old, old.except("cns").merge("cns" => "700000000000005"))).to eq(%w[cns])
  end
end
