# app/services/clinical_documents/issuers.rb
# Quem emite o quê (ADR 0033; spec §4; Desvio 9). O CBO é o da consulta (o
# vínculo com que a autora atendeu). Atestado: médico e dentista (CFM
# 2.382/2024 art. 9; Lei 5.081/1966). Receita: médico, dentista e enfermeiro —
# este só por protocolo (COFEN 801/2026; a trava é da receita). Declaração e
# requisição: qualquer autora de consulta. Declaração pelo atendimento:
# recepção (citizen_verifier) ou profissional com vínculo ativo na unidade.
module ClinicalDocuments
  module Issuers
    PREFIXES = { physician: %w[2251 2252 2253], dentist: %w[2232], nurse: %w[2235] }.freeze
    MATRIX = { "sick_note" => %i[physician dentist], "prescription" => %i[physician dentist nurse],
               "attendance_declaration" => :any, "exam_requisition" => :any }.freeze

    module_function

    def role(cbo)
      code = cbo.to_s
      PREFIXES.find { |_role, prefixes| prefixes.any? { |prefix| code.start_with?(prefix) } }&.first || :other
    end

    # Tipo fora da matriz (ex.: o registro da Notificação antes de ser
    # liberado) é recusado, nunca KeyError.
    def allowed?(kind, cbo)
      allowed = MATRIX.fetch(kind.to_s, [])
      allowed == :any || allowed.include?(role(cbo))
    end

    def declaration_staff(user, attendance)
      if user.has_role?("health_professional")
        link = ProfessionalLink.active.joins(:professional).where(professionals: { user_id: user.id })
                               .where(health_unit_id: attendance.health_unit_id).order(:started_at, :id).first
        return [ :ok, link.cbo_code ] if link
      end
      user.has_role?("citizen_verifier") ? [ :ok, nil ] : [ :missing_role, nil ]
    end
  end
end
