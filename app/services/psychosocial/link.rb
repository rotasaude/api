# O vínculo do paciente com o CAPS visto pela UBS (ADR 0049; contrato §7,
# P10, P27, P44, P46): a matrícula aberta mais antiga (started_on, created_at, id)
# e os casos compartilhados no matriciamento com as equipes das unidades em
# que quem lê tem professional_links ativo — fora os de matriciamento cuja
# ação foi cancelada (P44 D2). Sem matrícula aberta (nunca matriculado, ou de
# alta), os casos da equipe continuam visíveis: `{ enrolled: false,
# shared_cases }`, e `{ enrolled: false }` quando não há caso (P44 D1). Nunca
# CID, substância, PTS, evolução nem ação. Genérico (P46): o nome de um CAPS
# AD revela uso de substância, então da unidade sai só o telefone (nulo quando
# não cadastrado) — nunca nome, id nem modalidade —, mais o início, o nome do
# técnico de referência e, de cada caso, a data e o texto compartilhado. Quem chama confere o contexto de leitura
# (ClinicalRecord::Access) e grava a trilha quando há caso.
module Psychosocial
  module Link
    module_function

    # -> { enrolled: false, shared_cases:? } |
    #    { enrolled: true, caps: { phone }, since:, reference:, shared_cases: [ { held_on, shared_text } ] }
    def for(patient:, viewer:)
      cases = shared_cases(patient, viewer)
      enrollment = PsychosocialEnrollment.open_enrollments.where(patient_id: patient.id)
                                         .includes(:health_unit, reference_user: :professional)
                                         .order(:started_on, :created_at, :id).first
      return cases.empty? ? { "enrolled" => false } : { "enrolled" => false, "shared_cases" => cases } unless enrollment

      { "enrolled" => true, "caps" => { "phone" => enrollment.health_unit.phone },
        "since" => Json.date(enrollment.started_on),
        "reference" => { "name" => Screenings::Json.staff_name(enrollment.reference_user) },
        "shared_cases" => cases }
    end

    # Casos do paciente cujas equipes ficam nas unidades de vínculo ativo de
    # quem lê, de matriciamento com a ação não cancelada.
    def shared_cases(patient, viewer)
      unit_ids = ProfessionalLink.active.joins(:professional).where(professionals: { user_id: viewer.id }).select(:health_unit_id)
      PsychosocialMatrixCase.joins(psychosocial_matrix_support: %i[health_team psychosocial_action])
                            .where(patient_id: patient.id, health_teams: { health_unit_id: unit_ids },
                                   psychosocial_actions: { cancelled_at: nil })
                            .includes(:psychosocial_matrix_support)
                            .order("psychosocial_matrix_supports.held_on DESC, psychosocial_matrix_cases.created_at DESC, psychosocial_matrix_cases.id DESC")
                            .map do |matrix_case|
        { "held_on" => Json.date(matrix_case.psychosocial_matrix_support.held_on), "shared_text" => matrix_case.shared_text }
      end
    end

    private_class_method :shared_cases
  end
end
