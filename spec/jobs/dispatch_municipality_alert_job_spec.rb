require "rails_helper"

RSpec.describe DispatchMunicipalityAlertJob, type: :job do
  include ActiveJob::TestHelper

  # Mesmo slug/database_url de TEST_CITY_A: with_city(city.slug) reentra o
  # shard que o harness já tem aberto (ver anonymize_revoked_triage_job_spec.rb).
  let!(:city) do
    create(:city, slug: TEST_CITY_A.slug, status: "active", database_url: city_database_url("rota_saude_test_city_a"))
  end

  let(:triage_id) { SecureRandom.uuid }
  let(:args) { { city_slug: city.slug, triage_id: triage_id, tier: "alta", priority: 1, occurred_at: Time.current.iso8601 } }

  def create_recipient!
    CityConnection.with(city) do
      AlertRecipient.create!(channel: "email", destination: "secretaria@cidade.gov.br",
                             active: true, escalation_order: 1)
    end
  end

  def dedup_row_exists?
    CityConnection.with(city) { ProcessedEvent.exists?(consumer: "dispatch_alert", event_id: "alert:#{triage_id}") }
  end

  it "entrega o alerta de verdade (template real, B1) e cria o dedup row" do
    create_recipient!
    deliveries_before = ActionMailer::Base.deliveries.count

    described_class.perform_now(**args)

    expect(ActionMailer::Base.deliveries.count).to eq(deliveries_before + 1)
    expect(ActionMailer::Base.deliveries.last.to).to eq([ "secretaria@cidade.gov.br" ])
    expect(dedup_row_exists?).to be(true)
  end

  it "com o dedup row já existente, não entrega de novo" do
    create_recipient!
    CityConnection.with(city) do
      ProcessedEvent.create!(consumer: "dispatch_alert", event_id: "alert:#{triage_id}", processed_at: Time.current)
    end
    deliveries_before = ActionMailer::Base.deliveries.count

    described_class.perform_now(**args)

    expect(ActionMailer::Base.deliveries.count).to eq(deliveries_before)
  end

  it "sem AlertRecipient ativo de e-mail, levanta NoAlertRecipient e desfaz o dedup row" do
    expect {
      described_class.perform_now(**args)
    }.to raise_error(DispatchMunicipalityAlertJob::NoAlertRecipient)

    expect(dedup_row_exists?).to be(false)
  end

  # B2 (fix round 1): retry_on cobre erros transitórios de rede/SMTP. O
  # dedup row desfaz com a transação do with_city quando a entrega levanta
  # (comentário no topo da classe) -- o retry reentrega em vez de pular.
  it "erro transitório de entrega (Net::ReadTimeout) é retentado, e o dedup row é desfeito" do
    create_recipient!
    delivery = instance_double(ActionMailer::MessageDelivery)
    allow(AlertMailer).to receive(:urgent).and_return(delivery)
    allow(delivery).to receive(:deliver_now).and_raise(Net::ReadTimeout)

    # perform_now roda o callback chain do ActiveJob (retry_on incluso); só
    # chamar #perform direto no objeto puxaria a exceção sem o retry_on nunca
    # entrar em ação.
    expect {
      described_class.perform_now(**args)
    }.to have_enqueued_job(described_class)

    expect(dedup_row_exists?).to be(false)
  end

  it "erro fatal de SMTP (Net::SMTPFatalError) NÃO é retentado -- falha visível" do
    create_recipient!
    delivery = instance_double(ActionMailer::MessageDelivery)
    allow(AlertMailer).to receive(:urgent).and_return(delivery)
    allow(delivery).to receive(:deliver_now).and_raise(Net::SMTPFatalError, "550 mailbox unavailable")

    expect {
      described_class.perform_now(**args)
    }.to raise_error(Net::SMTPFatalError)

    expect(dedup_row_exists?).to be(false)
  end
end
