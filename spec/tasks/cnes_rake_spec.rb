# spec/tasks/cnes_rake_spec.rb
require "rails_helper"
require "rake"

RSpec.describe "cnes:import rake task" do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("cnes:import") }
  before { Rake::Task["cnes:import"].reenable }

  it "relata por município sem CPF nem CNS na saída" do
    City.find_by(slug: TEST_CITY_A.slug) ||
      City.create!(slug: TEST_CITY_A.slug, name: TEST_CITY_A.name, status: "active",
                   database_url: TEST_CITY_A.database_url, encryption_key: TEST_CITY_A.encryption_key,
                   schema_version: CitySchema.expected_version.to_s)
    CityProfile.create!(name: "Curitiba", uf: "PR", ibge_code: "4106902")
    out = StringIO.new
    original, $stdout = $stdout, out
    Rake::Task["cnes:import"].invoke("202609", Rails.root.join("spec/fixtures/cnes/202609").to_s)
    $stdout = original
    expect(out.string).to include("4106902: 4 estabelecimentos, 3 equipes, 5 vínculos")
    expect(out.string).not_to include("52998224725")
  ensure
    $stdout = original if original
    CityCatalog.reset_cache!
  end
end
