# Transcrição da caderneta de papel na sala (ADR 0047, Desvios 9, 10, 12 e 13;
# contrato §5; §15 V14, V19).
#
# Cada item: `immunobiological_code` e `dose_code` ativos, `applied_on`
# (AAAA-MM-DD, não futuro na cidade e não antes do nascimento), e em texto
# livre opcional `lot_number` (≤ 40), `manufacturer_name` (≤ 120, V19: sem a
# chave do catálogo) e `place` (≤ 120); texto em branco vira nulo. De 1 a
# MAX_TRANSCRIPTION_ITEMS itens. Todas as recusas de uma vez, com o path
# `items[i].<campo>`.
#
# Gravação: a dose `transcription: true`, `applied_at` = `applied_on` 12:00 no
# fuso da cidade, estratégia `1`, sem lote do estoque nem movimento; a fila
# RNDS (prazo = criação + 24 h); com `close_check: true`, a conferência
# `transcribed` (imutável); a situação materializada; uma trilha pela pessoa
# mostrada; `vaccination.immunization_recorded` por dose, só ids. Lote,
# fabricante e local cifrados; nada deles em log, evento ou erro.
module Vaccination
  module RecordTranscription
    ROUTINE = "1".freeze
    LOT_MAX = 40
    NOON = 12
    DATE = /\A\d{4}-\d{2}-\d{2}\z/

    module_function

    # -> Result.ok(immunizations:, card:) | fail(:invalid, details: { path:, problems: }) | fail(:missing_role)
    def call(room:, patient:, items:, close_check:, by:, now: Time.current, replaces: nil)
      link = Access.vaccinator_link(user: by, room: room)
      return Result.fail(:missing_role) unless link

      rnds_usable = Rnds::Gate.usable?(Current.city)
      today = now.in_time_zone.to_date
      problems = []
      problems << { path: "items", error: "invalid_request" } unless items.is_a?(Array) && items.size.between?(1, Catalog::MAX_TRANSCRIPTION_ITEMS)
      problems << { path: "close_check", error: "invalid_request" } unless [ true, false ].include?(close_check)
      return failure(problems) if problems.any?

      rows = items.each_with_index.map { |raw, index| Item.new(raw, "items[#{index}]", patient, today) }
      problems = rows.flat_map(&:problems)
      return failure(problems) if problems.any?

      Immunization.transaction(requires_new: true) do
        doses = rows.map { |row| write!(row, room: room, patient: patient, by: by, link: link, now: now, replaces: replaces) }
        if close_check
          VaccinationRecordCheck.create!(patient: patient, vaccine_room: room, checked_by_user: by, mode: "transcribed", checked_at: now)
        end
        Statuses.refresh!(patient, today: today)
        Trail.person_viewed!(user: by, patient_id: patient.id)
        Result.ok(immunizations: doses, card: Card.call(patient: patient, today: today, rnds_usable: rnds_usable, viewer: by))
      end
    end

    # Grava uma dose transcrita já conferida (também a substituta de uma
    # transcrição cancelada, Vaccination::CancelImmunization).
    def write!(row, room:, patient:, by:, link:, now:, replaces: nil)
      dose = Immunization.create!(
        patient: patient, vaccine_room: room, health_unit_id: room.health_unit_id, vaccinator_user: by, vaccinator_cbo: link.cbo_code,
        immunobiological_code: row.product.code, dose_code: row.dose_code, strategy: ROUTINE, applied_at: row.applied_at,
        transcription: true, lot_number_text: row.lot_number, manufacturer_text: row.manufacturer_name, place_text: row.place,
        replaces: replaces, calendar_version: Calendar.current.version
      )
      Rnds::Enqueue.call(dose, kind: "application", now: now)
      DomainEvents.publish("vaccination.immunization_recorded", immunization_id: dose.id, vaccine_room_id: room.id, user_id: by.id)
      dose
    end

    def failure(problems) = Result.fail(:invalid, details: { path: problems.first[:path], problems: problems })

    # Um item da transcrição: `problems` (todas as recusas, com o prefixo) e
    # os valores limpos.
    class Item
      attr_reader :product, :dose_code, :applied_at, :lot_number, :manufacturer_name, :place

      def initialize(raw, prefix, patient, today)
        @raw = raw
        @prefix = prefix
        @patient = patient
        @today = today
      end

      def problems
        return [ { path: @prefix, error: "invalid_request" } ] unless @raw.is_a?(Hash)

        @raw = @raw.transform_keys(&:to_s)
        @problems = []
        code = @raw["immunobiological_code"]
        @product = code.is_a?(String) ? Immunobiologicals.find(code) : nil
        add("immunobiological_code", "invalid_value") unless @product
        @dose_code = @raw["dose_code"]
        add("dose_code", "invalid_value") unless @dose_code.is_a?(String) && Terminologies.active?("dose", @dose_code)
        applied_on
        @lot_number = text("lot_number", LOT_MAX)
        @manufacturer_name = text("manufacturer_name", Catalog::TEXT_MAX)
        @place = text("place", Catalog::TEXT_MAX)
        @problems
      end

      private

      def add(field, error) = @problems << { path: "#{@prefix}.#{field}", error: error }

      def applied_on
        raw = @raw["applied_on"]
        on = raw.is_a?(String) && raw.match?(DATE) ? Date.iso8601(raw) : nil
        return add("applied_on", "invalid_value") unless on
        return add("applied_on", "applied_on_in_future") if on > @today

        birth = Statuses.birth_date(@patient)
        return add("applied_on", "applied_before_birth") if birth && on < birth

        @applied_at = on.in_time_zone.change(hour: NOON)
      rescue Date::Error
        add("applied_on", "invalid_value")
      end

      # Texto livre opcional: nulo ou em branco → nulo; senão até `max`.
      def text(field, max)
        raw = @raw[field]
        return nil if raw.nil?

        clean = raw.is_a?(String) ? raw.strip : nil
        return clean.presence if clean && clean.length <= max

        add(field, "invalid_value")
        nil
      end
    end

    private_class_method :failure
  end
end
