require "rails_helper"

# Módulo 24a (ADR 0042; contrato §15.3, §15.4 e L17): cada regra condicional
# das fichas de cadastro vira uma linha de código; o validador devolve a
# PRIMEIRA recusa com o caminho (como o módulo 22). Um exemplo por regra.
RSpec.describe TerritoryRegistry::Rules do
  let(:on) { Date.new(2026, 10, 23) }
  let(:woman) do
    { sex: "female", birth_date: Date.new(1990, 1, 1), race_color: "03", ethnicity: nil, has_cpf: true, mother_name_present: true }
  end
  let(:base) do
    { identification: { "nacionalidade_cidadao" => 1, "codigo_ibge_municipio_nascimento" => "4106902", "telefone_celular" => "41999990000",
                        "desconhece_nome_pai" => true },
      sociodemographic: { "status_deseja_informar_orientacao_sexual" => false, "status_deseja_informar_identidade_genero" => false },
      health_conditions: {}, street_situation: { "status_situacao_rua" => false }, refused: false, is_responsible: true }
  end

  # Seções também como palavras-chave: check(identification: { … }).
  def check(over = {}, person: woman, on: Date.new(2026, 10, 23), **sections)
    described_class.individual(base.deep_merge(over).deep_merge(sections), person: person, on: on)
  end
  def path(over = {}, **kw) = check(over, **kw).details[:path]
  def refused_input(over = {})
    { identification: {}, sociodemographic: nil, health_conditions: nil, street_situation: nil, refused: true, is_responsible: true }.merge(over)
  end

  describe ".individual" do
    it("aceita o mínimo válido") { expect(check).to be_ok }

    it "recusa com invalid_registration e o caminho" do
      expect(check(identification: { "nacionalidade_cidadao" => nil }).to_h)
        .to include(reason: :invalid_registration, details: { path: "identification.nacionalidade_cidadao" })
    end

    describe "identificação" do
      it "nascimento: nunca depois do atendimento nem mais de 130 anos antes" do
        expect(path(person: woman.merge(birth_date: Date.new(2026, 10, 24)))).to eq("birth_date")
        expect(path(person: woman.merge(birth_date: Date.new(1896, 10, 22)))).to eq("birth_date")
        expect(path(person: woman.merge(birth_date: "1896-10-23"))).to be_nil
      end

      it "raça/cor obrigatória e do paciente (01..05), salvo recusa" do
        expect(path(person: woman.merge(race_color: nil))).to eq("patient_demographics.race_color")
        expect(path(person: woman.merge(race_color: "06"))).to eq("patient_demographics.race_color")
        expect(described_class.individual(refused_input, person: woman.merge(race_color: nil), on: on)).to be_ok
      end

      it "etnia (L17): com 05, só etnia com código LEDI; com outra raça/cor não é validada" do
        indigenous = woman.merge(race_color: "05")
        expect(check(person: indigenous.merge(ethnicity: "0304"))).to be_ok
        expect(check(person: indigenous.merge(ethnicity: "0500")).to_h)
          .to include(reason: :invalid_ethnicity, details: { path: "patient_demographics.ethnicity" })
        expect(check(person: indigenous.merge(ethnicity: nil)).reason).to eq(:invalid_ethnicity)
        expect(check(person: woman.merge(ethnicity: "0500"))).to be_ok
      end

      it "nacionalidade obrigatória sem recusa; com recusa a identificação fica opcional" do
        expect(path(identification: { "nacionalidade_cidadao" => nil })).to eq("identification.nacionalidade_cidadao")
        expect(described_class.individual(refused_input, person: woman.merge(mother_name_present: false), on: on)).to be_ok
      end

      it "nacionalidade 1 exige município de nascimento e celular; 3 exige país e data de entrada" do
        expect(path(identification: { "codigo_ibge_municipio_nascimento" => nil })).to eq("identification.codigo_ibge_municipio_nascimento")
        expect(path(identification: { "nacionalidade_cidadao" => 3, "codigo_ibge_municipio_nascimento" => nil })).to eq("identification.pais_nascimento")
      end

      it "município de nascimento só com nacionalidade 1" do
        expect(path(identification: { "nacionalidade_cidadao" => 3, "pais_nascimento" => 45, "dt_entrada_brasil" => "2015-01-01" }))
          .to eq("identification.codigo_ibge_municipio_nascimento")
      end

      it "país de nascimento: com 1 só 31 (a ficha preenche 31); com 2 proibido; com 3 obrigatório" do
        expect(check(identification: { "pais_nascimento" => 31 })).to be_ok
        expect(path(identification: { "pais_nascimento" => 45 })).to eq("identification.pais_nascimento")
        naturalized = { "nacionalidade_cidadao" => 2, "codigo_ibge_municipio_nascimento" => nil, "dt_naturalizacao" => "2010-05-05",
                        "portaria_naturalizacao" => "PORT 123/2010" }
        expect(check(identification: naturalized)).to be_ok
        expect(path(identification: naturalized.merge("pais_nascimento" => 45))).to eq("identification.pais_nascimento")
      end

      it "naturalização: data e portaria só e sempre com nacionalidade 2; data entre o nascimento e o atendimento" do
        naturalized = { "nacionalidade_cidadao" => 2, "codigo_ibge_municipio_nascimento" => nil, "dt_naturalizacao" => "2010-05-05",
                        "portaria_naturalizacao" => "PORT 123/2010" }
        expect(path(identification: naturalized.merge("dt_naturalizacao" => nil))).to eq("identification.dt_naturalizacao")
        expect(path(identification: naturalized.merge("portaria_naturalizacao" => nil))).to eq("identification.portaria_naturalizacao")
        expect(path(identification: naturalized.merge("dt_naturalizacao" => "2026-10-24"))).to eq("identification.dt_naturalizacao")
        expect(path(identification: naturalized.merge("dt_naturalizacao" => "1989-12-31"))).to eq("identification.dt_naturalizacao")
        expect(path(identification: { "dt_naturalizacao" => "2010-05-05" })).to eq("identification.dt_naturalizacao")
        expect(path(identification: { "portaria_naturalizacao" => "PORT 1" })).to eq("identification.portaria_naturalizacao")
      end

      it "entrada no Brasil só e sempre com nacionalidade 3; entre o nascimento e o atendimento" do
        foreign = { "nacionalidade_cidadao" => 3, "codigo_ibge_municipio_nascimento" => nil, "pais_nascimento" => 45, "dt_entrada_brasil" => "2015-01-01" }
        expect(check(identification: foreign)).to be_ok
        expect(path(identification: foreign.merge("dt_entrada_brasil" => nil))).to eq("identification.dt_entrada_brasil")
        expect(path(identification: foreign.merge("dt_entrada_brasil" => "2026-10-24"))).to eq("identification.dt_entrada_brasil")
        expect(path(identification: foreign.merge("dt_entrada_brasil" => "1989-12-31"))).to eq("identification.dt_entrada_brasil")
        expect(path(identification: { "dt_entrada_brasil" => "2015-01-01" })).to eq("identification.dt_entrada_brasil")
      end

      it "celular obrigatório para nacionalidade 1 ou 2, opcional para 3" do
        expect(path(identification: { "telefone_celular" => nil })).to eq("identification.telefone_celular")
        foreign = { "nacionalidade_cidadao" => 3, "codigo_ibge_municipio_nascimento" => nil, "pais_nascimento" => 45,
                    "dt_entrada_brasil" => "2015-01-01", "telefone_celular" => nil }
        expect(check(identification: foreign)).to be_ok
      end

      it "nome do pai: proibido com desconhece_nome_pai, obrigatório sem" do
        expect(path(identification: { "nome_pai_cidadao" => "José da Silva" })).to eq("identification.nome_pai_cidadao")
        expect(path(identification: { "desconhece_nome_pai" => false })).to eq("identification.nome_pai_cidadao")
        expect(check(identification: { "desconhece_nome_pai" => false, "nome_pai_cidadao" => "José da Silva" })).to be_ok
      end

      it "nome da mãe (no paciente): obrigatório salvo desconhece_nome_mae, proibido com ele" do
        expect(path(person: woman.merge(mother_name_present: false))).to eq("mother_name")
        expect(check({ identification: { "desconhece_nome_mae" => true } }, person: woman.merge(mother_name_present: false))).to be_ok
        expect(path(identification: { "desconhece_nome_mae" => true })).to eq("identification.desconhece_nome_mae")
      end

      it "e-mail no padrão endereco@dominio.extensao" do
        expect(path(identification: { "email_cidadao" => "maria@posto" })).to eq("identification.email_cidadao")
        expect(check(identification: { "email_cidadao" => "maria@posto.gov.br" })).to be_ok
      end
    end

    describe "recusa do cadastro" do
      it "recusa: proíbe condições, sociodemográficos e situação de rua" do
        refused = described_class.individual({ identification: base[:identification], sociodemographic: { "status_frequenta_escola" => true },
                                               health_conditions: {}, street_situation: nil, refused: true, is_responsible: true }, person: woman, on: on)
        expect(refused.details[:path]).to eq("sociodemographic")
        expect(described_class.individual(refused_input(health_conditions: { "status_eh_fumante" => true }), person: woman, on: on).details[:path])
          .to eq("health_conditions")
        expect(described_class.individual(refused_input(street_situation: { "status_situacao_rua" => false }), person: woman, on: on).details[:path])
          .to eq("street_situation")
      end
    end

    describe "sociodemográfico" do
      it "obrigatórios sem recusa: deseja informar orientação sexual e identidade de gênero" do
        expect(path(sociodemographic: { "status_deseja_informar_orientacao_sexual" => nil })).to eq("sociodemographic.status_deseja_informar_orientacao_sexual")
        expect(path(sociodemographic: { "status_deseja_informar_identidade_genero" => nil })).to eq("sociodemographic.status_deseja_informar_identidade_genero")
        expect(path(sociodemographic: nil)).to eq("sociodemographic.status_deseja_informar_orientacao_sexual")
      end

      it "orientação sexual: obrigatória com deseja informar, proibida sem" do
        expect(path(sociodemographic: { "status_deseja_informar_orientacao_sexual" => true })).to eq("sociodemographic.orientacao_sexual_cidadao")
        expect(path(sociodemographic: { "orientacao_sexual_cidadao" => 148 })).to eq("sociodemographic.orientacao_sexual_cidadao")
        expect(check(sociodemographic: { "status_deseja_informar_orientacao_sexual" => true, "orientacao_sexual_cidadao" => 148 })).to be_ok
      end

      it "identidade de gênero: obrigatória com deseja informar, proibida sem" do
        expect(path(sociodemographic: { "status_deseja_informar_identidade_genero" => true })).to eq("sociodemographic.identidade_genero_cidadao")
        expect(path(sociodemographic: { "identidade_genero_cidadao" => 201 })).to eq("sociodemographic.identidade_genero_cidadao")
      end

      # Revisão final (m6): só o formato (a tabela CBO é grande; o SIAPS valida).
      it "ocupação CBO 2002: seis dígitos ou letras maiúsculas" do
        %w[51510 5151055 5151-0 2231f8 ABCDE!].each do |code|
          expect(path(sociodemographic: { "ocupacao_codigo_cbo2002" => code })).to eq("sociodemographic.ocupacao_codigo_cbo2002")
        end
        expect(check(sociodemographic: { "ocupacao_codigo_cbo2002" => "515105" })).to be_ok
        expect(check(sociodemographic: { "ocupacao_codigo_cbo2002" => "2231F8" })).to be_ok
      end

      it "deficiências: lista obrigatória com o status true e proibida com false" do
        expect(path(sociodemographic: { "status_tem_alguma_deficiencia" => true })).to eq("sociodemographic.deficiencias_cidadao")
        expect(path(sociodemographic: { "status_tem_alguma_deficiencia" => false, "deficiencias_cidadao" => [ 12 ] })).to eq("sociodemographic.deficiencias_cidadao")
      end

      it "relação de parentesco só para quem não é o responsável" do
        expect(path(sociodemographic: { "relacao_parentesco_cidadao" => 138 })).to eq("sociodemographic.relacao_parentesco_cidadao")
        expect(check(sociodemographic: { "relacao_parentesco_cidadao" => 138 }, is_responsible: false)).to be_ok
      end

      it "responsável por criança só antes dos 10 anos" do
        expect(path(sociodemographic: { "responsavel_por_crianca" => [ 1 ] })).to eq("sociodemographic.responsavel_por_crianca")
        child = woman.merge(birth_date: Date.new(2016, 10, 24))
        expect(check({ sociodemographic: { "responsavel_por_crianca" => [ 1 ] } }, person: child)).to be_ok
        expect(path({ sociodemographic: { "responsavel_por_crianca" => [ 1 ] } }, person: woman.merge(birth_date: Date.new(2016, 10, 23))))
          .to eq("sociodemographic.responsavel_por_crianca")
      end

      it "povo ou comunidade tradicional proibido com status de membro false" do
        expect(path(sociodemographic: { "status_membro_povo_comunidade_tradicional" => false, "co_povo_comunidade_tradicional" => 157 }))
          .to eq("sociodemographic.co_povo_comunidade_tradicional")
      end

      it "insegurança alimentar: as duas perguntas juntas ou nenhuma" do
        expect(path(sociodemographic: { "comeu_alguns_alimentos_que_tinha_dinheiro_acabou" => true }))
          .to eq("sociodemographic.alimentos_acabaram_antes_ter_dinheiro_comprar_mais")
        expect(path(sociodemographic: { "alimentos_acabaram_antes_ter_dinheiro_comprar_mais" => false }))
          .to eq("sociodemographic.comeu_alguns_alimentos_que_tinha_dinheiro_acabou")
      end
    end

    describe "condições de saúde" do
      it "gestante: proibido para homem e fora de 9–60 anos" do
        expect(path({ health_conditions: { "status_eh_gestante" => true } }, person: woman.merge(sex: "male"))).to eq("health_conditions.status_eh_gestante")
        expect(check({ health_conditions: { "status_eh_gestante" => true } }, person: woman.merge(birth_date: Date.new(1960, 1, 1)))).to be_failure
        expect(check({ health_conditions: { "status_eh_gestante" => true } }, person: woman.merge(birth_date: Date.new(2018, 1, 1)))).to be_failure
        expect(check(health_conditions: { "status_eh_gestante" => true })).to be_ok
      end

      it "maternidade de referência proibida com gestante false" do
        expect(path(health_conditions: { "status_eh_gestante" => false, "maternidade_de_referencia" => "Maternidade X" }))
          .to eq("health_conditions.maternidade_de_referencia")
      end

      it "doença cardíaca: lista obrigatória com o status true e proibida com false" do
        expect(path(health_conditions: { "status_teve_doenca_cardiaca" => true })).to eq("health_conditions.doenca_cardiaca")
        expect(check(health_conditions: { "status_teve_doenca_cardiaca" => false, "doenca_cardiaca" => [ 24 ] })).to be_failure
      end

      it "doença respiratória: lista obrigatória com o status true e proibida com false" do
        expect(path(health_conditions: { "status_tem_doenca_respiratoria" => true })).to eq("health_conditions.doenca_respiratoria")
        expect(path(health_conditions: { "status_tem_doenca_respiratoria" => false, "doenca_respiratoria" => [ 30 ] })).to eq("health_conditions.doenca_respiratoria")
      end

      it "doença nos rins: lista obrigatória com o status true e proibida com false" do
        expect(path(health_conditions: { "status_tem_teve_doencas_rins" => true })).to eq("health_conditions.doenca_rins")
        expect(path(health_conditions: { "status_tem_teve_doencas_rins" => false, "doenca_rins" => [ 27 ] })).to eq("health_conditions.doenca_rins")
      end

      it "causa da internação proibida sem internação; plantas medicinais proibidas sem uso" do
        expect(path(health_conditions: { "status_teve_internado_em12_meses" => false, "descricao_causa_internacao_em12_meses" => "Pneumonia" }))
          .to eq("health_conditions.descricao_causa_internacao_em12_meses")
        expect(path(health_conditions: { "status_usa_planta_medicinais" => false, "descricao_plantas_medicinais_usadas" => "Boldo" }))
          .to eq("health_conditions.descricao_plantas_medicinais_usadas")
      end
    end

    describe "situação de rua" do
      let(:street) { { "status_situacao_rua" => true } }

      it "status obrigatório sem recusa" do
        expect(path(street_situation: nil)).to eq("street_situation.status_situacao_rua")
        expect(described_class.individual(base.merge(street_situation: nil), person: woman, on: on).details[:path])
          .to eq("street_situation.status_situacao_rua")
      end

      it "situação de rua: campos de rua proibidos com status_situacao_rua false" do
        expect(path(street_situation: { "status_situacao_rua" => false, "tempo_situacao_rua" => 1 })).to eq("street_situation.tempo_situacao_rua")
        expect(path(street_situation: { "status_situacao_rua" => false, "status_recebe_beneficio" => false })).to eq("street_situation.status_recebe_beneficio")
        expect(check(street_situation: street.merge("tempo_situacao_rua" => 17))).to be_ok
      end

      it "parente frequentado proibido sem visita frequente" do
        expect(path(street_situation: street.merge("status_visita_familiar_frequentemente" => false, "grau_parentesco_familiar_frequentado" => "Irmã")))
          .to eq("street_situation.grau_parentesco_familiar_frequentado")
      end

      it "higiene: lista obrigatória com acesso à higiene" do
        expect(path(street_situation: street.merge("status_tem_acesso_higiene_pessoal_situacao_rua" => true)))
          .to eq("street_situation.higiene_pessoal_situacao_rua")
      end

      it "outra instituição proibida sem acompanhamento" do
        expect(path(street_situation: street.merge("status_acompanhado_por_outra_instituicao" => false, "outra_instituicao_que_acompanha" => "CAPS")))
          .to eq("street_situation.outra_instituicao_que_acompanha")
      end
    end
  end

  describe ".household" do
    let(:home) { { property_type: "1", living_conditions: { "localizacao" => 83, "situacao_moradia_posse_terra" => 75 }, refused: false } }
    let(:shelter) { { property_type: "7", living_conditions: { "localizacao" => 83, "instituicao_permanencia" => { "nome_responsavel_tecnico" => "Ana Maria Souza" } }, refused: false } }

    def household(input, families: []) = described_class.household(input, families: families)
    def hpath(input, families: []) = household(input, families: families).details[:path]

    it "aceita domicílio, abrigo com instituição e comércio sem condições de moradia" do
      expect(household(home, families: [ { members_count: 2 } ])).to be_ok
      expect(household(shelter)).to be_ok
      expect(household({ property_type: "2", living_conditions: nil, refused: false })).to be_ok
      expect(household({ property_type: "1", living_conditions: nil, refused: true })).to be_ok
    end

    it "domicílio: famílias só em tipo 1; condição de moradia proibida em comércio; nu_moradores ≥ Σ membros" do
      expect(described_class.household({ property_type: "2", living_conditions: { "localizacao" => 83 }, refused: false }, families: []).details[:path])
        .to eq("living_conditions")
      expect(described_class.household({ property_type: "2", living_conditions: nil, refused: false }, families: [ { members_count: 2 } ]).details[:path])
        .to eq("families")
      expect(described_class.household({ property_type: "1", living_conditions: { "localizacao" => 83, "situacao_moradia_posse_terra" => 75, "nu_moradores" => 2 },
                                         refused: false }, families: [ { members_count: 3 } ]).details[:path]).to eq("living_conditions.nu_moradores")
    end

    it "recusa: invalid_household; tipo de imóvel do domínio" do
      expect(household(home.merge(property_type: "14")).to_h).to include(reason: :invalid_household, details: { path: "property_type" })
      expect(hpath(home.merge(property_type: nil))).to eq("property_type")
    end

    it "com recusa do termo: sem condições de moradia e sem famílias" do
      expect(hpath(home.merge(refused: true))).to eq("living_conditions")
      expect(hpath(home.merge(refused: true, living_conditions: nil), families: [ { members_count: 1 } ])).to eq("families")
    end

    it "condições de moradia proibidas em 2, 3, 4, 5, 6, 12, 13 e 99" do
      %w[2 3 4 5 6 12 13 99].each do |type|
        expect(hpath(home.merge(property_type: type))).to eq("living_conditions"), type
      end
    end

    it "famílias com o mesmo responsável são recusadas" do
      same = [ { members_count: 1, responsible_patient_id: "p1" }, { members_count: 1, responsible_patient_id: "p1" } ]
      expect(hpath(home, families: same)).to eq("families")
    end

    it "instituição de permanência: obrigatória em 07–11 (sem recusa), proibida nos demais" do
      %w[7 8 9 10 11].each do |type|
        expect(hpath(shelter.merge(property_type: type, living_conditions: { "localizacao" => 83 }))).to eq("living_conditions.instituicao_permanencia"), type
        expect(hpath(shelter.merge(property_type: type, living_conditions: nil))).to eq("living_conditions.instituicao_permanencia"), type
      end
      expect(hpath(home.deep_merge(living_conditions: { "instituicao_permanencia" => { "nome_responsavel_tecnico" => "Ana Maria Souza" } })))
        .to eq("living_conditions.instituicao_permanencia")
    end

    it "07–11: proibidos produção rural, material das paredes, cômodos, acesso, tipo de domicílio e situação de moradia" do
      {
        "area_producao_rural" => 101, "material_predominante_paredes_ext_domicilio" => 109, "nu_comodos" => 3,
        "tipo_acesso_domicilio" => 89, "tipo_domicilio" => 85, "situacao_moradia_posse_terra" => 75
      }.each do |field, value|
        input = shelter.deep_merge(living_conditions: { "localizacao" => 84, field => value })
        expect(hpath(input)).to eq("living_conditions.#{field}"), field
      end
    end

    it "13 (CASAI): as proibições do campo ficam cobertas pela condição de moradia inteira proibida" do
      expect(hpath({ property_type: "13", living_conditions: { "localizacao" => 84, "tipo_domicilio" => 85 }, refused: false })).to eq("living_conditions")
    end

    it "localização sempre obrigatória com condições de moradia; situação de moradia salvo 07–11" do
      expect(hpath(home.merge(living_conditions: { "situacao_moradia_posse_terra" => 75 }))).to eq("living_conditions.localizacao")
      expect(hpath(home.merge(living_conditions: { "localizacao" => 83 }))).to eq("living_conditions.situacao_moradia_posse_terra")
    end

    it "animais só em domicílio (tipo 1)" do
      expect(hpath(shelter.deep_merge(living_conditions: { "st_animais_no_domicilio" => false }))).to eq("living_conditions.st_animais_no_domicilio")
      expect(hpath(shelter.deep_merge(living_conditions: { "animais_no_domicilio" => [ 128 ] }))).to eq("living_conditions.animais_no_domicilio")
      expect(hpath(shelter.deep_merge(living_conditions: { "quantos_animais_no_domicilio" => 1 }))).to eq("living_conditions.quantos_animais_no_domicilio")
    end

    it "animais: lista e quantidade proibidas sem animais; quantidade ≥ itens da lista" do
      expect(hpath(home.deep_merge(living_conditions: { "st_animais_no_domicilio" => false, "animais_no_domicilio" => [ 128 ] })))
        .to eq("living_conditions.animais_no_domicilio")
      expect(hpath(home.deep_merge(living_conditions: { "st_animais_no_domicilio" => false, "quantos_animais_no_domicilio" => 1 })))
        .to eq("living_conditions.quantos_animais_no_domicilio")
      expect(hpath(home.deep_merge(living_conditions: { "st_animais_no_domicilio" => true, "animais_no_domicilio" => [ 128, 129 ], "quantos_animais_no_domicilio" => 1 })))
        .to eq("living_conditions.quantos_animais_no_domicilio")
      expect(household(home.deep_merge(living_conditions: { "st_animais_no_domicilio" => true, "animais_no_domicilio" => [ 128, 129 ], "quantos_animais_no_domicilio" => 3 })))
        .to be_ok
    end

    it "produção rural proibida em localização urbana ou periurbana" do
      [ 83, 205 ].each do |localizacao|
        expect(hpath(home.deep_merge(living_conditions: { "localizacao" => localizacao, "area_producao_rural" => 101 })))
          .to eq("living_conditions.area_producao_rural")
      end
      expect(household(home.deep_merge(living_conditions: { "localizacao" => 84, "area_producao_rural" => 101 }))).to be_ok
    end

    it "origem da energia proibida sem energia elétrica" do
      expect(hpath(home.deep_merge(living_conditions: { "st_disponibilidade_energia_eletrica" => false, "tipo_origem_energia_eletrica" => 230 })))
        .to eq("living_conditions.tipo_origem_energia_eletrica")
    end

    it "moradores: ≥ número de famílias e ≥ Σ membros (1 quando a família não informa)" do
      two = home.deep_merge(living_conditions: { "nu_moradores" => 2 })
      expect(hpath(two, families: [ { members_count: nil }, { members_count: nil }, { members_count: nil } ])).to eq("living_conditions.nu_moradores")
      expect(household(two, families: [ { members_count: nil }, { members_count: 1 } ])).to be_ok
    end

    it "telefone de contato com 10 ou 11 dígitos" do
      expect(hpath(home.merge(contact_phone: "419999"))).to eq("contact_phone")
      expect(household(home.merge(contact_phone: "4133334444"))).to be_ok
    end
  end

  describe ".family" do
    let(:family) { { members_count: 3, income_band: "3", living_since: "2020-03" } }

    it "aceita a família do contrato; tudo opcional menos o tipo de imóvel" do
      expect(described_class.family(family, property_type: "1")).to be_ok
      expect(described_class.family({ members_count: nil, income_band: nil, living_since: nil }, property_type: "1")).to be_ok
    end

    it "família só em domicílio (tipo 1)" do
      expect(described_class.family(family, property_type: "2").to_h).to include(reason: :invalid_family, details: { path: "property_type" })
    end

    it "membros de 1 a 999" do
      expect(described_class.family(family.merge(members_count: 0), property_type: "1").details[:path]).to eq("members_count")
      expect(described_class.family(family.merge(members_count: 1000), property_type: "1").details[:path]).to eq("members_count")
      expect(described_class.family(family.merge(members_count: "3"), property_type: "1").details[:path]).to eq("members_count")
    end

    it "renda do domínio renda_familiar" do
      expect(described_class.family(family.merge(income_band: "9"), property_type: "1").details[:path]).to eq("income_band")
      expect(described_class.family(family.merge(income_band: 3), property_type: "1").details[:path]).to eq("income_band")
    end

    it "reside desde: AAAA-MM, nunca no futuro" do
      expect(described_class.family(family.merge(living_since: "2020-13"), property_type: "1").details[:path]).to eq("living_since")
      expect(described_class.family(family.merge(living_since: "2026-11"), property_type: "1", on: Date.new(2026, 10, 23)).details[:path]).to eq("living_since")
      expect(described_class.family(family.merge(living_since: "2026-10"), property_type: "1", on: Date.new(2026, 10, 23))).to be_ok
    end
  end
end
