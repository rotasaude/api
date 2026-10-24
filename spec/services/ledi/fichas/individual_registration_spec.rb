require "rails_helper"

# Módulo 24a (ADR 0042; contrato §15): a ficha de Cadastro Individual montada
# de valores (pura). Raça/cor e etnia traduzidas do código do paciente (BPA)
# para o LEDI; CPF ou CNS, nunca os dois; recusa só com a identificação;
# nomes no conjunto do "Validar nome" (maiúsculas, sem cedilha).
RSpec.describe Ledi::Fichas::IndividualRegistration do
  let(:header) { Ledi::Fichas::RegistrationHeader.new(cnes: "1234567", ine: "0000000001", professional_cns: "700000000000005", cbo: "515105",
                                                       saved_at: Time.zone.parse("2026-10-23 10:00"), ibge_code: "4106902") }
  let(:values) do
    { "identity" => { "full_name" => "Maria das Graças Lima", "birth_date" => "1953-08-20", "sex" => "female", "race_color" => "03",
                      "mother_name" => "Benedita Lima", "cpf" => "52998224725", "cns" => nil, "no_cpf_reason" => nil },
      "identification" => { "nacionalidade_cidadao" => 1, "codigo_ibge_municipio_nascimento" => "4106902", "telefone_celular" => "41999990000",
                            "desconhece_nome_pai" => true },
      "health_conditions" => { "status_tem_hipertensao_arterial" => true }, "sociodemographic" => {},
      "street_situation" => { "status_situacao_rua" => false }, "refused" => false, "micro_area_code" => "01", "is_responsible" => true,
      "exit" => nil }
  end

  # Ruby 3: thrift("chave" => …) chega como palavras-chave (chave String é
  # aceita em **); o resto vira o Hash de sobrescrita.
  def ficha(over = {}, originating: nil, **rest) =
    described_class.new(header: header, values: values.deep_merge(over.merge(rest.transform_keys(&:to_s))), originating_uuid: originating, source_id: "v1")

  def thrift(over = {}, originating: nil, **rest) = ficha(over, originating: originating, **rest).to_thrift(uuid: "1234567-u1")

  it "cadastro novo: originadora = uuid; atualização: a originadora; tpCdsOrigem 3" do
    expect(thrift.uuidFichaOriginadora).to eq("1234567-u1")
    expect(thrift.fichaAtualizada).to be(false)
    expect(thrift(originating: "1234567-u0").uuidFichaOriginadora).to eq("1234567-u0")
    expect(thrift(originating: "1234567-u0").fichaAtualizada).to be(true)
    expect(thrift.tpCdsOrigem).to eq(3)
  end

  it "interface de ficha: tipo, competência no fuso da cidade, CNES, INE, fonte e cabeçalho UnicaLotacao" do
    expect(Ledi::Ficha.assert!(ficha)).to be_a(described_class)
    expect([ ficha.type, ficha.competence, ficha.cnes, ficha.ine, ficha.source ])
      .to eq([ "cadastro_individual", "202610", "1234567", "0000000001", { type: "IndividualRegistrationVersion", id: "v1" } ])
    h = thrift.headerTransport
    expect([ h.profissionalCNS, h.cboCodigo_2002, h.cnes, h.ine, h.dataAtendimento, h.codigoIbgeMunicipio ])
      .to eq([ "700000000000005", "515105", "1234567", "0000000001", Time.zone.parse("2026-10-23 10:00").to_i * 1000, "4106902" ])
  end

  it "raça/cor 03 do paciente (parda no BPA) sai 4 na ficha; 04 sai 3; sexo feminino sai 1" do
    expect(thrift.identificacaoUsuarioCidadao.racaCorCidadao).to eq(4)
    expect(thrift("identity" => { "race_color" => "04" }).identificacaoUsuarioCidadao.racaCorCidadao).to eq(3)
    expect(thrift.identificacaoUsuarioCidadao.sexoCidadao).to eq(1)
    expect(thrift("identity" => { "sex" => "male" }).identificacaoUsuarioCidadao.sexoCidadao).to eq(0)
  end

  it "etnia 0304 sai 406 (só com raça/cor 05); com outra raça/cor a etnia não vai" do
    expect(thrift("identity" => { "race_color" => "05", "ethnicity" => "0304" }).identificacaoUsuarioCidadao.etnia).to eq(406)
    expect(thrift("identity" => { "race_color" => "05", "ethnicity" => "0315" }).identificacaoUsuarioCidadao.etnia).to eq(407)
    expect(thrift("identity" => { "race_color" => "05", "ethnicity" => "0012" }).identificacaoUsuarioCidadao.etnia).to eq(12)
    expect(thrift("identity" => { "race_color" => "03", "ethnicity" => "0304" }).identificacaoUsuarioCidadao.etnia).to be_nil
  end

  it "CPF ou CNS, nunca os dois; sem CPF: stNaoPossuiCpf e justificativa" do
    id = thrift.identificacaoUsuarioCidadao
    expect([ id.cpfCidadao, id.cnsCidadao, id.stNaoPossuiCpf, id.justificativaNaoPossuiCpf ]).to eq([ "52998224725", nil, false, nil ])
    id = thrift("identity" => { "cns" => "700000000000005" }).identificacaoUsuarioCidadao
    expect([ id.cpfCidadao, id.cnsCidadao ]).to eq([ "52998224725", nil ])
    id = thrift("identity" => { "cpf" => nil, "cns" => "700000000000005", "no_cpf_reason" => "3" }).identificacaoUsuarioCidadao
    expect([ id.cpfCidadao, id.cnsCidadao, id.stNaoPossuiCpf, id.justificativaNaoPossuiCpf ]).to eq([ nil, "700000000000005", true, 3 ])
  end

  it "responsável: statusEhResponsavel; quem não é leva o CPF (ou, sem CPF, o CNS) do responsável, um só" do
    id = thrift.identificacaoUsuarioCidadao
    expect([ id.statusEhResponsavel, id.cpfResponsavelFamiliar, id.cnsResponsavelFamiliar ]).to eq([ true, nil, nil ])
    id = thrift("is_responsible" => false, "responsible" => { "cpf" => "11144477735", "cns" => "700000000000005" }).identificacaoUsuarioCidadao
    expect([ id.statusEhResponsavel, id.cpfResponsavelFamiliar, id.cnsResponsavelFamiliar ]).to eq([ false, "11144477735", nil ])
    id = thrift("is_responsible" => false, "responsible" => { "cpf" => nil, "cns" => "700000000000005" }).identificacaoUsuarioCidadao
    expect([ id.cpfResponsavelFamiliar, id.cnsResponsavelFamiliar ]).to eq([ nil, "700000000000005" ])
  end

  it "microárea do domicílio; sem domicílio vai fora de área e sem microArea" do
    id = thrift.identificacaoUsuarioCidadao
    expect([ id.microArea, id.stForaArea ]).to eq([ "01", false ])
    id = thrift("micro_area_code" => nil).identificacaoUsuarioCidadao
    expect([ id.microArea, id.stForaArea ]).to eq([ nil, true ])
  end

  it "seções do dicionário pelo nome do IDL; país 31 com nacionalidade 1; datas em epoch ms; socioeconômico separado" do
    t = thrift("identification" => { "estado_civil" => 2 },
               "sociodemographic" => { "status_deseja_informar_orientacao_sexual" => false, "status_deseja_informar_identidade_genero" => false,
                                       "deficiencias_cidadao" => [ 12 ], "status_tem_alguma_deficiencia" => true,
                                       "alimentos_acabaram_antes_ter_dinheiro_comprar_mais" => true,
                                       "comeu_alguns_alimentos_que_tinha_dinheiro_acabou" => false },
               "health_conditions" => { "status_teve_internado_em12_meses" => true, "status_usa_planta_medicinais" => false })
    expect([ t.identificacaoUsuarioCidadao.paisNascimento, t.identificacaoUsuarioCidadao.estadoCivil ]).to eq([ 31, 2 ])
    expect([ t.condicoesDeSaude.statusTemHipertensaoArterial, t.condicoesDeSaude.statusTeveInternadoEm12Meses,
             t.condicoesDeSaude.statusUsaPlantaMedicinais ]).to eq([ true, true, false ])
    expect([ t.informacoesSocioDemograficas.deficienciasCidadao, t.informacoesSocioDemograficas.statusTemAlgumaDeficiencia ]).to eq([ [ 12 ], true ])
    expect([ t.informacoesSocioEconomicas.alimentosAcabaramAntesTerDinheiroComprarMais,
             t.informacoesSocioEconomicas.comeuAlgunsAlimentosQueTinhaDinheiroAcabou ]).to eq([ true, false ])
    expect(t.emSituacaoDeRua.statusSituacaoRua).to be(false)
    naturalized = thrift("identification" => { "nacionalidade_cidadao" => 2, "codigo_ibge_municipio_nascimento" => nil,
                                               "dt_naturalizacao" => "2001-05-10", "portaria_naturalizacao" => "P123" }).identificacaoUsuarioCidadao
    expect([ naturalized.paisNascimento, naturalized.dtNaturalizacao ]).to eq([ nil, Time.zone.parse("2001-05-10").to_i * 1000 ])
    expect(thrift.informacoesSocioDemograficas).to be_nil
    expect(thrift.informacoesSocioEconomicas).to be_nil
  end

  it "recusa só leva a identificação; saída por óbito leva 135 e a data" do
    refused = thrift("refused" => true, "health_conditions" => nil, "sociodemographic" => nil, "street_situation" => nil)
    expect([ refused.statusTermoRecusaCadastroIndividualAtencaoBasica, refused.condicoesDeSaude, refused.informacoesSocioDemograficas ]).to eq([ true, nil, nil ])
    expect([ refused.emSituacaoDeRua, refused.saidaCidadaoCadastro, refused.identificacaoUsuarioCidadao.nomeCidadao ])
      .to eq([ nil, nil, "MARIA DAS GRACAS LIMA" ])
    expect(thrift.statusTermoRecusaCadastroIndividualAtencaoBasica).to be(false)
    death = thrift("exit" => { "reason" => "death", "on" => "2026-10-20" })
    expect(death.saidaCidadaoCadastro.motivoSaidaCidadao).to eq(135)
    expect(death.saidaCidadaoCadastro.dataObito).to eq(Time.zone.parse("2026-10-20").to_i * 1000)
  end

  it "óbito: dataObito do death_on e numeroDO do death_certificate; mudança: 136 sem data nem DO" do
    death = thrift("exit" => { "reason" => "death", "on" => "2026-10-21", "death_on" => "2026-10-19", "death_certificate" => "123456789" })
    expect([ death.saidaCidadaoCadastro.dataObito, death.saidaCidadaoCadastro.numeroDO ])
      .to eq([ Time.zone.parse("2026-10-19").to_i * 1000, "123456789" ])
    moved = thrift("exit" => { "reason" => "moved", "on" => "2026-10-21", "death_certificate" => "123456789" }).saidaCidadaoCadastro
    expect([ moved.motivoSaidaCidadao, moved.dataObito, moved.numeroDO ]).to eq([ 136, nil, nil ])
  end

  it "nomes em maiúsculas no conjunto oficial (Validar nome regras 4 e 5): cedilha vira C, hífen vira espaço, apóstrofo reto" do
    t = thrift("identity" => { "full_name" => "Maria Gonçalves D’Ávila-Souza", "social_name" => "Malu Gonçalves", "mother_name" => "Inês Müller" },
               "identification" => { "nome_pai_cidadao" => "João D‘Ávila", "desconhece_nome_pai" => false })
    id = t.identificacaoUsuarioCidadao
    expect([ id.nomeCidadao, id.nomeSocial, id.nomeMaeCidadao, id.nomePaiCidadao ])
      .to eq([ "MARIA GONCALVES D'ÁVILA SOUZA", "MALU GONCALVES", "INÊS MÜLLER", "JOÃO D'ÁVILA" ])
    [ id.nomeCidadao, id.nomeSocial, id.nomeMaeCidadao, id.nomePaiCidadao ].each do |name|
      expect(TerritoryRegistry::Dictionary.valid_name?(name, strict: true)).to be(true), name
    end
  end

  it "desconhece o nome da mãe: o nome não vai" do
    id = thrift("identification" => { "desconhece_nome_mae" => true }, "identity" => { "mother_name" => nil }).identificacaoUsuarioCidadao
    expect([ id.desconheceNomeMae, id.nomeMaeCidadao ]).to eq([ true, nil ])
  end

  it "campo a campo com o exemplo de referência (spec/fixtures/ledi/cadastro_individual_referencia.json)" do
    reference = JSON.parse(Rails.root.join("spec/fixtures/ledi/cadastro_individual_referencia.json").read)
    roundtrip = Ledi::Version.deserialize(Br::Gov::Saude::Esusab::Ras::Cadastroindividual::CadastroIndividualThrift,
                                          Ledi::Version.serialize(thrift))
    expect(to_h_for_spec(roundtrip.identificacaoUsuarioCidadao)).to eq(reference["identificacaoUsuarioCidadao"])
    built = ficha
    [ built.inspect, built.to_s, built.pretty_inspect, built.as_json.to_s ].each do |text|
      expect(text).not_to include("Maria", "MARIA", "52998224725", "Benedita")
    end
  end
end
