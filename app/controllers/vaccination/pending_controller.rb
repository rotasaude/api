# GET /vaccination/rooms/:room_id/pending?before=&limit= (contrato §5; §15 V7,
# V8; dashboard D10) → { items: [ { immunization_id, patient_id,
# immunobiological: { code, name }, applied_at, rnds: <rnds> } ],
# counts: { blocked, rejected, failed, late }, next_before }.
# Vacinador ou responsável da sala (outra sala → 403). Sem nome, CPF nem CNS e
# sem trilha (Desvio 20). As regras de quem entra: Vaccination::Pending.
module Vaccination
  class PendingController < BaseController
    DEFAULT_LIMIT = 50
    MAX_LIMIT = 100

    def index
      room = member_room or return
      return unless query_only!(:before, :limit)

      limit = page_limit or return
      cursor = params.key?(:before) ? Pharmacy::Cursor.decode(params[:before]) : nil
      return render_refusal("before", "invalid_cursor") if params.key?(:before) && !valid_cursor?(cursor)

      now = Time.current
      enabled = Rnds::Gate.enabled?(Current.city)
      scope = Pending.scope(room, rnds_enabled: enabled, now: now)
      if cursor
        scope = scope.where("(immunizations.applied_at, rnds_outbox.id) < (?, ?)", Time.iso8601(cursor.first), cursor.last)
      end
      rows = scope.preload(:immunization).limit(limit + 1).to_a
      page = rows.first(limit)
      render json: { items: page.map { |entry| item(entry, enabled) }, counts: Pending.counts(room, rnds_enabled: enabled, now: now),
                     next_before: rows.size > limit ? Pharmacy::Cursor.encode([ page.last.immunization.applied_at.utc.iso8601(6), page.last.id ]) : nil }
    end

    private

    def item(entry, enabled)
      dose = entry.immunization
      { immunization_id: dose.id, patient_id: dose.patient_id,
        immunobiological: { code: dose.immunobiological_code, name: Immunobiologicals.find(dose.immunobiological_code)&.name },
        applied_at: dose.applied_at, rnds: Json.rnds(entry, enabled) }
    end

    def page_limit
      raw = params[:limit]
      return DEFAULT_LIMIT if raw.blank?

      value = Integer(raw.to_s, 10, exception: false)
      return value if value&.between?(1, MAX_LIMIT)

      render_refusal("limit", "invalid_limit")
      nil
    end

    def valid_cursor?(cursor)
      return false unless cursor && cursor.size == 2 && uuid?(cursor.last)

      Time.iso8601(cursor.first)
      true
    rescue ArgumentError
      false
    end
  end
end
