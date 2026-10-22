require "rails_helper"

RSpec.describe CareLines::SuggestJob do
  it "roda por cidade só com care_lines utilizável e agenda às 6h45" do
    care_city!
    unit = care_unit!
    doctor = care_doctor!(unit)
    care_team!(unit, doctor)
    adopted_line!("diabetes_c4")
    care_patient!(age: 58, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    Current.city.update!(record_mode: "integrated")
    CityCatalog.reset_cache!
    described_class.perform_now
    expect(CareLineSuggestion.count).to eq(0)
    Current.city.update!(record_mode: "record")
    CityCatalog.reset_cache!
    described_class.perform_now
    expect(CareLineSuggestion.count).to eq(1)
    recurring = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).dig("default", "care_lines_suggest")
    expect(recurring).to eq("class" => "CareLines::SuggestJob", "queue" => "housekeeping", "schedule" => "every day at 6:45am America/Sao_Paulo")
  end
end
