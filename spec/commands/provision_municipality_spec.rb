require "rails_helper"

RSpec.describe ProvisionMunicipality do
  # `city` is already registered and servable in the platform catalog (no DB
  # creation here — that is Plan 4's two-phase provisioning). TEST_CITY_B's
  # database exists (rails city:test_databases) but has no City row of its own
  # yet, so it is free for this command to provision resources into.
  let!(:city) do
    create(:city, slug: TEST_CITY_B.slug, status: "active",
                  database_url: city_database_url("rota_saude_test_city_b"))
  end

  # invited_by must be a User OF THAT CITY: invitations.invited_by_id is an FK
  # to the city database's own users table (D13).
  let!(:invited_by) { CityConnection.with(city) { User.create!(email_address: "seed@cidade-teste.gov.br", password: "secret123") } }

  let(:args) do
    {
      city: city, ibge_code: "3550308",
      channel: { phone_number_id: "PN1", waba_id: "WABA1", display_phone_number: "+5511", access_token: "tok" },
      admin_email: "admin@cidade.gov.br", invited_by: invited_by,
      terms: { version: "v1", body: "Termo..." },
      alert: [{ channel: "email", destination: "ops@cidade.gov.br", escalation_order: 0 }]
    }
  end

  it "cria o canal na plataforma + convite/termos/alerta atomicamente no banco da cidade" do
    res = described_class.call(**args)
    expect(res.ok?).to be true
    expect(res.payload[:city]).to eq(city)

    expect(CityChannel.where(city: city).count).to eq(1)

    CityConnection.with(city) do
      expect(Invitation.where(email: "admin@cidade.gov.br", role: "municipal_admin").count).to eq(1)
      expect(ConsentTerm.where(version: "v1").count).to eq(1)
      expect(AlertRecipient.where(destination: "ops@cidade.gov.br").count).to eq(1)
    end
  end

  it "emite Platform.audit municipality.provisioned (platform-scope), sem dado pessoal" do
    expect(Platform).to receive(:audit)
      .with("municipality.provisioned", hash_including(city_id: city.id, ibge_code: "3550308", by: invited_by.id))
      .and_call_original
    res = described_class.call(**args)
    expect(res.ok?).to be true

    event = PlatformEvent.find_by!(name: "municipality.provisioned")
    expect(event.payload).to include("city_id" => city.id, "ibge_code" => "3550308", "by" => invited_by.id)
    # Tight, not just "includes": the payload carries exactly these 3 keys —
    # no email/name/other personal data ever rides along (Ruling R18).
    expect(event.payload.keys).to contain_exactly("city_id", "ibge_code", "by")
  end

  it "refuses a non-servable city and writes nothing, on the platform or in the city" do
    # ProvisionMunicipality.call checks `city.servable?` (status == "active")
    # before touching anything — no CityChannel, no CityConnection.with, no
    # transaction. A "provisioning" city (City::STATUSES) is the realistic case:
    # the database exists but Plan 4's two-phase provisioning hasn't flipped it
    # active yet.
    non_servable = create(:city, slug: "provisioning-#{SecureRandom.hex(3)}", status: "provisioning",
                                  database_url: city_database_url("rota_saude_test_city_b"))

    result = nil
    expect { result = described_class.call(**args.merge(city: non_servable)) }
      .not_to change(PlatformEvent, :count)

    expect(result.failure?).to be(true)
    expect(result.reason).to eq(:city_not_servable)
    expect(CityChannel.where(city: non_servable).count).to eq(0)
    CityConnection.with(non_servable) do
      expect(Invitation.where(email: "admin@cidade.gov.br").count).to eq(0)
      expect(ConsentTerm.where(version: "v1").count).to eq(0)
    end
  end
end
