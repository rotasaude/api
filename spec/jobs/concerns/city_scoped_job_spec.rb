require "rails_helper"

# Task 5a fix round 1, achado #3: with_city precisa falhar fechado para uma
# cidade que existe mas não está servível (provisioning/suspended/archived) —
# City.find_by(slug:) sozinho não filtra por status, e CityConnection.with não
# checa. Uma cidade suspensa (primeiro passo de um offboarding) não pode
# continuar rodando jobs contra o próprio banco.
RSpec.describe CityScopedJob do
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
end
