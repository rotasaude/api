require "rails_helper"

# ADR 0029 §6 (spec §9 "lembrete"): véspera às 17h no fuso da cidade, só
# confirmados, idempotente; aviso sempre; SMS só com a chave da cidade, o
# provedor, o opt-in e sem o opt-out de lembretes; texto fixo, sem
# identificador. Falha do provedor não repete; erro de banco não é engolido.
RSpec.describe Appointments::RemindJob do
  include ActiveSupport::Testing::TimeHelpers
  before { Current.city = TEST_CITY_A; SmsGateway::Test.reset!; ensure_appointment_types! }
  after { SmsGateway::Test.reset!; Current.reset }

  let(:zone_name) { "America/Sao_Paulo" }
  let!(:city_record) { create(:city, slug: TEST_CITY_A.slug, database_url: TEST_CITY_A.database_url, time_zone: zone_name) }
  let(:zone) { ActiveSupport::TimeZone[zone_name] }
  let(:eve) { Time.zone.today + 3 }
  let(:unit) { create_unit }
  let(:shift) { shift!(doctor_link!(unit), starts_at: day_at(eve + 1, 8)) }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }

  def confirmed!(at = shift.starts_at, status: "confirmed", who: citizen, on: shift)
    appointment_row!(triage_request!(who, unit: unit), on, starts_at: at, status: status)
  end

  def day_at(day, hour, min = 0) = zone.local(day.year, day.month, day.day, hour, min)
  def at(hour, min = 0) = day_at(eve, hour, min)
  def run_at(time) = travel_to(time) { described_class.perform_now }
  def sms_on! = (CityProfile.current || CityProfile.create!(name: "Curitiba")).update!(campaigns_sms_enabled: true)
  def sms_off! = (CityProfile.current || CityProfile.create!(name: "Curitiba")).update!(campaigns_sms_enabled: false)
  def prefs!(who = citizen, opt_in: true, muted: false)
    CitizenContactPreference.create!(citizen_id: who.id, sms_opt_in: opt_in, appointment_reminders_muted: muted)
  end

  def reminded_payload = DomainEvent.where(name: "appointment.reminded").sole.payload

  def expect_notice_only(appointment)
    expect(SmsGateway::Test.deliveries).to be_empty
    expect(AppointmentNotice.where(appointment_id: appointment.id, citizen_id: appointment.citizen_id).count).to eq(1)
    expect(appointment.reload.reminded_at).to be_present
    expect(reminded_payload).to eq("appointment_id" => appointment.id, "sms" => false)
  end

  it "às 17h da véspera: aviso, SMS de texto fixo, reminded_at e evento; antes das 17h e na segunda rodada, nada" do
    sms_on!
    prefs!
    appointment = confirmed!
    run_at(at(16, 59))
    expect(AppointmentNotice.count).to eq(0)
    expect(appointment.reload.reminded_at).to be_nil

    run_at(at(17, 0))
    run_at(at(17, 15))
    expect(AppointmentNotice.where(appointment_id: appointment.id, citizen_id: citizen.id).count).to eq(1)
    expect(appointment.reload.reminded_at).to be_present
    expect(SmsGateway::Test.deliveries.size).to eq(1)
    expect(SmsGateway::Test.deliveries.first[:phone]).to eq(citizen.phone)
    body = SmsGateway::Test.deliveries.first[:body]
    expect(body).to eq("Secretaria de Saúde de Curitiba: você tem um compromisso de saúde amanhã. Veja em " \
                       "#{Campaigns::SmsText.link(TEST_CITY_A)}")
    expect(body).not_to include(unit.name, appointment.id)
    expect(reminded_payload).to eq("appointment_id" => appointment.id, "sms" => true)
  end

  describe "só o aviso, sem SMS" do
    it "sem opt-in" do
      sms_on!
      prefs!(opt_in: false)
      appointment = confirmed!
      run_at(at(17, 0))
      expect_notice_only(appointment)
    end

    it "sem preferência gravada (nunca deu opt-in)" do
      sms_on!
      appointment = confirmed!
      run_at(at(17, 0))
      expect_notice_only(appointment)
    end

    it "com opt-out de lembretes" do
      sms_on!
      prefs!(muted: true)
      appointment = confirmed!
      run_at(at(17, 0))
      expect_notice_only(appointment)
    end

    it "sem a chave de SMS da cidade" do
      sms_off!
      prefs!
      appointment = confirmed!
      run_at(at(17, 0))
      expect_notice_only(appointment)
    end

    it "sem provedor configurado" do
      sms_on!
      prefs!
      appointment = confirmed!
      with_sms_gateway(nil) { run_at(at(17, 0)) }
      expect_notice_only(appointment)
    end

    it "provedor que falha: não repete na rodada seguinte" do
      sms_on!
      prefs!
      appointment = confirmed!
      allow(SmsGateway).to receive(:deliver).and_raise(RuntimeError, "provider down +5541998765432")
      run_at(at(17, 0))
      run_at(at(17, 15))
      expect(SmsGateway).to have_received(:deliver).once
      expect_notice_only(appointment)
    end
  end

  it "erro de banco não é engolido: nada se grava" do
    sms_on!
    prefs!
    appointment = confirmed!
    allow(CitizenContactPreference).to receive(:find_by).and_raise(ActiveRecord::StatementInvalid, "boom")
    expect do
      travel_to(at(17, 0)) do
        CityConnection.with(city_record) { Appointments::Remind.call(appointment: appointment) }
      end
    end.to raise_error(ActiveRecord::StatementInvalid)
    expect(appointment.reload.reminded_at).to be_nil
    expect(AppointmentNotice.count).to eq(0)
    expect(DomainEvent.where(name: "appointment.reminded")).to be_empty
  end

  it "só confirmados de amanhã: não confirmado, de hoje e de depois de amanhã ficam de fora" do
    sms_on!
    prefs!
    unconfirmed = confirmed!(status: "scheduled")
    tonight = confirmed!(at(19, 0), who: person!, on: shift!(doctor_link!(unit), starts_at: at(18)))
    later_shift = shift!(doctor_link!(unit), starts_at: day_at(eve + 2, 8))
    later = confirmed!(later_shift.starts_at, who: person!, on: later_shift)
    run_at(at(17, 0))
    [ unconfirmed, tonight, later ].each { |a| expect(a.reload.reminded_at).to be_nil }
    expect(AppointmentNotice.count).to eq(0)
    expect(SmsGateway::Test.deliveries).to be_empty
  end

  it "depois das 20h (e antes das 17h), nada; às 19h45 ainda lembra" do
    sms_on!
    prefs!
    appointment = confirmed!
    [ at(20, 0), at(23, 45), at(8, 0), at(16, 45) ].each { |time| run_at(time) }
    expect(appointment.reload.reminded_at).to be_nil
    expect(AppointmentNotice.count).to eq(0)
    expect(SmsGateway::Test.deliveries).to be_empty
    expect(DomainEvent.where(name: "appointment.reminded")).to be_empty

    run_at(at(19, 45))
    expect(appointment.reload.reminded_at).to be_present
    expect(SmsGateway::Test.deliveries.size).to eq(1)
  end

  context "cidade em Manaus (UTC−4)" do
    let(:zone_name) { "America/Manaus" }

    it "as 17h são de Manaus, não de São Paulo (Review Focus 1)" do
      appointment = confirmed!
      run_at(ActiveSupport::TimeZone["America/Sao_Paulo"].local(eve.year, eve.month, eve.day, 17, 30)) # 16h30 em Manaus
      expect(appointment.reload.reminded_at).to be_nil
      run_at(at(17, 0))
      expect(appointment.reload.reminded_at).to be_present
    end

    it "às 20h30 de São Paulo (19h30 em Manaus) ainda lembra; às 20h de Manaus, não" do
      appointment = confirmed!
      run_at(at(20, 0))
      expect(appointment.reload.reminded_at).to be_nil
      run_at(ActiveSupport::TimeZone["America/Sao_Paulo"].local(eve.year, eve.month, eve.day, 20, 30))
      expect(appointment.reload.reminded_at).to be_present
    end
  end
end
