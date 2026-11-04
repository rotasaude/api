# O vínculo do paciente com o CAPS visto pela UBS (ADR 0049; contrato §7,
# P10, P27): a matrícula aberta mais antiga (started_on, created_at, id) e os
# casos compartilhados no matriciamento com as equipes das unidades em que
# quem lê tem professional_links ativo. Nunca CID, substância, PTS, evolução
# nem ação: só o CAPS (nome e telefone, nulo quando não cadastrado), o início,
# o nome do técnico de referência e o texto compartilhado. Quem chama confere o
# contexto de leitura (ClinicalRecord::Access) e grava a trilha.
module Psychosocial
  module Link
    module_function

    # -> { enrolled: false } | { enrolled: true, caps:, since:, reference:, shared_cases: [ { held_on, caps_name, shared_text } ] }
    def for(patient:, viewer:)
      enrollment = PsychosocialEnrollment.open_enrollments.where(patient_id: patient.id)
                                         .includes(:health_unit, reference_user: :professional)
                                         .order(:started_on, :created_at, :id).first
      return { "enrolled" => false } unless enrollment

      caps = enrollment.health_unit
      { "enrolled" => true, "caps" => { "id" => caps.id, "name" => caps.name, "phone" => caps.phone },
        "since" => Json.date(enrollment.started_on),
        "reference" => { "name" => Screenings::Json.staff_name(enrollment.reference_user) },
        "shared_cases" => shared_cases(patient, viewer) }
    end

    # Casos do paciente cujas equipes ficam nas unidades de vínculo ativo de quem lê.
    def shared_cases(patient, viewer)
      unit_ids = ProfessionalLink.active.joins(:professional).where(professionals: { user_id: viewer.id }).select(:health_unit_id)
      PsychosocialMatrixCase.joins(psychosocial_matrix_support: :health_team)
                            .where(patient_id: patient.id, health_teams: { health_unit_id: unit_ids })
                            .includes(psychosocial_matrix_support: :health_unit)
                            .order("psychosocial_matrix_supports.held_on DESC, psychosocial_matrix_cases.created_at DESC, psychosocial_matrix_cases.id DESC")
                            .map do |matrix_case|
        support = matrix_case.psychosocial_matrix_support
        { "held_on" => Json.date(support.held_on), "caps_name" => support.health_unit.name, "shared_text" => matrix_case.shared_text }
      end
    end

    private_class_method :shared_cases
  end
end
