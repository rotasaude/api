require "rails_helper"

RSpec.describe "Prova técnica do 35a", type: :model do
  let(:defaults) { YAML.load_file(Rails.root.join("config/vector_control/defaults.yml")) }
  let(:sources) { YAML.load_file(Rails.root.join("config/vector_control/sources.yml")) }

  it "os padrões de fábrica são os 19 do contrato §11" do
    expect(defaults).to eq(
      "default_days" => 60, "strategic_point_days" => 15, "block_radius_rings" => 1, "block_grouping_days" => 7,
      "block_diseases" => %w[dengue chikungunya zika], "ubv_cycles_max" => 3, "ubv_cycle_days_min" => 3,
      "ubv_cycle_days_max" => 5, "ubv_cycle_interval_days" => 5, "ovitrap_collection_days_min" => 3,
      "ovitrap_collection_days_max" => 10, "ovitrap_alert_eggs" => 100, "ovitrap_radius_rings" => 1,
      "liraa_standard_min" => 8100, "liraa_standard_max" => 12000, "liraa_half_min" => 2000,
      "liraa_base_sample" => 450, "liraa_household_fraction" => 0.2, "iip_bands" => [ 1.0, 4.0 ]
    )
  end

  it "toda fonte tem URL, data e SHA-256" do
    %w[liraa_manual epi_calendar deposit_groups].each do |key|
      expect(sources.fetch(key)).to include("url", "fetched_on", "pages")
      expect(sources.dig(key, "sha256")).to match(/\A\h{64}\z/)
    end
  end

  it "a semana epidemiológica é a do calendário do MS (Surveillance::EpiWeek)" do
    expect(Surveillance::EpiWeek.for(Date.new(2026, 1, 1)).to_s).to eq("2025-53")
    expect(Surveillance::EpiWeek.for(Date.new(2026, 1, 4)).to_s).to eq("2026-01")
    expect(Surveillance::EpiWeek.for(Date.new(2026, 11, 15)).to_s).to eq("2026-46")
    expect(Surveillance::EpiWeek.for(Date.new(2026, 11, 21)).to_s).to eq("2026-46")
    expect(Surveillance::EpiWeek.weeks_in(2025)).to eq(53)
  end

  it "domínios na ordem do catálogo, com os rótulos de risco do contrato §2" do
    domains = YAML.load_file(Rails.root.join("config/vector_control/domains.yml"))
    expect(domains["deposit_groups"].map { _1["code"] }).to eq(%w[A1 A2 B C D1 D2 E])
    expect(domains["risk_classes"].map { _1["label"] }).to eq(
      [ "Verde (baixo)", "Amarelo (médio)", "Vermelho (alto)", "Cinza (difícil acesso, com agendamento)",
        "Roxo (difícil acesso, exige intervenção legal ou VISA)" ]
    )
  end
end
