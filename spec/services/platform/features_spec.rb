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
    expect { described_class.set!(city: city, key: "rnds", enabled: true, maintainer: maintainer) }
      .to raise_error(described_class::UnknownFeature)
    expect { described_class.enabled?(city, "rnds") }.to raise_error(described_class::UnknownFeature)
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
    allow(IntegrationCredential).to receive(:pluck).and_raise(ActiveRecord::StatementInvalid, "PG::UndefinedTable")
    expect(described_class.city_state(city)).to be_nil
    expect(described_class.missing(city, "cadsus_lookup")).to eq([ "city_unreachable" ])
  end

  it "modo e PEC sem o cache do catálogo" do
    stale = City.find(city.id)
    City.where(id: city.id).update_all(record_mode: "record")
    expect(described_class.settings(stale)).to eq(record_mode: "record", pec_url: nil)
  end
end
