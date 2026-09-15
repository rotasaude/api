require "rails_helper"

# Task 5a fix round 1, achado #3: with_city precisa falhar fechado para uma
# cidade que existe mas não está servível (provisioning/suspended/archived) —
# City.find_by(slug:) sozinho não filtra por status, e CityConnection.with não
# checa. Uma cidade suspensa (primeiro passo de um offboarding) não pode
# continuar rodando jobs contra o próprio banco.
RSpec.describe CityScopedJob do
  include ActiveJob::TestHelper

  let(:job_class) do
    Class.new(ApplicationJob) do
      include CityScopedJob
      class << self; attr_accessor :ran; end

      def perform(slug)
        with_city(slug) { self.class.ran = true }
      end
    end
  end

  before { job_class.ran = false }

  # Ported from the retired spec/jobs/concerns/tenant_scoped_job_spec.rb
  # ("seta SET LOCAL dentro do bloco"): the positive half of the wrapper — the
  # block runs scoped to the job's city. Under per-city databases, "scoped" is
  # the city's own connection plus Current.city, not a GUC.
  it "runs the block on the city's database, with Current.city set" do
    city = create(:city, slug: TEST_CITY_B.slug, status: "active",
                         database_url: city_database_url("rota_saude_test_city_b"))
    seen = {}
    probe = Class.new(ApplicationJob) do
      include CityScopedJob

      define_method(:perform) do |slug|
        with_city(slug) do
          seen[:database] = CityRecord.connection_db_config.database
          seen[:city] = Current.city&.slug
        end
      end
    end

    probe.new.perform(city.slug)

    expect(seen).to eq(database: "rota_saude_test_city_b", city: TEST_CITY_B.slug)
  end

  it "raises CityMissing for a blank slug, without running the block" do
    expect { job_class.new.perform(nil) }.to raise_error(CityScopedJob::CityMissing)
    expect(job_class.ran).to be false
  end

  it "raises CityMissing when no city has that slug, without running the block" do
    expect { job_class.new.perform("cidade-inexistente-#{SecureRandom.hex(4)}") }
      .to raise_error(CityScopedJob::CityMissing)
    expect(job_class.ran).to be false
  end

  it "raises CityNotServable for a suspended city, without running the block" do
    suspended = create(:city, status: "suspended")

    expect { job_class.new.perform(suspended.slug) }.to raise_error(CityScopedJob::CityNotServable)
    expect(job_class.ran).to be false
  end

  it "raises CityNotServable (not CityMissing) for a city still provisioning, so the two failure modes stay distinguishable" do
    provisioning = create(:city, status: "provisioning")

    expect { job_class.new.perform(provisioning.slug) }.to raise_error(CityScopedJob::CityNotServable)
    expect(job_class.ran).to be false
  end

  describe "schema atrasado e cidade do worker (Plano 5)" do
    after { CityWorkers::Context.city_slug = nil }

    it "raises CitySchemaBehind for a city whose schema is behind, without running the block" do
      city = create(:city, slug: "atrasadajob", status: "active", schema_version: nil,
                           database_url: city_database_url("rota_saude_test_city_b"))

      expect { job_class.new.perform(city.slug) }.to raise_error(CityScopedJob::CitySchemaBehind)
      expect(job_class.ran).to be false
    end

    it "reschedules the job instead of failing it when the city's schema is behind" do
      city = create(:city, slug: "atrasadaretry", status: "active", schema_version: nil,
                           database_url: city_database_url("rota_saude_test_city_b"))

      expect { job_class.perform_now(city.slug) }.to have_enqueued_job(job_class).with(city.slug)
      expect(job_class.ran).to be false
    end

    it "raises CityMismatch for a job of another city than this worker's, without running the block" do
      city = create(:city, slug: "outracidade", status: "active", database_url: city_database_url("rota_saude_test_city_b"))
      CityWorkers::Context.city_slug = "curitiba"

      expect { job_class.new.perform(city.slug) }.to raise_error(CityScopedJob::CityMismatch)
      expect(job_class.ran).to be false
    end

    it "runs a job of the worker's own city" do
      city = create(:city, slug: "propriacidade", status: "active", database_url: city_database_url("rota_saude_test_city_b"))
      CityWorkers::Context.city_slug = city.slug

      job_class.new.perform(city.slug)

      expect(job_class.ran).to be true
    end
  end
end
