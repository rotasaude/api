require "rails_helper"

# Prova técnica do módulo 24b (ADR 0052; Task 1): os dicionários da ficha de
# visita domiciliar (FVD, tipo 8) e da atividade coletiva (FAC, tipo 6) em
# config/ledi/visit_activity_dictionaries.yml batem com a documentação
# oficial vendorizada (vendor/ledi/8.7.0/docs: dicionario-fvd.html,
# dicionario-fac.html e as tabelas de código de dicionario.html), com o IDL e
# com o gen-rb; as Tabelas 5 e 7 do cbo.html são as de quem registra.
RSpec.describe "Dicionários da FVD e da FAC (LEDI 8.7.0)", type: :model do
  let(:yaml) { YAML.load_file(Rails.root.join("config/ledi/visit_activity_dictionaries.yml")) }
  let(:fvd) { Ledi::Version.root.join("docs/dicionario-fvd.html").read }
  let(:fac) { Ledi::Version.root.join("docs/dicionario-fac.html").read }
  let(:dictionary) { Ledi::Version.root.join("docs/dicionario.html").read }

  def cbo_table(caption)
    html = Ledi::Version.root.join("docs/cbo.html").read
    finish = html.index(caption)
    html[html.rindex("<table", finish)...finish].scan(%r{<tr>\s*<td>\s*([0-9A-Z]{6})\s*</td>}).flatten
  end

  def text(fragment) = CGI.unescapeHTML(fragment.to_s.gsub(/<[^>]+>/, "")).gsub(/\s+/, " ").strip

  # Tabela de código pelo id do título: [[código, rótulo, observação], …], na ordem do HTML.
  def code_table(html, id)
    start = html.index(%(id="#{id}")) or raise "tabela #{id} ausente"
    html[start...html.index("</table>", start)]
      .scan(%r{<tr>\s*<td>(.*?)</td>\s*<td>(.*?)</td>(?:\s*<td>(.*?)</td>)?\s*</tr>}m)
      .map { |code, label, note| [ text(code), text(label), text(note) ] }
  end

  def domain(id) = code_table(dictionary, id).to_h { |code, label, _| [ Integer(code, 10), label ] }

  # Seção de um campo da ficha (do título #n até o próximo título).
  def field_section(html, ledi)
    start = html.index(/<h[23] id="\d+-#{ledi.downcase}"/) or raise "campo #{ledi} ausente"
    html[start...(html.index(/<h[23] /, start + 1) || html.size)]
  end

  # Faixa ("Valor mínimo … e máximo …" / "só aceita valores entre … e …") e casas
  # ("Máximo de N casa(s) decimal(is)"; sem a frase, inteiro) do texto do campo.
  def expect_range(section, key, m)
    range = section[/(?:mínimo|entre)\s+(\d+(?:\.\d+)?)\s+e\s+(?:máximo\s+)?(\d+(?:\.\d+)?)/, 0] or raise "faixa de #{key}"
    expect(range.scan(/\d+(?:\.\d+)?/).map(&:to_f)).to eq([ m.fetch("min").to_f, m.fetch("max").to_f ]), key
    expect(m.fetch("decimals")).to eq(section[/Máximo de (\d+) casas? decima/, 1].to_i), key
  end

  def codes_in(fragment) = fragment.scan(%r{<code>\s*0*(\d+)\b}).flatten.map(&:to_i)

  it "o HTML vendorizado é o dicionário oficial da FVD e da FAC na versão 8.7.0" do
    expect(fvd).to include("<title>Modelo de Informação de Visita Domiciliar e Territorial")
    expect(fac).to include("<title>Modelo de Informação de Atividade Coletiva")
    [ fvd, fac ].each { |html| expect(html).to include("Layout e-SUS APS de Dados e Interface Versão 8.7.0") }
    expect(yaml.fetch("version")).to eq("8.7.0")
    expect(yaml.fetch("source")).to eq(
      "fvd" => Digest::SHA256.file(Ledi::Version.root.join("docs/dicionario-fvd.html")).hexdigest,
      "fac" => Digest::SHA256.file(Ledi::Version.root.join("docs/dicionario-fac.html")).hexdigest
    )
  end

  it "registration_cbos: home_visit é a Tabela 7 e collective_activity é a Tabela 5, inteiras" do
    cbos = YAML.load_file(Rails.root.join("config/ledi/registration_cbos.yml"))
    expect(cbos.fetch("home_visit")).to eq(cbo_table("Tabela 7 -"))
    expect(cbos.fetch("home_visit")).to eq(%w[515105 515310 515140 515130 515125 322255 515120])
    expect(cbos.fetch("collective_activity")).to eq(cbo_table("Tabela 5 -"))
    expect(cbos.fetch("collective_activity").size).to eq(117)
    expect(cbos.fetch("collective_activity")).to include("2231F9", "1312C1", "352210")
    expect(cbos.fetch("collective_activity")).to all(be_a(String))
  end

  it "tipos de ficha 8 e 6 batem com TipoDadoSerializado e com as classes do gen-rb" do
    serialized = domain("tipodadoserializado")
    expect(serialized[8]).to eq("Modelo de Informação de Visita Domiciliar e Territorial")
    expect(serialized[6]).to eq("Modelo de Informação de Atividade Coletiva")
    expect(Ledi::FichaTypes.code("visita_domiciliar")).to eq(8)
    expect(Ledi::FichaTypes.code("atividade_coletiva")).to eq(6)
    expect(Ledi::FichaTypes.uuid_field("visita_domiciliar")).to eq(:uuidFicha)
    expect(Ledi::FichaTypes.uuid_field("atividade_coletiva")).to eq(:uuidFicha)
    expect(Ledi::FichaTypes.klass("visita_domiciliar")).to eq(Br::Gov::Saude::Esusab::Ras::Visitadomiciliar::FichaVisitaDomiciliarMasterThrift)
    expect(Ledi::FichaTypes.klass("atividade_coletiva")).to eq(Br::Gov::Saude::Esusab::Ras::Atividadecoletiva::FichaAtividadeColetivaThrift)
    expect(Ledi::FichaTypes.type_for_code(8)).to eq("visita_domiciliar")
    expect(Ledi::FichaTypes.type_for_code(6)).to eq("atividade_coletiva")
  end

  it "cada medida aponta um campo real de FichaVisitaDomiciliarChildThrift, com a faixa e as casas do dicionário" do
    Ledi::Version.load!
    fields = Br::Gov::Saude::Esusab::Ras::Visitadomiciliar::FichaVisitaDomiciliarChildThrift::FIELDS.values.map { |f| f[:name] }
    measurements = yaml.dig("home_visit", "measurements")
    expect(measurements.keys).to eq(%w[weight_kg height_cm systolic diastolic temperature_c glucose_mg_dl glucose_type])
    measurements.each do |key, m|
      expect(fields).to include(m.fetch("ledi"))
      section = text(field_section(fvd, m.fetch("ledi")))
      expect_range(section, key, m) if m.key?("min")
      expect(section).to include("obrigatório o preenchimento do campo") if m.key?("requires")
    end
    expect(measurements.dig("glucose_type", "domain")).to eq("tipo_glicemia")
    expect(measurements.select { |_, m| m["requires"] }.transform_values { _1["requires"] })
      .to eq("systolic" => "diastolic", "diastolic" => "systolic", "glucose_mg_dl" => "glucose_type", "glucose_type" => "glucose_mg_dl")
  end

  it "medidas do participante da atividade: peso e altura do ParticipanteRowItemThrift, com a faixa e as casas do dicionario-fac.html" do
    Ledi::Version.load!
    fields = Br::Gov::Saude::Esusab::Ras::Atividadecoletiva::ParticipanteRowItemThrift::FIELDS.values.map { |f| f[:name] }
    measurements = yaml.dig("collective_activity", "rules", "participant_measurements")
    expect(measurements.keys).to eq(%w[weight_kg height_cm])
    expect(measurements.transform_values { _1.fetch("ledi") }).to eq("weight_kg" => "peso", "height_cm" => "altura")
    measurements.each do |key, m|
      expect(fields).to include(m.fetch("ledi"))
      expect_range(text(field_section(fac, m.fetch("ledi"))), key, m)
    end
  end

  it "os domínios da visita e da atividade são os do dicionário vendorizado (fvd, fac e dicionario.html)" do
    {
      %w[home_visit desfecho] => [ fvd, "desfecho" ],
      %w[home_visit turno] => [ fvd, "turno" ],
      %w[home_visit tipo_glicemia] => [ fvd, "tipoglicemiacapilar" ],
      %w[collective_activity tipo_atividade_coletiva] => [ fac, "tipoatividadecoletiva" ],
      %w[collective_activity temas_para_reuniao] => [ fac, "temasparareuniao" ],
      %w[collective_activity temas_para_saude] => [ fac, "temasparasaude" ],
      %w[collective_activity praticas_em_saude] => [ fac, "praticasemsaude" ],
      %w[collective_activity publico_alvo] => [ fac, "publicoalvo" ]
    }.each do |(ficha, name), (sheet, id)|
      expect(sheet).to include("referencias/dicionario.html##{id}"), "#{ficha} não cita #{id}"
      official = domain(id)
      official = official.except(18) if name == "temas_para_saude"
      expect(yaml.dig(ficha, "domains", name).to_a).to eq(official.to_a), "#{ficha}.#{name}"
    end

    expect(fvd).to include("referencias/dicionario.html#motivovisita")
    group = nil
    official = code_table(dictionary, "motivovisita").to_h do |code, label, note|
      group = note.delete_prefix("#") if note.start_with?("#")
      [ Integer(code, 10), { "label" => label, "group" => group } ]
    end
    expect(yaml.dig("home_visit", "domains", "motivo_visita").to_a).to eq(official.to_a)
    expect(yaml.dig("home_visit", "domains", "motivo_visita_groups").keys).to eq(official.values.map { _1["group"] }.uniq)
    expect(yaml.dig("home_visit", "domains", "motivo_visita_groups").values).to all(include("group_label" => be_present))

    # tipo de imóvel e justificativa sem CPF: os domínios do 24a, citados pelas duas fichas.
    expect(fvd).to include("referencias/dicionario.html#tipodeimovel", "referencias/dicionario.html#justificativanaopossuicpf")
    expect(yaml.dig("home_visit", "domains").slice("tipo_de_imovel", "justificativa_nao_possui_cpf"))
      .to eq("tipo_de_imovel" => "territory", "justificativa_nao_possui_cpf" => "territory")
    territory = YAML.load_file(Rails.root.join("config/ledi/registration_dictionaries.yml")).fetch("domains")
    expect(territory.fetch("tipo_de_imovel").to_a).to eq(domain("tipodeimovel").to_a)

    procedures = code_table(fac, "outroprocedimentocoletivo").to_h { |code, label, _| [ code.delete("^0-9"), label ] }
    expect(procedures.size).to eq(58)
    expect(procedures.keys).to all(match(/\A\d{10}\z/))
    expect(yaml.dig("collective_activity", "domains", "outro_procedimento_coletivo")).to eq(procedures)
  end

  it "regras da visita: as listas do dicionario-fvd.html" do
    rules = yaml.dig("home_visit", "rules")
    motives = field_section(fvd, "motivosVisita")
    nested = motives[motives.index("só podem ser")...motives.index("</ul>", motives.index("só podem ser"))]
    expect(rules.fetch("non_residential_reasons")).to eq(codes_in(nested))
    expect(rules.fetch("non_residential_reasons")).to eq([ 1, 34, 35, 36, 37, 27, 31, 28 ])
    expect(rules.fetch("male_forbidden_reasons")).to eq([ 5, 6 ])
    expect(text(motives)).to include("5 (Gestante) e 6 (Puérpera) não podem ser informadas se o Sexo = 0 (masculino)")
    expect(rules.fetch("non_residential_property_types")).to eq(codes_in(field_section(fvd, "numProntuario")).map(&:to_s))
    expect(rules.fetch("non_residential_property_types")).to eq(TerritoryRegistry::Catalog::PROPERTY_TYPES - %w[1 7 8 9 10 11 99])
    expect(rules.fetch("outcomes_without_reasons_and_measurements")).to eq([ 2, 3 ])
    expect(rules.fetch("reasons_max")).to eq(36)
    expect(rules.fetch("visits_per_sheet")).to eq(99)
    expect(rules.fetch("cns_required_with_no_cpf")).to be(false)
    expect(text(field_section(fvd, "cnsCidadao"))).not_to include("stCidadaoNaoPossuiCpf")
    expect(rules.fetch("birth_and_sex_required")).to eq("with_person")
    # Residencial sem pessoa: nascimento e sexo seriam obrigatórios com qualquer motivo de
    # BUSCA_ATIVA/ACOMPANHAMENTO, com 25 ou 31, ou com peso/altura (dtNascimento e sexo).
    motivo = yaml.dig("home_visit", "domains", "motivo_visita")
    triggers = motivo.select { |_, m| %w[BUSCA_ATIVA ACOMPANHAMENTO].include?(m["group"]) }.keys + [ 25, 31 ]
    expect(rules.fetch("without_person_allowed_reasons")).to match_array(motivo.keys - triggers)
    expect(rules.fetch("without_person_forbidden_measurements")).to eq(%w[weight_kg height_cm])
    %w[dtNascimento sexo].each do |ledi|
      expect(text(field_section(fvd, ledi))).to include("25 Egresso de internação ou 31 Orientação / Prevenção")
    end
    # A-19 (pendente): documento do responsável familiar na visita periódica e no controle vetorial.
    expect(rules.fetch("responsible_document_reasons"))
      .to eq([ 29 ] + motivo.select { |_, m| m["group"] == "CONTROLE_AMBIENTAL_E_VETORIAL" }.keys)
    { "cnsCidadao" => "CNS", "cpfCidadao" => "CPF" }.each do |ledi, doc|
      expect(text(field_section(fvd, ledi)))
        .to include("Para visita periódica ou visita domiciliar para controle vetorial preencher este campo com o #{doc} do responsável familiar")
    end
  end

  it "regras da atividade: por tipo (1..7) → campo, e as listas do dicionario-fac.html" do
    rules = yaml.dig("collective_activity", "rules")
    fields = %w[meeting_topics target_audience health_topics health_practices participants]
    by_type = rules.fetch("by_activity_type")
    expect(by_type.keys).to eq((1..7).to_a)
    by_type.each_value do |row|
      expect(row.keys).to eq(fields)
      expect(row.values).to all(be_in(%w[required forbidden optional]))
    end
    column = ->(field) { by_type.transform_values { _1.fetch(field) }.group_by(&:last).transform_values { _1.map(&:first) } }
    expect(column.("meeting_topics")).to eq("required" => [ 1, 2, 3 ], "forbidden" => [ 4, 5, 6, 7 ])
    expect(column.("target_audience")).to eq("forbidden" => [ 1, 2, 3 ], "required" => [ 4, 5, 6, 7 ])
    expect(column.("health_topics")).to eq("forbidden" => [ 1, 2, 3 ], "required" => [ 4, 5, 7 ], "optional" => [ 6 ])
    expect(column.("health_practices")).to eq("forbidden" => [ 1, 2, 3, 4, 7 ], "optional" => [ 5 ], "required" => [ 6 ])
    expect(column.("participants")).to eq("optional" => [ 1, 2, 3, 4, 7 ], "required" => [ 5, 6 ])
    expect(rules.fetch("health_topics_meeting_exception")).to eq(6)
    expect(yaml.dig("collective_activity", "domains", "temas_para_reuniao", 6)).to eq("Educação permanente")
    expect(text(field_section(fac, "temasParaSaude"))).to include("1, 2 ou 3 e temasParaReuniao diferente de Educação permanente")

    expect(rules.fetch("type6_only_practices")).to eq([ 2, 9, 33 ])
    expect(rules.fetch("procedure_practice")).to eq(30)
    expect(rules.fetch("smoking_practices")).to eq(codes_in(field_section(fac, "cessouHabitoFumar")))
    expect(rules.fetch("smoking_practices")).to eq(codes_in(field_section(fac, "abandonouGrupo")))
    expect(rules.fetch("smoking_practices")).to eq([ 25, 26, 27, 28 ])
    expect(rules.fetch("others_target_audience")).to eq(18)
    expect(yaml.dig("collective_activity", "domains", "publico_alvo", 18)).to eq("Outros")
    expect(rules.fetch("participant_identifier_types")).to eq([ 5, 6 ])
    expect(rules.fetch("list_max")).to eq("meeting_topics" => 7, "target_audience" => 17, "health_topics" => 16, "health_practices" => 14)
  end

  it "o tema 18 (Semana saúde na escola) fica fora e o PSE nunca é opção" do
    expect(yaml.dig("collective_activity", "domains", "temas_para_saude").keys.map(&:to_i)).not_to include(18)
    expect(yaml.dig("collective_activity", "rules", "forbidden_health_topics")).to eq([ 18 ])
    expect(text(field_section(fac, "temasParaSaude"))).to include("18 - Semana saúde na escola, torna-se obrigatório o preenchimento de pseEducacao ou pseSaude")
  end
end
