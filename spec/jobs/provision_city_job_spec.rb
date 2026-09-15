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
    on_platform_queue { described_class.perform_now(city_id: city.id, **args) }

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
    on_platform_queue { described_class.perform_now(city_id: city.id, **args) }

    token = CityConnection.with(city) { Invitation.sole.token }
    expect(InvitationMailer).to have_received(:invite)
      .with(email_address: "Prefeita@Cidade.gov.br", accept_url: CityDashboardUrl.invitation(city, token: token)).once
  end

  it "stays provisioning after a failure and resumes without duplicating anything" do
    described_class.migrator = ->(_c) { raise "migração caiu" }
    on_platform_queue { described_class.perform_now(city_id: city.id, **args) } # retry_on engole e reagenda

    expect(city.reload.status).to eq("provisioning")
    expect(CityDatabase.exists?(slug: slug)).to be(true)

    described_class.migrator = ->(c) { CityMigrations.run(c) }
    2.times { on_platform_queue { described_class.perform_now(city_id: city.id, **args) } }

    expect(city.reload.status).to eq("active")
    CityConnection.with(city) do
      expect([ CityProfile.count, AlertRecipient.count, ProtocolDefinition.count, Invitation.count ]).to eq([ 1, 1, 1, 1 ])
    end
    expect(provisioned_events.count).to eq(1)
    expect(InvitationMailer).to have_received(:invite).once
  end

  it "re-sends the same invitation link when activation fails after seeding, and stops once the city is active" do
    allow(Platform).to receive(:audit).and_raise(ActiveRecord::StatementInvalid, "plataforma caiu")
    on_platform_queue { described_class.perform_now(city_id: city.id, **args) }

    expect(city.reload.status).to eq("provisioning")
    expect(InvitationMailer).to have_received(:invite).once

    allow(Platform).to receive(:audit).and_call_original
    2.times { on_platform_queue { described_class.perform_now(city_id: city.id, **args) } }

    expect(city.reload.status).to eq("active")
    token = CityConnection.with(city) { Invitation.sole.token }
    expect(InvitationMailer).to have_received(:invite)
      .with(email_address: "Prefeita@Cidade.gov.br", accept_url: CityDashboardUrl.invitation(city, token: token))
      .twice
    CityConnection.with(city) { expect(Invitation.count).to eq(1) }
  end

  it "does not lose the invitation when enqueuing the e-mail fails" do
    call_count = 0
    allow(InvitationMailer).to receive(:invite).and_wrap_original do |original, **kwargs|
      call_count += 1
      raise ActiveRecord::StatementInvalid, "fila caiu" if call_count == 1

      original.call(**kwargs)
    end

    on_platform_queue { described_class.perform_now(city_id: city.id, **args) }
    expect(city.reload.status).to eq("provisioning")

    on_platform_queue { described_class.perform_now(city_id: city.id, **args) }

    expect(city.reload.status).to eq("active")
    token = CityConnection.with(city) { Invitation.sole.token }
    CityConnection.with(city) { expect(Invitation.count).to eq(1) }
    expect(InvitationMailer).to have_received(:invite)
      .with(email_address: "Prefeita@Cidade.gov.br", accept_url: CityDashboardUrl.invitation(city, token: token))
      .at_least(:once)
  end

  it "invites the first admin again when the earlier invitation expired, e-mailing the new token" do
    on_platform_queue { described_class.perform_now(city_id: city.id, **args) }
    first_token = CityConnection.with(city) do
      Invitation.sole.tap { |inv| inv.update_columns(expires_at: 1.minute.ago) }.token
    end
    city.update_columns(status: "provisioning")

    on_platform_queue { described_class.perform_now(city_id: city.id, **args) }

    new_token = CityConnection.with(city) do
      expect(Invitation.count).to eq(2)
      Invitation.pending.sole.token
    end
    expect(new_token).not_to eq(first_token)
    expect(InvitationMailer).to have_received(:invite)
      .with(email_address: "Prefeita@Cidade.gov.br", accept_url: CityDashboardUrl.invitation(city, token: new_token)).once
    expect(InvitationMailer).to have_received(:invite).twice
  end

  it "keeps Current.city set for the whole seed step, not just inside InviteAdmin (M3, hardening review)" do
    observed = []
    allow(CityProfile).to receive(:exists?).and_wrap_original do |original, *a|
      observed << Current.city
      original.call(*a)
    end
    allow(AlertRecipient).to receive(:exists?).and_wrap_original do |original, *a|
      observed << Current.city
      original.call(*a)
    end

    on_platform_queue { described_class.perform_now(city_id: city.id, **args) }

    expect(observed).not_to be_empty
    expect(observed).to all(eq(city))
  end

  it "ignores a city that is not provisioning, and an unknown id" do
    city.update!(status: "suspended")
    expect(CityDatabase).not_to receive(:ensure!)

    on_platform_queue { described_class.perform_now(city_id: city.id, **args) }
    on_platform_queue { described_class.perform_now(city_id: SecureRandom.uuid, **args) }

    expect(city.reload.status).to eq("suspended")
  end
end
