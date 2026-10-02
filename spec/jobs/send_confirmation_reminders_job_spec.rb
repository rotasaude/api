require "rails_helper"

# api#39: um SMS 24h antes do prazo de confirmação (48h antes do horário), só
# enquanto o horário segue sem confirmação, dentro das 8h–20h da cidade. Não
# exige o opt-in das campanhas (é do próprio atendimento), mas respeita o
# opt-out de lembretes. Texto fixo, sem unidade, data nem motivo. Sem a chave
# de SMS da cidade ou sem provedor, nada sai e o lembrete fica registrado.
RSpec.describe SendConfirmationRemindersJob do
  include ActiveSupport::Testing::TimeHelpers
  before { Current.city = TEST_CITY_A; SmsGateway::Test.reset! }
  after { SmsGateway::Test.reset!; Current.reset }

  let!(:city_record) { create(:city, slug: TEST_CITY_A.slug, database_url: TEST_CITY_A.database_url) }
  let(:unit) { create_unit }
  let(:reception) { staff_with("recepcao@cidade.gov.br", "citizen_verifier") }
  let(:doctor) { staff_with("medica@cidade.gov.br", "health_professional") }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:t0) { Time.zone.parse("2026-10-01 10:00") }

  before { link_professional!(doctor, unit) }

  def sms_on! = CityProfile.create!(name: "Curitiba", campaigns_sms_enabled: true)

  # Horário a 3 dias: prazo = horário - 24h; lembrete = prazo - 24h.
  def appointment_at(at, now: t0)
    travel_to(now) do
      a = in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor)
      req = Attendances::Close.call(attendance: a, outcome: "return", referral_unit_id: nil, referral_note: nil,
                                    by: doctor).payload.fetch(:appointment_request)
      Appointments::Schedule.call(request: req, scheduled_at: at.iso8601, health_unit_id: unit.id, by: reception)
                            .payload.fetch(:appointment)
    end
  end

  def run_at(time) = travel_to(time) { described_class.perform_now }

  it "manda um SMS 24h antes do prazo, não antes, e só uma vez" do
    sms_on!
    appt = appointment_at(Time.zone.parse("2026-10-04 14:00")) # prazo 03/10 14h; lembrete 02/10 14h
    run_at(Time.zone.parse("2026-10-02 13:59"))
    expect(SmsGateway::Test.deliveries).to be_empty

    run_at(Time.zone.parse("2026-10-02 14:00"))
    run_at(Time.zone.parse("2026-10-02 14:15"))
    expect(SmsGateway::Test.deliveries.size).to eq(1)
    expect(SmsGateway::Test.deliveries.first[:phone]).to eq(citizen.phone)
    expect(AppointmentReminder.find_by!(appointment_id: appt.id).status).to eq("sent")
    expect(DomainEvent.where(name: "appointment.reminder_recorded").count).to eq(1)
  end

  it "texto fixo, sem unidade, data nem motivo, com o link do wpda" do
    sms_on!
    appointment_at(Time.zone.parse("2026-10-04 14:00"))
    run_at(Time.zone.parse("2026-10-02 14:00"))
    body = SmsGateway::Test.deliveries.first[:body]
    expect(body).to include("horário para confirmar")
    expect(body).to include(CityPublicUrl.wpda(TEST_CITY_A))
    expect(body).not_to include(unit.name)
    expect(body).not_to match(%r{\d{2}/\d{2}})
  end

  it "fora das 8h–20h espera a janela" do
    sms_on!
    appointment_at(Time.zone.parse("2026-10-04 07:00")) # lembrete 02/10 07h
    run_at(Time.zone.parse("2026-10-02 07:00"))
    expect(SmsGateway::Test.deliveries).to be_empty
    run_at(Time.zone.parse("2026-10-02 08:00"))
    expect(SmsGateway::Test.deliveries.size).to eq(1)
  end

  it "horário já confirmado, cancelado ou com prazo vencido não recebe lembrete" do
    sms_on!
    confirmed = appointment_at(Time.zone.parse("2026-10-04 14:00"))
    Appointments::Confirm.call(appointment: confirmed, now: t0)
    late = appointment_at(Time.zone.parse("2026-10-04 15:00"))
    run_at(Time.zone.parse("2026-10-03 15:00")) # já no prazo de late
    expect(SmsGateway::Test.deliveries).to be_empty
    expect(AppointmentReminder.where(appointment_id: [ confirmed.id, late.id ])).to be_empty
  end

  it "não exige o opt-in das campanhas, mas respeita o opt-out de lembretes" do
    sms_on!
    appt = appointment_at(Time.zone.parse("2026-10-04 14:00"))
    expect(CitizenContactPreference.find_by(citizen_id: citizen.id)&.sms_opt_in).to be_falsey
    CitizenContactPreference.create!(citizen_id: citizen.id, appointment_reminders_muted: true)
    run_at(Time.zone.parse("2026-10-02 14:00"))
    expect(SmsGateway::Test.deliveries).to be_empty
    expect(AppointmentReminder.find_by!(appointment_id: appt.id).status).to eq("opted_out")
  end

  it "com a chave de SMS da cidade desligada, nada sai e o lembrete fica como disabled" do
    appt = appointment_at(Time.zone.parse("2026-10-04 14:00"))
    run_at(Time.zone.parse("2026-10-02 14:00"))
    expect(SmsGateway::Test.deliveries).to be_empty
    expect(AppointmentReminder.find_by!(appointment_id: appt.id).status).to eq("disabled")
  end

  it "sem provedor, nada sai e o lembrete fica como unavailable" do
    sms_on!
    appt = appointment_at(Time.zone.parse("2026-10-04 14:00"))
    allow(SmsGateway).to receive(:configured?).and_return(false)
    run_at(Time.zone.parse("2026-10-02 14:00"))
    expect(AppointmentReminder.find_by!(appointment_id: appt.id).status).to eq("unavailable")
  end

  it "o evento carrega só ids e o status" do
    sms_on!
    appointment_at(Time.zone.parse("2026-10-04 14:00"))
    run_at(Time.zone.parse("2026-10-02 14:00"))
    payload = DomainEvent.find_by!(name: "appointment.reminder_recorded").payload
    expect(payload.keys).to match_array(%w[appointment_id appointment_request_id status])
  end

  it "o banco recusa um segundo lembrete do mesmo horário e recusa apagar ou mudar" do
    sms_on!
    appt = appointment_at(Time.zone.parse("2026-10-04 14:00"))
    run_at(Time.zone.parse("2026-10-02 14:00"))
    reminder = AppointmentReminder.find_by!(appointment_id: appt.id)
    attempt = ->(&b) { ApplicationRecord.transaction(requires_new: true, &b) }
    expect { attempt.call { AppointmentReminder.create!(appointment: appt, status: "sent") } }
      .to raise_error(ActiveRecord::RecordNotUnique)
    expect { attempt.call { AppointmentReminder.where(id: reminder.id).update_all(status: "failed") } }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect { attempt.call { AppointmentReminder.where(id: reminder.id).delete_all } }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end
end
