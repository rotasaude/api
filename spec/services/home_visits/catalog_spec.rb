require "rails_helper"

# Módulo 24b (ADR 0052): catálogos, eventos de domínio (contrato §1) e filtro de log (W-7).
RSpec.describe "catálogos do módulo 24b", type: :model do
  it "imóveis não residenciais e residenciais cobrem exatamente os tipos do 24a" do
    expect(HomeVisits::Catalog::NON_RESIDENTIAL + HomeVisits::Catalog::RESIDENTIAL)
      .to match_array(TerritoryRegistry::Catalog::PROPERTY_TYPES)
    expect((HomeVisits::Catalog::NON_RESIDENTIAL & HomeVisits::Catalog::RESIDENTIAL)).to be_empty
  end

  it "os CBOs das linhas de cuidado estão entre os de quem registra visita" do
    expect(HomeVisits::Catalog::CARE_LINE_CBOS - HomeVisits::Catalog::HOME_VISIT_CBOS.to_a).to be_empty
  end

  it "os valores fixados batem com o YAML de dicionários" do
    yaml = YAML.load_file(Rails.root.join("config/ledi/visit_activity_dictionaries.yml"))
    rules = yaml.dig("home_visit", "rules")
    expect(HomeVisits::Catalog::NON_RESIDENTIAL).to eq(rules["non_residential_property_types"])
    expect(HomeVisits::Catalog::NON_RESIDENTIAL_REASONS).to match_array(rules["non_residential_reasons"])
    expect(HomeVisits::Catalog::FEMALE_ONLY_REASONS).to eq(rules["male_forbidden_reasons"])
    expect(HomeVisits::Catalog::MAX_VISITS_PER_DAY).to eq(rules["visits_per_sheet"])
    crules = yaml.dig("collective_activity", "rules")
    expect(CollectiveActivities::Catalog::SMOKING_PRACTICES).to eq(crules["smoking_practices"])
    expect(CollectiveActivities::Catalog::PRACTICE_TYPE6_ONLY).to eq(crules["type6_only_practices"])
    expect(CollectiveActivities::Catalog::PROCEDURE_PRACTICE).to eq(crules["procedure_practice"])
    expect(CollectiveActivities::Catalog::FORBIDDEN_HEALTH_TOPICS).to eq(crules["forbidden_health_topics"])
    expect(CollectiveActivities::Catalog::PARTICIPANTS_REQUIRED).to eq(crules["participant_identifier_types"])
  end

  it "REGISTRATION_CBOS vem do 24a" do
    expect(HomeVisits::Catalog::HOME_VISIT_CBOS).to eq(TerritoryRegistry::Access::REGISTRATION_CBOS[:home_visit])
    expect(CollectiveActivities::Catalog::CBOS).to eq(TerritoryRegistry::Access::REGISTRATION_CBOS[:collective_activity])
  end

  it "os eventos de domínio são exatamente os 8 do contrato §1" do
    events = HomeVisits::Catalog::DOMAIN_EVENTS + CollectiveActivities::Catalog::DOMAIN_EVENTS
    expect(events).to match_array(%w[
      home_visit.recorded home_visit.withdrawn home_visit_day.closed micro_area.field_assignment_changed
      field_device.registered field_device.revoked
      collective_activity.recorded collective_activity.marked_mistaken
    ])
    expect(FieldSync::Catalog::CONTRACT).to eq("field-sync-v1")
  end

  it "o filtro de log mascara os campos de visita e atividade coletiva (W-7)" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    keys = %w[measurements meeting_topics target_audience health_topics health_practices altered_evaluation smoking
              qr_payload place_text note reasons token items body new_patient candidates withdrawal_reason mistaken_reason]
    filtered = filter.filter(keys.to_h { |key| [ key, "segredo" ] })
    expect(filtered.values.uniq).to eq([ "[FILTERED]" ])
  end
end
