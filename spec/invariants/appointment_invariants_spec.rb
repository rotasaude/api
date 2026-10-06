require "rails_helper"

# Módulo 08, critério de fechamento (ADR 0019). As recusas vêm do banco
# (constraints e triggers de db/city_triggers.sql), não só do modelo: por isso
# os ataques usam update_all/update_columns/insert_all. Como em
# db/city_triggers.sql, isto NÃO defende contra o DONO da tabela.
RSpec.describe "Invariantes do agendamento (ADR 0019)" do
  include ActiveSupport::Testing::TimeHelpers
  before { Current.city = TEST_CITY_A; link_professional!(doctor, unit) }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:other_unit) { create_unit("UPA Norte", kind: "upa") }
  let(:reception) { staff_with("recepcao@cidade.gov.br", "citizen_verifier") }
  let(:doctor) { staff_with("medica@cidade.gov.br", "health_professional") }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:t0) { Time.zone.parse("2026-10-01 10:00") }

  let(:note) { "reavaliar a pressão em duas semanas" }
  let(:cancel_reason) { "não consigo ir nesse dia" }
  let(:dismiss_reason) { "cidadão mudou de cidade" }
  let(:check_in_reason) { "chegou sem o celular" }

  # Savepoint: cada recusa aborta a transação; o savepoint deixa a próxima viva.
  def attempt(&block) = ApplicationRecord.transaction(requires_new: true, &block)

  def request_from_return
    a = in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor)
    Attendances::Close.call(attendance: a, outcome: "return", referral_unit_id: nil, referral_note: note,
                            by: doctor).payload.fetch(:appointment_request)
  end

  def schedule(req, at)
    Appointments::Schedule.call(request: req, scheduled_at: at.iso8601, health_unit_id: unit.id, by: reception)
                          .payload.fetch(:appointment)
  end

  describe "todo horário pertence a um pedido e todo pedido nasce de um atendimento" do
    it "o banco recusa pedido sem nenhuma origem (nem atendimento, nem triagem)" do
      req = travel_to(t0) { request_from_return }
      row = req.attributes.except("id", "origin_attendance_id").merge("origin_attendance_id" => nil)
      expect { attempt { AppointmentRequest.insert_all!([ row ]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_appointment_requests_origin/)
    end

    it "o banco recusa horário sem pedido" do
      appt = travel_to(t0) { schedule(request_from_return, t0 + 3.days) }
      row = appt.attributes.except("id").merge("request_id" => nil)
      expect { attempt { Appointment.insert_all!([ row ]) } }.to raise_error(ActiveRecord::NotNullViolation)
    end

    it "a origem do pedido nunca muda" do
      req = travel_to(t0) { request_from_return }
      other = travel_to(t0) { in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor) }
      expect { attempt { AppointmentRequest.where(id: req.id).update_all(origin_attendance_id: other.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /origin columns never change/)
    end
  end

  describe "um pedido tem no máximo um horário vivo" do
    it "o banco recusa um segundo horário vivo, mesmo por insert_all" do
      appt = travel_to(t0) { schedule(request_from_return, t0 + 3.days) }
      row = appt.attributes.except("id").merge("scheduled_at" => t0 + 4.days,
                                               "confirmation_deadline_at" => t0 + 3.days)
      expect { attempt { Appointment.insert_all!([ row ]) } }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "o que foi marcado nunca muda; horário encerrado não muda" do
    {
      "scheduled_at" => ->(_) { { scheduled_at: t0 + 5.days } },
      "health_unit_id" => ->(_) { { health_unit_id: other_unit.id } },
      "confirmation_deadline_at" => ->(_) { { confirmation_deadline_at: t0 + 4.days } },
      "citizen_id" => ->(_) { { citizen_id: Citizen.create!(cpf: "11144477735", phone: "+5541911112222").id } }
    }.each do |column, change|
      it "o banco recusa UPDATE de #{column}" do
        appt = travel_to(t0) { schedule(request_from_return, t0 + 3.days) }
        attrs = instance_exec(appt, &change)
        expect { attempt { Appointment.where(id: appt.id).update_all(attrs) } }
          .to raise_error(ActiveRecord::StatementInvalid, /scheduled columns never change/)
      end
    end

    it "o banco recusa qualquer mudança num horário encerrado" do
      appt = travel_to(t0) { schedule(request_from_return, t0 + 3.days) }
      Appointments::CancelByCitizen.call(appointment: appt, reason: cancel_reason)
      expect { attempt { Appointment.where(id: appt.id).update_all(cancel_reason: "outro motivo qualquer") } }
        .to raise_error(ActiveRecord::StatementInvalid, /already ended/)
    end

    it "o banco recusa transição fora do previsto (scheduled → checked_in)" do
      appt = travel_to(t0) { schedule(request_from_return, t0 + 3.days) }
      expect { attempt { Appointment.where(id: appt.id).update_all(status: "checked_in", ended_at: t0) } }
        .to raise_error(ActiveRecord::StatementInvalid, /invalid transition/)
    end

    it "o banco recusa DELETE de horário e de pedido" do
      appt = travel_to(t0) { schedule(request_from_return, t0 + 3.days) }
      expect { attempt { Appointment.where(id: appt.id).delete_all } }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      expect { attempt { AppointmentRequest.where(id: appt.request_id).delete_all } }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    end

    it "remarcar cria um horário novo e deixa o antigo intacto" do
      appt = travel_to(t0) { schedule(request_from_return, t0 + 3.days) }
      Appointments::Lapse.call(appointment: appt, to: "expired", now: appt.confirmation_deadline_at)
      before = appt.reload.attributes
      fresh = travel_to(appt.confirmation_deadline_at + 1.hour) { schedule(appt.request.reload, t0 + 6.days) }
      expect(fresh.id).not_to eq(appt.id)
      expect(appt.reload.attributes).to eq(before)
    end
  end

  describe "cancelamento exige motivo" do
    it "o banco recusa cancelar sem motivo ou com motivo curto" do
      appt = travel_to(t0) { schedule(request_from_return, t0 + 3.days) }
      [ nil, "curto" ].each do |reason|
        expect do
          attempt do
            Appointment.where(id: appt.id).update_all(status: "cancelled_by_citizen", cancel_reason: reason,
                                                      ended_at: t0)
          end
        end.to raise_error(ActiveRecord::StatementInvalid, /ck_appointments_cancel_reason/)
      end
    end

    it "o banco recusa encerrar o pedido sem justificativa" do
      req = travel_to(t0) { request_from_return }
      expect do
        attempt do
          AppointmentRequest.where(id: req.id).update_all(status: "closed", closed_reason: "dismissed",
                                                          closed_at: t0, dismiss_reason: nil)
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /ck_appointment_requests_dismiss_reason/)
    end
  end

  describe "expiração e falta devolvem o pedido à fila, marcado" do
    it "expired e no_show reabrem o pedido com a marca; ninguém sai da fila sem decisão" do
      expired = travel_to(t0) { schedule(request_from_return, t0 + 3.days) }
      Appointments::Lapse.call(appointment: expired, to: "expired", now: expired.confirmation_deadline_at)
      expect(expired.request.reload).to have_attributes(status: "open", reopened_reason: "expired")

      missed = travel_to(t0) { schedule(request_from_return, t0 + 1.day) } # nasce confirmado
      Appointments::Lapse.call(appointment: missed, to: "no_show", now: t0 + 2.days)
      expect(missed.request.reload).to have_attributes(status: "open", reopened_reason: "no_show")
    end
  end

  describe "check-in de horário só no dia, na unidade e com o horário confirmado" do
    def exception_check_in(appt, unit_id: unit.id)
      Attendances::CheckInByException.call(cpf: citizen.cpf, appointment_id: appt.id, health_unit_id: unit_id,
                                           reason: check_in_reason, by: reception)
    end

    it "recusa outra unidade, outro dia e horário não confirmado; aceita o caso certo" do
      travel_to(t0) do
        unconfirmed = schedule(request_from_return, t0 + 3.days)
        tomorrow = schedule(request_from_return, t0 + 1.day)
        today = schedule(request_from_return, t0 + 2.hours)

        expect(exception_check_in(unconfirmed).reason).to eq(:appointment_not_eligible)
        expect(exception_check_in(tomorrow).reason).to eq(:not_today)
        expect(exception_check_in(today, unit_id: other_unit.id).reason).to eq(:wrong_unit)
        expect(Attendance.where(appointment_id: [ unconfirmed.id, tomorrow.id, today.id ])).to be_empty

        expect(exception_check_in(today)).to be_ok
        expect(today.request.reload).to have_attributes(status: "closed", closed_reason: "fulfilled")
      end
    end
  end

  describe "nenhum payload de evento carrega CPF, celular, motivo ou nota" do
    it "percorre o ciclo inteiro e confere todos os eventos de agendamento e check-in" do
      travel_to(t0) do
        # marcar → confirmar → check-in por exceção
        today = schedule(request_from_return, t0 + 2.hours)
        exception_check_in = Attendances::CheckInByException.call(
          cpf: citizen.cpf, appointment_id: today.id, health_unit_id: unit.id, reason: check_in_reason, by: reception
        )
        expect(exception_check_in).to be_ok

        # marcar → cancelar pelo cidadão
        cancelled = schedule(request_from_return, t0 + 3.days)
        expect(Appointments::CancelByCitizen.call(appointment: cancelled, reason: cancel_reason)).to be_ok

        # marcar → confirmar → expirar/faltar
        confirmed = schedule(request_from_return, t0 + 4.days)
        expect(Appointments::Confirm.call(appointment: confirmed)).to be_ok
        Appointments::Lapse.call(appointment: confirmed, to: "no_show", now: t0 + 5.days)
        expired = schedule(request_from_return, t0 + 5.days)
        Appointments::Lapse.call(appointment: expired, to: "expired", now: expired.confirmation_deadline_at)

        # encerrar pedido com justificativa
        dismissed = request_from_return
        expect(AppointmentRequests::Dismiss.call(request: dismissed, reason: dismiss_reason,
                                                 health_unit_id: unit.id, by: reception)).to be_ok
      end

      events = DomainEvent.where("name LIKE 'appointment%' OR name = 'attendance.checked_in'").to_a
      names = events.map(&:name).uniq
      expect(names).to include("appointment_request.created", "appointment_request.closed", "appointment.scheduled",
                               "appointment.confirmed", "appointment.cancelled", "appointment.no_show",
                               "appointment.expired", "appointment.checked_in", "attendance.checked_in")

      forbidden_keys = %w[cpf phone cpf_masked note referral_note cancel_reason dismiss_reason exception_reason reason]
      secrets = [ citizen.cpf, citizen.phone, citizen.cpf_masked, note, cancel_reason, dismiss_reason,
                  check_in_reason ]
      events.each do |event|
        keys = event.payload.keys.map(&:to_s)
        expect(keys & forbidden_keys).to eq([]), "#{event.name} carrega #{keys & forbidden_keys}"
        dump = event.payload.to_json
        secrets.each { |s| expect(dump).not_to include(s), "#{event.name} carrega um dado pessoal" }
      end
    end
  end
end
