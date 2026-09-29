# spec/services/campaigns/audience_spec.rb
require "rails_helper"

RSpec.describe Campaigns::Audience do
  before { create_default_protocol! }

  let(:centro) { Neighborhood.create!(name: "Centro", source: "seed") }
  let(:batel) { Neighborhood.create!(name: "Batel", source: "seed") }
  let(:window) { { "from" => (Time.zone.today - 30).iso8601, "to" => Time.zone.today.iso8601 } }

  def audience(geo: { "scope" => "city" }, all: [])
    { "version" => 1, "geo" => geo, "clinical" => { "all" => all } }
  end

  def ids(value) = Citizen.where(id: described_class.new(value).citizen_ids).pluck(:id)

  it "recorte: cidade toda inclui quem não declarou bairro; bairros e unidade, não" do
    no_neighborhood = person!
    in_centro = person!(neighborhood: centro)
    in_batel = person!(neighborhood: batel)
    unit = create_unit("UBS Centro")
    NeighborhoodCoverage.create!(neighborhood: centro, health_unit: unit)

    expect(ids(audience)).to contain_exactly(no_neighborhood.id, in_centro.id, in_batel.id)
    expect(ids(audience(geo: { "scope" => "neighborhoods", "neighborhood_ids" => [ batel.id ] }))).to eq([ in_batel.id ])
    expect(ids(audience(geo: { "scope" => "unit", "health_unit_id" => unit.id }))).to eq([ in_centro.id ])
  end

  it "combina recorte e dois critérios por E" do
    both = person!(neighborhood: centro).tap do |c|
      CampaignHistory.no_show!(c, at: 3.days.ago, unit: unit!, by: staff!)
      CampaignHistory.triage!(c, status: "aborted_by_timeout", at: 2.days.ago)
    end
    person!(neighborhood: centro).tap { |c| CampaignHistory.no_show!(c, at: 3.days.ago, unit: unit!, by: staff!) }
    person!(neighborhood: centro).tap { |c| CampaignHistory.triage!(c, status: "aborted_by_timeout", at: 2.days.ago) }
    person!(neighborhood: batel).tap do |c|
      CampaignHistory.no_show!(c, at: 3.days.ago, unit: unit!, by: staff!)
      CampaignHistory.triage!(c, status: "aborted_by_timeout", at: 2.days.ago)
    end

    value = audience(geo: { "scope" => "neighborhoods", "neighborhood_ids" => [ centro.id ] },
                     all: [ { "kind" => "appointment_no_show" }.merge(window), { "kind" => "triage_incomplete" }.merge(window) ])
    expect(ids(value)).to eq([ both.id ])
  end

  it "exclui quem tem a conversa mais recente revogada; revogação antiga não exclui" do
    revoked = person!.tap { |c| CampaignHistory.triage!(c, at: 5.days.ago); revoked_conversation!(c, at: 1.day.ago) }
    healed = person!.tap { |c| revoked_conversation!(c, at: 5.days.ago); CampaignHistory.triage!(c, at: 1.day.ago) }
    plain = person!
    expect(ids(audience)).to contain_exactly(healed.id, plain.id)
    expect(ids(audience)).not_to include(revoked.id)
  end

  it "empate de created_at entre conversas: vale a de maior id" do
    at = 2.days.ago
    citizen = person!
    revoked = revoked_conversation!(citizen, at: at)
    other = Conversation.create!(channel: "web", citizen: citizen, phone: citizen.phone, state: "completed", created_at: at)
    expect(ids(audience)).to eq(revoked.id > other.id ? [] : [ citizen.id ])
  end

  it "resumo conta telefones distintos; telefone compartilhado conta uma vez" do
    shared = next_phone
    person!(phone: shared, cpf: CampaignHistory.cpf_for("#{shared}-a"))
    person!(phone: shared, cpf: CampaignHistory.cpf_for("#{shared}-b"))
    person!
    expect(described_class.new(audience).summary).to eq(citizens: 3, phones: 2)
  end

  it "mínimo de 5 telefones: 4 → below_minimum; 5 → as contagens" do
    4.times { person! }
    expect(described_class.new(audience).preview).to eq(below_minimum: true)
    expect(described_class.new(audience)).to be_below_minimum
    person!
    expect(described_class.new(audience).preview).to eq(citizens: 5, phones: 5)
  end

  it "cinco CPFs num telefone só não chegam ao mínimo" do
    shared = next_phone
    5.times { |i| person!(phone: shared, cpf: CampaignHistory.cpf_for("#{shared}-#{i}")) }
    expect(described_class.new(audience).preview).to eq(below_minimum: true)
  end

  it "não carrega cidadão em Ruby: citizen_ids é uma relação SQL" do
    expect(described_class.new(audience).citizen_ids).to be_a(ActiveRecord::Relation)
  end
end
