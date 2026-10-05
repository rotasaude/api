require "rails_helper"

# ADR 0027 (spec 2026-10-05 §3.2, §6.2; contratos §4.2): a cidade pausa,
# ordena, restringe (só profile.age, profile.sex, citizen.neighborhood_id) e
# limita o período; nunca amplia. Evento só com nome e usuário.
RSpec.describe Triages::SetOffer do
  before { Current.city = TEST_CITY_A }
  after { Current.reset; Rails.cache.clear }

  let(:admin) { staff_with("catalogo-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin") }
  let(:centro) { "0b6f6c1e-9f1a-4d8b-9a4c-1f2e3d4c5b6a" }
  let(:valid) do
    { "enabled" => true, "position" => 2, "restriction" => { "in" => ["citizen.neighborhood_id", [centro]] },
      "available_from" => nil, "available_until" => "2026-12-31" }
  end

  before { active_protocol!("saude-do-idoso") }

  # Chaves string sem chaves {} chegam como **kwargs (Ruby 3): junta os dois.
  def set(attrs = {}, **rest)
    name = rest.delete(:name) || "saude-do-idoso"
    described_class.call(protocol_name: name, attributes: valid.merge(attrs).merge(rest), by: admin)
  end
  def events = DomainEvent.where(name: "triage_offer.changed").map(&:payload)

  it "cria a linha, depois atualiza; evento só quando muda" do
    expect(set).to be_ok
    expect(TriageOffer.sole).to have_attributes(enabled: true, position: 2, available_until: Date.new(2026, 12, 31),
                                                restriction: valid["restriction"], updated_by_user_id: admin.id)
    set
    set("enabled" => false)
    expect(TriageOffer.sole.enabled).to be(false)
    expect(events).to eq([ { "protocol_name" => "saude-do-idoso", "user_id" => admin.id } ] * 2)
  end

  it "protocolo sem nenhuma versão: :unknown_protocol" do
    expect(set(name: "fantasma").reason).to eq(:unknown_protocol)
    expect(TriageOffer.count).to eq(0)
  end

  it "versão não ativa também configura (a cidade prepara antes de ativar)" do
    ProtocolDefinition.create!(name: "rascunho", version: 1, status: "draft", definition: catalog_definition("rascunho"))
    expect(set(name: "rascunho")).to be_ok
  end

  it "recusa enabled, posição e período inválidos" do
    [ nil, "sim", 1 ].each { |v| expect(set("enabled" => v).reason).to eq(:invalid_enabled), v.inspect }
    [ nil, 0, -1, 10_001, 1.5, "2" ].each { |v| expect(set("position" => v).reason).to eq(:invalid_position), v.inspect }
    [
      { "available_from" => "2026-12-31", "available_until" => "2026-01-01" },
      { "available_from" => "31/12/2026" }, { "available_until" => "2026-02-30" }, { "available_from" => 20261231 }
    ].each { |v| expect(set(v).reason).to eq(:invalid_period), v.inspect }
    expect(TriageOffer.count).to eq(0)
  end

  it "recusa restrição inválida: tabela (Review Focus 5)" do
    [
      { "xyz" => [ "profile.age", 1 ] },
      { "gte" => [ "outcome.score", 1 ] },
      { "eq" => [ "q1", "true" ] },
      { "eq" => [ "profile.sex", "outro" ] },
      { "in" => [ "citizen.neighborhood_id", [ "nao-uuid" ] ] },
      { "any" => [] },
      "lixo", [ 1 ], 42,
      { "in" => [ "citizen.neighborhood_id", Array.new(120) { SecureRandom.uuid } ] } # > 4096 bytes
    ].each do |restriction|
      expect(set("restriction" => restriction).reason).to eq(:invalid_restriction), restriction.inspect[0, 80]
    end
    expect(TriageOffer.count).to eq(0)
  end

  it "restrição nula = sem restrição" do
    expect(set("restriction" => nil)).to be_ok
    expect(TriageOffer.sole.restriction).to be_nil
  end
end
