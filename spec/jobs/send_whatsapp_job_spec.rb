require "rails_helper"

RSpec.describe SendWhatsappJob do
  # Same slug/database_url as TEST_CITY_A so the job's with_city(city_slug)
  # re-enters the shard the harness already has open — OutboundMessage is then
  # readable via the default connection below without a second
  # CityConnection.with.
  let!(:city) do
    create(:city, slug: TEST_CITY_A.slug, status: "active", database_url: city_database_url("rota_saude_test_city_a"))
  end
  let!(:channel) do
    CityChannel.create!(city: city, phone_number_id: "PNID", waba_id: "WABA",
                        display_phone_number: "+551199", access_token: "tok", active: true)
  end
  # Fix round 1 (M1): a second, active CityChannel belonging to a DIFFERENT
  # city — so a job that resolved its channel without actually scoping by
  # the current city (e.g. "any active channel") would pick the wrong one
  # instead of vacuously passing because only one channel existed.
  let!(:other_channel) do
    other_city = create(:city, database_url: city_database_url("rota_saude_test_city_b"))
    CityChannel.create!(city: other_city, phone_number_id: "PNID-OTHER", waba_id: "WABA-OTHER",
                        display_phone_number: "+551188", access_token: "tok2", active: true)
  end

  def text_msg(body) = Messaging::Reply.text(body).to_h

  before do
    allow(Whatsapp::SessionWindow).to receive(:open?).and_return(true)
  end

  it "usa o CityChannel da cidade corrente (a conexão escopa, não uma FK manual)" do
    deliver_result = Whatsapp::Outbound::Result.new(status: 200, body: '{"ok":true}')
    outbound = instance_double(Whatsapp::Outbound, deliver_text: deliver_result)
    expect(Whatsapp::Outbound).to receive(:new).with(channel).and_return(outbound)
    described_class.new.perform(to: "+5511988", message: text_msg("ola"), city_slug: city.slug)
    om = OutboundMessage.last
    expect(om.to).to eq("+5511988")
    expect(om.status).to eq(200)
  end

  it "dedup contra crash-retry: 2ª chamada idêntica não bate HTTP" do
    deliver_result = Whatsapp::Outbound::Result.new(status: 200, body: "ok")
    outbound = instance_double(Whatsapp::Outbound, deliver_text: deliver_result)
    expect(Whatsapp::Outbound).to receive(:new).once.and_return(outbound)
    described_class.new.perform(to: "+551188", message: text_msg("ola"), city_slug: city.slug)
    described_class.new.perform(to: "+551188", message: text_msg("ola"), city_slug: city.slug)
    expect(OutboundMessage.where(to: "+551188").count).to eq(1)
  end

  it "despacha interativo quando o reply tem botões" do
    deliver_result = Whatsapp::Outbound::Result.new(status: 200, body: "ok")
    outbound = instance_double(Whatsapp::Outbound)
    expect(outbound).to receive(:deliver_interactive).and_return(deliver_result)
    expect(Whatsapp::Outbound).to receive(:new).and_return(outbound)
    msg = Messaging::Reply.buttons(body: "Tosse?", options: [{ id: "true", title: "Sim" }, { id: "false", title: "Não" }]).to_h
    described_class.new.perform(to: "+551177", message: msg, city_slug: city.slug)
    expect(OutboundMessage.where(to: "+551177").count).to eq(1)
  end

  # I1 (hardening review): same LogSubscriber gap fixed for CityMailDeliveryJob
  # (71c2f09) and ProvisionCityJob — ActiveJob logs "with arguments: ..." at
  # info level for any job whose log_arguments? is true (the default),
  # bypassing filter_parameters. SendWhatsappJob's arguments carry the
  # citizen's phone number (`to:`) and the message body (`message:`) straight
  # from NotifyCitizenJob.
  it "does not log the citizen's phone number or message text when enqueuing" do
    log_output = StringIO.new
    original_logger = ActiveJob::Base.logger
    ActiveJob::Base.logger = ActiveSupport::Logger.new(log_output)

    begin
      described_class.perform_later(
        to: "+5511999998888",
        message: text_msg("Sua triage (leve): https://example/s3cr3t-report"),
        city_slug: city.slug
      )
    ensure
      ActiveJob::Base.logger = original_logger
    end

    logged = log_output.string
    expect(logged).not_to include("+5511999998888")
    expect(logged).not_to include("s3cr3t-report")
  end

  it "levanta CityMissing sem city_slug" do
    expect {
      described_class.new.perform(to: "+5511988", message: text_msg("ola"), city_slug: nil)
    }.to raise_error(CityScopedJob::CityMissing)
  end

  describe "24h window guard" do
    let(:client) { instance_double(Whatsapp::Outbound) }

    before do
      allow(Whatsapp::Outbound).to receive(:new).and_return(client)
      allow(client).to receive(:deliver_text).and_return(Whatsapp::Outbound::Result.new(status: 200, body: "{}"))
      allow(client).to receive(:deliver_interactive).and_return(Whatsapp::Outbound::Result.new(status: 200, body: "{}"))
      allow(client).to receive(:deliver_template).and_return(Whatsapp::Outbound::Result.new(status: 200, body: "{}"))
    end

    it "sends a template message via deliver_template (any window state)" do
      allow(Whatsapp::SessionWindow).to receive(:open?).and_return(false)
      msg = Messaging::Reply.template(name: "rota_saude_ask").to_h
      described_class.new.perform(to: "5511999", message: msg, city_slug: city.slug)
      expect(client).to have_received(:deliver_template)
    end

    it "sends free-form text within the window" do
      allow(Whatsapp::SessionWindow).to receive(:open?).and_return(true)
      msg = Messaging::Reply.text("Olá").to_h
      described_class.new.perform(to: "5511999", message: msg, city_slug: city.slug)
      expect(client).to have_received(:deliver_text)
    end

    it "substitutes the resume template for free-form outside the window" do
      allow(Whatsapp::SessionWindow).to receive(:open?).and_return(false)
      msg = Messaging::Reply.text("Olá").to_h
      described_class.new.perform(to: "5511999", message: msg, city_slug: city.slug)
      expect(client).to have_received(:deliver_template) do |to:, reply:|
        expect(reply.name).to eq("rota_saude_resume")
      end
      expect(client).not_to have_received(:deliver_text)
    end
  end
end
