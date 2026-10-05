# spec/services/triages/offer_for_spec.rb
require "rails_helper"

# Triages::Offer.for carrega do banco: protocolos ativos, linhas do catálogo,
# perfil do par e a última conclusão por protocolo (data local da cidade).
RSpec.describe Triages::Offer, ".for" do
  include ActiveSupport::Testing::TimeHelpers
  before { Current.city = TEST_CITY_A }
  after { Current.reset; Rails.cache.clear }

  let(:admin) { staff_with("oferta-#{SecureRandom.hex(3)}@cidade.gov.br") }
  let!(:idoso) do
    active_protocol!("saude-do-idoso", offer: { "title" => "Saúde do idoso", "eligibility" => { "gte" => ["profile.age", 60] },
                                                "retake_after_days" => 365 })
  end
  let!(:respiratoria) { create_default_protocol! }

  before { TriageOffer.create!(protocol_name: "saude-do-idoso", updated_by_user: admin, position: 1) }

  it "avó vê os dois; neto só o de todos; nome inexistente nunca está em oferta" do
    avo = profiled_citizen!(age: 62)
    neto = profiled_citizen!(age: 8, sex: "male", cpf: CampaignHistory.cpf_for("neto"))
    expect(described_class.for(citizen: avo).map(&:protocol_name)).to eq(%w[saude-do-idoso triage-respiratoria])
    expect(described_class.for(citizen: neto).map(&:protocol_name)).to eq(%w[triage-respiratoria])
    expect(described_class.available?(citizen: neto, protocol_name: "saude-do-idoso")).to be(false)
    expect(described_class.available?(citizen: avo, protocol_name: "fantasma")).to be(false)
  end

  it "conclusão há 100 dias deixa recent; triagem de outro par não conta" do
    avo = profiled_citizen!(age: 62)
    completed_triage!(avo, "saude-do-idoso", at: 100.days.ago)
    outro = profiled_citizen!(age: 70, phone: "+5541900000001")
    completed_triage!(outro, "saude-do-idoso", at: 1.day.ago)
    item = described_class.for(citizen: avo).find { |i| i.protocol_name == "saude-do-idoso" }
    expect(item).to have_attributes(state: "recent", next_available_on: (100.days.ago.to_date + 365))
    expect(described_class.for(citizen: outro).find { |i| i.protocol_name == "saude-do-idoso" }.state).to eq("recent")
  end

  it "faz 60 hoje no fuso de Manaus, não no de São Paulo" do
    manaus = TEST_CITY_A.dup.tap { |c| c.time_zone = "America/Manaus" }
    CityConnection.with(manaus) do
      travel_to(Time.utc(2026, 10, 6, 3, 30)) do # 23h30 de 05/10 em Manaus; 00h30 de 06/10 em SP
        avo = Citizen.create!(cpf: "52998224725", phone: "+5541998765432", birth_date: "1966-10-06", sex: "female",
                              profile_source: "declared")
        expect(described_class.available?(citizen: avo, protocol_name: "saude-do-idoso")).to be(false)
      end
      travel_to(Time.utc(2026, 10, 6, 4, 1)) do # 00h01 de 06/10 em Manaus
        avo = Citizen.find_by!(cpf: "52998224725", phone: "+5541998765432")
        expect(described_class.available?(citizen: avo, protocol_name: "saude-do-idoso")).to be(true)
      end
    end
  end
end
