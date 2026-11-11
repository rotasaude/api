require "rails_helper"

# Módulo 33, Task 7 (ADR 0051; contrato §9; Q15): o aviso da ouvidoria nasce
# sem texto, só o tipo; o SMS é o texto fixo, sem protocolo, só na janela
# 8h–20h (fora dela não sai nem é reagendado), com opt-in e sem notices_muted.
RSpec.describe Ombudsman::Notify do
  include ActiveSupport::Testing::TimeHelpers

  before { SmsGateway::Test.reset! }
  after { SmsGateway::Test.reset! }
  after { travel_back }

  let!(:city) { ombudsman_city! }
  let(:citizen) { web_citizen! }
  let(:manifestation) { manifestation!(citizen: citizen) }

  def sms_on! = (CityProfile.current || CityProfile.create!(name: "Curitiba")).update!(campaigns_sms_enabled: true)
  def prefs!(opt_in: true, **over) = CitizenContactPreference.create!(citizen_id: citizen.id, sms_opt_in: opt_in, **over)
  def bodies = SmsGateway::Test.deliveries.map { |d| d[:body] }
  def notify(at: Time.zone.local(2026, 11, 11, 10, 0), kind: "final_response")
    travel_to(at)
    described_class.call(manifestation: manifestation, kind: kind)
  end

  it "grava o aviso só com o tipo e devolve true" do
    expect(notify(kind: "interim_response")).to be(true)
    notice = OmbudsmanNotice.sole
    expect(notice).to have_attributes(citizen_id: citizen.id, ombudsman_manifestation_id: manifestation.id,
                                      kind: "interim_response", read_at: nil)
    expect(OmbudsmanNotice.column_names).not_to include("body", "text")
  end

  it "sem citizen_id devolve false e não grava nada" do
    anonymous = manifestation!(identification_mode: "anonymous", kind: "report", citizen: nil)
    expect(described_class.call(manifestation: anonymous, kind: "final_response")).to be(false)
    expect(OmbudsmanNotice.count).to eq(0)
  end

  it "tipo fora de NOTICE_KINDS é ArgumentError" do
    expect { described_class.call(manifestation: manifestation, kind: "nope") }.to raise_error(ArgumentError)
    expect(OmbudsmanNotice.count).to eq(0)
  end

  it "o SMS sai às 10h com opt-in e é exatamente o texto fixo, sem protocolo" do
    sms_on!
    prefs!
    notify
    expect(bodies).to eq([ Ombudsman::Catalog::SMS_TEXT ])
    expect(bodies.first).not_to include(manifestation.protocol)
  end

  it "às 21h grava o aviso mas não envia nem reagenda" do
    sms_on!
    prefs!
    expect { notify(at: Time.zone.local(2026, 11, 11, 21, 0)) }.not_to have_enqueued_job
    expect(OmbudsmanNotice.count).to eq(1)
    expect(bodies).to be_empty
  end

  it "com notices_muted o SMS não sai, mas o aviso nasce" do
    sms_on!
    prefs!(notices_muted: true)
    expect(notify).to be(true)
    expect(bodies).to be_empty
    expect(OmbudsmanNotice.count).to eq(1)
  end

  it "appointment_reminders_muted não vale aqui (A17): o SMS sai" do
    sms_on!
    prefs!(appointment_reminders_muted: true)
    notify
    expect(bodies.size).to eq(1)
  end

  it "sem opt-in ou com a chave de SMS da cidade desligada, não envia" do
    prefs!(opt_in: false)
    sms_on!
    notify
    expect(bodies).to be_empty

    CitizenContactPreference.where(citizen_id: citizen.id).update_all(sms_opt_in: true)
    CityProfile.current.update!(campaigns_sms_enabled: false)
    notify
    expect(bodies).to be_empty
  end

  it "falha do provedor não derruba o aviso e o log leva só a classe" do
    sms_on!
    prefs!
    allow(SmsGateway).to receive(:deliver).and_raise(RuntimeError, "boom #{manifestation.protocol}")
    allow(Rails.logger).to receive(:warn)
    expect(notify).to be(true)
    expect(OmbudsmanNotice.count).to eq(1)
    expect(Rails.logger).to have_received(:warn).with(satisfy { |m| m.include?("RuntimeError") && !m.include?(manifestation.protocol) })
  end
end
