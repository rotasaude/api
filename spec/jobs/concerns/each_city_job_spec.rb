require "rails_helper"

# Plano 5: no worker de uma cidade, EachCityJob roda só nela (a tarefa recorrente
# mora na fila dela); fora de worker de cidade, em toda cidade ativa; nos dois
# casos pula cidade com schema atrasado (spec §4).
RSpec.describe EachCityJob do
  let(:job_class) do
    stub_const("EachCityProbeJob", Class.new(ApplicationJob) do
      prepend EachCityJob
      class << self; attr_accessor :visited; end

      def perform
        self.class.visited << [ Current.city.slug, CityRecord.connection_db_config.database ]
      end
    end)
  end

  let!(:city_a) { create(:city, slug: "cadaa#{SecureRandom.hex(3)}", database_url: city_database_url("rota_saude_test_city_a")) }
  let!(:city_b) { create(:city, slug: "cadab#{SecureRandom.hex(3)}", database_url: city_database_url("rota_saude_test_city_b")) }

  before { job_class.visited = [] }
  after { CityWorkers::Context.city_slug = nil }

  it "visits every active city outside a city worker" do
    job_class.new.perform

    expect(job_class.visited).to contain_exactly([ city_a.slug, "rota_saude_test_city_a" ],
                                                 [ city_b.slug, "rota_saude_test_city_b" ])
  end

  it "visits only the worker's own city inside a city worker" do
    CityWorkers::Context.city_slug = city_b.slug

    job_class.new.perform

    expect(job_class.visited).to eq([ [ city_b.slug, "rota_saude_test_city_b" ] ])
  end

  it "skips a city whose schema is behind" do
    city_b.update!(schema_version: nil)

    job_class.new.perform

    expect(job_class.visited).to eq([ [ city_a.slug, "rota_saude_test_city_a" ] ])
  end

  # Fix round 1, Minor: a city worker whose own slug matches no active city
  # (unknown slug, or the city is not active) must not silently fall back to
  # running every city — it should warn, naming the slug, and run nothing.
  it "warns and runs nothing when the worker's own city is not active" do
    CityWorkers::Context.city_slug = "cidade-nao-cadastrada"
    allow(Rails.logger).to receive(:warn)

    job_class.new.perform

    expect(job_class.visited).to eq([])
    expect(Rails.logger).to have_received(:warn).with(a_string_matching(/cidade-nao-cadastrada/))
  end

  # Bug de 2026-09-25: perform atribuía Current.city a cada cidade do laço e não
  # restaurava. Rodado inline (perform_now) num processo que já tinha cidade —
  # script de runner, console com ReencryptionJob.perform_now —, a cidade do
  # chamador virava a ÚLTIMA do laço, e a escrita seguinte saía cifrada com a
  # chave determinística dela dentro do banco da cidade do chamador.
  describe "caller's city context" do
    it "leaves Current.city as it was after running inline" do
      Current.set(city: city_a) do
        job_class.perform_now

        expect(Current.city).to eq(city_a)
      end
    end

    it "keeps a write right after the job readable with the caller's city key" do
      phone = "+5541999990#{rand(100..999)}"

      id = CityConnection.with(city_a) do
        job_class.perform_now
        Conversation.create!(phone: phone, state: :greeting).id
      end

      expect(job_class.visited.map(&:first)).to include(city_b.slug)
      expect(CityConnection.with(city_a) { Conversation.find(id).phone }).to eq(phone)
    end
  end
end
