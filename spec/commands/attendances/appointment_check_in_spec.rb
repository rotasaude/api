require "rails_helper"

RSpec.describe "Check-in de horário" do
  include ActiveSupport::Testing::TimeHelpers
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:other_unit) { create_unit("UPA Norte", kind: "upa") }
  let(:reception) { staff_with("recepcao@cidade.gov.br", "citizen_verifier") }
  let(:doctor) { staff_with("medica@cidade.gov.br", "health_professional") }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }

  # Horário confirmado hoje às `hour` (nasce confirmado: < 48h).
  def confirmed_today(hour: 15)
    a = in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor)
    a.triage.update_columns(priority: 3)
    req = Attendances::Close.call(attendance: a, outcome: "return", referral_unit_id: nil, referral_note: nil,
                                  by: doctor).payload.fetch(:appointment_request)
    Appointments::Schedule.call(request: req, scheduled_at: Time.zone.now.change(hour: hour).iso8601,
                                health_unit_id: unit.id, by: reception).payload.fetch(:appointment)
  end

  it "por código: abre atendimento do horário, encerra o pedido como fulfilled e publica" do
    travel_to(Time.zone.parse("2026-10-02 09:00")) do
      appt = confirmed_today
      code = Citizens::IssueAppointmentCheckInCode.call(citizen: citizen, appointment: appt).payload.fetch(:code)

      lookup = Attendances::LookupForCheckIn.call(cpf: citizen.cpf, code: code, health_unit_id: unit.id)
      expect(lookup.payload[:appointment]).to eq(appt)
      expect(lookup.payload[:triage]).to be_nil

      r = Attendances::CheckIn.call(cpf: citizen.cpf, code: code, health_unit_id: unit.id, document_checked: false,
                                    by: reception)
      attendance = r.payload[:attendance]
      expect(attendance).to have_attributes(appointment_id: appt.id, triage_id: nil, status: "waiting")
      expect(attendance.priority).to eq(3)
      expect(appt.reload.status).to eq("checked_in")
      expect(appt.request.reload).to have_attributes(status: "closed", closed_reason: "fulfilled")
      expect(DomainEvent.where(name: "appointment.checked_in").count).to eq(1)
    end
  end

  it "horário de outra unidade: wrong_unit com o nome da unidade" do
    travel_to(Time.zone.parse("2026-10-02 09:00")) do
      appt = confirmed_today
      code = Citizens::IssueAppointmentCheckInCode.call(citizen: citizen, appointment: appt).payload.fetch(:code)
      r = Attendances::LookupForCheckIn.call(cpf: citizen.cpf, code: code, health_unit_id: other_unit.id)
      expect(r.reason).to eq(:wrong_unit)
      expect(r.details[:unit_name]).to eq(unit.name)
    end
  end

  it "horário às 23h30 locais é hoje; o código não nasce em outro dia" do
    travel_to(Time.zone.parse("2026-10-02 09:00")) do
      appt = confirmed_today(hour: 23) # 23h00 locais = 02h00 UTC do dia 3
      expect(Citizens::IssueAppointmentCheckInCode.call(citizen: citizen, appointment: appt)).to be_ok
    end
    travel_to(Time.zone.parse("2026-10-03 00:30")) do
      appt = Appointment.last
      expect(Citizens::IssueAppointmentCheckInCode.call(citizen: citizen, appointment: appt).reason).to eq(:not_today)
    end
  end

  it "exceção por CPF lista os horários de hoje desta unidade e faz check-in com motivo" do
    travel_to(Time.zone.parse("2026-10-02 09:00")) do
      appt = confirmed_today
      search = Attendances::EligibleTriages.call(cpf: citizen.cpf, by: reception, health_unit_id: unit.id)
      expect(search.payload[:appointments]).to eq([ appt ])
      expect(Attendances::EligibleTriages.call(cpf: citizen.cpf, by: reception, health_unit_id: other_unit.id)
                                         .payload[:appointments]).to eq([])

      r = Attendances::CheckInByException.call(cpf: citizen.cpf, appointment_id: appt.id, health_unit_id: unit.id,
                                               reason: "chegou sem o celular", by: reception)
      expect(r.payload[:attendance]).to have_attributes(appointment_id: appt.id, check_in_method: "cpf_exception")
      expect(appt.reload.status).to eq("checked_in")
    end
  end

  it "horário ainda scheduled (não confirmado) não recebe check-in" do
    travel_to(Time.zone.parse("2026-10-02 09:00")) do
      a = in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor)
      req = Attendances::Close.call(attendance: a, outcome: "return", referral_unit_id: nil, referral_note: nil,
                                    by: doctor).payload.fetch(:appointment_request)
      appt = Appointments::Schedule.call(request: req, scheduled_at: 3.days.from_now.iso8601, health_unit_id: unit.id,
                                         by: reception).payload.fetch(:appointment)
      expect(Citizens::IssueAppointmentCheckInCode.call(citizen: citizen, appointment: appt).reason)
        .to eq(:appointment_not_eligible)
    end
  end

  context "corrida: o cidadão cancela entre a checagem sem lock e o lock" do
    def cancel_elsewhere(appt)
      r = Appointments::CancelByCitizen.call(appointment: Appointment.find(appt.id), reason: "não vou conseguir ir")
      expect(r).to be_ok
    end

    it "por código: falha com appointment_not_eligible, não cria atendimento nem consome o código" do
      travel_to(Time.zone.parse("2026-10-02 09:00")) do
        appt = confirmed_today
        code = Citizens::IssueAppointmentCheckInCode.call(citizen: citizen, appointment: appt).payload.fetch(:code)
        vcode = CitizenVerificationCode.find_by!(appointment_id: appt.id)
        allow(Citizens::VerificationCodeMatch).to receive(:call).and_wrap_original do |m, **kw|
          m.call(**kw).tap { cancel_elsewhere(appt) }
        end

        r = Attendances::CheckIn.call(cpf: citizen.cpf, code: code, health_unit_id: unit.id, document_checked: false,
                                      by: reception)
        expect(r.reason).to eq(:appointment_not_eligible)
        expect(Attendance.where(appointment_id: appt.id)).to be_empty
        expect(vcode.reload.consumed_at).to be_nil
        # O cancelamento simulado roda na mesma conexão, dentro da transação do
        # check-in, e desfaz junto; em produção ele já teria sido commitado.
        expect(DomainEvent.where(name: "appointment.checked_in").count).to eq(0)
      end
    end

    it "por exceção: falha com appointment_not_eligible e não cria atendimento" do
      travel_to(Time.zone.parse("2026-10-02 09:00")) do
        appt = confirmed_today
        stale = Appointment.find(appt.id)
        cancel_elsewhere(appt)
        scope = instance_double(ActiveRecord::Relation, find_by: stale)
        allow(Attendances::AppointmentCheckInEligibility).to receive(:eligible_for).and_return(scope)

        r = Attendances::CheckInByException.call(cpf: citizen.cpf, appointment_id: appt.id, health_unit_id: unit.id,
                                                 reason: "chegou sem o celular", by: reception)
        expect(r.reason).to eq(:appointment_not_eligible)
        expect(Attendance.where(appointment_id: appt.id)).to be_empty
        expect(appt.reload.status).to eq("cancelled_by_citizen")
      end
    end
  end
end
