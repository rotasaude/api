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
    SOURCES = {
      "triage" => Sources::TriageSource, "attendance" => Sources::AttendanceSource,
      "screening" => Sources::ScreeningSource, "appointment" => Sources::AppointmentSource,
      "consultation" => Sources::ConsultationSource, "clinical_document" => Sources::ClinicalDocumentSource,
      "controlled_notification" => Sources::ControlledNotificationSource, "campaign" => Sources::CampaignSource,
      "exam" => Sources::ExamSource
    }.freeze

    Page = Data.define(:entries, :next_before)

    module_function

    def call(person:, kinds: Timeline::KINDS, before: nil, limit: DEFAULT_LIMIT, from: nil, to: nil)
      rows = kinds.flat_map do |kind|
        SOURCES.fetch(kind).entries(person: person, before: before, limit: limit + 1, from: from, to: to)
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

      documents ? Timeline::KINDS.dup : Timeline::KINDS - DOCUMENT_KINDS
    end
  end
end
