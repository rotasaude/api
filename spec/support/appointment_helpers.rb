module AppointmentHelpers
  def staff_with(email, *roles)
    User.create!(email_address: email, password: "senha-segura-123").tap do |u|
      roles.each { |r| Membership.create!(user: u, role: r, granted_at: Time.current) }
    end
  end

  # Atendimento aberto por check-in por código (caminho real), já na unidade.
  def waiting_attendance(citizen, unit:, by:)
    triage = completed_web_triage_for(citizen)
    code = Citizens::IssueCheckInCode.call(citizen: citizen, triage: triage).payload.fetch(:code)
    Attendances::CheckIn.call(cpf: citizen.cpf, code: code, health_unit_id: unit.id, document_checked: false, by: by)
                        .payload.fetch(:attendance)
  end

  def in_care!(attendance, by:)
    attendance.update!(status: "in_care", called_by_user: by, called_at: Time.current)
    attendance
  end

  # F-10.5: chamar e registrar desfecho clínico exigem vínculo ativo com a
  # unidade. Cria o perfil (se faltar) e abre o vínculo direto no banco.
  def link_professional!(user, unit, cbo: "225125")
    professional = user.professional || Professional.create!(
      user: user, professional_name: user.email_address.split("@").first.capitalize, council: "CRM",
      council_state: "PR", registration_number: (Professional.count + 10_000).to_s,
      cns: Professionals::Cns.generate(user.id)
    )
    admin = User.joins(:memberships).merge(Membership.active.where(role: "municipal_admin")).first ||
            staff_with("admin-link-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin")
    ProfessionalLink.create!(professional: professional, health_unit: unit, cbo_code: cbo,
                             started_at: Time.current, started_by_user: admin)
  end

  # Grava o pedido direto (cenário de teste); o caminho real é Attendances::Close.
  def request_for(attendance, kind: "return", target: attendance.health_unit)
    AppointmentRequest.create!(origin_attendance: attendance, citizen: attendance.citizen,
                               root_triage: attendance.root_triage, origin_unit: attendance.health_unit,
                               target_unit: target, kind: kind)
  end
end

RSpec.configure { |c| c.include AppointmentHelpers }
