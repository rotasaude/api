# Junção da linha do tempo (ADR 0035; spec §4): cada fornecedor devolve até
# limit + 1 entradas depois do cursor; aqui junta, ordena pela chave total e
# corta. Se sobrou alguma, há próxima página e next_before é o cursor da
# última entrada mostrada.
module Timeline
  module Query
    DEFAULT_LIMIT = 50
    MAX_LIMIT = 100
    DOCUMENT_KINDS = %w[clinical_document controlled_notification].freeze
    DECLARED_KINDS = %w[triage appointment].freeze
    # 27a (H7): só o profissional vê; nunca entra na visão do cidadão.
    PROFESSIONAL_ONLY_KINDS = %w[dispensation].freeze
    # Módulo 31 (ADR 0049; contrato §10, P18): os kinds do CAPS ficam FORA de
    # Timeline::KINDS, então o cidadão, o PEC externo e todo filtro que valida
    # contra KINDS nunca os veem. O marcador do vínculo entra só na lista do
    # profissional (PROFESSIONAL_KINDS); a fonte do CAPS, só na rota da equipe
    # lotada (GET /psychosocial/enrollments/:id/timeline), sempre recortada
    # pelo CAPS da matrícula (`psychosocial_unit_id`). O cursor aceita os dois.
    LINK_KINDS = %w[psychosocial_link].freeze
    CAPS_ONLY_KINDS = %w[psychosocial].freeze
    PROFESSIONAL_KINDS = (Timeline::KINDS + LINK_KINDS).freeze
    CURSOR_KINDS = (PROFESSIONAL_KINDS + CAPS_ONLY_KINDS).freeze
    SOURCES = {
      "triage" => Sources::TriageSource, "attendance" => Sources::AttendanceSource,
      "screening" => Sources::ScreeningSource, "appointment" => Sources::AppointmentSource,
      "consultation" => Sources::ConsultationSource, "clinical_document" => Sources::ClinicalDocumentSource,
      "controlled_notification" => Sources::ControlledNotificationSource, "campaign" => Sources::CampaignSource,
      "exam" => Sources::ExamSource, "procedure" => Sources::ProcedureSource,
      "dispensation" => Sources::DispensationSource, "vaccination" => Sources::VaccinationSource,
      "transport" => Sources::TransportSource, "psychosocial" => Sources::PsychosocialSource,
      "psychosocial_link" => Sources::PsychosocialLinkSource
    }.freeze

    Page = Data.define(:entries, :next_before)

    module_function

    # `active_vaccinations_only: true` (cidadão e PEC externo): a vacina só traz doses ativas, sem canceladas (29; W4).
    # `psychosocial_unit_id`: o CAPS da matrícula, único recorte da fonte do CAPS (sem ele, a fonte não traz nada).
    def call(person:, kinds: Timeline::KINDS, before: nil, limit: DEFAULT_LIMIT, from: nil, to: nil, active_vaccinations_only: false,
             psychosocial_unit_id: nil)
      rows = kinds.flat_map do |kind|
        args = { person: person, before: before, limit: limit + 1, from: from, to: to }
        args[:active_only] = true if active_vaccinations_only && kind == "vaccination"
        args[:health_unit_id] = psychosocial_unit_id if CAPS_ONLY_KINDS.include?(kind)
        SOURCES.fetch(kind).entries(**args)
      end
      rows.sort_by!(&:sort_key)
      page = rows.first(limit)
      Page.new(entries: page, next_before: rows.size > limit ? Cursor.encode(page.last) : nil)
    end

    def limit(raw)
      value = raw.is_a?(Integer) ? raw : (raw.is_a?(String) && raw.match?(/\A\d+\z/) ? raw.to_i : nil)
      return DEFAULT_LIMIT if value.nil? || value < 1

      [ value, MAX_LIMIT ].min
    end

    def citizen_kinds(verified:, documents:)
      return DECLARED_KINDS.dup unless verified

      kinds = Timeline::KINDS - PROFESSIONAL_ONLY_KINDS
      documents ? kinds : kinds - DOCUMENT_KINDS
    end
  end
end
