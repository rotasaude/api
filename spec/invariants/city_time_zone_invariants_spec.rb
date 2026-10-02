require "rails_helper"

# api#27: uma cidade em America/Manaus (UTC-4) vive no relógio DELA. Os
# instantes escolhidos caem entre a meia-noite de São Paulo e a de Manaus
# (03h00–04h00 UTC), a hora em que um fuso fixo erraria o dia.
RSpec.describe "Invariantes do fuso da cidade (api#27)" do
  include ActiveSupport::Testing::TimeHelpers
  after { Current.reset }

  let(:manaus) { TEST_CITY_A.dup.tap { |c| c.time_zone = "America/Manaus" } }
  let(:unit) { create_unit }
  let(:reception) { staff_with("recepcao@cidade.gov.br", "citizen_verifier") }
  let(:doctor) { staff_with("medica@cidade.gov.br", "health_professional") }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }

  def in_manaus(&) = CityConnection.with(manaus, &)

  def confirmed_at(local)
    a = in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor)
    req = Attendances::Close.call(attendance: a, outcome: "return", referral_unit_id: nil, referral_note: nil,
                                  by: doctor).payload.fetch(:appointment_request)
    Appointments::Schedule.call(request: req, scheduled_at: local.iso8601, health_unit_id: unit.id, by: reception)
                          .payload.fetch(:appointment)
  end

  before { link_professional!(doctor, unit) }

  describe "agendamento" do
    it "horário das 22h de Manaus é 'hoje' até a meia-noite de Manaus, não a de São Paulo" do
      in_manaus do
        appt = travel_to(Time.utc(2026, 10, 2, 13)) { confirmed_at(Time.zone.parse("2026-10-02 22:00")) }
        travel_to(Time.utc(2026, 10, 3, 3, 30)) do # 00h30 em SP, 23h30 de 2/10 em Manaus
          expect(appt.today?).to be(true)
          expect(Attendances::AppointmentCheckInEligibility.check(appt, health_unit_id: unit.id)).to eq(:ok)
          expect(Appointments::Lapse.due?(appt, "no_show", Time.current)).to be(false)
        end
        travel_to(Time.utc(2026, 10, 3, 4, 1)) do # 00h01 de 3/10 em Manaus
          expect(appt.today?).to be(false)
          expect(Appointments::Lapse.due?(appt, "no_show", Time.current)).to be(true)
        end
      end
    end

    it "o job de falta, rodando por cidade, só marca depois da meia-noite local" do
      city_record = create(:city, slug: TEST_CITY_A.slug, database_url: TEST_CITY_A.database_url,
                                  time_zone: "America/Manaus")
      expect(city_record.time_zone).to eq("America/Manaus")
      appt = in_manaus do
        travel_to(Time.utc(2026, 10, 2, 13)) { confirmed_at(Time.zone.parse("2026-10-02 22:00")) }
      end
      travel_to(Time.utc(2026, 10, 3, 3, 30)) { MarkNoShowAppointmentsJob.perform_now }
      expect(appt.reload.status).to eq("confirmed")
      travel_to(Time.utc(2026, 10, 3, 4, 1)) { MarkNoShowAppointmentsJob.perform_now }
      expect(appt.reload.status).to eq("no_show")
    end

    it "o prazo de confirmação e a regra das 48h contam em instantes, iguais em qualquer fuso" do
      in_manaus do
        travel_to(Time.utc(2026, 10, 2, 13)) do
          appt = confirmed_at(Time.zone.parse("2026-10-06 09:00"))
          expect(appt.status).to eq("scheduled")
          expect(appt.confirmation_deadline_at).to eq(Time.zone.parse("2026-10-05 09:00"))
          expect(appt.confirmation_deadline_at.utc).to eq(Time.utc(2026, 10, 5, 13))
        end
      end
    end
  end

  describe "telas e e-mails" do
    before(type: :request) do
      City.find_by!(slug: TEST_CITY_A.slug).update!(time_zone: "America/Manaus")
      CityCatalog.reset_cache!
    end

    it "a agenda do dia usa o dia de Manaus", type: :request do
      late = in_manaus do
        travel_to(Time.utc(2026, 10, 2, 13)) { confirmed_at(Time.zone.parse("2026-10-02 23:30")) }
      end
      sign_in_as(reception)
      get "/attendance/units/#{unit.id}/agenda", params: { date: "2026-10-02" }
      expect(JSON.parse(response.body)["appointments"].map { |a| a["id"] }).to eq([ late.id ])
      get "/attendance/units/#{unit.id}/agenda", params: { date: "2026-10-03" }
      expect(JSON.parse(response.body)["appointments"]).to eq([])
    end

    it "os painéis declaram o fuso da cidade e cortam 'hoje' na meia-noite local", type: :request do
      admin = staff_with("admin@cidade.gov.br", "municipal_admin")
      sign_in_as(admin)
      travel_to(Time.utc(2026, 10, 3, 3, 30)) do
        get "/admin/api/overview", params: { period: "today" }
        expect(response).to have_http_status(:ok), response.body[0, 300]
        expect(JSON.parse(response.body).dig("data", "scope", "tz")).to eq("America/Manaus")
      end
      period = CityConnection.with(City.find_by!(slug: TEST_CITY_A.slug)) do
        travel_to(Time.utc(2026, 10, 3, 3, 30)) do
          Admin::Api::Period.parse(key: "today", from: nil, to: nil, tz: Time.zone)
        end
      end
      expect(period.from.utc).to eq(Time.utc(2026, 10, 2, 4)) # 00h00 de 2/10 em Manaus
    end

    it "o aviso de segurança mostra a hora de Manaus mesmo entregue fora da cidade" do
      mail = SecurityMailer.authenticator_changed(
        email_address: "a@cidade.gov.br", kind: "enrolled", city_name: "Manaus", ip_address: "10.0.0.1",
        occurred_at: "2026-10-03T03:30:00Z", time_zone: "America/Manaus"
      )
      expect(Time.zone.name).to eq("America/Sao_Paulo") # fora da cidade
      expect(mail.body.encoded).to include("23:30")
      expect(mail.body.encoded).not_to include("00:30")
    end
  end

  describe "campanhas e analytics" do
    it "a janela do SMS (8h–20h) é a hora de Manaus" do
      in_manaus do
        travel_to(Time.utc(2026, 10, 2, 11, 30)) { expect(Campaigns::SmsBatchJob::WINDOW_HOURS.cover?(Time.current.hour)).to be(false) } # 7h30
        travel_to(Time.utc(2026, 10, 2, 12, 0)) { expect(Campaigns::SmsBatchJob::WINDOW_HOURS.cover?(Time.current.hour)).to be(true) } # 8h00
      end
    end

    it "o dia do analytics é o de Manaus" do
      in_manaus do
        expect(Analytics.tz).to eq("America/Manaus")
        day = ApplicationRecord.connection.select_value(ApplicationRecord.sanitize_sql_array([
          "SELECT ((:at::timestamp AT TIME ZONE 'UTC') AT TIME ZONE :tz)::date::text",
          { at: "2026-10-03 03:30:00", tz: Analytics.tz }
        ]))
        expect(day).to eq("2026-10-02")
      end
    end
  end
end
