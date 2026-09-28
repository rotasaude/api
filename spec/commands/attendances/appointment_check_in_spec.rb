require "rails_helper"

RSpec.describe "Check-in de horário" do
  include ActiveSupport::Testing::TimeHelpers
  before { Current.city = TEST_CITY_A; link_professional!(doctor, unit) }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:other_unit) { create_unit("UPA Norte", kind: "upa") }
  let(:reception) { staff_with("recepcao@cidade.gov.br", "citizen_verifier") }
  let(:doctor) { staff_with("medica@cidade.gov.br", "health_professional") }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }

  # Horário confirmado hoje às `hour` (nasce confirmado: < 48h).
  def confirmed_today(hour: 15)
    confirmed_at(Time.zone.now.change(hour: hour))
  end

  def confirmed_at(time)
    a = in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor)
    a.triage.update_columns(priority: 3)
    req = Attendances::Close.call(attendance: a, outcome: "return", referral_unit_id: nil, referral_note: nil,
                                  by: doctor).payload.fetch(:appointment_request)
    Appointments::Schedule.call(request: req, scheduled_at: time.iso8601,
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

  context "check-in recusado com o motivo certo" do
    def exception_check_in(appt, unit_id: unit.id)
      Attendances::CheckInByException.call(cpf: citizen.cpf, appointment_id: appt.id, health_unit_id: unit_id,
                                           reason: "chegou sem o celular", by: reception)
    end

    it "por código em outra unidade: wrong_unit com o nome, sem atendimento e sem consumir o código" do
      travel_to(Time.zone.parse("2026-10-02 09:00")) do
        appt = confirmed_today
        code = Citizens::IssueAppointmentCheckInCode.call(citizen: citizen, appointment: appt).payload.fetch(:code)
        r = Attendances::CheckIn.call(cpf: citizen.cpf, code: code, health_unit_id: other_unit.id,
                                      document_checked: false, by: reception)
        expect(r.reason).to eq(:wrong_unit)
        expect(r.details[:unit_name]).to eq(unit.name)
        expect(Attendance.where(appointment_id: appt.id)).to be_empty
        expect(CitizenVerificationCode.find_by!(appointment_id: appt.id).consumed_at).to be_nil
      end
    end

    it "por código no dia seguinte: recusado (o código já expirou) e o horário segue confirmado" do
      code = nil
      appt = nil
      travel_to(Time.zone.parse("2026-10-02 09:00")) do
        appt = confirmed_today(hour: 23)
        code = Citizens::IssueAppointmentCheckInCode.call(citizen: citizen, appointment: appt).payload.fetch(:code)
      end
      travel_to(Time.zone.parse("2026-10-03 00:05")) do
        r = Attendances::CheckIn.call(cpf: citizen.cpf, code: code, health_unit_id: unit.id,
                                      document_checked: false, by: reception)
        expect(r).not_to be_ok
        expect(appt.reload.status).to eq("confirmed")
      end
    end

    it "por exceção em outra unidade: wrong_unit com o nome (não triage_not_eligible)" do
      travel_to(Time.zone.parse("2026-10-02 09:00")) do
        appt = confirmed_today
        r = exception_check_in(appt, unit_id: other_unit.id)
        expect(r.reason).to eq(:wrong_unit)
        expect(r.details[:unit_name]).to eq(unit.name)
        expect(Attendance.where(appointment_id: appt.id)).to be_empty
      end
    end

    it "por exceção em outro dia: not_today" do
      travel_to(Time.zone.parse("2026-10-02 09:00")) do
        appt = confirmed_at(Time.zone.parse("2026-10-03 10:00"))
        expect(appt.status).to eq("confirmed")
        expect(exception_check_in(appt).reason).to eq(:not_today)
      end
    end

    it "por exceção de horário não confirmado: appointment_not_eligible" do
      travel_to(Time.zone.parse("2026-10-02 09:00")) do
        a = in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor)
        req = Attendances::Close.call(attendance: a, outcome: "return", referral_unit_id: nil, referral_note: nil,
                                      by: doctor).payload.fetch(:appointment_request)
        appt = Appointments::Schedule.call(request: req, scheduled_at: 3.days.from_now.iso8601,
                                           health_unit_id: unit.id, by: reception).payload.fetch(:appointment)
        expect(exception_check_in(appt).reason).to eq(:appointment_not_eligible)
      end
    end

    it "por exceção com horário de outro cidadão: appointment_not_eligible" do
      travel_to(Time.zone.parse("2026-10-02 09:00")) do
        appt = confirmed_today
        other = Citizen.create!(cpf: "11144477735", phone: "+5541911112222")
        r = Attendances::CheckInByException.call(cpf: other.cpf, appointment_id: appt.id, health_unit_id: unit.id,
                                                 reason: "chegou sem o celular", by: reception)
        expect(r.reason).to eq(:appointment_not_eligible)
      end
    end

    it "fulfil reconfere unidade e dia sob o lock" do
      travel_to(Time.zone.parse("2026-10-02 09:00")) do
        appt = confirmed_today
        expect { Attendances::CheckIn.fulfil(appt, health_unit_id: other_unit.id) }
          .to raise_error(Attendances::CheckIn::AppointmentNotEligible)
        expect(appt.reload.status).to eq("confirmed")
      end
      travel_to(Time.zone.parse("2026-10-02 09:00")) do
        tomorrow = confirmed_at(Time.zone.parse("2026-10-03 10:00"))
        expect { Attendances::CheckIn.fulfil(tomorrow, health_unit_id: unit.id) }
          .to raise_error(Attendances::CheckIn::AppointmentNotEligible)
        expect(tomorrow.reload.status).to eq("confirmed")
      end
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
        cancel_elsewhere(appt)
        # A leitura sem lock ainda viu o horário confirmado; a reconferência
        # sob lock (a segunda chamada) enxerga o cancelamento.
        calls = 0
        allow(Attendances::AppointmentCheckInEligibility).to receive(:check).and_wrap_original do |m, *args, **kw|
          (calls += 1) == 1 ? :ok : m.call(*args, **kw)
        end

        r = Attendances::CheckInByException.call(cpf: citizen.cpf, appointment_id: appt.id, health_unit_id: unit.id,
                                                 reason: "chegou sem o celular", by: reception)
        expect(r.reason).to eq(:appointment_not_eligible)
        expect(Attendance.where(appointment_id: appt.id)).to be_empty
        expect(appt.reload.status).to eq("cancelled_by_citizen")
      end
    end
  end
end
