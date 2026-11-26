require "rails_helper"

# Módulo 27b, Q42: o fim do reenvio de R é o MENOR entre o fim de R+1 no fuso da
# cidade e o fim de R+1 em Brasília (-03:00): o SI-BNAFAR só aceita a data
# atual ou a do dia anterior na hora dele (MSG73). Cidade a oeste de Brasília
# fecha às 23:00 locais; a de Brasília segue até 23:59.
RSpec.describe Bnafar::Window, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:zone) { "America/Sao_Paulo" }
  let!(:city) do
    # O fuso da cidade nasce com ela (trigger de imutabilidade): a linha é criada
    # antes do helper, que reaproveita a existente.
    City.create!(slug: TEST_CITY_A.slug, name: TEST_CITY_A.name, status: "active", time_zone: zone,
                 database_url: TEST_CITY_A.database_url, encryption_key: TEST_CITY_A.encryption_key,
                 schema_version: CitySchema.expected_version.to_s)
    pharmacy_city!
  end
  # Dentro de CityConnection.with o Time.zone é o da cidade; aqui a cidade nasce
  # no let!, depois do bloco do runner, então o fuso entra à mão.
  before do
    @previous_zone = Time.zone
    Time.zone = city.time_zone
  end
  after { Time.zone = @previous_zone }
  let(:admin) { pharmacy_admin! }
  let(:reference_on) { Date.new(2026, 11, 20) }
  let!(:submission) do
    BnafarSubmission.create!(reference_on: reference_on, subject: "position", environment: "production", status: "queued")
  end

  def at(hour, min = 0, day: reference_on + 1) = day.in_time_zone.change(hour: hour, min: min)
  def retry_at(time) = travel_to(time) { Bnafar::RetrySubmission.call(submission: submission, by: admin, today: Time.zone.today, domains: []) }

  def unsent_part!
    BnafarBatch.create!(bnafar_submission: submission, operation: "post", status: "queued")
  end

  shared_examples "fechamento no fuso da cidade" do |closing_hour|
    it "R+1 às #{closing_hour - 1}:30 locais o reenvio segue aberto; às #{closing_hour}:30 → retry_window_closed" do
      expect(retry_at(at(closing_hour - 1, 30)).reason).to eq(:nothing_to_retry)
      expect(retry_at(at(closing_hour, 30)).reason).to eq(:retry_window_closed)
    end

    it "close! às #{closing_hour}:10 locais de R+1 perde a parte não enviada; uma hora antes, não" do
      unsent_part!
      travel_to(at(closing_hour - 1, 50)) { expect(described_class.close!(today: Time.zone.today)).to be_empty }
      expect(submission.reload.status).to eq("queued")

      travel_to(at(closing_hour, 10)) { expect(described_class.close!(today: Time.zone.today)).to eq([ submission.id ]) }
      expect(submission.reload.status).to eq("lost")
    end

    it "Q31: parte em processamento nunca vira lost pelo close!; a parte na fila é varrida" do
      inflight = BnafarBatch.create!(bnafar_submission: submission, operation: "post", status: "processing", protocol: 9)
      queued = unsent_part!
      travel_to(at(closing_hour, 10)) { expect(described_class.close!(today: Time.zone.today)).to be_empty }
      expect(submission.reload.status).to eq("queued")
      expect(inflight.reload.status).to eq("processing")
      expect(queued.reload).to have_attributes(status: "failed", last_error: "window_closed")
    end
  end

  context "cidade em Brasília (America/Sao_Paulo)" do
    it "o reenvio vai até 23:59 locais de R+1" do
      expect(retry_at(at(23, 30)).reason).to eq(:nothing_to_retry)
      expect(retry_at(at(0, 5, day: reference_on + 2)).reason).to eq(:retry_window_closed)
    end

    it "close! às 23:10 de R+1 não perde; às 00:10 de R+2, sim" do
      unsent_part!
      travel_to(at(23, 10)) { expect(described_class.close!(today: Time.zone.today)).to be_empty }
      travel_to(at(0, 10, day: reference_on + 2)) { expect(described_class.close!(today: Time.zone.today)).to eq([ submission.id ]) }
    end
  end

  context "cidade em America/Manaus (-04:00)" do
    let(:zone) { "America/Manaus" }

    it "o prazo é 23:00 locais (fim de R+1 em Brasília)" do
      expect(described_class.retry_until(submission).utc.iso8601).to eq("2026-11-22T02:59:59Z")
    end

    include_examples "fechamento no fuso da cidade", 23
  end

  context "cidade em America/Rio_Branco (-05:00)" do
    let(:zone) { "America/Rio_Branco" }

    include_examples "fechamento no fuso da cidade", 22
  end
end
