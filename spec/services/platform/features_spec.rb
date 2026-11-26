require "rails_helper"

# ADR 0028 (spec 2026-10-05 §3.1; contratos §2): ligado vem da plataforma; o que
# falta lê a plataforma (modo, PEC) e o banco da cidade (IBGE, credenciais). Com
# a cidade fora do ar, o liga/desliga continua e o resto degrada.
RSpec.describe Platform::Features do
  # A mesma linha de catálogo dos request specs: CityConnection.with(city) cai na
  # sessão de TEST_CITY_A da transação, onde as linhas abaixo são criadas.
  let!(:city) do
    City.find_by(slug: TEST_CITY_A.slug) ||
      City.create!(slug: TEST_CITY_A.slug, name: TEST_CITY_A.name, status: "active",
                   database_url: TEST_CITY_A.database_url, encryption_key: TEST_CITY_A.encryption_key,
                   schema_version: CitySchema.expected_version.to_s)
  end
  let(:admin) { staff_with("admin@cidade.gov.br", "municipal_admin") }
  let(:maintainer) do
    Maintainer.create!(email_address: "m-#{SecureRandom.hex(3)}@rotasaude.app", password: "s3nha-forte-1",
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end
  # Cidade ativa cuja conexão recusa. A recusa é simulada: discar uma porta morta
  # de verdade deixa o shard registrado e quebra o setup de fixtures do exemplo
  # seguinte (harness).
  let(:unreachable) do
    create(:city).tap do |dead|
      allow(CityConnection).to receive(:with).and_call_original
      allow(CityConnection).to receive(:with).with(dead).and_raise(PG::ConnectionBad, "recusada")
    end
  end

  after { CityCatalog.reset_cache! }

  def credential!(kind, status: nil)
    IntegrationCredential.create!(kind: kind, secret: { "username" => "u", "password" => "p" }, set_by_user: admin,
                                  set_at: Time.current, last_check_status: status)
  end

  it "ledi_export sem nada: falta tudo, na ordem do contrato" do
    expect(described_class.missing(city, "ledi_export"))
      .to eq(%w[record_mode_off pec_url_missing ibge_code_missing credential_missing:ledi])
  end

  it "ledi_export completo não falta nada; credencial recusada volta a faltar" do
    city.update!(record_mode: "integrated", pec_url: "https://pec.cidade.gov.br")
    CityProfile.create!(name: "Cidade", uf: "PR", ibge_code: "4106902")
    credential = credential!("ledi", status: "ok")
    expect(described_class.missing(city, "ledi_export")).to eq([])
    credential.update!(last_check_status: "unauthorized")
    expect(described_class.missing(city, "ledi_export")).to eq(%w[credential_unauthorized:ledi])
  end

  it "credencial cadastrada e nunca testada conta como presente" do
    credential!("cadsus")
    expect(described_class.missing(city, "cadsus_lookup")).to eq([])
  end

  it "utilizável exige ligado E nada faltando" do
    credential!("cadsus", status: "ok")
    expect(described_class.usable?(city, "cadsus_lookup")).to be(false)
    described_class.set!(city: city, key: "cadsus_lookup", enabled: true, maintainer: maintainer)
    expect(described_class.enabled?(city, "cadsus_lookup")).to be(true)
    expect(described_class.usable?(city, "cadsus_lookup")).to be(true)
    expect(described_class.enabled_keys(city)).to eq(%w[cadsus_lookup])
  end

  it "set! audita só quando muda, só com ids" do
    expect {
      described_class.set!(city: city, key: "ledi_export", enabled: true, maintainer: maintainer)
      described_class.set!(city: city, key: "ledi_export", enabled: true, maintainer: maintainer)
    }.to change { PlatformEvent.where(name: "city.feature_changed").count }.by(1)
    expect(PlatformEvent.where(name: "city.feature_changed").last.payload)
      .to eq("city_id" => city.id, "key" => "ledi_export", "enabled" => true, "maintainer_id" => maintainer.id)
    described_class.set!(city: city, key: "ledi_export", enabled: false, maintainer: maintainer)
    expect(described_class.enabled?(city, "ledi_export")).to be(false)
  end

  it "chave fora do catálogo levanta" do
    expect { described_class.set!(city: city, key: "no_such_feature", enabled: true, maintainer: maintainer) }
      .to raise_error(described_class::UnknownFeature)
    expect { described_class.enabled?(city, "no_such_feature") }.to raise_error(described_class::UnknownFeature)
  end

  it "cidade inalcançável: liga, e o resumo degrada sem levantar" do
    described_class.set!(city: unreachable, key: "cadsus_lookup", enabled: true, maintainer: maintainer)
    row = described_class.summary(unreachable).find { |f| f[:key] == "cadsus_lookup" }
    expect(row).to include(enabled: true, usable: false, missing: [ "city_unreachable" ],
                           changed_by: maintainer.email_address)
    expect(row[:changed_at]).to be_present
  end

  it "cidade não ativa não é discada" do
    archived = create(:city, status: "archived")
    expect(CityConnection).not_to receive(:with)
    expect(described_class.city_state(archived)).to be_nil
  end

  it "cidade com schema atrasado conta como inalcançável (R5)" do
    allow(IntegrationCredential).to receive(:in_use).and_raise(ActiveRecord::StatementInvalid, "PG::UndefinedTable")
    expect(described_class.city_state(city)).to be_nil
    expect(described_class.missing(city, "cadsus_lookup")).to eq([ "city_unreachable" ])
  end

  it "modo e PEC sem o cache do catálogo" do
    stale = City.find(city.id)
    City.where(id: city.id).update_all(record_mode: "record")
    expect(described_class.settings(stale)).to eq(record_mode: "record", pec_url: nil)
  end

  # Módulo 31 (ADR 0049; Valor fixado 1; contrato P19): o CAPS fecha o catálogo,
  # requer o prontuário utilizável e é a única chave escondida do cidadão.
  it "psychosocial_care requer o prontuário e fica fora da sessão do cidadão" do
    entry = described_class::CATALOG.find { |e| e.key == "psychosocial_care" }
    expect(entry.key).to eq("psychosocial_care")
    expect(entry.requires).to eq(%w[feature:clinical_record])
    expect(entry.description).to start_with("Atenção psicossocial (CAPS)")
    expect(described_class::CITIZEN_HIDDEN).to eq(%w[psychosocial_care collective_activities vector_control zoonoses bnafar bnafar_medications bnafar_vector_supplies bnafar_vaccines rnds_regulation])
    expect(described_class::CITIZEN_HIDDEN).to be_frozen
  end

  it "módulo 32a: urgency_care exige o prontuário; waiting_room_display é independente" do
    keys = Platform::Features::CATALOG.map(&:key)
    expect(keys.last(15).first(2)).to eq(%w[urgency_care waiting_room_display])
    expect(Platform::Features::CATALOG.find { |e| e.key == "urgency_care" }.requires).to eq(%w[feature:clinical_record])
    expect(Platform::Features::CATALOG.find { |e| e.key == "waiting_room_display" }.requires).to eq([])
    expect(Platform::Features::CITIZEN_HIDDEN).not_to include("urgency_care", "waiting_room_display")
  end

  it "módulo 32b: urgency_stock_deduction exige a urgência e a farmácia" do
    entry = Platform::Features::CATALOG[-13]
    expect(entry.key).to eq("urgency_stock_deduction")
    expect(entry.requires).to eq(%w[feature:urgency_care feature:pharmacy])
    expect(entry.description).to eq("Atendimentos da UPA com prescrição de medicação atualizam o estoque")
    expect(Platform::Features::CITIZEN_HIDDEN).not_to include("urgency_stock_deduction")
  end

  it "módulo 33: ombudsman fecha o catálogo; a denúncia anônima exige a ouvidoria; as duas vão ao cidadão" do
    keys = Platform::Features::CATALOG.map(&:key)
    expect(keys.last(12).first(2)).to eq(%w[ombudsman ombudsman_anonymous_web])
    expect(described_class.find("ombudsman").requires).to eq([])
    expect(described_class.find("ombudsman").description).to eq("Ouvidoria do SUS municipal")
    expect(described_class.find("ombudsman_anonymous_web").requires).to eq(%w[feature:ombudsman])
    expect(described_class::CITIZEN_HIDDEN).not_to include("ombudsman", "ombudsman_anonymous_web")
  end

  it "denúncia anônima ligada sem a ouvidoria fica inutilizável com ombudsman_disabled" do
    city = clinical_city!
    Platform::Features.set!(city: city, key: "ombudsman_anonymous_web", enabled: true, maintainer: ledi_maintainer!)
    expect(Platform::Features.missing(city, "ombudsman_anonymous_web")).to eq(%w[ombudsman_disabled])
    expect(Ombudsman::AnonymousGate.usable?(city)).to be(false)
  end

  it "módulo 24b: home_visits e collective_activities fecham o catálogo; só home_visits vai ao cidadão (Q24)" do
    keys = Platform::Features::CATALOG.map(&:key)
    expect(keys.last(10).first(2)).to eq(%w[home_visits collective_activities])
    expect(described_class.find("home_visits").requires).to eq(%w[feature:territory_registry])
    expect(described_class.find("collective_activities").requires).to eq(%w[feature:clinical_record])
    expect(described_class::CITIZEN_HIDDEN).not_to include("home_visits")
    expect(described_class::CITIZEN_HIDDEN).to include("collective_activities")
    expect(described_class.find("home_visits").description).to start_with("Folha do dia")
  end

  it "home_visits com o cadastro territorial sem IBGE fica inutilizável (territory_registry_disabled)" do
    city = registry_city!
    CityConnection.with(city) { CityProfile.current.update!(ibge_code: nil) }
    Platform::Features.set!(city: city, key: "home_visits", enabled: true, maintainer: ledi_maintainer!)
    expect(Platform::Features.missing(city, "home_visits")).to eq(%w[territory_registry_disabled])
    expect(HomeVisits::Gate.usable?(city)).to be(false)
    expect(TerritoryRegistry::Gate.usable?(city)).to be(true)
  end

  it "módulo 35a: vector_control vem antes do zoonoses, exige home_visits e não vai ao cidadão" do
    expect(Platform::Features::CATALOG[-8].key).to eq("vector_control")
    expect(described_class.find("vector_control").requires).to eq(%w[feature:home_visits])
    expect(described_class.find("vector_control").description)
      .to eq("Boletim do agente na visita, quarteirões, ciclos, ovitrampas, LIRAa e bloqueio de transmissão") # Q12
    expect(described_class::CITIZEN_HIDDEN).to include("vector_control")
  end

  # Módulo 35b (ADR 0054; contrato §1; Q27): o centro de zoonoses fecha o
  # catálogo, exige o cadastro territorial (sem cascata para o vector_control)
  # e não vai ao cidadão.
  it "módulo 35b: zoonoses fecha o catálogo do 35, exige feature:territory_registry, a descrição da Q27 e está em CITIZEN_HIDDEN" do
    expect(Platform::Features::CATALOG[-7].key).to eq("zoonoses")
    expect(described_class.find("zoonoses").requires).to eq(%w[feature:territory_registry])
    expect(described_class.find("zoonoses").description)
      .to eq("Animal com tutor, vacinação antirrábica, demandas da ouvidoria, observação do agressor, leishmaniose canina e canil")
    expect(described_class::CITIZEN_HIDDEN).to include("zoonoses")
  end

  it "vector_control ligado com home_visits desligado fica inutilizável (home_visits_disabled)" do
    city = home_visit_city!
    Platform::Features.set!(city: city, key: "home_visits", enabled: false, maintainer: ledi_maintainer!)
    Platform::Features.set!(city: city, key: "vector_control", enabled: true, maintainer: ledi_maintainer!)
    expect(Platform::Features.missing(city, "vector_control")).to eq(%w[home_visits_disabled])
    expect(VectorControl::Gate.usable?(city)).to be(false)
  end

  it "faltando a farmácia, o interruptor ligado fica inutilizável com pharmacy_disabled" do
    city = urgency_city!
    Platform::Features.set!(city: city, key: "urgency_stock_deduction", enabled: true, maintainer: ledi_maintainer!)
    expect(Platform::Features.missing(city, "urgency_stock_deduction")).to eq(%w[pharmacy_disabled])
    expect(Urgency::StockGate.usable?(city)).to be(false)
  end

  # Contrato Q11: só os pré-requisitos diretos, na ordem do `requires`; nunca o
  # pré-requisito do pré-requisito.
  it "missing devolve só os pré-requisitos diretos, na ordem do requires" do
    city = urgency_city!
    Platform::Features.set!(city: city, key: "clinical_record", enabled: false, maintainer: ledi_maintainer!)
    expect(Platform::Features.missing(city, "urgency_stock_deduction")).to eq(%w[urgency_care_disabled pharmacy_disabled])
    expect(Platform::Features.missing(city, "urgency_stock_deduction")).not_to include("clinical_record_disabled")
  end

  # Módulo 27b (contrato §1; Q6): cinco interruptores fecham o catálogo.
  it "módulo 27b: os cinco bnafar precedem o rnds_regulation, nessa ordem, com os requires do Valor 1" do
    expect(described_class::CATALOG.last(6).first(5).map(&:key))
      .to eq(%w[bnafar bnafar_medications bnafar_vector_supplies bnafar_vaccines bnafar_mock])
    expect(described_class.find("bnafar").requires).to eq(%w[credential:bnafar ibge_code])
    expect(described_class.find("bnafar").description).to eq("Envio diário da posição de estoque e das saídas ao SI-BNAFAR")
    expect(described_class.find("bnafar_medications").requires).to eq(%w[feature:bnafar feature:pharmacy])
    expect(described_class.find("bnafar_medications").description).to eq("BNAFAR: medicamentos da farmácia")
    expect(described_class.find("bnafar_vector_supplies").requires).to eq(%w[feature:bnafar vector_supplies])
    expect(described_class.find("bnafar_vector_supplies").description).to eq("BNAFAR: produtos de endemias e zoonoses")
    expect(described_class.find("bnafar_vaccines").requires).to eq(%w[feature:bnafar feature:vaccination])
    expect(described_class.find("bnafar_vaccines").description).to eq("BNAFAR: vacinas e rede de frio")
    expect(described_class.find("bnafar_mock").requires).to eq(%w[feature:bnafar])
    expect(described_class.find("bnafar_mock").description).to eq("BNAFAR simulado — envio sem validade")
  end

  it "módulo 27b: bnafar_mock some em produção; as quatro primeiras ficam escondidas do cidadão, o mock não" do
    expect(described_class.catalog(env: "production").map(&:key)).not_to include("bnafar_mock")
    expect(described_class.catalog(env: "production").map(&:key)).to include("bnafar")
    expect(described_class.catalog(env: "test").map(&:key)).to include("bnafar_mock")
    expect(described_class::CITIZEN_HIDDEN).to include("bnafar", "bnafar_medications", "bnafar_vector_supplies", "bnafar_vaccines")
    expect(described_class::CITIZEN_HIDDEN).not_to include("bnafar_mock")
  end

  it "módulo 27b: bnafar_vector_supplies sem vector_control nem zoonoses → vector_supplies_disabled; com só zoonoses → vazio" do
    state = { credentials: { "bnafar" => "ok" }, ibge_code: "4106902", uf: "PR", pec_origin: false, pec_hmac_key: false }
    platform = { record_mode: "record", pec_url: nil }
    allow(described_class).to receive(:usable?).and_call_original
    allow(described_class).to receive(:usable?).with(city, "vector_control", anything).and_return(false)
    allow(described_class).to receive(:usable?).with(city, "zoonoses", anything).and_return(false)
    expect(described_class.missing_for("vector_supplies", platform, state, city: city)).to eq("vector_supplies_disabled")
    allow(described_class).to receive(:usable?).with(city, "zoonoses", anything).and_return(true)
    expect(described_class.missing_for("vector_supplies", platform, state, city: city)).to be_nil
  end

  it "módulo 27b: bnafar sem credencial → credential_missing:bnafar; sem IBGE → ibge_code_missing" do
    state = { credentials: {}, ibge_code: nil, uf: "PR", pec_origin: false, pec_hmac_key: false }
    allow(described_class).to receive(:city_state).with(city).and_return(state)
    expect(described_class.missing(city, "bnafar")).to eq(%w[credential_missing:bnafar ibge_code_missing])
  end

  it "módulo 27b (Q9): só credencial de homologação com a cidade em produção → credential_missing:bnafar" do
    IntegrationCredential.create!(kind: "bnafar", environment: "homologation", secret: { "username" => "u", "password" => "p" },
                                  set_by_user: admin, set_at: Time.current)
    expect(Bnafar::Environment.current(env: "production")).to eq("production")
    expect(described_class.city_state(city)[:credentials]).not_to have_key("bnafar")
    expect(described_class.missing(city, "bnafar")).to include("credential_missing:bnafar")
  end

  it "módulo 27b (Q9): com o ambiente em uso homologação, a credencial de homologação conta; a de produção não" do
    IntegrationCredential.create!(kind: "bnafar", environment: "production", secret: { "username" => "u", "password" => "p" },
                                  set_by_user: admin, set_at: Time.current, last_check_status: "ok")
    IntegrationCredential.create!(kind: "bnafar", environment: "homologation", secret: { "username" => "u", "password" => "p" },
                                  set_by_user: admin, set_at: Time.current, last_check_status: "unauthorized")
    expect(described_class.city_state(city)[:credentials]["bnafar"]).to eq("ok")
    allow(Bnafar::Environment).to receive(:current).and_return("homologation")
    expect(described_class.city_state(city)[:credentials]["bnafar"]).to eq("unauthorized")
  end

  # Módulo 26c (Valor 1; Q14): o envio da regulação fecha o catálogo; rnds_mock
  # serve os dois envios pelo requisito alternativo rnds_sending.
  it "módulo 26c: rnds_regulation fecha o catálogo com os requires do Valor 1 e some do cidadão" do
    expect(described_class::CATALOG.last.key).to eq("rnds_regulation")
    entry = described_class.find("rnds_regulation")
    expect(entry.requires).to eq(%w[feature:care_regulation credential:rnds_regulation ibge_code uf])
    expect(entry.description).to eq("Envio da regulação à RNDS")
    expect(described_class::CITIZEN_HIDDEN).to include("rnds_regulation")
    expect(described_class.catalog(env: "production").map(&:key)).to include("rnds_regulation")
  end

  it "módulo 26c: sem credencial → credential_missing; recusada → credential_unauthorized; care_regulation desligado → care_regulation_disabled" do
    state = { credentials: {}, ibge_code: "4106902", uf: "PR", pec_origin: false, pec_hmac_key: false }
    allow(described_class).to receive(:usable?).and_call_original
    allow(described_class).to receive(:usable?).with(city, "care_regulation", anything).and_return(true)
    expect(described_class.missing(city, "rnds_regulation", state: state)).to eq(%w[credential_missing:rnds_regulation])
    state[:credentials]["rnds_regulation"] = "unauthorized"
    expect(described_class.missing(city, "rnds_regulation", state: state)).to eq(%w[credential_unauthorized:rnds_regulation])
    state[:credentials]["rnds_regulation"] = "ok"
    expect(described_class.missing(city, "rnds_regulation", state: state)).to eq([])
    allow(described_class).to receive(:usable?).with(city, "care_regulation", anything).and_return(false)
    expect(described_class.missing(city, "rnds_regulation", state: state)).to eq(%w[care_regulation_disabled])
  end

  it "módulo 26c (Q14): rnds_mock exige rnds_sending — um dos dois envios utilizável" do
    expect(described_class.find("rnds_mock").requires).to eq(%w[rnds_sending])
    state = { credentials: {}, ibge_code: "4106902", uf: "PR", pec_origin: false, pec_hmac_key: false }
    allow(described_class).to receive(:usable?).and_call_original
    allow(described_class).to receive(:usable?).with(city, "rnds_immunization", anything).and_return(false)
    allow(described_class).to receive(:usable?).with(city, "rnds_regulation", anything).and_return(false)
    expect(described_class.missing(city, "rnds_mock", state: state)).to eq(%w[rnds_sending_disabled])
    allow(described_class).to receive(:usable?).with(city, "rnds_regulation", anything).and_return(true)
    expect(described_class.missing(city, "rnds_mock", state: state)).to eq([])
    allow(described_class).to receive(:usable?).with(city, "rnds_regulation", anything).and_return(false)
    allow(described_class).to receive(:usable?).with(city, "rnds_immunization", anything).and_return(true)
    expect(described_class.missing(city, "rnds_mock", state: state)).to eq([])
  end

  it "módulo 26c: rnds_mock segue fora de produção" do
    expect(described_class.catalog(env: "production").map(&:key)).not_to include("rnds_mock")
    expect(described_class.catalog(env: "test").map(&:key)).to include("rnds_mock")
  end
end
