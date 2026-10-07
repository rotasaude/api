require "rails_helper"

# Desvio 7: o console nunca abre banco de cidade; a cidade publica as contagens
# na plataforma (padrão de Analytics::Publish, ADR 0025). R26: retenção por
# idade (corrente + 12), não por número de linhas.
RSpec.describe Ledi::PublishProductionJob do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { register_test_city! }

  def entry!(status, competence)
    attrs = { uuid: "1234567-#{SecureRandom.uuid}", ficha_type: "procedimento", competence: competence,
              source_type: "synthetic", source_id: SecureRandom.uuid, ledi_version: "8.7.0",
              next_attempt_at: Time.current, status: status }
    status == "accepted" ? attrs[:accepted_at] = Time.current : attrs[:bytes] = "x".b
    attrs[:last_error_codes] = [ Ledi::ErrorCodes::UNKNOWN ] if status == "rejected"
    LediOutboxEntry.create!(attrs)
  end

  after { CityProductionSummary.where(city_id: city.id).delete_all }

  it "publica a competência corrente e a anterior, idempotente, e guarda 13" do
    travel_to Time.zone.local(2026, 11, 3, 10) do
      2.times { entry!("accepted", "202611") }
      entry!("rejected", "202610")
      CityProductionSummary.create!(city_id: city.id, competence: "202510", published_at: 1.year.ago)
      CityProductionSummary.create!(city_id: city.id, competence: "202511", published_at: 1.year.ago)

      2.times { described_class.perform_now }

      rows = CityProductionSummary.where(city_id: city.id).order(:competence)
      expect(rows.pluck(:competence)).to eq(%w[202511 202610 202611])
      expect(rows.last.slice(:accepted, :rejected, :pending, :sending)).to eq("accepted" => 2, "rejected" => 0, "pending" => 0, "sending" => 0)
      expect(rows.second.rejected).to eq(1)
    end
  end

  it "está no recurring.yml, a cada 10 minutos, na fila housekeeping" do
    task = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).dig("production", "ledi_publish_production")
    expect(task).to eq("class" => "Ledi::PublishProductionJob", "queue" => "housekeeping",
                       "schedule" => "every 10 minutes")
  end
end
