require "rails_helper"

# ADR 0029 §3.2: o modelo liga-se ao turno; o vínculo ganha um tipo padrão
# (para o turno sem modelo). Mudar nenhum dos dois move horário marcado.
RSpec.describe "Modelo no turno e tipo padrão do vínculo" do
  before { Current.city = TEST_CITY_A; ensure_appointment_types! }
  after { Current.reset }

  let(:admin) { staff_with("admin-agenda@cidade.gov.br", "municipal_admin") }
  let(:unit) { create_unit }
  let(:link) { doctor_link!(unit) }
  let(:template) { ScheduleTemplate.create!(name: "Manhã", blocks: [ { "starts" => "09:00", "ends" => "10:00", "kind" => "blocked" } ]) }
  let(:starts) { 2.days.from_now.change(hour: 8) }

  it "lança turno com modelo ativo; modelo inativo ou inexistente é invalid_template" do
    shift = Professionals::ScheduleShift.call(link: link, starts_at: starts, ends_at: starts + 4.hours, by: admin,
                                              schedule_template_id: template.id).payload[:shift]
    expect(shift.schedule_template_id).to eq(template.id)
    template.update!(active: false)
    expect(Professionals::ScheduleShift.call(link: link, starts_at: starts + 1.day, ends_at: starts + 1.day + 4.hours,
                                             by: admin, schedule_template_id: template.id).reason).to eq(:invalid_template)
    expect(Professionals::ScheduleShift.call(link: link, starts_at: starts + 1.day, ends_at: starts + 1.day + 4.hours,
                                             by: admin, schedule_template_id: SecureRandom.uuid).reason).to eq(:invalid_template)
    expect(Professionals::ScheduleShift.call(link: link, starts_at: starts + 1.day, ends_at: starts + 1.day + 4.hours,
                                             by: admin, schedule_template_id: "não-é-uuid").reason).to eq(:invalid_template)
    expect(ProfessionalShift.where(professional_link: link).count).to eq(1)
  end

  it "troca e tira o modelo do turno, sem mexer no horário marcado; turno cancelado recusa" do
    shift = shift!(link, starts_at: starts)
    appt = appointment_row!(triage_request!(Citizen.create!(cpf: "52998224725", phone: "+5541998765432"), unit: unit),
                            shift, starts_at: starts + 1.hour)
    expect(Professionals::SetShiftTemplate.call(shift: shift, schedule_template_id: template.id, by: admin)).to be_ok
    expect(shift.reload.schedule_template_id).to eq(template.id)
    expect(Professionals::SetShiftTemplate.call(shift: shift, schedule_template_id: nil, by: admin)).to be_ok
    expect(shift.reload.schedule_template_id).to be_nil
    expect(appt.reload).to have_attributes(scheduled_at: starts + 1.hour, shift_id: shift.id, status: "confirmed")
    expect(DomainEvent.where(name: "professional.shift_template_set").pluck(:payload)).to contain_exactly(
      { "shift_id" => shift.id, "schedule_template_id" => template.id, "by_user_id" => admin.id },
      { "shift_id" => shift.id, "schedule_template_id" => nil, "by_user_id" => admin.id }
    )

    template.update!(active: false)
    expect(Professionals::SetShiftTemplate.call(shift: shift, schedule_template_id: template.id, by: admin).reason)
      .to eq(:invalid_template)
    expect(shift.reload.schedule_template_id).to be_nil

    template.update!(active: true)
    shift.update!(cancelled_at: Time.current, cancelled_by_user: admin, cancel_reason: "troca de escala")
    expect(Professionals::SetShiftTemplate.call(shift: shift, schedule_template_id: template.id, by: admin).reason)
      .to eq(:already_cancelled)
    expect(shift.reload.schedule_template_id).to be_nil
    expect(DomainEvent.where(name: "professional.shift_template_set").count).to eq(2)
  end

  it "tipo padrão do vínculo: só tipo ativo que serve o CBO; nil limpa; vínculo encerrado recusa" do
    expect(Professionals::SetLinkDefaultType.call(link: link, appointment_type_key: "retorno", by: admin)).to be_ok
    expect(link.reload.default_appointment_type_key).to eq("retorno")
    expect(DomainEvent.where(name: "professional.link_default_type_set").sole.payload)
      .to eq("professional_link_id" => link.id, "appointment_type_key" => "retorno", "by_user_id" => admin.id)
    expect(Professionals::SetLinkDefaultType.call(link: link, appointment_type_key: "consulta_enfermagem", by: admin).reason)
      .to eq(:type_not_served)
    expect(Professionals::SetLinkDefaultType.call(link: link, appointment_type_key: "fantasma", by: admin).reason)
      .to eq(:type_not_served)
    AppointmentType.find_by!(key: "consulta_medica").update!(active: false)
    expect(Professionals::SetLinkDefaultType.call(link: link, appointment_type_key: "consulta_medica", by: admin).reason)
      .to eq(:inactive_type)
    expect(link.reload.default_appointment_type_key).to eq("retorno")
    expect(Professionals::SetLinkDefaultType.call(link: link, appointment_type_key: nil, by: admin)).to be_ok
    expect(link.reload.default_appointment_type_key).to be_nil

    link.update!(ended_at: Time.current, ended_by_user: admin)
    expect(Professionals::SetLinkDefaultType.call(link: link, appointment_type_key: "retorno", by: admin).reason)
      .to eq(:already_ended)
    expect(link.reload.default_appointment_type_key).to be_nil
  end
end
