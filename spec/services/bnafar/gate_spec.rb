require "rails_helper"

# Módulo 27b (Valor fixado 2): o interruptor do envio ao SI-BNAFAR e os domínios
# cujo interruptor está utilizável. Leitura pura (R19): nada aqui grava.
RSpec.describe Bnafar::Gate, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:maintainer) { ledi_maintainer! }
  let(:location) { Struct.new(:kind) }

  def bnafar_credential!(status: nil)
    profile = city_profile!
    profile.update!(ibge_code: "4106902") if profile.ibge_code.blank?
    IntegrationCredential.create!(kind: "bnafar", environment: "production", secret: { "username" => "rota", "password" => "x" },
                                  set_by_user: pharmacy_admin!, set_at: Time.current, last_check_status: status)
  end

  def switch!(city, *keys, enabled: true)
    keys.each { |key| Platform::Features.set!(city: city, key: key, enabled: enabled, maintainer: maintainer) }
  end

  it "KEY e DOMAIN_KEYS" do
    expect(described_class::KEY).to eq("bnafar")
    expect(described_class::DOMAIN_KEYS).to eq(
      Stock::Domain::MEDICATION => "bnafar_medications",
      Stock::Domain::VECTOR_CONTROL => "bnafar_vector_supplies",
      Stock::Domain::IMMUNOBIOLOGICAL => "bnafar_vaccines"
    )
  end

  it "domains com o bnafar desligado é vazio, mesmo com o domínio ligado" do
    city = pharmacy_city!
    bnafar_credential!
    switch!(city, "bnafar_medications")
    expect(described_class.usable?(city)).to be(false)
    expect(described_class.domains(city)).to eq([])
  end

  it "domains traz só o domínio utilizável" do
    city = pharmacy_city!
    bnafar_credential!
    switch!(city, "bnafar", "bnafar_medications")
    expect(described_class.usable?(city)).to be(true)
    expect(described_class.domains(city)).to eq([ Stock::Domain::MEDICATION ])
  end

  it "domínio ligado e inutilizável (credencial recusada) fica fora (Q6)" do
    city = pharmacy_city!
    bnafar_credential!(status: "unauthorized")
    switch!(city, "bnafar", "bnafar_medications")
    expect(Platform::Features.missing(city, "bnafar")).to eq([ "credential_unauthorized:bnafar" ])
    expect(described_class.domains(city)).to eq([])
  end

  it "bnafar_vector_supplies só com vector_control ou zoonoses utilizável" do
    city = home_visit_city!
    bnafar_credential!
    switch!(city, "bnafar", "bnafar_vector_supplies")
    expect(Platform::Features.missing(city, "bnafar_vector_supplies")).to eq([ "vector_supplies_disabled" ])
    expect(described_class.domains(city)).to eq([])
    switch!(city, "zoonoses")
    expect(Platform::Features.missing(city, "bnafar_vector_supplies")).to eq([])
    expect(described_class.domains(city)).to eq([ Stock::Domain::VECTOR_CONTROL ])
  end

  it "domains_through: ligado em R às 23:00 entra; em R+1 às 00:30 não" do
    city = pharmacy_city!
    bnafar_credential!
    zone = ActiveSupport::TimeZone[city.time_zone]
    day = Date.new(2026, 11, 20)
    travel_to(zone.local(2026, 11, 19, 12, 0)) { switch!(city, "bnafar") }
    travel_to(zone.local(2026, 11, 20, 23, 0)) { switch!(city, "bnafar_medications") }
    expect(described_class.domains_through(city, day)).to eq([ Stock::Domain::MEDICATION ])

    CityFeature.where(city_id: city.id, key: "bnafar_medications").update_all(changed_at: zone.local(2026, 11, 21, 0, 30))
    expect(described_class.domains(city)).to eq([ Stock::Domain::MEDICATION ])
    expect(described_class.domains_through(city, day)).to eq([])
  end

  it "domains_through exige também o bnafar ligado até o fim do dia" do
    city = pharmacy_city!
    bnafar_credential!
    zone = ActiveSupport::TimeZone[city.time_zone]
    travel_to(zone.local(2026, 11, 20, 8, 0)) { switch!(city, "bnafar_medications") }
    travel_to(zone.local(2026, 11, 21, 8, 0)) { switch!(city, "bnafar") }
    expect(described_class.domains_through(city, Date.new(2026, 11, 20))).to eq([])
    expect(described_class.domains_through(city, Date.new(2026, 11, 21))).to eq([ Stock::Domain::MEDICATION ])
  end

  # R25 (revisão final): o alerta `late` conta o dia devido pelo interruptor
  # LIGADO, mesmo com a credencial recusada (Delivery#pause! → `unauthorized`).
  it "domains_due: credencial recusada ainda deve o dia; domains_through não" do
    city = pharmacy_city!
    bnafar_credential!(status: "unauthorized")
    zone = ActiveSupport::TimeZone[city.time_zone]
    travel_to(zone.local(2026, 11, 18, 9, 0)) { switch!(city, "bnafar", "bnafar_medications") }
    day = Date.new(2026, 11, 20)

    expect(described_class.domains(city)).to eq([])
    expect(described_class.domains_through(city, day)).to eq([])
    expect(described_class.domains_due(city, day)).to eq([ Stock::Domain::MEDICATION ])
  end

  it "domains_due respeita o corte do dia e exige o bnafar e o domínio ligados" do
    city = pharmacy_city!
    bnafar_credential!(status: "unauthorized")
    zone = ActiveSupport::TimeZone[city.time_zone]
    travel_to(zone.local(2026, 11, 21, 0, 30)) { switch!(city, "bnafar", "bnafar_medications") }
    expect(described_class.domains_due(city, Date.new(2026, 11, 20))).to eq([])
    expect(described_class.domains_due(city, Date.new(2026, 11, 21))).to eq([ Stock::Domain::MEDICATION ])

    switch!(city, "bnafar", enabled: false)
    expect(described_class.domains_due(city, Date.new(2026, 11, 22))).to eq([])
    expect(described_class.domains_due(nil, Date.new(2026, 11, 22))).to eq([])
  end

  it "required_for? num vaccine_room só com bnafar_vaccines" do
    city = vaccination_city!
    bnafar_credential!
    switch!(city, "bnafar", "pharmacy", "bnafar_medications")
    expect(described_class.required_for?(city, location.new("vaccine_room"))).to be(false)
    switch!(city, "bnafar_vaccines")
    expect(described_class.required_for?(city, location.new("vaccine_room"))).to be(true)
    expect(described_class.required_for?(city, location.new("central"))).to be(true)
  end

  it "usable? com city nil ou sem id é falso" do
    expect(described_class.usable?(nil)).to be(false)
  end
end
