require "rails_helper"

# Fase 1 do provisionamento em duas fases (spec banco-por-cidade §4, Plano 4): só
# registra no catálogo e enfileira. Quem cria banco é o worker (ProvisionCityJob).
RSpec.describe ProvisionCity do
  include ActiveJob::TestHelper

  let(:operator) do
    Operator.create!(email_address: "op-#{SecureRandom.hex(3)}@rotasaude.app", password: "s3nha-forte-1",
                     otp_secret: ROTP::Base32.random, otp_enabled: true)
  end
  let(:args) do
    { slug: "novacidade", name: "Nova Cidade", uf: "PR", ibge_code: "4113700",
      admin_email: "prefeita@novacidade.gov.br", alert_email: "alertas@novacidade.gov.br", by: operator }
  end

  it "registers the city as provisioning, with its own role and database, and enqueues phase two" do
    result = nil
    expect { result = described_class.call(**args) }.to have_enqueued_job(ProvisionCityJob).with(
      city_id: kind_of(String), ibge_code: "4113700", admin_email: "prefeita@novacidade.gov.br",
      alert_email: "alertas@novacidade.gov.br", operator_id: operator.id
    )

    expect(result.ok?).to be(true)
    city = result.payload[:city]
    expect(city).to have_attributes(slug: "novacidade", name: "Nova Cidade", uf: "PR", status: "provisioning",
                                    schema_version: nil)
    url = URI.parse(city.database_url)
    expect([ url.user, url.path ]).to eq([ "rota_test_city_novacidade", "/rota_saude_test_city_novacidade" ])
    expect(url.password).to match(/\A\h{48}\z/)
  end

  it "re-enqueues phase two for a city still provisioning, without a second catalog row or a new password" do
    first = described_class.call(**args).payload[:city]
    original_url = first.database_url

    expect { described_class.call(**args) }
      .to have_enqueued_job(ProvisionCityJob).with(hash_including(city_id: first.id))
    expect(City.where(slug: "novacidade").pluck(:id)).to eq([ first.id ])
    expect(first.reload.database_url).to eq(original_url)
  end

  it "refuses a slug that belongs to a city past provisioning, enqueuing nothing" do
    create(:city, slug: "novacidade", status: "active")

    result = nil
    expect { result = described_class.call(**args) }.not_to have_enqueued_job(ProvisionCityJob)
    expect(result.reason).to eq(:city_exists)
  end

  {
    slug: [ "x" * 41, "admin", "Maiuscula", %w[lista], nil ],
    name: [ "", %w[lista], nil ],
    uf: [ "pr", "PRX", nil ],
    ibge_code: [ "123", "41137000", nil ],
    admin_email: [ "nao-e-email", [ "a@b.co" ], nil ],
    alert_email: [ "nao-e-email", nil ]
  }.each do |field, bad_values|
    bad_values.each do |bad|
      it "refuses #{field}=#{bad.inspect.truncate(20)} without touching the catalog or the queue" do
        result = nil
        expect { result = described_class.call(**args.merge(field => bad)) }.not_to have_enqueued_job
        expect(result.reason).to eq(:invalid)
        expect(City.count).to eq(City.where(slug: TEST_CITY_A.slug).count)
      end
    end
  end
end
