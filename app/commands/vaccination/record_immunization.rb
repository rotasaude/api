# Registro da dose aplicada na sala (ADR 0047, Desvios 9, 12, 13 e 20;
# contrato §5; §15 V5, V14, V20; Review Focus 4).
#
# Todas as recusas de uma vez, em `problems`, na ordem:
#  1. forma, na ordem dos campos do contrato: terminologias (`invalid_value`
#     por campo; só códigos ATIVOS — grupo de atendimento inativo é recusado
#     na dose nova, V20), `applied_at` com fuso, `campaign_id`, e o
#     `override_reason` (10..500 → senão `invalid_reason`);
#  2. `dose_not_in_calendar` (estratégia `1` com par fora do calendário; as
#     outras estratégias aceitam qualquer dose da terminologia);
#  3. `applied_at_in_future` (> agora + 1 min);
#  4. lote: `invalid_value` (ausente ou malformado), `lot_not_in_room`,
#     `lot_product_mismatch` (lote de outro imunobiológico, V22),
#     `lot_expired` (validade < dia da aplicação na cidade), `lot_blocked`
#     (excursão aberta — vale também com o frasco já aberto, Review Focus 4),
#     `insufficient_balance` (unidose sem saldo);
#  5. frasco: `vial_required` (multidose sem frasco), `invalid_value`
#     (frasco de outra sala, ou frasco em unidose), `vial_lot_mismatch`,
#     `vial_expired` (vencido), `vial_closed_out` (descartado, V22), `vial_empty`;
#  6. `sex_not_allowed`, `maternal_condition_required` (V27: mulher de 10 a
#     49 anos completos na data da aplicação, sem ela; fora disso pode vir nula);
#  7. avisos `interval_too_short` / `age_out_of_range` com `overridable: true`
#     (V5), só sem `override_reason` válido.
#
# Tudo é conferido já sob as travas, na ordem do módulo: lote → local →
# frasco (a mesma do OpenVial/Pharmacy::Ledger; o frasco FOR UPDATE serializa
# com o descarte e o job de vencimento antes de contar as doses usadas).
# Gravação: a dose (o motivo do aviso cifrado), o movimento `immunization`
# (−1, só unidose), a situação materializada, a fila RNDS, a trilha da pessoa
# e o evento `vaccination.immunization_recorded` só com ids. Nada da vacina,
# do lote ou do motivo em log, evento ou erro.
module Vaccination
  module RecordImmunization
    TERMS = { "dose_code" => "dose", "strategy" => "strategy", "care_group" => "care_group",
              "route" => "route", "site" => "site" }.freeze
    ROUTINE = "1".freeze
    FUTURE_TOLERANCE = 1.minute
    ZONED = /(Z|[+-]\d{2}:?\d{2})\z/
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    # V27: idade fértil para a condição maternal — 10 anos completos até a véspera dos 50.
    CHILDBEARING_FROM = Calendar::Age.new(years: 10, months: 0, days: 0)
    CHILDBEARING_UNTIL = Calendar::Age.new(years: 50, months: 0, days: 0)

    module_function

    # attrs: Hash com as chaves String do contrato §5 (sem patient_id).
    # replaces: a dose original da substituição (Task 9), na mesma transação.
    # -> Result.ok(immunization:) | fail(:invalid, details: { path:, problems: [ { path:, error:, overridable? } ] })
    #    | fail(:missing_role) (sem vínculo de vacinador na unidade da sala)
    def call(room:, patient:, attrs:, by:, now: Time.current, replaces: nil)
      link = Access.vaccinator_link(user: by, room: room)
      return Result.fail(:missing_role) unless link

      attrs = attrs.is_a?(Hash) ? attrs.transform_keys(&:to_s) : {}
      result = nil
      Immunization.transaction(requires_new: true) do
        result = write(room: room, patient: patient, attrs: attrs, by: by, link: link, now: now, replaces: replaces)
        raise ActiveRecord::Rollback if result.failure?
      end
      result
    end

    def write(room:, patient:, attrs:, by:, link:, now:, replaces:)
      form = Form.new(attrs, room, patient, now)
      problems = form.problems
      return failure(problems) if problems.any?

      dose = Immunization.create!(
        patient: patient, vaccine_room: room, health_unit_id: room.health_unit_id, vaccinator_user: by, vaccinator_cbo: link.cbo_code,
        immunobiological_code: form.product.code, dose_code: attrs["dose_code"], strategy: attrs["strategy"], care_group: attrs["care_group"],
        route: attrs["route"], site: attrs["site"], maternal_condition: attrs["maternal_condition"], applied_at: form.applied_at,
        transcription: false, stock_lot: form.lot, vial_opening: form.vial, campaign_id: attrs["campaign_id"],
        override_reason: form.override_reason, replaces: replaces, calendar_version: Calendar.current.version
      )
      unless form.product.multidose
        Pharmacy::Ledger.record!(location: form.location, lot: form.lot, kind: "immunization", quantity: 1, by: by, document: dose, at: now)
      end
      Statuses.refresh!(patient, today: now.in_time_zone.to_date)
      Rnds::Enqueue.call(dose, kind: "application", now: now)
      Trail.person_viewed!(user: by, patient_id: patient.id)
      DomainEvents.publish("vaccination.immunization_recorded", immunization_id: dose.id, vaccine_room_id: room.id, user_id: by.id)
      Result.ok(immunization: dose)
    rescue Pharmacy::Ledger::Insufficient
      failure([ { path: "lot_id", error: "insufficient_balance" } ])
    end

    def failure(problems)
      first = problems.first
      Result.fail(:invalid, details: { path: first[:path], problems: problems })
    end

    # Conferência de um corpo, já sob as travas (lote → local → frasco).
    class Form
      attr_reader :product, :applied_at, :lot, :location, :vial, :override_reason

      def initialize(attrs, room, patient, now)
        @attrs = attrs
        @room = room
        @patient = patient
        @now = now
        @problems = []
        @valid = {}
      end

      def problems
        shape
        @entry = calendar_entry
        add("dose_code", "dose_not_in_calendar") if @product && @valid["dose_code"] && @valid["strategy"] && @attrs["strategy"] == ROUTINE && @entry.nil?
        add("applied_at", "applied_at_in_future") if @applied_at && @applied_at > @now + FUTURE_TOLERANCE
        lot_checks
        vial_checks
        person_checks
        warnings unless @override_reason
        @problems
      end

      private

      def add(path, error, **extra) = @problems << { path: path, error: error, **extra }
      def text(key) = @attrs[key].is_a?(String) ? @attrs[key] : nil
      def applied_on = (@applied_at || @now).in_time_zone.to_date

      def shape
        @product = text("immunobiological_code") && Immunobiologicals.find(@attrs["immunobiological_code"])
        add("immunobiological_code", "invalid_value") unless @product
        TERMS.each do |key, kind|
          @valid[key] = text(key) && Terminologies.active?(kind, @attrs[key])
          add(key, "invalid_value") unless @valid[key]
        end
        maternal = @attrs["maternal_condition"]
        add("maternal_condition", "invalid_value") unless maternal.nil? || (text("maternal_condition") && Terminologies.active?("maternal_condition", maternal))
        @applied_at = parse_time(@attrs["applied_at"])
        add("applied_at", "invalid_value") unless @applied_at
        campaign = @attrs["campaign_id"]
        add("campaign_id", "invalid_value") unless campaign.nil? || (text("campaign_id")&.match?(UUID) && Campaign.exists?(id: campaign))
        reason
      end

      def reason
        raw = @attrs["override_reason"]
        return if raw.nil?

        clean = raw.is_a?(String) ? raw.strip : nil
        if clean && Catalog::REASON.cover?(clean.length)
          @override_reason = clean
        else
          add("override_reason", "invalid_reason")
        end
      end

      def parse_time(raw)
        return nil unless raw.is_a?(String) && raw.match?(ZONED)

        Time.iso8601(raw).in_time_zone
      rescue ArgumentError
        nil
      end

      def calendar_entry
        return nil unless @product && @valid["dose_code"]

        Calendar.current.entry(@product.code, @attrs["dose_code"])
      end

      # Trava o lote (FOR UPDATE) e o local (FOR SHARE), nessa ordem.
      def lot_checks
        id = text("lot_id")
        locked = id&.match?(UUID) ? Pharmacy::Ledger.lock_lots!([ id ])[id] : nil
        @location = Pharmacy::Ledger.lock_location!(@room.stock_location_id)
        return add("lot_id", "invalid_value") unless id&.match?(UUID)
        return add("lot_id", "lot_not_in_room") unless in_room?(locked)
        return add("lot_id", "lot_product_mismatch") if @product && Immunobiologicals.normalize(locked.immunobiological_code) != @product.code

        @lot = locked
        add("lot_id", "lot_expired") if locked.expires_on < applied_on
        if StockLotBlock.open_blocks.exists?(stock_location_id: @location.id, stock_lot_id: locked.id)
          add("lot_id", "lot_blocked")
        elsif @product && !@product.multidose && Pharmacy::Ledger.balance(location_id: @location.id, lot_id: locked.id) < 1
          add("lot_id", "insufficient_balance")
        end
      rescue Pharmacy::Ledger::Inactive
        @location = nil
        add("lot_id", "lot_not_in_room")
      end

      def in_room?(lot)
        lot && @location && Stock::Domain.immunobiological?(@location) && lot.immunobiological? &&
          StockMovement.exists?(stock_location_id: @location.id, stock_lot_id: lot.id)
      end

      # Depois do lote e do local: o frasco FOR UPDATE, e só então as doses usadas.
      def vial_checks
        id = @attrs["vial_id"]
        return unless @product
        return add("vial_id", "invalid_value") if !@product.multidose && !id.nil?
        return unless @product.multidose
        return add("vial_id", "vial_required") if id.nil?

        vial = text("vial_id")&.match?(UUID) ? VialOpening.lock("FOR UPDATE").find_by(id: id, vaccine_room_id: @room.id) : nil
        return add("vial_id", "invalid_value") unless vial
        return add("vial_id", "vial_lot_mismatch") if @lot.nil? || vial.stock_lot_id != @lot.id
        status = vial.status(@now)
        return add("vial_id", "vial_closed_out") if status == "closed_out"
        return add("vial_id", "vial_expired") unless status == "open"
        return add("vial_id", "vial_empty") if vial.doses_used >= vial.doses_per_vial

        @vial = vial
      end

      def person_checks
        series = @entry&.first
        add("immunobiological_code", "sex_not_allowed") if series&.sex && series.sex != @patient.sex
        add("maternal_condition", "maternal_condition_required") if @attrs["maternal_condition"].nil? && childbearing_age?
      end

      # V27: sexo feminino com 10 a 49 anos completos em `applied_on` (dia da
      # cidade), por aritmética de calendário (Calendar::Age). Sem nascimento
      # conhecido, continua exigindo (como antes).
      def childbearing_age?
        return false unless @patient.sex == "female"

        birth = Statuses.birth_date(@patient)
        return true unless birth

        CHILDBEARING_FROM.reached?(birth, applied_on) && !CHILDBEARING_UNTIL.reached?(birth, applied_on)
      end

      # Avisos que aceitam motivo (V5): intervalo desde a dose anterior da série
      # e a faixa de idade da dose (aritmética de calendário).
      def warnings
        return unless @entry && @applied_at

        series, dose = @entry
        add("dose_code", "interval_too_short", overridable: true) if interval_too_short?(series, dose)
        birth = Statuses.birth_date(@patient)
        add("dose_code", "age_out_of_range", overridable: true) if birth && dose.age_status(birth: birth, on: applied_on) != :ok
      end

      def interval_too_short?(series, dose)
        return false unless dose.min_interval_days && series.doses.index(dose).to_i.positive?

        previous = Statuses.doses_of(@patient.id).select { |d| series.accepts.include?(Immunobiologicals.normalize(d[:code])) && d[:on] <= applied_on }.last
        previous.present? && (applied_on - previous[:on]) < dose.min_interval_days
      end
    end

    private_class_method :write, :failure
  end
end
