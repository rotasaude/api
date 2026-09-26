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

  # Grava o pedido direto (cenário de teste); o caminho real é Attendances::Close.
  def request_for(attendance, kind: "return", target: attendance.health_unit)
    AppointmentRequest.create!(origin_attendance: attendance, citizen: attendance.citizen,
                               root_triage: attendance.root_triage, origin_unit: attendance.health_unit,
                               target_unit: target, kind: kind)
  end
end

RSpec.configure { |c| c.include AppointmentHelpers }
