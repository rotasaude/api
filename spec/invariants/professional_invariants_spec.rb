require "rails_helper"

# Módulo 10, critério de fechamento (ADR 0021; spec 2026-09-27 §7.1). Cada
# bloco tem a mutação que precisa deixá-lo vermelho (registrada no relatório
# da fatia 4).
RSpec.describe "Invariantes dos profissionais (ADR 0021)", type: :request do
  before { Current.city = TEST_CITY_A; Rails.cache.clear }
  after { Current.reset }

  let(:admin) { staff_with("admin@cidade.gov.br", "municipal_admin") }
  let(:reception) { staff_with("recepcao@cidade.gov.br", "citizen_verifier") }
  let(:doctor) { staff_with("medica@cidade.gov.br", "health_professional") }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:unit) { create_unit }
  let(:attrs) do
    { professional_name: "Helena", council: "CRM", council_state: "PR", registration_number: "12345", cns: "700000000000005" }
  end

  def profile! = Professionals::Create.call(user_id: doctor.id, attrs: attrs, by: admin).payload[:professional]
  def sql(statement) = ApplicationRecord.transaction(requires_new: true) { ApplicationRecord.connection.execute(statement) }

  # Mutação: remover o índice único de professionals.user_id.
  it "perfil 1:1 com o usuário, garantido pelo banco" do
    profile!
    expect do
      sql("INSERT INTO professionals (id, user_id, professional_name, council, council_state, registration_number, cns, " \
          "created_at, updated_at) VALUES (gen_random_uuid(), '#{doctor.id}', 'X', 'CRM', 'PR', '999', 'x', now(), now())")
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  # Mutação: tirar a checagem de papel de Professionals::Create.
  it "perfil só para quem tem o papel" do
    expect(Professionals::Create.call(user_id: reception.id, attrs: attrs, by: admin).reason).to eq(:missing_role)
  end

  # Mutação: desligar professional_links_guard.
  it "vínculo só por acréscimo" do
    link = link_professional!(doctor, unit)
    expect { sql("DELETE FROM professional_links WHERE id = '#{link.id}'") }.to raise_error(ActiveRecord::StatementInvalid)
    expect { sql("UPDATE professional_links SET cbo_code = '225124' WHERE id = '#{link.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid)
    Professionals::EndLink.call(link: link, by: admin)
    expect { sql("UPDATE professional_links SET ended_at = now() WHERE id = '#{link.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid)
  end

  # Mutação: remover idx_professional_links_one_active.
  it "um vínculo ativo por (profissional, unidade, CBO)" do
    link = link_professional!(doctor, unit)
    expect do
      ProfessionalLink.create!(professional: link.professional, health_unit: unit, cbo_code: "225125",
                               started_at: Time.current, started_by_user: admin)
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  describe "turnos" do
    let(:link) { link_professional!(doctor, unit) }
    let(:day) { Time.zone.tomorrow.in_time_zone }
    let(:shift) do
      Professionals::ScheduleShift.call(link: link, starts_at: day.change(hour: 7), ends_at: day.change(hour: 13), by: admin)
                                  .payload[:shift]
    end

    # Mutação: remover professional_shifts_guard, a EXCLUDE ou o CHECK de janela.
    it "só por acréscimo, sem sobreposição, até 24h" do
      expect { sql("DELETE FROM professional_shifts WHERE id = '#{shift.id}'") }.to raise_error(ActiveRecord::StatementInvalid)
      expect { sql("UPDATE professional_shifts SET starts_at = starts_at - interval '1 hour' WHERE id = '#{shift.id}'") }
        .to raise_error(ActiveRecord::StatementInvalid)
      expect do
        ProfessionalShift.create!(professional_link: link, professional: link.professional, created_by_user: admin,
                                  starts_at: shift.starts_at + 1.hour, ends_at: shift.ends_at + 1.hour)
      end.to raise_error(ActiveRecord::ExclusionViolation)
      expect do
        ProfessionalShift.create!(professional_link: link, professional: link.professional, created_by_user: admin,
                                  starts_at: day + 2.days, ends_at: day + 3.days + 1.minute)
      end.to raise_error(ActiveRecord::StatementInvalid)
    end

    # Mutação: tirar o cancelamento de EndLink (e o IF de vínculo encerrado do trigger).
    it "não existe turno válido futuro em vínculo encerrado" do
      shift
      Professionals::EndLink.call(link: link, by: admin)
      expect(shift.reload.cancelled_at).to be_present
      expect(link.shifts.valid_shifts.where("starts_at > ?", Time.current)).to be_empty
      expect(Professionals::ScheduleShift.call(link: link, starts_at: day + 2.days, ends_at: day + 2.days + 1.hour,
                                               by: admin).reason).to eq(:link_ended)
    end
  end

  # Mutação: trocar require_admin por require_attendance_staff num dos controllers.
  describe "só o municipal_admin cadastra" do
    (Membership::ROLES - %w[municipal_admin]).each do |role|
      it "#{role}: 403 em toda rota de escrita, com step-up aberto" do
        link = link_professional!(doctor, unit)
        sign_in_as(staff_with("#{role}@c.gov.br", role)).update!(mfa_verified_at: Time.current)
        [
          [ "/professionals", attrs.merge(user_id: doctor.id) ],
          [ "/professionals/#{link.professional_id}", { council_state: "SC" } ],
          [ "/professionals/#{link.professional_id}/links", { health_unit_id: unit.id, cbo_code: "225124" } ],
          [ "/professionals/links/#{link.id}/end", {} ],
          [ "/professionals/links/#{link.id}/shifts", { starts_at: 1.day.from_now.iso8601, ends_at: (1.day.from_now + 1.hour).iso8601 } ],
          [ "/professionals/shifts/#{SecureRandom.uuid}/cancel", { reason: "x" } ]
        ].each do |path, params|
          json_post path, params
          expect(response).to have_http_status(:forbidden), "#{role} POST #{path}"
        end
        expect(link.reload.ended_at).to be_nil
        expect(ProfessionalShift.count).to eq(0)
      end
    end
  end

  # Mutação: tirar o `check` de Attendances::Call e de Attendances::Close.
  describe "chamada e desfecho exigem papel + vínculo com a unidade do atendimento" do
    let(:other_unit) { create_unit("UPA Norte", kind: "upa") }

    # Um atendimento só: as recusas não mudam o estado, então o mesmo
    # atendimento serve a todas as tentativas.
    let(:attendance) { waiting_attendance(citizen, unit: unit, by: reception) }

    def call(by) = Attendances::Call.call(attendance: attendance.reload, health_unit_id: unit.id, by: by)

    it "sem papel: missing_role" do
      expect(call(reception).reason).to eq(:missing_role)
    end

    it "sem vínculo, vínculo em outra unidade, vínculo encerrado: missing_link" do
      expect(call(doctor).reason).to eq(:missing_link)
      other = link_professional!(doctor, other_unit)
      expect(call(doctor).reason).to eq(:missing_link)
      mine = link_professional!(doctor, unit)
      Professionals::EndLink.call(link: mine, by: admin)
      expect(call(doctor).reason).to eq(:missing_link)
      expect(other.reload).to be_active
    end

    it "desfecho clínico sem vínculo: missing_link; left pela recepção: ok" do
      in_care!(attendance, by: doctor)
      expect(Attendances::Close.call(attendance: attendance, outcome: "discharged", referral_unit_id: nil,
                                     referral_note: nil, by: doctor).reason).to eq(:missing_link)
      waiting = waiting_attendance(Citizen.create!(cpf: "11144477735", phone: "+5541998765433"), unit: unit, by: reception)
      expect(Attendances::Close.call(attendance: waiting, outcome: "left", referral_unit_id: nil,
                                     referral_note: nil, by: reception)).to be_ok
    end
  end

  # Mutação: fazer ClinicalAuthorization exigir turno válido no instante.
  it "turno nunca bloqueia ato clínico: vinculado sem turno, e com turno cancelado, chama e fecha" do
    link = link_professional!(doctor, unit)
    day = Time.zone.tomorrow.in_time_zone
    shift = Professionals::ScheduleShift.call(link: link, starts_at: day.change(hour: 7), ends_at: day.change(hour: 13),
                                              by: admin).payload[:shift]
    Professionals::CancelShift.call(shift: shift, reason: "troca", by: admin)

    attendance = waiting_attendance(citizen, unit: unit, by: reception)
    expect(Attendances::Call.call(attendance: attendance, health_unit_id: unit.id, by: doctor)).to be_ok
    expect(Attendances::Close.call(attendance: attendance.reload, outcome: "discharged", referral_unit_id: nil,
                                   referral_note: nil, by: doctor)).to be_ok
  end

  # Mutação: pôr `cns: professional.cns` no payload de professional.created.
  it "nenhum evento professional.* carrega dado sensível" do
    professional = profile!
    professional.update!(phone: "41998765432", contact_email: "helena@ubs.org")
    Professionals::UpdateProfile.call(professional: professional, attrs: { "professional_name" => "Helena D." }, by: admin)
    link = Professionals::OpenLink.call(professional: professional, health_unit_id: unit.id, cbo_code: "225125", by: admin)
                                  .payload[:link]
    day = Time.zone.tomorrow.in_time_zone
    shift = Professionals::ScheduleShift.call(link: link, starts_at: day.change(hour: 7), ends_at: day.change(hour: 13),
                                              by: admin).payload[:shift]
    Professionals::CancelShift.call(shift: shift, reason: "troca", by: admin)
    Professionals::EndLink.call(link: link, by: admin)

    payloads = DomainEvent.where("name LIKE 'professional.%'").map { |e| e.payload.to_json }
    expect(payloads.size).to eq(6)
    [ professional.cns, professional.registration_number, "41998765432", "helena@ubs.org", "Helena" ].each do |secret|
      expect(payloads).to all(satisfy { |p| !p.include?(secret) }), "vazou #{secret}"
    end
  end
end
