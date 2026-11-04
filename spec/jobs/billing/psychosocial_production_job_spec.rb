require "rails_helper"

# Consumidor de psychosocial.action_recorded (ADR 0049; contrato §8): a ação
# BPA-C/BPA-I vira linha do BPA (Billing::FromPsychosocial, idempotente por
# ação) só com procedure_billing ligado no momento do evento.
RSpec.describe Billing::PsychosocialProductionJob, type: :job do
  let!(:city) { psychosocial_city!(billing: true) }
  let(:caps) { caps! }
  let(:staff) { caps_staff!(caps, cbo: "251510") }

  def args(action, event_id: SecureRandom.uuid)
    { event_id: event_id, event_name: "psychosocial.action_recorded", city_slug: Current.city.slug, payload: { "action_id" => action.id } }
  end

  it "o evento da ação está ligado ao consumidor; o cancelamento não tem consumidor" do
    expect(DomainEvents.registry["psychosocial.action_recorded"].map(&:job)).to eq([ "Billing::PsychosocialProductionJob" ])
    expect(DomainEvents.registry["psychosocial.action_cancelled"]).to be_empty
  end

  it "grava uma vez, mesmo reprocessado (mesmo evento ou outro)" do
    action = record_action!(caps, staff, sigtap_code: "0301080313")
    payload = args(action)
    described_class.new.perform(**payload)
    described_class.new.perform(**payload)
    described_class.new.perform(**args(action))
    expect(ProcessedEvent.where(event_id: payload[:event_id], consumer: "Billing::PsychosocialProductionJob").count).to eq(1)
    expect(PerformedProcedure.where(psychosocial_action_id: action.id).count).to eq(1)
  end

  it "com o portão do BPA desligado no momento do evento, nada" do
    action = record_action!(caps, staff, sigtap_code: "0301080313")
    Platform::Features.set!(city: Current.city, key: "procedure_billing", enabled: false, maintainer: ledi_maintainer!)
    described_class.new.perform(**args(action))
    expect(PerformedProcedure.where(psychosocial_action_id: action.id)).to be_empty
  end
end
