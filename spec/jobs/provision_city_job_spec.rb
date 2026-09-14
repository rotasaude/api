require "rails_helper"

# Fase 2 do provisionamento (spec banco-por-cidade §4, Plano 4), contra bancos e
# roles DE VERDADE. A migração roda em processo aqui (a suíte não tem threads do
# Solid Queue); o subprocesso usado no worker é provado em
# city_migrations_subprocess_spec.rb.
RSpec.describe ProvisionCityJob, type: :job do
  self.use_transactional_tests = false

  let(:slug) { "prov#{SecureRandom.hex(4)}" }
  let(:operator_id) { SecureRandom.uuid }
  let(:args) do
    { ibge_code: "4113700", admin_email: "Prefeita@Cidade.gov.br", alert_email: "alertas@cidade.gov.br",
      operator_id: operator_id }
  end
  let!(:city) do
    City.create!(slug: slug, name: "Cidade Nova", uf: "PR", status: "provisioning",
                 database_url: CityDatabase.url_for(slug: slug, password: SecureRandom.hex(24)),
                 encryption_key: SecureRandom.hex(32))
  end

  around do |example|
    migrator_was = described_class.migrator
    described_class.migrator = ->(c) { CityMigrations.run(c) }
    example.run
  ensure
    described_class.migrator = migrator_was
  end

  before { allow(InvitationMailer).to receive(:invite).and_call_original }

  after { cleanup_provisioned_city!(city) }

  def provisioned_events
    PlatformEvent.where(name: "municipality.provisioned").where("payload->>'city_id' = ?", city.id)
  end

  it "creates database and role, migrates, seeds the city, activates it and audits once" do
    described_class.perform_now(city_id: city.id, **args)

    city.reload
    expect(city.status).to eq("active")
    expect(city.schema_version).to eq(CitySchema.expected_version.to_s)
    expect(URI.parse(city.database_url).user).to eq(CityDatabase.role_name(slug))

    CityConnection.with(city) do
      expect(CityProfile.current).to have_attributes(name: "Cidade Nova", uf: "PR", ibge_code: "4113700")
      expect(AlertRecipient.pluck(:channel, :destination, :active)).to eq([ [ "email", "alertas@cidade.gov.br", true ] ])
      expect(ProtocolDefinition.pluck(:name, :status)).to eq([ %w[triage-respiratoria draft] ])
      expect(Invitation.pluck(:email, :role, :invited_by_id)).to eq([ [ "prefeita@cidade.gov.br", "municipal_admin", nil ] ])
      expect(ConsentTerm.count).to eq(0)
    end

    expect(provisioned_events.count).to eq(1)
    expect(provisioned_events.first.payload.keys).to contain_exactly("city_id", "ibge_code", "by")
    expect(provisioned_events.first.payload).to include("ibge_code" => "4113700", "by" => operator_id)
  end

  it "e-mails the invitation link to the first admin" do
    described_class.perform_now(city_id: city.id, **args)

    token = CityConnection.with(city) { Invitation.sole.token }
    expect(InvitationMailer).to have_received(:invite)
      .with(email_address: "Prefeita@Cidade.gov.br", accept_url: CityDashboardUrl.invitation(city, token: token)).once
  end

  it "stays provisioning after a failure and resumes without duplicating anything" do
    described_class.migrator = ->(_c) { raise "migração caiu" }
    described_class.perform_now(city_id: city.id, **args) # retry_on engole e reagenda

    expect(city.reload.status).to eq("provisioning")
    expect(CityDatabase.exists?(slug: slug)).to be(true)

    described_class.migrator = ->(c) { CityMigrations.run(c) }
    2.times { described_class.perform_now(city_id: city.id, **args) }

    expect(city.reload.status).to eq("active")
    CityConnection.with(city) do
      expect([ CityProfile.count, AlertRecipient.count, ProtocolDefinition.count, Invitation.count ]).to eq([ 1, 1, 1, 1 ])
    end
    expect(provisioned_events.count).to eq(1)
    expect(InvitationMailer).to have_received(:invite).once
  end

  it "does not e-mail the invitation twice when activation fails after seeding" do
    allow(Platform).to receive(:audit).and_raise(ActiveRecord::StatementInvalid, "plataforma caiu")
    described_class.perform_now(city_id: city.id, **args)

    expect(city.reload.status).to eq("provisioning")
    expect(InvitationMailer).to have_received(:invite).once

    allow(Platform).to receive(:audit).and_call_original
    described_class.perform_now(city_id: city.id, **args)

    expect(city.reload.status).to eq("active")
    expect(InvitationMailer).to have_received(:invite).once
    CityConnection.with(city) { expect(Invitation.count).to eq(1) }
  end

  it "ignores a city that is not provisioning, and an unknown id" do
    city.update!(status: "suspended")
    expect(CityDatabase).not_to receive(:ensure!)

    described_class.perform_now(city_id: city.id, **args)
    described_class.perform_now(city_id: SecureRandom.uuid, **args)

    expect(city.reload.status).to eq("suspended")
  end
end
