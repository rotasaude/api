require "rails_helper"

# Módulo 17 (ADR 0029; spec §3–§5): o banco garante o que o modelo não vê.
RSpec.describe "Guardas das tabelas da agenda" do
  include ActiveSupport::Testing::TimeHelpers
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:link) { doctor_link!(unit) }
  let(:shift) { shift!(link, starts_at: 2.days.from_now.change(hour: 8)) }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:other) { Citizen.create!(cpf: "11144477735", phone: "+5541911112222") }

  def attempt(&) = ApplicationRecord.transaction(requires_new: true, &)

  describe "appointments" do
    it "slot e encaixe exigem profissional, tipo, fim e turno; legacy não" do
      req = triage_request!(citizen, unit: unit)
      row = appointment_row!(req, shift, starts_at: shift.starts_at).attributes.except("id")
      row.merge!("status" => "cancelled_by_citizen", "cancel_reason" => "não posso ir mais", "ended_at" => Time.current)
      expect { attempt { Appointment.insert_all!([ row.merge("ends_at" => nil) ]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_appointments_booking_fields/)
      expect { attempt { Appointment.insert_all!([ row.merge("booking_kind" => "outro") ]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_appointments_booking_kind/)
      expect { attempt { Appointment.insert_all!([ row.merge("ends_at" => row["scheduled_at"]) ]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_appointments_ends/)
      legacy = row.merge("booking_kind" => "legacy", "professional_id" => nil, "shift_id" => nil, "ends_at" => nil,
                         "appointment_type_key" => nil)
      expect { attempt { Appointment.insert_all!([ legacy ]) } }.not_to raise_error
    end

    it "encaixe exige justificativa de 10+ caracteres; slot não pode ter justificativa" do
      shift # fora do savepoint: o turno precisa sobreviver ao rollback da primeira tentativa
      expect { attempt { appointment_row!(triage_request!(citizen, unit: unit), shift, starts_at: shift.starts_at, kind: "fit_in", reason: "curta") } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_appointments_fit_in_reason/)
      expect { attempt { appointment_row!(triage_request!(other, unit: unit), shift, starts_at: shift.starts_at, reason: "gestante com dor") } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_appointments_fit_in_reason/)
    end

    it "dois slots ativos sobrepostos do mesmo profissional: o banco recusa; encaixe e cancelado não contam" do
      first = appointment_row!(triage_request!(citizen, unit: unit), shift, starts_at: shift.starts_at)
      expect { attempt { appointment_row!(triage_request!(other, unit: unit), shift, starts_at: shift.starts_at + 10.minutes) } }
        .to raise_error(ActiveRecord::ExclusionViolation, /excl_appointments_slot_overlap/)
      expect { attempt { appointment_row!(triage_request!(other, unit: unit), shift, starts_at: shift.starts_at + 10.minutes, kind: "fit_in", reason: "retorno que não espera") } }
        .not_to raise_error
      third = Citizen.create!(cpf: "39053344705", phone: "+5541933334444")
      attempt do
        first.update!(status: "checked_in", ended_at: Time.current)
        expect { attempt { appointment_row!(triage_request!(third, unit: unit), shift, starts_at: shift.starts_at) } }
          .to raise_error(ActiveRecord::ExclusionViolation, /excl_appointments_slot_overlap/)
        raise ActiveRecord::Rollback
      end
      first.reload.update!(status: "cancelled_by_citizen", cancel_reason: "não posso ir mais", ended_at: Time.current)
      expect { attempt { appointment_row!(triage_request!(third, unit: unit), shift, starts_at: shift.starts_at) } }.not_to raise_error
    end

    it "profissional, tipo, fim, turno, modo e justificativa nunca mudam" do
      appt = appointment_row!(triage_request!(citizen, unit: unit), shift, starts_at: shift.starts_at)
      { professional_id: doctor_link!(unit).professional_id, appointment_type_key: "retorno",
        ends_at: appt.ends_at + 5.minutes, shift_id: shift!(link, starts_at: 5.days.from_now.change(hour: 8)).id,
        booking_kind: "legacy" }.each do |column, value|
        expect { attempt { Appointment.where(id: appt.id).update_all(column => value) } }
          .to raise_error(ActiveRecord::StatementInvalid, /scheduled columns never change/), column.to_s
      end
      expect { Appointment.where(id: appt.id).update_all(reminded_at: Time.current, reschedule_requested: false) }.not_to raise_error

      fit_in = appointment_row!(triage_request!(other, unit: unit), shift, starts_at: shift.starts_at, kind: "fit_in",
                                reason: "gestante com dor forte")
      expect { attempt { Appointment.where(id: fit_in.id).update_all(fit_in_reason: "outro motivo qualquer") } }
        .to raise_error(ActiveRecord::StatementInvalid, /scheduled columns never change/)
    end
  end

  describe "appointment_requests" do
    it "exatamente uma origem; pedido de triagem tem origin_triage; sem origem nem as duas, recusa" do
      req = triage_request!(citizen, unit: unit)
      row = req.attributes.except("id")
      expect { attempt { AppointmentRequest.insert_all!([ row.merge("origin_triage_id" => nil) ]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_appointment_requests_origin/)
      expect { attempt { AppointmentRequest.insert_all!([ row.merge("kind" => "return", "appointment_type_key" => "x") ]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_appointment_requests_triage_kind/)
      %w[priority preferred_period reschedule_reason_code].each do |column|
        expect { attempt { AppointmentRequest.where(id: req.id).update_all(column => "lixo") } }
          .to raise_error(ActiveRecord::StatementInvalid, /ck_appointment_requests_#{column}/)
      end
      expect { attempt { AppointmentRequest.where(id: req.id).update_all(reschedule_note: "x" * 201) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_appointment_requests_reschedule_note/)
    end

    it "unidade de destino: nula → unidade uma vez; depois nunca muda" do
      req = triage_request!(citizen, unit: nil)
      expect { AppointmentRequest.where(id: req.id).update_all(target_unit_id: unit.id) }.not_to raise_error
      expect { attempt { AppointmentRequest.where(id: req.id).update_all(target_unit_id: create_unit("UBS Sul").id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /origin columns never change/)
      expect { attempt { AppointmentRequest.where(id: req.id).update_all(origin_triage_id: completed_web_triage_for(other).id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /origin columns never change/)
    end

    # Vivo = aberto ou agendado: reabrir o agendado nunca colide com outro aberto.
    it "um pedido de triagem vivo (aberto ou agendado) por tipo por cidadão" do
      first = triage_request!(citizen, unit: unit)
      expect { attempt { triage_request!(citizen, unit: unit) } }
        .to raise_error(ActiveRecord::RecordNotUnique, /idx_appointment_requests_one_live_triage_type/)
      expect { attempt { triage_request!(citizen, unit: unit, type_key: "retorno") } }.not_to raise_error
      AppointmentRequest.where(id: first.id).update_all(status: "scheduled")
      expect { attempt { triage_request!(citizen, unit: unit) } }
        .to raise_error(ActiveRecord::RecordNotUnique, /idx_appointment_requests_one_live_triage_type/)
    end
  end

  it "tipos: key e origin nunca mudam; DELETE recusado" do
    type = type_row!("acupuntura")
    expect { attempt { AppointmentType.where(id: type.id).update_all(key: "outra") } }
      .to raise_error(ActiveRecord::StatementInvalid, /key and origin never change/)
    expect { attempt { AppointmentType.where(id: type.id).update_all(origin: "platform") } }
      .to raise_error(ActiveRecord::StatementInvalid, /key and origin never change/)
    expect { attempt { AppointmentType.where(id: type.id).delete_all } }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
    expect { attempt { type_row!("Maiuscula") } }.to raise_error(ActiveRecord::StatementInvalid, /ck_appointment_types_key/)
    expect { attempt { type_row!("longa", minutes: 241) } }.to raise_error(ActiveRecord::StatementInvalid, /ck_appointment_types_duration/)
    expect { attempt { type_row!("vazia", cbo: []) } }.to raise_error(ActiveRecord::StatementInvalid, /ck_appointment_types_cbo_prefixes/)
  end

  it "modelos: limite 0..20, blocks é lista, DELETE recusado" do
    template = ScheduleTemplate.create!(name: "Manhã", blocks: [])
    expect { attempt { ScheduleTemplate.where(id: template.id).update_all(fit_in_limit: 21) } }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_schedule_templates_fit_in_limit/)
    expect { attempt { ScheduleTemplate.where(id: template.id).update_all(blocks: {}) } }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_schedule_templates_blocks/)
    expect { attempt { ScheduleTemplate.where(id: template.id).delete_all } }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "ligação pedido↔triagem é só acréscimo; aviso de lembrete registra só a primeira leitura e aceita DELETE" do
    req = triage_request!(citizen, unit: unit)
    link_row = AppointmentRequestTriage.create!(request: req, triage: completed_web_triage_for(citizen), created_at: Time.current)
    expect { attempt { AppointmentRequestTriage.where(id: link_row.id).delete_all } }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)

    notice = AppointmentNotice.create!(appointment: appointment_row!(req, shift, starts_at: shift.starts_at),
                                       citizen: citizen, created_at: Time.current)
    expect { AppointmentNotice.where(id: notice.id).update_all(read_at: Time.current) }.not_to raise_error
    expect { attempt { AppointmentNotice.where(id: notice.id).update_all(read_at: 1.day.ago) } }
      .to raise_error(ActiveRecord::StatementInvalid, /only the first read/)
    expect { AppointmentNotice.where(id: notice.id).delete_all }.not_to raise_error
  end

  it "limite de encaixe padrão da cidade: 0..20" do
    CityProfile.create!(name: "Cidade") unless CityProfile.exists?
    expect(CityProfile.current.default_fit_in_limit).to eq(2)
    expect { attempt { CityProfile.update_all(default_fit_in_limit: 21) } }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_city_profile_default_fit_in_limit/)
  end
end
