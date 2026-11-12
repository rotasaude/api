# Linha do tempo que o cidadão lê (ADR 0051; contrato §3; Q4). Só os eventos
# `visible_to_citizen` dos tipos de Catalog::CITIZEN_EVENT_KINDS, cada um
# `{ kind, at, text? }` — nunca o ator, o nome de quem respondeu, o `data`, o
# extrato nem o encaminhamento. O texto só vai nos tipos que falam com o
# cidadão (TEXT_KINDS); no `archived`, o rótulo do motivo nas palavras dele
# (Catalog::ARCHIVE_REASON_CITIZEN_LABELS, pelo `data.reason` do evento).
module Ombudsman
  module Timeline
    TEXT_KINDS = %w[complement_requested extended interim_response final_response reopen_rejected].freeze

    module_function

    # `events`: os da manifestação, na ordem (created_at, id).
    def citizen(events)
      events.select { |event| event.visible_to_citizen && Catalog::CITIZEN_EVENT_KINDS.include?(event.kind) }
            .map { |event| citizen_item(event) }
    end

    def citizen_item(event)
      item = { kind: event.kind, at: event.created_at.iso8601 }
      text = if event.kind == "archived"
        Catalog::ARCHIVE_REASON_CITIZEN_LABELS[event.data["reason"]]
      elsif TEXT_KINDS.include?(event.kind)
        event.text
      end
      item[:text] = text if text.present?
      item
    end

    private_class_method :citizen_item
  end
end
